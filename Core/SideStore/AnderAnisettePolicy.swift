//
//  AnderAnisettePolicy.swift
//  AnderStore
//
//  AnderStore runs its own anisette server (anisette.andresot.uk), and that is what signing in
//  must use. Upstream defaults to computing the Apple tokens on the device instead (ADI), which
//  on a fresh AnderStore install can never succeed — nothing provisions ADI, so the first
//  sign-in dies with "Device not provisioned (-45061)".
//
//  This file owns that decision so the choice does not live inside vendored SideStore code.
//

import Foundation

enum AnderAnisettePolicy {

    /// Set once the user picks a mode themselves. Until then AnderStore decides.
    private static let explicitChoiceKey = "anderAnisetteModeChosenByUser"

    static var userChoseMode: Bool {
        UserDefaults.standard.bool(forKey: explicitChoiceKey)
    }

    static func recordUserChoice() {
        UserDefaults.standard.set(true, forKey: explicitChoiceKey)
    }

    /// The mode actually used. On-device ADI only when the user asked for it.
    static var useOnDeviceAnisette: Bool {
        userChoseMode && UserDefaults.standard.useOnDeviceAnisette
    }

    /// Cheap and idempotent: safe to call before every command.
    static func applyDefaults(force: Bool = false) {
        if force || !userChoseMode {
            if UserDefaults.standard.useOnDeviceAnisette {
                UserDefaults.standard.useOnDeviceAnisette = false
            }
        }
        if UserDefaults.standard.menuAnisetteURL.isEmpty {
            UserDefaults.standard.menuAnisetteURL = AppConstants.Anisette.Servers.defaultServerURL
        }
        if UserDefaults.standard.menuAnisetteList.isEmpty {
            UserDefaults.standard.menuAnisetteList = AppConstants.Anisette.Servers.defaultSource
        }
    }

    /// The remote path reads its server list from a local cache that only the daily sync fills.
    /// On a fresh install that cache is empty, so seed it with our own server first — otherwise
    /// the very first sign-in fails with "no servers configured".
    nonisolated(unsafe) private static var didSeed = false

    static func seedServerListIfNeeded(force: Bool = false) async {
        guard force || !didSeed else { return }
        didSeed = true

        let manager = AnisetteServersManager.shared
        let active = await manager.getActiveServerURLs()
        guard active.isEmpty else { return }

        debugLog("[AnderAnisettePolicy] No anisette servers cached; seeding the AnderStore server")
        await manager.saveLocalServers([
            AnisetteServerItem(name: "AnderStore",
                               address: AppConstants.Anisette.Servers.defaultServerURL)
        ])
        await manager.performDailySyncIfNeeded()
    }

    /// Called when the mode changes: both paths share one adi.pb in the keychain, and a blob
    /// left half-provisioned by one of them breaks the other.
    static func clearProvisioningBlob() {
        AnisetteConfigManager.shared.anisetteAdiBlob = nil
    }
}
