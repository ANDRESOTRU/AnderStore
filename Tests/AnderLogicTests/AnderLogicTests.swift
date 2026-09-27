import Foundation
import XCTest
@testable import AnderLogic

final class AnderLogicTests: XCTestCase {
    func testInstallDownloadPauseIgnoresLateAndForeignProgress() {
        let start = Date(timeIntervalSince1970: 100)
        var operation = AnderInstallOperation(now: start)
        let id = operation.id
        operation.recordDownload(bytes: 25, expected: 100, operationID: id, now: start)
        XCTAssertEqual(operation.fraction, 0.25)
        XCTAssertTrue(operation.transition(.paused, operationID: id, now: start))
        operation.recordDownload(bytes: 50, expected: 100, operationID: id)
        XCTAssertEqual(operation.downloadedBytes, 25)
        XCTAssertFalse(operation.isDelayed(now: start.addingTimeInterval(300)))
        XCTAssertFalse(operation.transition(.downloading, operationID: UUID()))
        XCTAssertTrue(operation.transition(.downloading, operationID: id, now: start.addingTimeInterval(300)))
        operation.recordDownload(bytes: 50, expected: 100, operationID: UUID())
        XCTAssertEqual(operation.downloadedBytes, 25)
        operation.recordDownload(bytes: 50, expected: 100, operationID: id)
        XCTAssertEqual(operation.fraction, 0.5)
    }

    func testInstallUnknownSizeAndDelayFollowRealProgress() {
        let start = Date(timeIntervalSince1970: 100)
        var operation = AnderInstallOperation(now: start)
        operation.recordDownload(bytes: 5, expected: -1, operationID: operation.id, now: start)
        XCTAssertNil(operation.fraction)
        XCTAssertFalse(operation.isDelayed(now: start.addingTimeInterval(29)))
        XCTAssertTrue(operation.isDelayed(now: start.addingTimeInterval(30)))
        operation.recordDownload(bytes: 6, expected: 100, operationID: operation.id, now: start.addingTimeInterval(30))
        XCTAssertFalse(operation.isDelayed(now: start.addingTimeInterval(31)))
        operation.recordDownload(bytes: 4, expected: 100, operationID: operation.id)
        XCTAssertEqual(operation.downloadedBytes, 6)
    }

    func testInstallOnlyCommittedReplacementCanSucceed() {
        var operation = AnderInstallOperation()
        let id = operation.id
        operation.recordDownload(bytes: 100, expected: 100, operationID: id)
        XCTAssertEqual(operation.stage, .downloading) // 100% downloaded is not installed.
        XCTAssertFalse(operation.transition(.succeeded, operationID: id))
        XCTAssertTrue(operation.transition(.verifying, operationID: id))
        XCTAssertNil(operation.fraction)
        XCTAssertTrue(operation.transition(.preparing, operationID: id))
        XCTAssertFalse(operation.transition(.paused, operationID: id))
        XCTAssertTrue(operation.transition(.installing, operationID: id))
        XCTAssertFalse(operation.transition(.cancelled, operationID: id))
        XCTAssertTrue(operation.transition(.succeeded, operationID: id))
        XCTAssertFalse(operation.transition(.failed, operationID: id))
        operation.recordDownload(bytes: 0, expected: 0, operationID: id)
        XCTAssertEqual(operation.stage, .succeeded)
    }

    func testCancelledAndFailedInstallCannotBeRevivedByLateEvents() {
        for stage in [AnderInstallOperation.Stage.cancelled, .failed] {
            var old = AnderInstallOperation()
            let oldID = old.id
            XCTAssertTrue(old.transition(stage, operationID: oldID))
            XCTAssertFalse(old.transition(.verifying, operationID: oldID))
            var next = AnderInstallOperation()
            next.recordDownload(bytes: 50, expected: 100, operationID: oldID)
            XCTAssertNil(next.fraction)
            XCTAssertFalse(next.transition(.failed, operationID: oldID))
            XCTAssertEqual(next.stage, .downloading)
        }
    }

    func testPreparationProgressResetsDelayWithoutInventingPercentage() {
        let start = Date(timeIntervalSince1970: 100)
        var operation = AnderInstallOperation(stage: .verifying, now: start)
        let id = operation.id
        XCTAssertTrue(operation.transition(.preparing, operationID: id, now: start))
        operation.recordPreparation(fraction: 0.5, operationID: id, now: start.addingTimeInterval(29))
        XCTAssertFalse(operation.isDelayed(now: start.addingTimeInterval(30)))
        XCTAssertNil(operation.fraction)
        operation.recordPreparation(fraction: 0.4, operationID: id, now: start.addingTimeInterval(58))
        XCTAssertTrue(operation.isDelayed(now: start.addingTimeInterval(59)))
    }

    func testInterruptedReplacementRestoresOldCopyBeforeLoadingApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("App.app")
        let prepared = root.appendingPathComponent("Prepared.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try "new".write(to: prepared.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try AnderBundleSwap(destination: old).installPreparedBundle(from: prepared)
        // No rollback/commit: simulate process termination after moving the new bundle.
        try AnderBundleSwap.recoverInterrupted(in: root)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker"), encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["App.app"])
        try AnderBundleSwap.recoverInterrupted(in: root) // Recovery is idempotent.
    }

    func testCommittedReplacementSurvivesRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("App.app")
        let prepared = root.appendingPathComponent("Prepared.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try "old".write(to: old.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        try "new".write(to: prepared.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let swap = AnderBundleSwap(destination: old)
        try swap.installPreparedBundle(from: prepared)
        try swap.commit()
        try AnderBundleSwap.recoverInterrupted(in: root)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("marker"), encoding: .utf8), "new")
    }

    func testInterruptedNewInstallIsNotReportedAsInstalled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("App.app")
        let prepared = root.appendingPathComponent("Prepared.app")
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try AnderBundleSwap(destination: destination).installPreparedBundle(from: prepared)
        try AnderBundleSwap.recoverInterrupted(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testCompletedDownloadMayAdvanceWhenPauseArrivesAtSameTime() {
        var operation = AnderInstallOperation()
        let id = operation.id
        XCTAssertTrue(operation.transition(.paused, operationID: id))
        // URLSession already finished writing before the user pressed pause.
        XCTAssertTrue(operation.transition(.verifying, operationID: id))
        XCTAssertFalse(operation.transition(.paused, operationID: id))
        XCTAssertTrue(operation.transition(.preparing, operationID: id))
    }

    func testHomeLaunchParsesLegacyIconAndForwardedParameters() throws {
        let url = try XCTUnwrap(AnderHomeShortcutURL.make(bundleName: "Приложение Test.app", containerFolderName: "Данные & 1"))
        let request = try XCTUnwrap(AnderHomeLaunchRequest(url: url))
        XCTAssertEqual(request.bundleName, "Приложение Test.app")
        XCTAssertEqual(request.container, "Данные & 1")
        XCTAssertNil(request.openURL)
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let target = "testapp://open?name=Привет"
        components.queryItems?.append(URLQueryItem(name: "open-url", value: Data(target.utf8).base64EncodedString()))
        components.queryItems?.append(URLQueryItem(name: "jit", value: "false"))
        let forwarded = try XCTUnwrap(AnderHomeLaunchRequest(url: XCTUnwrap(components.url)))
        XCTAssertEqual(forwarded.openURL, target)
        XCTAssertEqual(forwarded.forceJIT, false)
    }

    func testHomeLaunchRejectsAmbiguousAndInvalidLinks() {
        for value in ["livecontainer://livecontainer-launch", "livecontainer://livecontainer-launch?bundle-name=ui",
                      "livecontainer://livecontainer-launch?bundle-name=../A.app",
                      "livecontainer://livecontainer-launch?bundle-name=A.app&bundle-name=B.app",
                      "livecontainer://livecontainer-launch?bundle-name=A.app&container-folder-name=../data",
                      "livecontainer://livecontainer-launch?bundle-name=A.app&open-url=bad",
                      "livecontainer://livecontainer-launch?bundle-name=A.app&jit=maybe"] {
            XCTAssertNil(URL(string: value).flatMap { AnderHomeLaunchRequest(url: $0) }, value)
        }
    }

    func testHomeLaunchGateSerializesAndAllowsRetryOnlyAfterFinish() throws {
        let first = try XCTUnwrap(URL(string: "livecontainer://livecontainer-launch?bundle-name=A.app").flatMap { AnderHomeLaunchRequest(url: $0) })
        let second = try XCTUnwrap(URL(string: "livecontainer://livecontainer-launch?bundle-name=B.app").flatMap { AnderHomeLaunchRequest(url: $0) })
        var gate = AnderHomeLaunchGate()
        XCTAssertTrue(gate.begin(first))
        XCTAssertFalse(gate.begin(first))
        XCTAssertFalse(gate.begin(second))
        XCTAssertEqual(gate.active, first)
        gate.finish()
        XCTAssertTrue(gate.begin(second))
    }

    func testProfileHTTPServesOnlyExactDownloadPath() {
        let path = "/random/AnderStoreShortcut.mobileconfig"
        XCTAssertTrue(AnderShortcutHTTP.accepts("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", path: path))
        for request in ["GET / HTTP/1.1\r\n\r\n", "POST \(path) HTTP/1.1\r\n\r\n",
                        "GET \(path)?other HTTP/1.1\r\n\r\n", "GET /random/../file HTTP/1.1\r\n\r\n"] {
            XCTAssertFalse(AnderShortcutHTTP.accepts(request, path: path))
        }
    }

    func testSelfUpdateUsesRealStagesAndClearsPreviousStageProgress() {
        var state = AnderSelfUpdateState(status: .running, lastAdvanceAt: 10)
        state.receive(["operationID": "a", "kind": "stage", "value": "download"], now: 20)
        XCTAssertEqual(state.stageKey, "lc.update.stageDownload")
        state.receive(["operationID": "a", "kind": "progress", "value": 0.4], now: 21)
        XCTAssertEqual(state.progress, 0.4)
        state.receive(["operationID": "a", "kind": "stage", "value": "prepare"], now: 22)
        XCTAssertEqual(state.stageKey, "lc.update.stagePrepare")
        XCTAssertNil(state.progress)
    }

    func testSelfUpdateRepeatedEventsDoNotHideDelay() {
        var state = AnderSelfUpdateState(operationID: "a", status: .running, stage: "download", lastAdvanceAt: 0)
        state.receive(["operationID": "a", "kind": "progress", "value": 0.2], now: 10)
        state.receive(["operationID": "a", "kind": "progress", "value": 0.2], now: 39)
        state.receive(["operationID": "a", "kind": "stage", "value": "download"], now: 39)
        XCTAssertFalse(state.isDelayed(now: 39))
        XCTAssertTrue(state.isDelayed(now: 40))
        state.receive(["operationID": "a", "kind": "progress", "value": 0.3], now: 41)
        XCTAssertFalse(state.isDelayed(now: 41))
    }

    func testSelfUpdateRejectsLateAndInvalidProgress() {
        var state = AnderSelfUpdateState(operationID: "new", status: .running, stage: "download", progress: 0.5, lastAdvanceAt: 10)
        let before = state
        state.receive(["operationID": "old", "kind": "stage", "value": "install"], now: 20)
        for value in [Double.nan, Double.infinity, -0.1, 1.1, 0.4] {
            state.receive(["operationID": "new", "kind": "progress", "value": value], now: 20)
        }
        XCTAssertEqual(state, before)
        state.status = .failed
        state.receive(["operationID": "new", "kind": "progress", "value": 1.0], now: 30)
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.progress, 0.5)
    }

    func testSelfUpdateDoesNotClaimSuccessAtOneHundredPercent() {
        var state = AnderSelfUpdateState()
        state.restore(["operationID": "a", "version": "2.0", "status": "installed",
                       "stage": "reopen", "progress": 1.0], runningVersion: "1.9")
        XCTAssertEqual(state.status, .installed)
        XCTAssertTrue(state.blocksNewUpdate)
        state.restore(["operationID": "a", "version": "2.0", "status": "running",
                       "stage": "install", "progress": 1.0], runningVersion: "2.0")
        XCTAssertEqual(state.status, .verified)
        XCTAssertFalse(state.blocksNewUpdate)
    }

    func testSelfUpdateRestoresUncertainInstallationAndAllowsOnlyConfirmedRetry() {
        var state = AnderSelfUpdateState()
        state.restore(["operationID": "a", "version": "2.0", "status": "uncertain",
                       "stage": "install", "replacementStarted": true], runningVersion: "1.9")
        XCTAssertTrue(state.blocksNewUpdate)
        XCTAssertTrue(state.replacementStarted)
        state.restore(["operationID": "a", "version": "2.0", "status": "failed",
                       "failureKind": "updateNetworkFailed"], runningVersion: "1.9")
        XCTAssertFalse(state.blocksNewUpdate)
        XCTAssertEqual(state.failureKind, "updateNetworkFailed")
    }

    func testSelfUpdateStagesAndRecoveryMessagesHaveStableKeys() {
        for (stage, key) in [("vpn", "Connection"), ("catalog", "Catalog"), ("download", "Download"),
                             ("prepare", "Prepare"), ("install", "Install"), ("reopen", "Reopen")] {
            XCTAssertEqual(AnderSelfUpdateState(stage: stage).stageKey, "lc.update.stage\(key)")
        }
        XCTAssertEqual(AnderErrorText.key(for: "updateNetworkFailed"), "lc.update.networkFailed")
        XCTAssertEqual(AnderErrorText.key(for: "updateBackgroundRequired"), "lc.update.backgroundRequired")
        XCTAssertEqual(AnderErrorText.key(for: "updateStorageFailed"), "lc.update.storageFailed")
    }

    func testUpdatesManifestRequiresArtifactIntegrity() throws {
        let good = Data(#"{"anderstore":{"version":"1.6.23","url":"https://example.test/AnderStore.ipa","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","notes":"Fix"},"core":{"version":"1"},"liveContainer":{"version":"1"},"installer":{"version":"1"}}"#.utf8)
        XCTAssertEqual(AnderLatestUpdateParser.updatesManifest(good)?.version, "1.6.23")

        let missingHash = Data(#"{"anderstore":{"version":"1.6.23","url":"https://example.test/AnderStore.ipa"},"core":{"version":"1"},"liveContainer":{"version":"1"},"installer":{"version":"1"}}"#.utf8)
        XCTAssertNil(AnderLatestUpdateParser.updatesManifest(missingHash))
    }

    func testGitHubFallbackAcceptsOnlyStableExactAssetWithDigest() throws {
        let release = Data(#"{"tag_name":"v1.6.23","body":"Fix","draft":false,"prerelease":false,"assets":[{"name":"AnderStore.ipa","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://example.test/AnderStore.ipa"}]}"#.utf8)
        XCTAssertEqual(AnderLatestUpdateParser.githubRelease(release)?.version, "1.6.23")

        let nightly = Data(#"{"tag_name":"nightly","body":"","draft":false,"prerelease":true,"assets":[{"name":"AnderStore.ipa","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://example.test/AnderStore.ipa"}]}"#.utf8)
        XCTAssertNil(AnderLatestUpdateParser.githubRelease(nightly))
    }

    func testNewestUpdatePrefersGitHubWhenServerManifestIsStale() {
        let server = AnderLatestUpdate(version: "1.6.22", notes: "Server")
        let github = AnderLatestUpdate(version: "1.6.26", notes: "GitHub")
        XCTAssertEqual(AnderLatestUpdateParser.newest(server, github), github)
        XCTAssertEqual(AnderLatestUpdateParser.newest(github, server), github)
        XCTAssertEqual(AnderLatestUpdateParser.newest(server, nil), server)
    }

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

    func testVPNLeaseOnlyStopsTunnelStartedByAnderStore() {
        var existingTunnel = AnderVPNLeasePolicy()
        existingTunnel.acquire(tunnelWasAlreadyConnected: true)
        XCTAssertFalse(existingTunnel.release())

        var ownedTunnel = AnderVPNLeasePolicy()
        ownedTunnel.acquire(tunnelWasAlreadyConnected: false)
        ownedTunnel.acquire(tunnelWasAlreadyConnected: false)
        XCTAssertFalse(ownedTunnel.release())
        XCTAssertTrue(ownedTunnel.release())
        XCTAssertEqual(ownedTunnel.activeLeases, 0)
    }

    func testVPNHandoffExpiresAfterTwoMinutes() {
        XCTAssertTrue(AnderVPNHandoffPolicy.isRecoverable(createdAt: 1_000, now: 1_119))
        XCTAssertFalse(AnderVPNHandoffPolicy.isRecoverable(createdAt: 1_000, now: 1_121))
        XCTAssertFalse(AnderVPNHandoffPolicy.isRecoverable(createdAt: 1_001, now: 1_000))
    }

    func testSignatureReminderIsExactlyTwoDaysBeforeExpiry() {
        let expiration = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(AnderSignatureReminderPolicy.fireDate(expiration: expiration),
                       expiration.addingTimeInterval(-48 * 60 * 60))
        XCTAssertTrue(AnderSignatureReminderPolicy.shouldDeliverImmediately(
            expiration: expiration,
            now: expiration.addingTimeInterval(-24 * 60 * 60)
        ))
        XCTAssertFalse(AnderSignatureReminderPolicy.shouldDeliverImmediately(
            expiration: expiration,
            now: expiration.addingTimeInterval(-72 * 60 * 60)
        ))
    }

    /// 25 September 2026: on LTE minimuxer answered noConnection while LocalDevVPN was up,
    /// and the app said «VPN не включился». No Wi-Fi is its own state now.
    func testNoConnectionMeansNoWiFiNotNoVPN() {
        let status = AnderDeviceStatusLogic.evaluate(pairing: .valid, minimuxerFailure: "noConnection")
        XCTAssertEqual(status.vpn, .noWifi)
        XCTAssertEqual(status.pairing, .valid)
        XCTAssertFalse(status.ready)
        XCTAssertEqual(AnderDeviceStatusLogic.evaluate(pairing: .valid, minimuxerFailure: "noVPN").vpn,
                       .disconnected)
    }

    func testVPNProbeDecision() {
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: "connected", vpnReady: false), .connected)
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: "checking", vpnReady: true), .connected)
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: "noWifi", vpnReady: false), .needsWiFi)
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: "disconnected", vpnReady: false), .openVPN)
        // Core still starting: wait instead of bouncing the user to LocalDevVPN.
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: "checking", vpnReady: false), .wait)
        XCTAssertEqual(AnderVPNProbeDecision.decide(vpnState: nil, vpnReady: false), .wait)
    }

    /// Self-update re-signs inside Core: no session or certificate — no update, and the
    /// interface must say why (1.6.26 → 1.6.28 hung at 0 %).
    func testUpdateBlocker() {
        XCTAssertEqual(AnderUpdateBlocker.from(signedIn: false, hasCertificate: true), .signInRequired)
        XCTAssertEqual(AnderUpdateBlocker.from(signedIn: false, hasCertificate: false), .signInRequired)
        XCTAssertEqual(AnderUpdateBlocker.from(signedIn: true, hasCertificate: false), .certificateNotFound)
        XCTAssertNil(AnderUpdateBlocker.from(signedIn: true, hasCertificate: true))
    }

    private func readiness(certificate: Bool = true,
                           signedIn: Bool = true,
                           pairing: AnderPairingState = .valid,
                           vpn: AnderVPNState = .connected,
                           vpnApp: Bool = true,
                           jitLess: Bool = true) -> AnderReadiness {
        AnderReadinessLogic.evaluate(AnderReadinessInput(
            certificatePresent: certificate,
            certificateValid: certificate,
            signedIn: signedIn,
            pairing: pairing,
            vpn: vpn,
            vpnAppInstalled: vpnApp,
            jitLessReady: jitLess
        ))
    }

    /// 25 September 2026: right after AnderStore switched its own VPN off, the screen asked
    /// the user to turn the VPN on. A switched-off tunnel is fine while the app is installed.
    func testSwitchedOffVPNIsNotAProblem() {
        XCTAssertEqual(readiness(vpn: .disconnected), .ready)
        XCTAssertEqual(readiness(vpn: .checking), .ready)
        XCTAssertEqual(readiness(vpn: .disconnected, vpnApp: false), .needsVPN)
        XCTAssertEqual(readiness(vpn: .connected, vpnApp: false), .ready)
        XCTAssertEqual(readiness(vpn: .noWifi), .needsWiFi)
    }

    /// Apps launch with the certificate, but renewal needs the Apple ID: say so first.
    func testCertificateWithoutSignInAsksToSignIn() {
        XCTAssertEqual(readiness(signedIn: false), .needsSignIn)
        XCTAssertEqual(readiness(certificate: false, signedIn: false), .needsAccount)
        XCTAssertEqual(readiness(certificate: false, signedIn: true), .needsCertificate)
        XCTAssertEqual(readiness(pairing: .checking), .checking)
        XCTAssertEqual(readiness(pairing: .missing), .needsPairing)
        XCTAssertEqual(readiness(jitLess: false), .needsJITLess)
        XCTAssertEqual(readiness(), .ready)
    }

    /// «You are not signed in.» reached the screen as raw English. Every sign-in failure
    /// now has one Russian text, and a wrong password is only "wrong" while signing in.
    func testSignInFailuresHaveOneText() {
        XCTAssertEqual(AnderErrorText.key(for: "signInRequired"), "lc.account.signInNeeded")
        XCTAssertEqual(AnderErrorText.key(for: "sessionExpired"), "lc.account.signInNeeded")
        XCTAssertEqual(AnderErrorText.key(for: "needsAuth"), "lc.account.signInNeeded")
        XCTAssertEqual(AnderErrorText.key(for: "needsAuth", context: .signIn), "lc.account.errorPassword")
        XCTAssertEqual(AnderErrorText.key(forMessage: "You are not signed in."), "lc.account.signInNeeded")
        XCTAssertTrue(AnderErrorText.requiresSignIn("signInRequired"))
        XCTAssertTrue(AnderErrorText.requiresSignIn("sessionExpired"))
        XCTAssertFalse(AnderErrorText.requiresSignIn("noVPN"))
    }

    func testUnknownFailureFallsBackToGeneralText() {
        XCTAssertNil(AnderErrorText.key(for: "unknown"))
        XCTAssertNil(AnderErrorText.key(forMessage: "Something odd happened."))
        XCTAssertEqual(AnderErrorText.key(for: "anisetteUnavailable"), "lc.account.errorAnisette")
        XCTAssertEqual(AnderErrorText.key(forMessage: "ADIOTPRequest failed (-45061)"), "lc.account.errorAnisette")
    }

    func testUpdateWatchdogEndsSilentOrEndlessUpdates() {
        XCTAssertFalse(AnderUpdateWatchdogPolicy.hasExpired(startedAt: 0, lastEventAt: 0, now: 179))
        XCTAssertTrue(AnderUpdateWatchdogPolicy.hasExpired(startedAt: 0, lastEventAt: 0, now: 180))
        // Events keep coming, but the whole update is capped.
        XCTAssertFalse(AnderUpdateWatchdogPolicy.hasExpired(startedAt: 0, lastEventAt: 800, now: 899))
        XCTAssertTrue(AnderUpdateWatchdogPolicy.hasExpired(startedAt: 0, lastEventAt: 899, now: 900))
    }
}
