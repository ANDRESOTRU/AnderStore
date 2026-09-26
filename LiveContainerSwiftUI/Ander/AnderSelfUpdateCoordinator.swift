import Combine
import Foundation
import UIKit
import UserNotifications

/// Owns the operation and VPN lease independently of any screen's lifetime.
@MainActor
final class AnderSelfUpdateCoordinator: ObservableObject {
    static let shared = AnderSelfUpdateCoordinator()
    @Published private(set) var state = AnderSelfUpdateState()
    @Published private(set) var delayed = false
    @Published private(set) var errorText: String?
    @Published private(set) var showSuccess = false
    private var operation: Task<Void, Never>?
    private var polling = false
    private var lastPoll: TimeInterval = 0
    private var subscriptions = Set<AnyCancellable>()
    private var confirmedOperationID = ""
    var protectsVPN: Bool { state.status == .running || state.status == .uncertain }

    private init() {
        restoreJournal()
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.tick() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.restoreJournal()
                self?.checkStatus()
            }.store(in: &subscriptions)
    }

    private func restoreJournal() {
        guard let path = getenv("LC_HOME_PATH") else { return }
        let url = URL(fileURLWithPath: String(cString: path)).appendingPathComponent("Documents/SideStore/AnderStoreUpdate.json")
        guard let data = try? Data(contentsOf: url),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if operation != nil {
            guard !state.operationID.isEmpty,
                  payload["operationID"] as? String == state.operationID else { return }
        }
        state.restore(payload, runningVersion: AnderUpdateChecker.currentVersion)
        if state.status == .failed {
            errorText = failureText(AnderCoreFailure(kind: state.failureKind ?? "terminated", message: ""))
        }
        if state.status == .verified {
            showSuccess = UserDefaults.standard.string(forKey: "anderAcknowledgedUpdate") != state.operationID
            if UserDefaults.standard.string(forKey: "anderLatestVersion") == state.version {
                UserDefaults.standard.set("", forKey: "anderLatestNotes")
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["anderstore.update.open"])
            confirmVersion()
        }
    }

    func start(version: String) {
        guard operation == nil, !state.blocksNewUpdate else { return }
        errorText = nil
        showSuccess = false
        delayed = false
        state = AnderSelfUpdateState(version: version, status: .running,
                                     lastAdvanceAt: Date().timeIntervalSince1970)
        operation = Task {
            defer { operation = nil }
            do {
                let readiness = try await request("update.readiness")
                if let blocker = readiness["blocker"] as? String {
                    throw AnderCoreFailure(kind: blocker, message: "")
                }
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
                try await AnderVPNCoordinator.shared.withVPN(reason: .selfUpdate) {
                    do {
                        let result = try await self.request("self.update", params: [
                            "version": version, "runningVersion": AnderUpdateChecker.currentVersion,
                            "hostBundleIdentifier": UserDefaults.lcMainBundle().bundleIdentifier ?? "",
                            "notificationsAllowed": allowed,
                            "notificationTitle": "lc.update.notificationTitle".loc,
                            "notificationBody": "lc.update.openManually".loc
                        ], onEvent: { [weak self] event in
                            self?.state.receive(event, now: Date().timeIntervalSince1970)
                        })
                        self.state.status = .installed
                        self.state.stage = "reopen"
                        if result["version"] as? String == AnderUpdateChecker.currentVersion {
                            self.state.status = .verified
                        }
                        AnderState.shared.markDeviceConnectionReady()
                        self.errorText = nil
                    } catch {
                        await self.resolveAfterDisconnect(originalError: error)
                    }
                }
            } catch { fail(error) }
        }
    }

    private func resolveAfterDisconnect(originalError: Error) async {
        while !Task.isCancelled {
            restoreJournal()
            if state.status == .verified || state.status == .installed { return }
            do {
                let payload = try await request("update.status")
                if payload["status"] as? String == "idle" {
                    if state.stage == "install" {
                        state.status = .uncertain
                        errorText = "lc.update.uncertain".loc
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        continue
                    }
                    fail(originalError)
                    return
                }
                if payload["version"] as? String != state.version,
                   payload["active"] as? Bool != true,
                   payload["status"] as? String != "uncertain" {
                    fail(originalError)
                    return
                }
                state.restore(payload, runningVersion: AnderUpdateChecker.currentVersion)
                if state.status == .failed {
                    fail(AnderCoreFailure(kind: state.failureKind ?? "unknown", message: ""))
                    return
                }
                if state.status == .verified || state.status == .installed { return }
                if state.status == .uncertain { errorText = "lc.update.uncertain".loc }
            } catch {
                state.status = .uncertain
                errorText = "lc.update.uncertain".loc
            }
            // An unknown installation retains VPN and blocks another installer.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func fail(_ error: Error) {
        state.status = .failed
        delayed = false
        errorText = (error as? AnderCoreFailure).map(failureText) ?? AnderAccountAPI.friendlyError(error)
        if let failure = error as? AnderCoreFailure,
           AnderErrorText.requiresSignIn(failure.kind) { AnderState.shared.markSignInNeeded() }
    }

    func checkStatus() {
        if state.status == .verified { confirmVersion(); return }
        guard state.blocksNewUpdate, !polling else { return }
        if operation != nil && state.operationID.isEmpty { return }
        polling = true
        lastPoll = Date().timeIntervalSince1970
        Task {
            defer { polling = false }
            do {
                let payload = try await request("update.status")
                let id = payload["operationID"] as? String ?? ""
                guard !id.isEmpty, state.operationID.isEmpty || id == state.operationID else { return }
                state.restore(payload, runningVersion: AnderUpdateChecker.currentVersion)
                errorText = nil
                if state.status == .verified { confirmVersion() }
                if !protectsVPN { AnderVPNCoordinator.shared.recoverOwnedSessionIfNeeded() }
                if state.status == .failed {
                    errorText = failureText(AnderCoreFailure(kind: state.failureKind ?? "terminated", message: ""))
                }
            } catch {
                if state.status != .verified { errorText = "lc.update.uncertain".loc }
            }
        }
    }

    private func confirmVersion() {
        guard !state.operationID.isEmpty, confirmedOperationID != state.operationID else { return }
        let id = state.operationID
        confirmedOperationID = id
        Task {
            do { _ = try await request("update.confirmVersion", params: ["version": AnderUpdateChecker.currentVersion]) }
            catch { confirmedOperationID = "" }
        }
    }

    private func failureText(_ failure: AnderCoreFailure) -> String {
        if let key = AnderErrorText.key(for: failure.kind) ?? AnderErrorText.key(forMessage: failure.message) {
            return key.loc
        }
        return "lc.update.failedGeneric".loc
    }

    func acknowledgeSuccess() {
        UserDefaults.standard.set(state.operationID, forKey: "anderAcknowledgedUpdate")
        showSuccess = false
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        delayed = state.isDelayed(now: now)
        if state.status == .running, state.stage != "vpn", delayed, now - lastPoll >= 5 { checkStatus() }
    }

    private func request(_ command: String, params: [String: Any] = [:],
                         onEvent: @escaping ([String: Any]) -> Void = { _ in }) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let started = AnderAccountAPI.perform(command, params: params, onEvent: onEvent) { payload, failure in
                if let failure { continuation.resume(throwing: failure) }
                else { continuation.resume(returning: payload ?? [:]) }
            }
            if !started { continuation.resume(throwing: AnderCoreFailure.unavailable) }
        }
    }
}
