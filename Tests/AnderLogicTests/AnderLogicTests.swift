import Foundation
import XCTest
@testable import AnderLogic

final class AnderLogicTests: XCTestCase {
    func testDeviceStatusKeepsPairingValidWhenVPNIsUnavailable() {
        let status = AnderDeviceStatusLogic.evaluate(pairing: .valid, minimuxerFailure: "noVPN")
        XCTAssertEqual(status.pairing, .valid)
        XCTAssertEqual(status.vpn, .disconnected)
        XCTAssertEqual(status.connection, .unreachable)
        XCTAssertFalse(status.ready)
    }

    func testDeviceStatusTreatsMinimuxerStartupAsChecking() {
        let status = AnderDeviceStatusLogic.evaluate(pairing: .valid, minimuxerFailure: "pairingNotLoaded")
        XCTAssertEqual(status.pairing, .valid)
        XCTAssertEqual(status.vpn, .checking)
        XCTAssertEqual(status.connection, .starting)
    }

    func testDeviceStatusOnlyInvalidatesConfirmedBadPairing() {
        let status = AnderDeviceStatusLogic.evaluate(pairing: .valid, minimuxerFailure: "invalidPairing")
        XCTAssertEqual(status.pairing, .invalid)
        XCTAssertFalse(status.pairingReady)
    }

    func testHomeShortcutURLPercentEncodesBundleAndContainer() throws {
        let url = try XCTUnwrap(AnderHomeShortcutURL.make(
            bundleName: "Приложение Test.app",
            containerFolderName: "Основной контейнер & 1"
        ))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "bundle-name" })?.value,
                       "Приложение Test.app")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "container-folder-name" })?.value,
                       "Основной контейнер & 1")
        XCTAssertTrue(url.absoluteString.contains("%20"))
    }

    func testNumericVersionsAndBuilds() {
        XCTAssertFalse(AnderVersioning.isNewer(version: "1.2.0", build: "10", than: "1.2", currentBuild: "10"))
        XCTAssertTrue(AnderVersioning.isNewer(version: "1.2", build: "11", than: "1.2.0", currentBuild: "10"))
        XCTAssertFalse(AnderVersioning.isNewer(version: "1.1.9", build: "999", than: "1.2", currentBuild: "1"))
    }

    func testProvenanceRequiresBothExactFields() {
        XCTAssertTrue(AnderProvenanceIdentity.matches(installedSourceURL: "https://store.test/source.json",
                                                       installedBundleID: "test.app",
                                                       sourceURL: "https://store.test/source.json",
                                                       bundleID: "test.app"))
        XCTAssertFalse(AnderProvenanceIdentity.matches(installedSourceURL: nil,
                                                        installedBundleID: "test.app",
                                                        sourceURL: "https://store.test/source.json",
                                                        bundleID: "test.app"))
        XCTAssertFalse(AnderProvenanceIdentity.matches(installedSourceURL: "https://other.test/source.json",
                                                        installedBundleID: "test.app",
                                                        sourceURL: "https://store.test/source.json",
                                                        bundleID: "test.app"))
    }

    func testSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("AnderStore".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try AnderFileIntegrity.sha256(of: file),
                       "85904ab99a53458bc7548d1b8842fc78d4f72c9fd2e850ccd0623f7df673ef86")
    }

    func testCertificateSyncPolicy() {
        let data = Data("certificate".utf8)
        let digest = AnderCertificateSyncPolicy.digest(data)
        XCTAssertEqual(digest.count, 64)
        XCTAssertFalse(AnderCertificateSyncPolicy.hasChanged(oldSerial: "123",
                                                              oldDigest: digest,
                                                              newSerial: "123",
                                                              newDigest: digest))
        XCTAssertTrue(AnderCertificateSyncPolicy.hasChanged(oldSerial: "old",
                                                             oldDigest: digest,
                                                             newSerial: "new",
                                                             newDigest: digest))

        let now: TimeInterval = 100_000
        XCTAssertFalse(AnderCertificateSyncPolicy.shouldSynchronize(force: false,
                                                                     localCertificatePresent: true,
                                                                     localCertificateValid: true,
                                                                     lastSync: now - 60,
                                                                     now: now))
        XCTAssertTrue(AnderCertificateSyncPolicy.shouldSynchronize(force: false,
                                                                    localCertificatePresent: false,
                                                                    localCertificateValid: true,
                                                                    lastSync: now - 60,
                                                                    now: now))
        XCTAssertTrue(AnderCertificateSyncPolicy.shouldSynchronize(force: false,
                                                                    localCertificatePresent: true,
                                                                    localCertificateValid: false,
                                                                    lastSync: now - 60,
                                                                    now: now))
        XCTAssertTrue(AnderCertificateSyncPolicy.shouldSynchronize(force: true,
                                                                    localCertificatePresent: true,
                                                                    localCertificateValid: true,
                                                                    lastSync: now,
                                                                    now: now))
    }

    func testCatalogAndUpdatesDecoding() throws {
        let catalog = #"{"name":"Test","apps":[{"name":"App","bundleIdentifier":"test.app","versions":[{"version":"2.0","buildNumber":"20","downloadURL":"app.ipa","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","minOSVersion":"16.0"}]}]}"#
        let source = try JSONDecoder().decode(AltStoreSourceResponse.self, from: Data(catalog.utf8))
        let version = try XCTUnwrap(source.apps?.first?.versions?.first)
        XCTAssertEqual(version.buildVersion, "20")
        XCTAssertEqual(version.minimumOSVersion, "16.0")
        XCTAssertEqual(version.sha256?.count, 64)

        let artifact = #"{"version":"1.6.0","url":"https://example.test/file","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
        let updates = "{\"anderstore\":\(artifact),\"core\":\(artifact),\"liveContainer\":\(artifact),\"installer\":\(artifact)}"
        let manifest = try JSONDecoder().decode(AnderUpdatesManifest.self, from: Data(updates.utf8))
        XCTAssertEqual(manifest.anderstore.version, "1.6.0")
        XCTAssertEqual(manifest.installer.sha256?.count, 64)
    }

    func testBundleReplacementRollsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("App.app")
        let prepared = root.appendingPathComponent("Prepared.app")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("marker"))
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: prepared.appendingPathComponent("marker"))

        let transaction = AnderBundleSwap(destination: destination)
        try transaction.installPreparedBundle(from: prepared)
        transaction.rollback()

        let restored = try String(contentsOf: destination.appendingPathComponent("marker"), encoding: .utf8)
        XCTAssertEqual(restored, "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
    }
}
