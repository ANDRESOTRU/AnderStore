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

    /// Free Apple ID (ALTTeamType.free == 1): three apps, ten App IDs a week.
    var isFreeAccount: Bool { teamType == 1 }
}

struct AnderCoreApp: Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var version: String
    var expirationDate: Date?
    var hasUpdate: Bool

    var id: String { bundleIdentifier }
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

    /// Expiration of AnderStore's own signature, read from the provisioning profile.
    @Published var signatureExpiration: Date?

    private init() {
        loadCache()
        signatureExpiration = AnderSignature.expirationDate()
    }

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

    // MARK: - Snapshot

    private func apply(_ snapshot: [String: Any]) {
        if let accountPayload = snapshot["account"] as? [String: Any] {
            var info = AnderAccountInfo()
            info.signedIn = accountPayload["signedIn"] as? Bool ?? false
            info.appleID = accountPayload["appleID"] as? String
            info.team = accountPayload["team"] as? String
            info.teamType = accountPayload["teamType"] as? Int
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
        // Only plain values travel here: never the certificate itself, never a password.
        LCUtils.appGroupUserDefault.set(snapshot, forKey: Self.cacheKey)
    }
}
