//
//  AnderVPNCoordinator.swift
//  AnderStore
//
//  LocalDevVPN is an App Store app because a free Personal Team cannot sign a Network
//  Extension. AnderStore controls it through its public URL scheme and verifies the real
//  minimuxer state before allowing a device operation to continue.
//

import Foundation
import Combine
import UIKit

enum AnderVPNReason: String, Codable, Equatable {
    case signatureRefresh
    case selfUpdate
    case appsRefresh
    case deviceOperation
}

enum AnderVPNCoordinatorState: Equatable {
    case idle
    case checking
    case missingApp
    case enabling
    case connected
    case inUse(Int)
    case disabling
    case failed(String)
}

enum AnderVPNCoordinatorError: LocalizedError, Equatable {
    case appMissing
    case pairingUnavailable
    case coreUnavailable
    case couldNotOpen
    case connectionTimedOut
    /// minimuxer answers only over Wi‑Fi; LocalDevVPN being connected does not help on LTE.
    case wifiRequired

    var errorDescription: String? {
        switch self {
        case .wifiRequired:
            return "lc.vpn.wifiRequired".loc
        case .appMissing:
            return "lc.vpn.missing".loc
        case .pairingUnavailable:
            return "lc.vpn.pairingRequired".loc
        case .coreUnavailable:
            return "lc.account.errorNoExtension".loc
        case .couldNotOpen:
            return "lc.vpn.openFailed".loc
        case .connectionTimedOut:
            return "lc.vpn.enableFailed".loc
        }
    }
}

@MainActor
final class AnderVPNCoordinator: ObservableObject {
    static let shared = AnderVPNCoordinator()

    private enum HandoffAction: String, Codable {
        case enable
        case disable
    }

    private struct StoredHandoff: Codable {
        var action: HandoffAction
        var reason: AnderVPNReason
        var createdAt: TimeInterval
    }

    private struct DeviceProbe {
        var pairingState: String
        var decision: AnderVPNProbeDecision

        var vpnConnected: Bool { decision == .connected }
        var pairingUsable: Bool { pairingState != "missing" && pairingState != "invalid" }
    }

    private static let handoffKey = "anderVPNHandoffV1"
    private static let cleanupKey = "anderVPNNeedsCleanup"
    private static let appURL = URL(string: "localdevvpn://enable")!
    private static let storeURL = URL(string: "https://apps.apple.com/app/id6755608044")!

    @Published private(set) var state: AnderVPNCoordinatorState = .idle
    @Published private(set) var lastReason: AnderVPNReason?
    @Published private(set) var appInstalled = false

    private var leasePolicy = AnderVPNLeasePolicy()
    private var activationTask: Task<Bool, Error>?
    private var recoveryTask: Task<Void, Never>?
    private var awaitingInstallConfirmation = false

    private init() {
        appInstalled = UIApplication.shared.canOpenURL(Self.appURL)
    }

    var needsAttention: Bool {
        switch state {
        case .missingApp, .failed:
            return true
        default:
            return false
        }
    }

    /// Returns true while this foreground transition belongs to the VPN handoff. Callers must
    /// skip normal foreground automation in that case or they can recursively start renewal.
    @discardableResult
    func handleForeground() -> Bool {
        appInstalled = UIApplication.shared.canOpenURL(Self.appURL)
        // Returning from the App Store must not silently resume the deferred operation. The
        // user explicitly confirms installation with the retry button in AnderStore.
        if awaitingInstallConfirmation {
            return true
        }

        if let handoff = loadHandoff() {
            if AnderVPNHandoffPolicy.isRecoverable(createdAt: handoff.createdAt,
                                                    now: Date().timeIntervalSince1970) {
                if activationTask == nil, state != .enabling, state != .disabling {
                    recoverInterruptedHandoff(handoff)
                }
                return true
            }
            clearHandoff()
        }

        if UserDefaults.standard.bool(forKey: Self.cleanupKey), leasePolicy.activeLeases == 0 {
            recoverOwnedSessionIfNeeded()
            return true
        }
        return state == .enabling || state == .disabling
    }

    private func recoverInterruptedHandoff(_ handoff: StoredHandoff) {
        guard recoveryTask == nil else { return }
        clearHandoff()
        lastReason = handoff.reason
        state = .checking
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            let probe = try? await self.probeDevice()
            let vpnConnected = probe?.vpnConnected ?? false
            if vpnConnected {
                UserDefaults.standard.set(true, forKey: Self.cleanupKey)
                await self.disableOwnedTunnel()
            } else {
                UserDefaults.standard.removeObject(forKey: Self.cleanupKey)
                self.state = .idle
            }
            self.recoveryTask = nil
        }
    }

    func recoverOwnedSessionIfNeeded() {
        guard recoveryTask == nil,
              UserDefaults.standard.bool(forKey: Self.cleanupKey),
              leasePolicy.activeLeases == 0 else { return }

        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.disableOwnedTunnel()
            self.recoveryTask = nil
        }
    }

    func refreshAvailability() {
        awaitingInstallConfirmation = false
        appInstalled = UIApplication.shared.canOpenURL(Self.appURL)
        if appInstalled, state == .missingApp {
            state = .idle
        } else if !appInstalled {
            state = .missingApp
        }
    }

    func openStore() {
        awaitingInstallConfirmation = true
        UIApplication.shared.open(Self.storeURL)
    }

    func openVPNApp() {
        guard let url = makeControlURL(action: .enable) else { return }
        UIApplication.shared.open(url)
    }

    func withVPN<T>(reason: AnderVPNReason,
                    operation: @escaping @MainActor () async throws -> T) async throws -> T {
        try await acquire(reason: reason)
        do {
            let value = try await operation()
            await release()
            return value
        } catch {
            await release()
            throw error
        }
    }

    private func acquire(reason: AnderVPNReason) async throws {
        lastReason = reason

        if leasePolicy.activeLeases > 0 {
            leasePolicy.acquire(tunnelWasAlreadyConnected: false)
            state = .inUse(leasePolicy.activeLeases)
            return
        }

        let activation: Task<Bool, Error>
        if let activationTask {
            activation = activationTask
        } else {
            let newTask = Task { [weak self] () throws -> Bool in
                guard let self else { throw AnderVPNCoordinatorError.coreUnavailable }
                return try await self.activate(reason: reason)
            }
            activationTask = newTask
            activation = newTask
        }

        do {
            let wasAlreadyConnected = try await activation.value
            activationTask = nil
            leasePolicy.acquire(tunnelWasAlreadyConnected: wasAlreadyConnected)
            state = .inUse(leasePolicy.activeLeases)
        } catch {
            activationTask = nil
            // The readiness card must show what the coordinator just learned, not a stale
            // answer from before the trip to LocalDevVPN.
            AnderState.shared.refreshDeviceStatus()
            throw error
        }
    }

    /// Any error leaves a final state behind: before 1.6.29 a failed probe left the card on
    /// «Включаем VPN…» forever and blocked every later foreground refresh.
    private func activate(reason: AnderVPNReason) async throws -> Bool {
        do {
            return try await activateSteps(reason: reason)
        } catch {
            clearHandoff()
            switch state {
            case .failed, .missingApp:
                break
            default:
                let detail = (error as? AnderVPNCoordinatorError)?.localizedDescription
                    ?? AnderVPNCoordinatorError.coreUnavailable.localizedDescription
                state = .failed(detail)
            }
            throw error
        }
    }

    private func activateSteps(reason: AnderVPNReason) async throws -> Bool {
        state = .checking
        var initial = try await probeDevice()
        // Core (and minimuxer inside it) may just be starting. Opening LocalDevVPN now would
        // bounce the user out of AnderStore — and later switch off a VPN they had turned on.
        if initial.decision == .wait, initial.pairingUsable {
            initial = try await settle(initial)
        }
        switch initial.decision {
        case .connected:
            state = .connected
            return true
        case .needsWiFi:
            state = .failed(AnderVPNCoordinatorError.wifiRequired.localizedDescription)
            throw AnderVPNCoordinatorError.wifiRequired
        case .wait, .openVPN:
            break
        }
        guard initial.pairingUsable else {
            state = .failed(AnderVPNCoordinatorError.pairingUnavailable.localizedDescription)
            throw AnderVPNCoordinatorError.pairingUnavailable
        }

        appInstalled = UIApplication.shared.canOpenURL(Self.appURL)
        guard appInstalled else {
            state = .missingApp
            throw AnderVPNCoordinatorError.appMissing
        }

        guard let url = makeControlURL(action: .enable) else {
            state = .failed(AnderVPNCoordinatorError.couldNotOpen.localizedDescription)
            throw AnderVPNCoordinatorError.couldNotOpen
        }

        storeHandoff(action: .enable, reason: reason)
        state = .enabling
        guard await open(url) else {
            clearHandoff()
            state = .failed(AnderVPNCoordinatorError.couldNotOpen.localizedDescription)
            throw AnderVPNCoordinatorError.couldNotOpen
        }

        guard try await waitForVPN(connected: true) else {
            clearHandoff()
            state = .failed(AnderVPNCoordinatorError.connectionTimedOut.localizedDescription)
            throw AnderVPNCoordinatorError.connectionTimedOut
        }

        clearHandoff()
        UserDefaults.standard.set(true, forKey: Self.cleanupKey)
        state = .connected
        return false
    }

    private func release() async {
        let shouldStop = leasePolicy.release()
        if leasePolicy.activeLeases > 0 {
            state = .inUse(leasePolicy.activeLeases)
            return
        }
        guard shouldStop else {
            state = .idle
            return
        }
        await disableOwnedTunnel()
    }

    private func disableOwnedTunnel() async {
        guard UserDefaults.standard.bool(forKey: Self.cleanupKey) else {
            clearHandoff()
            state = .idle
            return
        }
        guard appInstalled || UIApplication.shared.canOpenURL(Self.appURL),
              let url = makeControlURL(action: .disable) else {
            UserDefaults.standard.removeObject(forKey: Self.cleanupKey)
            clearHandoff()
            state = .idle
            return
        }

        storeHandoff(action: .disable, reason: lastReason ?? .deviceOperation)
        state = .disabling
        guard await open(url) else {
            clearHandoff()
            state = .failed("lc.vpn.disableFailed".loc)
            return
        }

        let disconnected = (try? await waitForVPN(connected: false)) ?? false
        clearHandoff()
        if disconnected {
            UserDefaults.standard.removeObject(forKey: Self.cleanupKey)
            state = .idle
        } else {
            state = .failed("lc.vpn.disableFailed".loc)
        }
    }

    /// Polls while Core reports "still starting", up to about ten seconds.
    private func settle(_ probe: DeviceProbe) async throws -> DeviceProbe {
        var current = probe
        for _ in 0..<13 where current.decision == .wait {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: 750_000_000)
            current = try await probeDevice()
        }
        return current
    }

    private func waitForVPN(connected expected: Bool) async throws -> Bool {
        let attempts = 20
        for attempt in 0..<attempts {
            if Task.isCancelled { throw CancellationError() }
            let probe = try await probeDevice()
            if probe.vpnConnected == expected { return true }
            // Turning the tunnel on cannot help without Wi‑Fi: say so instead of timing out.
            if expected, probe.decision == .needsWiFi {
                throw AnderVPNCoordinatorError.wifiRequired
            }
            if attempt + 1 < attempts {
                try await Task.sleep(nanoseconds: 750_000_000)
            }
        }
        return false
    }

    private func probeDevice() async throws -> DeviceProbe {
        try await withCheckedThrowingContinuation { continuation in
            let started = AnderAccountAPI.perform("device.status") { response, failure in
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                guard let response else {
                    continuation.resume(throwing: AnderVPNCoordinatorError.coreUnavailable)
                    return
                }
                continuation.resume(returning: DeviceProbe(
                    pairingState: response["pairingState"] as? String ?? "checking",
                    decision: AnderVPNProbeDecision.decide(
                        vpnState: response["vpnState"] as? String,
                        vpnReady: response["vpnReady"] as? Bool == true
                    )
                ))
            }
            if !started {
                continuation.resume(throwing: AnderVPNCoordinatorError.coreUnavailable)
            }
        }
    }

    private func makeControlURL(action: HandoffAction) -> URL? {
        var components = URLComponents()
        components.scheme = "localdevvpn"
        components.host = action.rawValue
        components.queryItems = [URLQueryItem(name: "scheme", value: "livecontainer")]
        return components.url
    }

    private func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }

    private func storeHandoff(action: HandoffAction, reason: AnderVPNReason) {
        let value = StoredHandoff(action: action,
                                  reason: reason,
                                  createdAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.handoffKey)
        }
    }

    private func loadHandoff() -> StoredHandoff? {
        guard let data = UserDefaults.standard.data(forKey: Self.handoffKey) else { return nil }
        return try? JSONDecoder().decode(StoredHandoff.self, from: data)
    }

    private func clearHandoff() {
        UserDefaults.standard.removeObject(forKey: Self.handoffKey)
    }
}
