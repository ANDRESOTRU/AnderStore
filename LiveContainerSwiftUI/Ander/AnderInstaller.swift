//
//  AnderInstaller.swift
//  AnderStore
//
//  One way in for every install: the store, a file, a link. It used to live on the app list
//  screen, which is why installing from the store had to switch tabs first and wait half a
//  second for that screen to exist. Now the screen only answers questions it alone can answer
//  (replace or install as new), and the work happens here.
//

import Foundation
import SwiftUI
import UIKit

/// Where an app came from. Written next to the app so updates can be offered later.
struct AnderProvenance {
    let sourceURL: String
    let storeBundleId: String
    let version: String?
    let buildVersion: String?
    let expectedSHA256: String?
    let minimumOSVersion: String?
}

enum InstallSource {
    case storeApp(app: AltStoreSourceApp, sourceURL: URL)
    case fileURL(URL)
    case remoteURL(URL)
}

enum InstallMode {
    case newInstall
    case replace(LCAppModel)

    var replacement: LCAppModel? {
        if case .replace(let app) = self { return app }
        return nil
    }
}

final class AnderInstaller: ObservableObject {

    static let shared = AnderInstaller()

    /// Shown by the progress bar on the app list.
    @Published var progressVisible = false
    @Published var progressValue: Float = 0.0
    /// Catalog identifier of the app being installed, so its row in the store can show progress.
    @Published private(set) var activeStoreBundleId: String?
    /// Store identifiers still waiting in a sequential batch operation.
    @Published private(set) var queuedStoreBundleIDs: [String] = []
    @Published var errorMessage: String?

    var isBusy: Bool { progressVisible }

    /// Asks the user whether to replace an installed app or add a second copy.
    /// Set by the app list, which owns that dialog. Without it we never guess: we cancel.
    var conflictResolver: (([AppReplaceOption]) async -> AppReplaceOption?)?
    /// Downloads with the full-screen progress sheet, owned by the tab view.
    var downloader: DownloadHelper?

    private var installObserver: NSKeyValueObservation?

    private init() {}

    // MARK: - Entry points

    @MainActor
    @discardableResult
    func install(_ source: InstallSource, mode: InstallMode = .newInstall) async -> Bool {
        switch source {
        case .storeApp(let app, let sourceURL):
            guard let version = app.latestVersion else {
                report("lc.sources.error.missingDownload".loc)
                return false
            }
            if sourceURL.host?.lowercased() == "store.andresot.uk",
               (version.sha256?.isEmpty ?? true) {
                report("lc.appList.invalidChecksum".loc)
                return false
            }
            let provenance = AnderProvenance(sourceURL: sourceURL.absoluteString,
                                             storeBundleId: app.bundleIdentifier,
                                             version: version.version,
                                             buildVersion: version.buildVersion,
                                             expectedSHA256: version.sha256,
                                             minimumOSVersion: version.minimumOSVersion)
            if let minimum = version.minimumOSVersion,
               AnderPackageCheck.isVersion(minimum, newerThan: UIDevice.current.systemVersion) {
                report(String(format: "lc.appList.needsNewerIOS".loc, minimum))
                return false
            }
            return await install(urlString: version.downloadURL.absoluteString,
                                 provenance: provenance,
                                 preferredReplacement: mode.replacement)
        case .fileURL(let url):
            return await install(urlString: url.absoluteString)
        case .remoteURL(let url):
            return await install(urlString: url.absoluteString)
        }
    }

    /// The signer is deliberately serialized. A failure is recorded for that app and the
    /// remaining updates continue; the caller decides how to present the final summary.
    @MainActor
    func installSequentially(_ candidates: [AnderUpdateCandidate]) async
        -> [(candidate: AnderUpdateCandidate, succeeded: Bool)] {
        queuedStoreBundleIDs = candidates.map { $0.storeApp.bundleIdentifier }
        defer { queuedStoreBundleIDs = [] }
        var results: [(candidate: AnderUpdateCandidate, succeeded: Bool)] = []
        for candidate in candidates {
            queuedStoreBundleIDs.removeAll { $0 == candidate.storeApp.bundleIdentifier }
            let succeeded = await install(
                .storeApp(app: candidate.storeApp, sourceURL: candidate.sourceURL),
                mode: .replace(candidate.installedApp)
            )
            results.append((candidate, succeeded))
            if !succeeded { errorMessage = nil }
        }
        return results
    }

    @discardableResult
    func install(urlString: String,
                 provenance: AnderProvenance? = nil,
                 preferredReplacement: LCAppModel? = nil) async -> Bool {
        errorMessage = nil
        if urlString.lowercased().hasPrefix("itms-services://") {
            return await installFromPlist(urlString: urlString,
                                          provenance: provenance,
                                          preferredReplacement: preferredReplacement)
        }
        return await installFromUrl(urlString: urlString,
                                    provenance: provenance,
                                    preferredReplacement: preferredReplacement)
    }

    // MARK: - Sources

    @MainActor
    private func installFromPlist(urlString: String,
                                  provenance: AnderProvenance?,
                                  preferredReplacement: LCAppModel?) async -> Bool {
        if progressVisible { return false }
        guard checkPrimaryInstance() else { return false }

        var plistUrlStr = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                report("lc.appList.plistInvalidError".loc)
                return false
            }
        }

        guard let plistUrl = URL(string: plistUrlStr) else {
            report("lc.appList.urlInvalidError".loc)
            return false
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                report("lc.appList.plistParseError".loc)
                return false
            }

            var ipaUrlStr: String?
            for asset in assets {
                if let kind = asset["kind"] as? String, kind == "software-package",
                   let url = asset["url"] as? String {
                    ipaUrlStr = url
                    break
                }
            }

            guard let ipaUrlStr else {
                report("lc.appList.plistNoIpaError".loc)
                return false
            }
            return await installFromUrl(urlString: ipaUrlStr,
                                        provenance: provenance,
                                        preferredReplacement: preferredReplacement)
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    @MainActor
    private func installFromUrl(urlString: String,
                                provenance: AnderProvenance?,
                                preferredReplacement: LCAppModel?) async -> Bool {
        // One install at a time: the signer is not reentrant.
        if progressVisible {
            report("lc.appList.installBusy".loc)
            return false
        }
        guard checkPrimaryInstance() else { return false }

        guard var installUrl = URL(string: urlString) else {
            report("lc.appList.urlInvalidError".loc)
            return false
        }

        progressVisible = true
        activeStoreBundleId = provenance?.storeBundleId
        defer {
            progressVisible = false
            activeStoreBundleId = nil
        }

        if installUrl.isFileURL {
            let fileExtension = installUrl.pathExtension.lowercased()
            if fileExtension != "ipa" && fileExtension != "tipa" {
                report("lc.appList.urlFileIsNotIpaError".loc)
                return false
            }

            let fm = FileManager.default
            var didStartAccessing = false
            if !fm.isReadableFile(atPath: installUrl.path),
               let bookmarkData = LCUtils.appGroupUserDefault.data(forKey: "LCLaunchExtensionFileBookmark") {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: URL.BookmarkResolutionOptions(rawValue: 1 << 10),
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    installUrl = resolvedURL
                    didStartAccessing = resolvedURL.startAccessingSecurityScopedResource()
                } catch {
                    report("Failed to resolve shared IPA bookmark: \(error.localizedDescription)")
                    return false
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                report("lc.appList.ipaAccessError".loc)
                return false
            }

            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try verifyChecksum(of: installUrl, expected: provenance?.expectedSHA256)
                try await installIpaFile(installUrl,
                                         provenance: provenance,
                                         preferredReplacement: preferredReplacement)
            } catch is CancellationError {
                return false
            } catch {
                report(error.localizedDescription)
                return false
            }

            do {
                // delete ipa if it's in inbox
                var shouldDelete = false
                if let documentsDirectory = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let inboxURL = documentsDirectory.appendingPathComponent("Inbox")
                    shouldDelete = installUrl.deletingLastPathComponent().standardizedFileURL == inboxURL.standardizedFileURL
                }
                if shouldDelete {
                    try fm.removeItem(at: installUrl)
                }
            } catch {
                // Installation has already committed. Inbox cleanup is best-effort and must not
                // turn a successful install into a failed batch result.
            }
            return true
        }

        guard let downloader else {
            report("lc.appList.urlInvalidError".loc)
            return false
        }

        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("ipa")
            defer { try? fileManager.removeItem(at: destinationURL) }

            try await downloader.download(url: installUrl, to: destinationURL)
            if downloader.cancelled {
                return false
            }
            try verifyChecksum(of: destinationURL, expected: provenance?.expectedSHA256)
            try await installIpaFile(destinationURL,
                                     provenance: provenance,
                                     preferredReplacement: preferredReplacement)
            return true
        } catch is CancellationError {
            return false
        } catch {
            report(error.localizedDescription)
            return false
        }
    }

    // MARK: - The install itself

    private func decompress(_ path: String, _ destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }

    @MainActor
    private func installIpaFile(_ url: URL,
                                provenance: AnderProvenance?,
                                preferredReplacement: LCAppModel? = nil) async throws {
        let fm = FileManager()

        let installProgress = Progress.discreteProgress(totalUnitCount: 100)
        progressValue = 0.0
        installObserver = installProgress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async {
                AnderInstaller.shared.progressValue = Float(p.fractionCompleted)
            }
        }
        let decompressProgress = Progress.discreteProgress(totalUnitCount: 100)
        installProgress.addChild(decompressProgress, withPendingUnitCount: 80)
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("ander-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let payloadPath = stagingRoot.appendingPathComponent("Payload", isDirectory: true)

        guard await decompress(url.path, stagingRoot.path, decompressProgress) == 0 else {
            try? fm.removeItem(at: stagingRoot)
            throw "lc.appList.urlFileIsNotIpaError".loc
        }

        let payloadContents = try fm.contentsOfDirectory(atPath: payloadPath.path)
        var appBundleName: String? = nil
        for fileName in payloadContents {
            if fileName.hasSuffix(".app") {
                appBundleName = fileName
                break
            }
        }
        guard let appBundleName else {
            throw "lc.appList.bundleNotFondError".loc
        }

        let appFolderPath = payloadPath.appendingPathComponent(appBundleName)

        guard let newAppInfo = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.infoPlistCannotReadError".loc
        }

        // Refuse what LiveContainer cannot run, with a reason, instead of installing an app
        // that silently fails to start.
        if let problem = AnderPackageCheck.problem(with: newAppInfo, at: appFolderPath) {
            try? fm.removeItem(at: payloadPath)
            throw problem
        }

        let sharedModel = DataManager.shared.model
        var appRelativePath = "\(newAppInfo.bundleIdentifier()!.sanitizeNonACSII()).app"
        var outputFolder = LCPath.bundlePath.appendingPathComponent(appRelativePath)
        var appToReplace: LCAppModel? = nil
        var bundleSwap: AnderBundleSwap?
        var transactionCommitted = false
        defer {
            try? fm.removeItem(at: stagingRoot)
            if !transactionCommitted {
                bundleSwap?.rollback()
            }
        }
        var sameBundleIdApp = sharedModel.apps.filter { app in
            return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
        }
        if sameBundleIdApp.count == 0 {
            sameBundleIdApp = sharedModel.hiddenApps.filter { app in
                return app.appInfo.bundleIdentifier()! == newAppInfo.bundleIdentifier()
            }

            // we found a hidden app, we need to authenticate before proceeding
            if sameBundleIdApp.count > 0 && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        throw CancellationError()
                    }
                } catch {
                    throw error
                }
            }
        }

        if fm.fileExists(atPath: outputFolder.path) || sameBundleIdApp.count > 0 {
            appRelativePath = "\(newAppInfo.bundleIdentifier()!)_\(Int(CFAbsoluteTimeGetCurrent())).app"

            var options = [AppReplaceOption(isReplace: false, nameOfFolderToInstall: appRelativePath)]
            for app in sameBundleIdApp {
                options.append(AppReplaceOption(isReplace: true,
                                                nameOfFolderToInstall: app.appInfo.relativeBundlePath,
                                                appToReplace: app))
            }

            guard let installOptionChosen = await resolveConflict(options,
                                                                  provenance: provenance,
                                                                  preferredReplacement: preferredReplacement,
                                                                  among: sameBundleIdApp) else {
                throw CancellationError()
            }

            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
        }

        guard let stagedNewApp = LCAppInfo(bundlePath: appFolderPath.path) else {
            throw "lc.appList.appInfoInitError".loc
        }
        stagedNewApp.relativeBundlePath = appRelativePath

        // Patch and sign entirely inside the staging directory. The installed bundle remains
        // untouched until this succeeds, so a signer failure cannot interrupt a working app.
        var signError: String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                stagedNewApp.dontSign = true
            }
            stagedNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                if let signProgress {
                    installProgress.addChild(signProgress, withPendingUnitCount: 20)
                }
            }, forceSign: false)
        })

        if !signSuccess && !stagedNewApp.dontSign {
            throw (signError ?? "lc.signer.latestCertificateInvalidErr").loc
        }

        // Commit the prepared bundle. The narrow backup window below only starts after every
        // fallible preparation step has completed, and the defer above restores on any error.
        let swap = AnderBundleSwap(destination: outputFolder, fileManager: fm)
        bundleSwap = swap
        try swap.installPreparedBundle(from: appFolderPath)

        guard let finalNewApp = LCAppInfo(bundlePath: outputFolder.path) else {
            throw "lc.appList.appInfoInitError".loc
        }
        finalNewApp.relativeBundlePath = appRelativePath

        if let appToReplace {
            // copy previous configration to new app
            finalNewApp.autoSaveDisabled = true
            finalNewApp.isLocked = appToReplace.appInfo.isLocked
            finalNewApp.isHidden = appToReplace.appInfo.isHidden
            finalNewApp.isJITNeeded = appToReplace.appInfo.isJITNeeded
            finalNewApp.isShared = appToReplace.appInfo.isShared
            finalNewApp.spoofSDKVersion = appToReplace.appInfo.spoofSDKVersion
            finalNewApp.doSymlinkInbox = appToReplace.appInfo.doSymlinkInbox
            finalNewApp.containerInfo = appToReplace.appInfo.containerInfo
            finalNewApp.tweakFolder = appToReplace.appInfo.tweakFolder
            finalNewApp.selectedLanguage = appToReplace.appInfo.selectedLanguage
            finalNewApp.dataUUID = appToReplace.appInfo.dataUUID
            finalNewApp.orientationLock = appToReplace.appInfo.orientationLock
            finalNewApp.dontInjectTweakLoader = appToReplace.appInfo.dontInjectTweakLoader
            finalNewApp.hideLiveContainer = appToReplace.appInfo.hideLiveContainer
            finalNewApp.dontLoadTweakLoader = appToReplace.appInfo.dontLoadTweakLoader
            finalNewApp.doUseLCBundleId = appToReplace.appInfo.doUseLCBundleId
            finalNewApp.fixFilePickerNew = appToReplace.appInfo.fixFilePickerNew
            finalNewApp.fixLocalNotification = appToReplace.appInfo.fixLocalNotification
            finalNewApp.lastLaunched = appToReplace.appInfo.lastLaunched
            finalNewApp.jitLaunchScriptJs = appToReplace.appInfo.jitLaunchScriptJs
            finalNewApp.multitaskSpecified = appToReplace.appInfo.multitaskSpecified
            finalNewApp.classicMode = appToReplace.appInfo.classicMode
            // keep where it came from, unless this install brought newer information
            if provenance == nil {
                finalNewApp.anderSourceURL = appToReplace.appInfo.anderSourceURL
                finalNewApp.anderStoreBundleId = appToReplace.appInfo.anderStoreBundleId
                finalNewApp.anderStoreVersion = appToReplace.appInfo.anderStoreVersion
                finalNewApp.anderStoreBuildVersion = appToReplace.appInfo.anderStoreBuildVersion
            }
            finalNewApp.autoSaveDisabled = false
            finalNewApp.save()
        } else {
            // enable SDK version spoof by defalut
            finalNewApp.spoofSDKVersion = true
        }
        if let provenance {
            finalNewApp.anderSourceURL = provenance.sourceURL
            finalNewApp.anderStoreBundleId = provenance.storeBundleId
            finalNewApp.anderStoreVersion = provenance.version
            finalNewApp.anderStoreBuildVersion = provenance.buildVersion
        }
        finalNewApp.installationDate = Date.now

        if let appToReplace {
            let newAppModel = LCAppModel(appInfo: finalNewApp)

            if appToReplace.uiIsHidden {
                sharedModel.hiddenApps.removeAll { $0 == appToReplace }
                sharedModel.hiddenApps.append(newAppModel)
            } else {
                sharedModel.apps.removeAll { $0 == appToReplace }
                sharedModel.apps.append(newAppModel)
            }
        } else {
            let newAppModel = LCAppModel(appInfo: finalNewApp)
            sharedModel.apps.append(newAppModel)

            if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: urlSchemes as! [Any])
            }
        }

        transactionCommitted = true
        swap.commit()
        progressVisible = false
    }

    // MARK: - Helpers

    /// An update replaces the copy it came from without asking; anything else is the user's call.
    @MainActor
    private func resolveConflict(_ options: [AppReplaceOption],
                                 provenance: AnderProvenance?,
                                 preferredReplacement: LCAppModel?,
                                 among installed: [LCAppModel]) async -> AppReplaceOption? {
        if let preferredReplacement,
           let option = options.first(where: { $0.appToReplace == preferredReplacement }) {
            return option
        }
        if let provenance {
            let match = installed.first { $0.appInfo.anderStoreBundleId == provenance.storeBundleId }
            if let match,
               let option = options.first(where: { $0.appToReplace == match }) {
                return option
            }
        }
        guard let conflictResolver else { return nil }
        return await conflictResolver(options)
    }

    private func verifyChecksum(of url: URL, expected: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        let normalized = expected.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw "lc.appList.invalidChecksum".loc
        }

        let actual = try AnderFileIntegrity.sha256(of: url)
        guard actual == normalized else {
            throw "lc.appList.checksumMismatch".loc
        }
    }

    @MainActor
    private func checkPrimaryInstance() -> Bool {
        if DataManager.shared.model.multiLCStatus == 2 {
            report("lc.appList.manageInPrimaryTip".loc)
            return false
        }
        return true
    }

    @MainActor
    private func report(_ message: String) {
        errorMessage = message
    }
}
