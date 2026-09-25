import CryptoKit
import Foundation

enum AnderPairingState: String, Codable {
    case checking
    case missing
    case invalid
    case valid
}

enum AnderVPNState: String, Codable {
    case checking
    case disconnected
    case connected
    /// minimuxer needs Wi‑Fi: on mobile data it fails even with LocalDevVPN connected.
    case noWifi
}

enum AnderConnectionState: String, Codable {
    case starting
    case ready
    case unreachable
}

struct AnderDeviceStatusValue: Equatable {
    let pairing: AnderPairingState
    let vpn: AnderVPNState
    let connection: AnderConnectionState

    var pairingReady: Bool { pairing == .valid }
    var vpnReady: Bool { vpn == .connected }
    var ready: Bool { pairingReady && vpnReady && connection == .ready }
}

enum AnderDeviceStatusLogic {
    /// Maps independent file/VPN/connection signals without turning startup or network failures
    /// into a false "invalid pairing file" warning.
    static func evaluate(pairing: AnderPairingState,
                         minimuxerFailure: String?) -> AnderDeviceStatusValue {
        guard pairing == .valid else {
            return AnderDeviceStatusValue(pairing: pairing,
                                          vpn: .checking,
                                          connection: .unreachable)
        }

        switch minimuxerFailure {
        case nil:
            return AnderDeviceStatusValue(pairing: .valid, vpn: .connected, connection: .ready)
        case "invalidPairing":
            return AnderDeviceStatusValue(pairing: .invalid, vpn: .connected, connection: .unreachable)
        case "noConnection":
            return AnderDeviceStatusValue(pairing: .valid, vpn: .noWifi, connection: .unreachable)
        case "noVPN", "invalidVPN":
            return AnderDeviceStatusValue(pairing: .valid, vpn: .disconnected, connection: .unreachable)
        case "notStarted", "pairingNotLoaded":
            return AnderDeviceStatusValue(pairing: .valid, vpn: .checking, connection: .starting)
        default:
            return AnderDeviceStatusValue(pairing: .valid, vpn: .checking, connection: .unreachable)
        }
    }
}

/// What the VPN coordinator does with one `device.status` answer.
enum AnderVPNProbeDecision: Equatable {
    /// minimuxer answers — the tunnel is up.
    case connected
    /// Core or minimuxer is still starting: wait, opening LocalDevVPN would be premature.
    case wait
    /// No Wi‑Fi: LocalDevVPN cannot fix it, ask for Wi‑Fi instead.
    case needsWiFi
    /// The tunnel is really down: turn LocalDevVPN on.
    case openVPN

    static func decide(vpnState: String?, vpnReady: Bool) -> AnderVPNProbeDecision {
        if vpnReady || vpnState == "connected" { return .connected }
        switch vpnState {
        case "noWifi":
            return .needsWiFi
        case "disconnected":
            return .openVPN
        default:
            return .wait
        }
    }
}

/// Why AnderStore cannot update itself right now. Self-update re-signs the new IPA inside
/// Core, which needs Core's own Apple session and certificate; without them the pipeline
/// never finishes (1.6.26 → 1.6.28, 25 September 2026).
enum AnderUpdateBlocker: String, Equatable {
    case signInRequired
    case certificateNotFound

    static func from(signedIn: Bool, hasCertificate: Bool) -> AnderUpdateBlocker? {
        if !signedIn { return .signInRequired }
        if !hasCertificate { return .certificateNotFound }
        return nil
    }
}

/// What the «Устройство» screen says first: one state, one action.
enum AnderReadiness: Equatable {
    case checking
    /// First setup: no certificate and no Apple ID yet.
    case needsAccount
    /// Signed in, but Core has not handed over a certificate yet.
    case needsCertificate
    case invalidCertificate
    /// Apps launch, but renewing needs the Apple ID again.
    case needsSignIn
    case needsPairing
    /// On mobile data: minimuxer needs Wi‑Fi even with the VPN connected.
    case needsWiFi
    /// The VPN app is not installed.
    case needsVPN
    case needsJITLess
    case ready
}

struct AnderReadinessInput: Equatable {
    var certificatePresent: Bool
    var certificateValid: Bool
    var signedIn: Bool
    var pairing: AnderPairingState
    var vpn: AnderVPNState
    var vpnAppInstalled: Bool
    var jitLessReady: Bool
}

enum AnderReadinessLogic {
    /// A tunnel that is merely off is not a problem: AnderStore turns the VPN on for each
    /// operation and off again afterwards. Before 1.6.30 the screen asked the user to turn on
    /// the VPN right after AnderStore itself had turned it off (25 September 2026).
    static func evaluate(_ input: AnderReadinessInput) -> AnderReadiness {
        guard input.certificatePresent else {
            return input.signedIn ? .needsCertificate : .needsAccount
        }
        if !input.certificateValid { return .invalidCertificate }
        if !input.signedIn { return .needsSignIn }
        switch input.pairing {
        case .checking:
            return .checking
        case .missing, .invalid:
            return .needsPairing
        case .valid:
            break
        }
        if input.vpn == .noWifi { return .needsWiFi }
        if !input.vpnAppInstalled && input.vpn != .connected { return .needsVPN }
        if !input.jitLessReady { return .needsJITLess }
        return .ready
    }
}

/// Which text the screen shows for a Core failure. The `kind` decides; nil means the kind is
/// unknown and the screen shows a general text instead of Core's raw English message.
enum AnderErrorText {
    enum Context: Equatable {
        /// The user has just typed a password: "needsAuth" means it was wrong.
        case signIn
        /// Renewal, update, portal: "needsAuth" means the stored sign-in no longer works.
        case operation
    }

    static func key(for kind: String, context: Context = .operation) -> String? {
        switch kind {
        case "cancelled":
            return "lc.account.errorCancelled"
        case "certificateRevoked":
            return "lc.account.errorRevoked"
        case "certificateLimit", "appIDLimit", "certificateExpired":
            return "lc.account.errorCertLimit"
        case "certificateNotFound":
            return "lc.certificateSync.notFound"
        case "signInRequired", "sessionExpired":
            return "lc.account.signInNeeded"
        case "needsAuth":
            return context == .signIn ? "lc.account.errorPassword" : "lc.account.signInNeeded"
        case "notInstalled":
            return "lc.update.notTracked"
        case "updateTimedOut":
            return "lc.update.timedOut"
        case "terminated", "startTimeout":
            return "lc.account.errorCoreStopped"
        case "invalidCertificate":
            return "lc.settings.invalidCertError"
        case "updateNotFound":
            return "lc.update.notFound"
        case "rateLimited":
            return "lc.account.errorRateLimited"
        case "adiNotProvisioned", "anisetteUnavailable":
            return "lc.account.errorAnisette"
        case "noVPN", "needsMinimuxer", "noConnection", "needsPairing", "noDevice", "timedOut":
            return "lc.account.errorVPN"
        case "coreUnavailable", "noBundle", "notConnected", "unsupportedCommand", "unsupportedProtocol":
            return "lc.account.errorNoExtension"
        default:
            return nil
        }
    }

    /// Fallback for messages an older Core could not classify.
    static func key(forMessage message: String, context: Context = .operation) -> String? {
        let lower = message.lowercased()
        // Before the VPN branch below, whose "connect" would otherwise swallow this.
        if lower.contains("-45061") || lower.contains("adiotprequest") || lower.contains("not provisioned") {
            return "lc.account.errorAnisette"
        }
        if lower.contains("not signed in") {
            return "lc.account.signInNeeded"
        }
        if lower.contains("429") || lower.contains("too many requests") {
            return "lc.account.errorTooMany"
        }
        if lower.contains("cancellationerror") || lower.contains("cancelled") || lower.contains("canceled") {
            return "lc.account.errorCancelled"
        }
        if lower.contains("revoked") {
            return "lc.account.errorRevoked"
        }
        if lower.contains("certificate") && (lower.contains("limit") || lower.contains("maximum")) {
            return "lc.account.errorCertLimit"
        }
        if lower.contains("password") || lower.contains("incorrect") || lower.contains("-22406") {
            return context == .signIn ? "lc.account.errorPassword" : "lc.account.signInNeeded"
        }
        if lower.contains("vpn") || lower.contains("connect") || lower.contains("timed out") || lower.contains("minimuxer") || lower.contains("heartbeat") {
            return "lc.account.errorVPN"
        }
        if lower.contains("liveprocess") || lower.contains("extension") {
            return "lc.account.errorNoExtension"
        }
        return nil
    }

    /// Failures after which the Apple ID card must turn back into the sign-in form.
    static func requiresSignIn(_ kind: String) -> Bool {
        kind == "signInRequired" || kind == "sessionExpired"
    }
}

/// When an update that stopped reporting progress is given up on instead of spinning forever.
enum AnderUpdateWatchdogPolicy {
    /// No progress or stage event for this long — Core is stuck or gone.
    static let stallLimit: TimeInterval = 3 * 60
    /// Even a slow download plus signing fits comfortably in this.
    static let totalLimit: TimeInterval = 15 * 60

    static func hasExpired(startedAt: TimeInterval,
                           lastEventAt: TimeInterval,
                           now: TimeInterval) -> Bool {
        now - lastEventAt >= stallLimit || now - startedAt >= totalLimit
    }
}

enum AnderHomeShortcutURL {
    static func make(bundleName: String, containerFolderName: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "livecontainer"
        components.host = "livecontainer-launch"
        var items = [URLQueryItem(name: "bundle-name", value: bundleName)]
        if let containerFolderName, !containerFolderName.isEmpty {
            items.append(URLQueryItem(name: "container-folder-name", value: containerFolderName))
        }
        components.queryItems = items
        return components.url
    }
}

struct AnderLatestUpdate: Equatable {
    let version: String
    let notes: String?
}

enum AnderLatestUpdateParser {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case body, draft, prerelease, assets
            case tagName = "tag_name"
        }
    }

    static func updatesManifest(_ data: Data) -> AnderLatestUpdate? {
        guard let manifest = try? JSONDecoder().decode(AnderUpdatesManifest.self, from: data),
              let url = manifest.anderstore.url,
              URL(string: url) != nil,
              validSHA256(manifest.anderstore.sha256) else { return nil }
        return AnderLatestUpdate(version: manifest.anderstore.version,
                                 notes: manifest.anderstore.notes)
    }

    static func githubRelease(_ data: Data) -> AnderLatestUpdate? {
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              !release.draft, !release.prerelease,
              release.tagName.hasPrefix("v"),
              let asset = release.assets.first(where: { $0.name == "AnderStore.ipa" }),
              URL(string: asset.browserDownloadURL) != nil,
              validGitHubDigest(asset.digest) else { return nil }
        let version = String(release.tagName.dropFirst())
        guard !version.isEmpty else { return nil }
        return AnderLatestUpdate(version: version, notes: release.body)
    }

    /// Chooses the newest valid stable result instead of trusting whichever endpoint replies
    /// first. This keeps a temporarily stale server manifest from hiding a newer GitHub release.
    static func newest(_ candidates: AnderLatestUpdate?...) -> AnderLatestUpdate? {
        candidates.compactMap { $0 }.reduce(Optional<AnderLatestUpdate>.none) { current, candidate in
            guard let current else { return candidate }
            return AnderVersioning.isNewer(version: candidate.version,
                                           build: nil,
                                           than: current.version,
                                           currentBuild: nil) ? candidate : current
        }
    }

    private static func validGitHubDigest(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("sha256:") else { return false }
        return validSHA256(String(value.dropFirst("sha256:".count)))
    }

    private static func validSHA256(_ value: String?) -> Bool {
        guard let value, value.count == 64 else { return false }
        return value.allSatisfy { $0.isHexDigit }
    }
}

enum AnderVersioning {
    static func isNewer(version: String,
                        build: String?,
                        than currentVersion: String,
                        currentBuild: String?) -> Bool {
        let versionComparison = compareNumericComponents(version, currentVersion)
        if versionComparison != .orderedSame {
            return versionComparison == .orderedDescending
        }
        guard let build, !build.isEmpty,
              let currentBuild, !currentBuild.isEmpty else { return false }
        return compareNumericComponents(build, currentBuild) == .orderedDescending
    }

    /// Missing trailing zeroes compare equal (`1.2` == `1.2.0`).
    static func compareNumericComponents(_ left: String, _ right: String) -> ComparisonResult {
        let lhs = left.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rhs = right.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : "0"
            let r = index < rhs.count ? rhs[index] : "0"
            let result = l.compare(r, options: [.numeric, .caseInsensitive])
            if result != .orderedSame { return result }
        }
        return .orderedSame
    }
}

enum AnderProvenanceIdentity {
    static func matches(installedSourceURL: String?,
                        installedBundleID: String?,
                        sourceURL: String,
                        bundleID: String) -> Bool {
        installedSourceURL == sourceURL && installedBundleID == bundleID
    }
}

enum AnderFileIntegrity {
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum AnderCertificateSyncPolicy {
    static let interval: TimeInterval = 6 * 3600

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func shouldSynchronize(force: Bool,
                                  localCertificatePresent: Bool,
                                  localCertificateValid: Bool,
                                  lastSync: TimeInterval,
                                  now: TimeInterval) -> Bool {
        force || !localCertificatePresent || !localCertificateValid || now - lastSync >= interval
    }

    static func hasChanged(oldSerial: String?,
                           oldDigest: String?,
                           newSerial: String,
                           newDigest: String) -> Bool {
        oldSerial != newSerial || oldDigest != newDigest
    }
}

/// A narrow filesystem transaction used when replacing an installed app bundle.
/// Call `commit()` after model updates; otherwise `rollback()` restores the previous bundle.
final class AnderBundleSwap {
    private let fileManager: FileManager
    private let destination: URL
    private var backup: URL?
    private var installedPreparedBundle = false

    init(destination: URL, fileManager: FileManager = .default) {
        self.destination = destination
        self.fileManager = fileManager
    }

    func installPreparedBundle(from prepared: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            let backupURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".ander-backup-\(UUID().uuidString).app")
            try fileManager.moveItem(at: destination, to: backupURL)
            backup = backupURL
        }
        do {
            try fileManager.moveItem(at: prepared, to: destination)
            installedPreparedBundle = true
        } catch {
            if let backup, fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
                self.backup = nil
            }
            throw error
        }
    }

    func rollback() {
        if installedPreparedBundle, fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        if let backup, fileManager.fileExists(atPath: backup.path) {
            try? fileManager.moveItem(at: backup, to: destination)
        }
        backup = nil
        installedPreparedBundle = false
    }

    func commit() {
        if let backup { try? fileManager.removeItem(at: backup) }
        backup = nil
        installedPreparedBundle = false
    }
}

struct AltStoreSourceResponse: Decodable {
    let name: String?
    let identifier: String?
    let subtitle: String?
    let description: String?
    let iconURL: String?
    let headerURL: String?
    let tintColor: String?
    let website: String?
    let apps: [AltStoreSourceAppResponse]?
}

struct AltStoreSourceAppResponse: Decodable {
    let beta: Bool?
    let name: String?
    let bundleIdentifier: String?
    let developerName: String?
    let subtitle: String?
    let version: String?
    let versionDate: String?
    let versionDescription: String?
    let downloadURL: String?
    let localizedDescription: String?
    let iconURL: String?
    let tintColor: String?
    let screenshotURLs: [String]?
    let versions: [AltStoreSourceAppVersionResponse]?
}

struct AltStoreSourceAppVersionResponse: Decodable {
    let version: String?
    let buildVersion: String?
    let date: String?
    let localizedDescription: String?
    let downloadURL: String?
    let size: Int64?
    let sha256: String?
    let minimumOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, buildVersion, buildNumber, date, localizedDescription, downloadURL, size, sha256
        case minimumOSVersion = "minOSVersion"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        buildVersion = try container.decodeIfPresent(String.self, forKey: .buildVersion)
            ?? container.decodeIfPresent(String.self, forKey: .buildNumber)
        date = try container.decodeIfPresent(String.self, forKey: .date)
        localizedDescription = try container.decodeIfPresent(String.self, forKey: .localizedDescription)
        downloadURL = try container.decodeIfPresent(String.self, forKey: .downloadURL)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        minimumOSVersion = try container.decodeIfPresent(String.self, forKey: .minimumOSVersion)
    }
}

struct AnderUpdatesManifest: Decodable {
    struct Artifact: Decodable {
        let version: String
        let url: String?
        let sha256: String?
        let minIOS: String?
        let minCompatible: String?
        let mandatory: Bool?
        let notes: String?
    }

    let anderstore: Artifact
    let core: Artifact
    let liveContainer: Artifact
    let installer: Artifact
}

// MARK: - VPN and signature reminder policies

/// Pure ownership bookkeeping shared by the UI coordinator and its tests. AnderStore only
/// switches off a tunnel it started itself, and only after the final dependent operation ends.
struct AnderVPNLeasePolicy: Equatable {
    private(set) var activeLeases = 0
    private(set) var startedByAnderStore = false

    mutating func acquire(tunnelWasAlreadyConnected: Bool) {
        if activeLeases == 0 {
            startedByAnderStore = !tunnelWasAlreadyConnected
        }
        activeLeases += 1
    }

    /// Returns true when the caller must request VPN shutdown.
    mutating func release() -> Bool {
        guard activeLeases > 0 else { return false }
        activeLeases -= 1
        let shouldStop = activeLeases == 0 && startedByAnderStore
        if activeLeases == 0 {
            startedByAnderStore = false
        }
        return shouldStop
    }
}

enum AnderVPNHandoffPolicy {
    static let maximumAge: TimeInterval = 2 * 60

    static func isRecoverable(createdAt: TimeInterval,
                              now: TimeInterval,
                              maximumAge: TimeInterval = maximumAge) -> Bool {
        createdAt > 0 && now >= createdAt && now - createdAt <= maximumAge
    }
}

enum AnderSignatureReminderPolicy {
    static let leadTime: TimeInterval = 48 * 60 * 60

    static func fireDate(expiration: Date) -> Date {
        expiration.addingTimeInterval(-leadTime)
    }

    static func shouldDeliverImmediately(expiration: Date, now: Date) -> Bool {
        expiration > now && fireDate(expiration: expiration) <= now
    }

    static func deliveryToken(expiration: Date) -> String {
        String(Int(expiration.timeIntervalSince1970))
    }
}
