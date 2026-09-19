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

/// Where an app came from. Written next to the app so updates can be offered later.
struct AnderProvenance {
    let sourceURL: String
    let storeBundleId: String
    let version: String?
    let buildVersion: String?
}

final class AnderInstaller: ObservableObject {

    static let shared = AnderInstaller()

    /// Shown by the progress bar on the app list.
    @Published var progressVisible = false
    @Published var progressValue: Float = 0.0
    /// Catalog identifier of the app being installed, so its row in the store can show progress.
    @Published private(set) var activeStoreBundleId: String?
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
    func install(urlString: String, provenance: AnderProvenance? = nil) async {
        if urlString.lowercased().hasPrefix("itms-services://") {
            await installFromPlist(urlString: urlString, provenance: provenance)
            return
        }
        await installFromUrl(urlString: urlString, provenance: provenance)
    }

    @MainActor
    func installLocalFile(_ fileUrl: URL, provenance: AnderProvenance? = nil) async {
        progressVisible = true
        do {
            try await installIpaFile(fileUrl, provenance: provenance)
            try FileManager.default.removeItem(at: fileUrl)
        } catch {
            report(error.localizedDescription)
            progressVisible = false
        }
    }

    // MARK: - Sources

    @MainActor
    private func installFromPlist(urlString: String, provenance: AnderProvenance?) async {
        if progressVisible { return }
        guard checkPrimaryInstance() else { return }

        var plistUrlStr = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        if plistUrlStr.lowercased().hasPrefix("itms-services://") {
            if let urlComponents = URLComponents(string: plistUrlStr),
               let queryItems = urlComponents.queryItems,
               let urlParam = queryItems.first(where: { $0.name == "url" })?.value {
                plistUrlStr = urlParam
            } else {
                report("lc.appList.plistInvalidError".loc)
                return
            }
        }

        guard let plistUrl = URL(string: plistUrlStr) else {
            report("lc.appList.urlInvalidError".loc)
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: plistUrl)
            guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  let items = plist["items"] as? [[String: Any]],
                  let firstItem = items.first,
                  let assets = firstItem["assets"] as? [[String: Any]] else {
                report("lc.appList.plistParseError".loc)
                return
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
                return
            }
            await installFromUrl(urlString: ipaUrlStr, provenance: provenance)
        } catch {
            report(error.localizedDescription)
        }
    }

    @MainActor
    private func installFromUrl(urlString: String, provenance: AnderProvenance?) async {
        // One install at a time: the signer is not reentrant.
        if progressVisible {
            report("lc.appList.installBusy".loc)
            return
        }
        guard checkPrimaryInstance() else { return }

        guard var installUrl = URL(string: urlString) else {
            report("lc.appList.urlInvalidError".loc)
            return
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
                return
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
                    return
                }
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                didStartAccessing = installUrl.startAccessingSecurityScopedResource()
            }

            if !fm.isReadableFile(atPath: installUrl.path) && !didStartAccessing {
                report("lc.appList.ipaAccessError".loc)
                return
            }

            defer {
                if didStartAccessing {
                    installUrl.stopAccessingSecurityScopedResource()
                }
            }

            do {
                try await installIpaFile(installUrl, provenance: provenance)
            } catch {
                report(error.localizedDescription)
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
                report(error.localizedDescription)
            }
            return
        }

        guard let downloader else {
            report("lc.appList.urlInvalidError".loc)
            return
        }

        do {
            let fileManager = FileManager.default
            let destinationURL = fileManager.temporaryDirectory.appendingPathComponent(installUrl.lastPathComponent)
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }

            try await downloader.download(url: installUrl, to: destinationURL)
            if downloader.cancelled {
                return
            }
            try await installIpaFile(destinationURL, provenance: provenance)
            try fileManager.removeItem(at: destinationURL)
        } catch {
            report(error.localizedDescription)
        }
    }

    // MARK: - The install itself

    private func decompress(_ path: String, _ destination: String, _ progress: Progress) async -> Int32 {
        extract(path, destination, progress)
    }

    @MainActor
    private func installIpaFile(_ url: URL, provenance: AnderProvenance?) async throws {
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
        let payloadPath = fm.temporaryDirectory.appendingPathComponent("Payload")
        if fm.fileExists(atPath: payloadPath.path) {
            try fm.removeItem(at: payloadPath)
        }

        guard await decompress(url.path, fm.temporaryDirectory.path, decompressProgress) == 0 else {
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
                        progressVisible = false
                        return
                    }
                } catch {
                    report(error.localizedDescription)
                    progressVisible = false
                    return
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

            guard let installOptionChosen = await resolveConflict(options, provenance: provenance, among: sameBundleIdApp) else {
                // user cancelled
                progressVisible = false
                try fm.removeItem(at: payloadPath)
                return
            }

            if let appToReplace = installOptionChosen.appToReplace, appToReplace.uiIsShared {
                outputFolder = LCPath.lcGroupBundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            } else {
                outputFolder = LCPath.bundlePath.appendingPathComponent(installOptionChosen.nameOfFolderToInstall)
            }
            appRelativePath = installOptionChosen.nameOfFolderToInstall
            appToReplace = installOptionChosen.appToReplace
            if installOptionChosen.isReplace {
                try fm.removeItem(at: outputFolder)
            }
        }
        // Move it!
        try fm.moveItem(at: appFolderPath, to: outputFolder)
        let finalNewApp = LCAppInfo(bundlePath: outputFolder.path)
        finalNewApp?.relativeBundlePath = appRelativePath

        guard let finalNewApp else {
            report("lc.appList.appInfoInitError".loc)
            return
        }

        // patch and sign it
        var signError: String? = nil
        var signSuccess = false
        await withUnsafeContinuation({ c in
            if appToReplace?.uiDontSign ?? false || LCUtils.appGroupUserDefault.bool(forKey: "LCDontSignApp") {
                finalNewApp.dontSign = true
            }
            finalNewApp.patchExecAndSignIfNeed(completionHandler: { success, error in
                signError = error
                signSuccess = success
                c.resume()
            }, progressHandler: { signProgress in
                installProgress.addChild(signProgress!, withPendingUnitCount: 20)
            }, forceSign: false)
        })

        // we leave it unsigned even if signing failed
        if let signError {
            if signSuccess {
                report("\("lc.appList.signSuccessWithError".loc)\n\n\(signError)")
            } else {
                report(signError.loc)
            }
        }

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

        DispatchQueue.main.async {
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

                // add url schemes
                if let urlSchemes = finalNewApp.urlSchemes(), urlSchemes.count > 0 {
                    UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                        .addObjects(from: urlSchemes as! [Any])
                }
            }

            self.progressVisible = false
        }
    }

    // MARK: - Helpers

    /// An update replaces the copy it came from without asking; anything else is the user's call.
    @MainActor
    private func resolveConflict(_ options: [AppReplaceOption],
                                 provenance: AnderProvenance?,
                                 among installed: [LCAppModel]) async -> AppReplaceOption? {
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
