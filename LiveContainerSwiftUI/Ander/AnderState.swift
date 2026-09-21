//
//  AnderState.swift
//  AnderStore
//
//  One place that knows what AnderStore knows: the Apple ID, the certificate, the signature
//  and the apps Core manages. It paints from a cached snapshot first, so opening a screen
//  never has to start Core, and refreshes in the background only when something changed.
//

import Foundation
import SwiftUI

struct AnderAccountInfo: Equatable {
    var signedIn: Bool = false
    var appleID: String?
    var team: String?
    var teamType: Int?
    var portalSessionState: AnderPortalSessionState = .unknown

    /// Free Apple ID (ALTTeamType.free == 1): three apps, ten App IDs a week.
    var isFreeAccount: Bool { teamType == 1 }
}

enum AnderPortalSessionState: String, Equatable {
    case unknown
    case ready
    case reauthRequired
    case rateLimited
}

struct AnderCoreApp: Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var version: String
    var expirationDate: Date?
    var hasUpdate: Bool

    var id: String { bundleIdentifier }
}

enum AnderReadiness: Equatable {
    case checking
    case needsAccount
    case needsCertificate
    case invalidCertificate
    case needsPairing
    case needsVPN
    case needsJITLess
    case ready
}

enum AnderRenewalState: Equatable {
    case idle
    case refreshing(Double)
    case needsVPN
    case failed(String)
    case complete
}

enum AnderCertificateSyncState: Equatable {
    case idle
    case syncing
    case updated
    case current
    case missing
    case failed(String)
}

/// Used from the interface only, like SharedModel: every method runs on the main thread.
final class AnderState: ObservableObject {

    static let shared = AnderState()

    private static let cacheKey = "AnderStateSnapshotV1"
    /// A cached snapshot older than this is refreshed when a screen appears.
    private static let maxAge: TimeInterval = 15 * 60

    @Published private(set) var account = AnderAccountInfo()
    @Published private(set) var certificatePresent = false
    @Published private(set) var coreApps: [AnderCoreApp] = []
    @Published private(set) var capturedAt: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var readiness: AnderReadiness = .checking
    @Published private(set) var vpnReady = false
    @Published private(set) var pairingReady = false
    @Published private(set) var pairingState: AnderPairingState = .checking
    @Published private(set) var vpnState: AnderVPNState = .checking
    @Published private(set) var connectionState: AnderConnectionState = .starting
    @Published private(set) var jitLessReady = false
    @Published private(set) var certificateValid = false
    @Published private(set) var renewalState: AnderRenewalState = .idle
    @Published private(set) var certificateSyncState: AnderCertificateSyncState = .idle
    @Published private(set) var resignSummary: String?
    @Published private(set) var notificationPermissionDenied = false

    /// Expiration of AnderStore's own signature, read from the provisioning profile.
    @Published var signatureExpiration: Date?

    private init() {
        loadCache()
        signatureExpiration = AnderSignature.expirationDate()
    }

    private var deviceStatusGeneration = 0

    var coreAvailable: Bool { AnderAccountAPI.isAvailable }

    var isStale: Bool {
        guard let capturedAt else { return true }
        return Date().timeIntervalSince(capturedAt) > Self.maxAge
    }

    // MARK: - Refresh

    /// Reads everything Core knows locally. No Apple API call, no VPN — safe to call on appear.
    func refresh(force: Bool = false) {
        guard coreAvailable, !isRefreshing, force || isStale else { return }
        isRefreshing = true
        let started = AnderAccountAPI.perform("snapshot",
                                              params: ["fields": ["account", "certificate", "apps"]]) { [weak self] response, _ in
            guard let self else { return }
            self.isRefreshing = false
            guard let response else { return }
            self.apply(response)
            self.saveCache(response)
            self.refreshDeviceStatus()
            self.validateLocalSetup()
        }
        if !started {
            isRefreshing = false
        }
    }

    /// Called after anything that changes the account, the certificate or the apps.
    func invalidate() {
        capturedAt = nil
        signatureExpiration = AnderSignature.expirationDate()
        refresh(force: true)
    }

    func clearAccountAfterSignOut() {
        account = AnderAccountInfo()
        capturedAt = nil
        evaluateReadiness()
        LCUtils.appGroupUserDefault.removeObject(forKey: Self.cacheKey)
    }

    func certificateDidChange() {
        certificatePresent = LCSharedUtils.certificatePassword() != nil
        validateLocalSetup(resignAfterSuccess: true)
        invalidate()
    }

    /// Pulls the active P12 from Core and installs it for Live Apps. This is the only path used
    /// by automatic and manual Core-to-host certificate synchronization.
    func synchronizeCertificate(force: Bool = false,
                                resignAfterChange: Bool = true,
                                completion: ((AnderCertificateSyncState) -> Void)? = nil) {
        guard coreAvailable else {
            certificateSyncState = .failed("lc.account.errorNoExtension".loc)
            completion?(certificateSyncState)
            return
        }
        guard certificateSyncState != .syncing else { return }

        let defaults = LCUtils.appGroupUserDefault
        let lastSync = defaults.double(forKey: "anderLastCertificateSync")
        let localCertificatePresent = LCUtils.certificateData() != nil && LCSharedUtils.certificatePassword() != nil
        if !AnderCertificateSyncPolicy.shouldSynchronize(
            force: force,
            localCertificatePresent: localCertificatePresent,
            localCertificateValid: certificateValid,
            lastSync: lastSync,
            now: Date().timeIntervalSince1970
        ) {
            certificateSyncState = .current
            completion?(certificateSyncState)
            return
        }

        certificateSyncState = .syncing
        let started = AnderAccountAPI.synchronizeCertificateFromCore { [weak self] result, failure in
            guard let self else { return }
            if let failure {
                self.certificateSyncState = failure.kind == "certificateNotFound"
                    ? .missing : .failed(AnderAccountAPI.friendly(failure))
                self.evaluateReadiness()
                completion?(self.certificateSyncState)
                return
            }

            let changed = result == .updated
            self.certificatePresent = true
            self.certificateSyncState = changed ? .updated : .current
            self.signatureExpiration = AnderSignature.expirationDate()
            self.validateLocalSetup(resignAfterSuccess: changed && resignAfterChange)
            self.capturedAt = nil
            self.refresh(force: true)
            completion?(self.certificateSyncState)
        }
        if !started {
            certificateSyncState = .failed("lc.account.errorNoExtension".loc)
            completion?(certificateSyncState)
        }
    }

    func handleForeground() {
        scheduleSignatureReminder()
        refresh()
        refreshDeviceStatus()
        validateLocalSetup()
        synchronizeCertificate { [weak self] _ in
            self?.autoRenewIfNeeded()
        }
    }

    func scheduleSignatureReminder() {
        guard let signatureExpiration else { return }
        AnderSignature.scheduleReminders(expiration: signatureExpiration) { [weak self] granted in
            DispatchQueue.main.async {
                self?.notificationPermissionDenied = !granted
            }
        }
    }

    func refreshDeviceStatus() {
        deviceStatusGeneration += 1
        refreshDeviceStatus(generation: deviceStatusGeneration, attempt: 0)
    }

    private func refreshDeviceStatus(generation: Int, attempt: Int) {
        guard coreAvailable else { return }
        _ = AnderAccountAPI.perform("device.status") { [weak self] response, _ in
            guard let self, generation == self.deviceStatusGeneration, let response else { return }
            self.pairingState = (response["pairingState"] as? String)
                .flatMap { AnderPairingState(rawValue: $0) }
                ?? ((response["pairingReady"] as? Bool ?? false) ? .valid : .checking)
            self.vpnState = (response["vpnState"] as? String)
                .flatMap { AnderVPNState(rawValue: $0) }
                ?? ((response["vpnReady"] as? Bool ?? false) ? .connected : .checking)
            self.connectionState = (response["connectionState"] as? String)
                .flatMap { AnderConnectionState(rawValue: $0) } ?? .starting
            self.vpnReady = self.vpnState == .connected
            self.pairingReady = self.pairingState == .valid
            self.evaluateReadiness()

            if attempt < 3,
               self.pairingState == .checking || self.connectionState == .starting {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
                    self?.refreshDeviceStatus(generation: generation, attempt: attempt + 1)
                }
            }
        }
    }

    func markDeviceConnectionReady() {
        pairingState = .valid
        vpnState = .connected
        connectionState = .ready
        pairingReady = true
        vpnReady = true
        evaluateReadiness()
    }

    func validateLocalSetup(resignAfterSuccess: Bool = false) {
        guard LCUtils.certificateData() != nil else {
            certificateValid = false
            jitLessReady = false
            evaluateReadiness()
            return
        }
        readiness = .checking
        LCUtils.validateCertificate { [weak self] status, _, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.certificateValid = status == 0
                guard self.certificateValid else {
                    self.jitLessReady = false
                    self.evaluateReadiness()
                    return
                }
                LCUtils.validateJITLessSetup { success, _ in
                    DispatchQueue.main.async {
                        self.jitLessReady = success
                        self.evaluateReadiness()
                        if success && resignAfterSuccess {
                            Task { await self.resignAllLiveApps() }
                        }
                    }
                }
            }
        }
    }

    func autoRenewIfNeeded(force: Bool = false) {
        renewSignatures(manual: force)
    }

    /// Runs the single renewal pipeline used by both foreground automation and the manual
    /// "renew now" button. Manual requests bypass the age/three-day gates, but never start a
    /// second Core request while one is already active.
    func renewSignatures(manual: Bool = true,
                         completion: ((AnderRenewalState) -> Void)? = nil) {
        if case .refreshing = renewalState { return }
        guard coreAvailable else {
            renewalState = .failed("lc.account.errorNoExtension".loc)
            completion?(renewalState)
            return
        }
        guard account.signedIn else {
            renewalState = .failed("lc.account.sessionExpired".loc)
            completion?(renewalState)
            return
        }

        let defaults = LCUtils.appGroupUserDefault
        let lastAttempt = defaults.double(forKey: "anderLastAutoRefresh")
        if !manual {
            guard let expiration = signatureExpiration,
                  AnderSignature.daysLeft(until: expiration) <= 3,
                  Date().timeIntervalSince1970 - lastAttempt > 6 * 3600 else { return }
        }

        certificateSyncState = .idle
        renewalState = .refreshing(0)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await AnderVPNCoordinator.shared.withVPN(reason: .signatureRefresh) {
                    try await AnderAccountAPI.refreshAsync { [weak self] value in
                        self?.renewalState = .refreshing(value)
                    } onStarted: {
                        // Missing VPN/Core must not consume the six-hour automatic retry interval.
                        defaults.set(Date().timeIntervalSince1970, forKey: "anderLastAutoRefresh")
                    }
                }
            } catch let failure as AnderCoreFailure {
                self.renewalState = failure.kind == "noVPN" || failure.kind == "needsMinimuxer"
                    ? .needsVPN : .failed(AnderAccountAPI.friendly(failure))
                completion?(self.renewalState)
                return
            } catch let failure as AnderVPNCoordinatorError {
                self.renewalState = failure == .appMissing || failure == .connectionTimedOut || failure == .couldNotOpen
                    ? .needsVPN : .failed(failure.localizedDescription)
                completion?(self.renewalState)
                return
            } catch {
                self.renewalState = .failed(error.localizedDescription)
                completion?(self.renewalState)
                return
            }

            self.markDeviceConnectionReady()
            self.synchronizeCertificate(force: true) { [weak self] syncState in
                guard let self else { return }
                switch syncState {
                case .updated, .current:
                    self.signatureExpiration = AnderSignature.expirationDate()
                    self.scheduleSignatureReminder()
                    self.renewalState = .complete
                    self.invalidate()
                case .missing:
                    self.renewalState = .failed("lc.certificateSync.notFound".loc)
                case .failed(let message):
                    self.renewalState = .failed(message)
                case .idle, .syncing:
                    return
                }
                completion?(self.renewalState)
            }
        }
    }

    @MainActor
    private func resignAllLiveApps() async {
        let model = DataManager.shared.model
        // Do not reveal hidden app names in the result until the user has authenticated.
        let apps = model.apps + (model.isHiddenAppUnlocked ? model.hiddenApps : [])
        var skipped: [String] = []
        var failed: [String] = []
        var resigned = 0
        for app in apps {
            if app.isAppRunning {
                skipped.append(app.displayName)
                continue
            }
            do {
                try await app.forceResign()
                resigned += 1
            } catch {
                failed.append(app.displayName)
            }
        }
        var parts = [String(format: "lc.readiness.resignComplete".loc, resigned)]
        if !skipped.isEmpty { parts.append(String(format: "lc.readiness.resignSkipped".loc, skipped.joined(separator: ", "))) }
        if !failed.isEmpty { parts.append(String(format: "lc.readiness.resignFailed".loc, failed.joined(separator: ", "))) }
        resignSummary = parts.joined(separator: "\n")
    }

    private func evaluateReadiness() {
        if !certificatePresent && LCSharedUtils.certificatePassword() == nil {
            readiness = account.signedIn ? .needsCertificate : .needsAccount
        }
        else if !certificateValid { readiness = .invalidCertificate }
        else if pairingState == .checking || vpnState == .checking || connectionState == .starting { readiness = .checking }
        else if pairingState == .missing || pairingState == .invalid { readiness = .needsPairing }
        else if vpnState == .disconnected || connectionState == .unreachable { readiness = .needsVPN }
        else if !jitLessReady { readiness = .needsJITLess }
        else { readiness = .ready }
    }

    // MARK: - Snapshot

    private func apply(_ snapshot: [String: Any]) {
        if let accountPayload = snapshot["account"] as? [String: Any] {
            var info = AnderAccountInfo()
            info.signedIn = accountPayload["signedIn"] as? Bool ?? false
            info.appleID = accountPayload["appleID"] as? String
            info.team = accountPayload["team"] as? String
            info.teamType = accountPayload["teamType"] as? Int
            info.portalSessionState = (accountPayload["portalSessionState"] as? String)
                .flatMap { AnderPortalSessionState(rawValue: $0) } ?? .unknown
            account = info
        }
        if let certificatePayload = snapshot["certificate"] as? [String: Any] {
            certificatePresent = certificatePayload["present"] as? Bool ?? false
        }
        if let appsPayload = snapshot["apps"] as? [[String: Any]] {
            coreApps = appsPayload.compactMap { entry in
                guard let bundleIdentifier = entry["bundleIdentifier"] as? String,
                      let name = entry["name"] as? String else { return nil }
                return AnderCoreApp(bundleIdentifier: bundleIdentifier,
                                    name: name,
                                    version: entry["version"] as? String ?? "",
                                    expirationDate: entry["expirationDate"] as? Date,
                                    hasUpdate: entry["hasUpdate"] as? Bool ?? false)
            }
        }
        capturedAt = snapshot["capturedAt"] as? Date ?? Date()
    }

    // MARK: - Cache

    private func loadCache() {
        guard let stored = LCUtils.appGroupUserDefault.dictionary(forKey: Self.cacheKey) else { return }
        apply(stored)
    }

    private func saveCache(_ snapshot: [String: Any]) {
        // Persist only the summary fields used to paint the UI. Never persist certificate
        // serials, passwords, private keys or imported .p12 contents in this cache.
        var safe: [String: Any] = ["capturedAt": snapshot["capturedAt"] as? Date ?? Date()]
        if let account = snapshot["account"] as? [String: Any] {
            safe["account"] = [
                "signedIn": account["signedIn"] as? Bool ?? false,
                "teamType": account["teamType"] as? Int ?? 0,
                "portalSessionState": account["portalSessionState"] as? String ?? "unknown"
            ]
        }
        if let certificate = snapshot["certificate"] as? [String: Any] {
            safe["certificate"] = ["present": certificate["present"] as? Bool ?? false]
        }
        if let apps = snapshot["apps"] as? [[String: Any]] {
            safe["apps"] = apps.map { app in
                [
                    "bundleIdentifier": app["bundleIdentifier"] as? String ?? "",
                    "name": app["name"] as? String ?? "",
                    "version": app["version"] as? String ?? "",
                    "expirationDate": app["expirationDate"] as? Date ?? Date.distantPast,
                    "hasUpdate": app["hasUpdate"] as? Bool ?? false
                ]
            }
        }
        LCUtils.appGroupUserDefault.set(safe, forKey: Self.cacheKey)
    }
}
