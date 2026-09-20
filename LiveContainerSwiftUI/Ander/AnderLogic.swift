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
        case "noVPN", "invalidVPN", "noConnection":
            return AnderDeviceStatusValue(pairing: .valid, vpn: .disconnected, connection: .unreachable)
        case "notStarted", "pairingNotLoaded":
            return AnderDeviceStatusValue(pairing: .valid, vpn: .checking, connection: .starting)
        default:
            return AnderDeviceStatusValue(pairing: .valid, vpn: .checking, connection: .unreachable)
        }
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
