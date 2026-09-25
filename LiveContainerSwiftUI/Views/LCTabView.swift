//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import Foundation
import SwiftUI
import UserNotifications

struct LCTabView: View {
    @State var errorShow = false
    @State var crashReportShow = false
    @State var errorInfo = ""
    
    @EnvironmentObject var sharedModel : SharedModel
    @EnvironmentObject var sceneDelegate: SceneDelegate
    @State var shouldToggleMainWindowOpen = false
    @Environment(\.scenePhase) var scenePhase
    @StateObject var downloadHelper = DownloadHelper()
    @AppStorage("anderWelcomeShown") private var welcomeShown = false
    @AppStorage("anderLatestVersion") private var anderLatestVersion = ""

    let pub = NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)
    
    var body: some View {
        TabView(selection: $sharedModel.selectedTab) {
            if DataManager.shared.model.multiLCStatus != 2 {
                LCSourcesView()
                    .tabItem {
                        Label("lc.tabView.sources".loc, systemImage: "bag.fill")
                    }
                    .tag(LCTabIdentifier.sources)
            }
            LCAppListView()
                .tabItem {
                    Label("lc.tabView.apps".loc, systemImage: "square.grid.2x2.fill")
                }
                .tag(LCTabIdentifier.apps)
            // Always present: when Core is missing the screen explains it, instead of the
            // whole section quietly disappearing.
            AnderAccountView()
                .tabItem {
                    Label("lc.tabView.device".loc, systemImage: "iphone")
                }
                .badge(!anderLatestVersion.isEmpty && AnderUpdateChecker.isNewer(anderLatestVersion, than: AnderUpdateChecker.currentVersion) ? 1 : 0)
                .tag(LCTabIdentifier.account)
            LCSettingsView()
                .tabItem {
                    Label("lc.tabView.settings".loc, systemImage: "gearshape.fill")
                }
                .tag(LCTabIdentifier.settings)
        }
        .tint(AnderTheme.accent)
        .fullScreenCover(isPresented: Binding(get: { !welcomeShown }, set: { if !$0 { welcomeShown = true } })) {
            AnderWelcomeView { welcomeShown = true }
        }
        .onAppear {
            AnderTheme.applyAppearance()
            AnderUpdateChecker.checkIfNeeded()
        }
        .downloadAlert(helper: downloadHelper)
        .environmentObject(downloadHelper)
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .sheet(isPresented: $crashReportShow) {
            NavigationView {
                ScrollView {
                    Text(errorInfo)
                        .font(.system(size: 12).monospaced())
                        .fixedSize(horizontal: false, vertical: false)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if #available(iOS 16.0, *) {
                            if let log = UserDefaults.lcShared().url(forKey: "LC32BitTranslationLayerLogFile") {
                                ShareLink(item: log)
                            } else {
                                ShareLink(item: errorInfo)
                            }
                        } else {
                            Button("lc.common.copy".loc) {
                                copyError()
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("lc.common.ok".loc, action: {
                            crashReportShow = false
                        })
                    }
                }
                .navigationTitle("lc.common.error".loc)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task {
            closeDuplicatedWindow()
            checkLastLaunchError()
            checkTeamId()
            checkAndSaveBundleId()
            checkGetTaskAllow()
            checkPrivateContainerBookmark()
        }
        .onReceive(pub) { out in
            if let scene1 = sceneDelegate.window?.windowScene, let scene2 = out.object as? UIWindowScene, scene1 == scene2 {
                if shouldToggleMainWindowOpen {
                    DataManager.shared.model.mainWindowOpened = false
                }
            }
        }
        .onOpenURL { url in
            dispatchURL(url: url)
        }
    }
    
    func dispatchURL(url: URL) {
        repeat {
            if url.isFileURL {
                sharedModel.selectedTab = .apps
                break
            }
            if url.scheme?.lowercased() == "sidestore" {
                sharedModel.selectedTab = .apps
                break
            }
            
            guard let host = url.host?.lowercased() else {
                return
            }
            
            switch host {
            case "livecontainer-launch", "install", "open-web-page", "open-url":
                sharedModel.selectedTab = .apps
            case "certificate":
                sharedModel.selectedTab = .settings
            case "source":
                sharedModel.selectedTab = .sources
            default:
                return
            }
            
        } while(false)

        sharedModel.deepLink = url
    }
    
    func closeDuplicatedWindow() {
        if let session = sceneDelegate.window?.windowScene?.session, DataManager.shared.model.mainWindowOpened {
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { e in
                print(e)
            }
        } else {
            shouldToggleMainWindowOpen = true
        }
        DataManager.shared.model.mainWindowOpened = true
    }
    
    func checkLastLaunchError() {
        var errorStr = UserDefaults.standard.string(forKey: "error")
        
        if errorStr == nil && UserDefaults.standard.bool(forKey: "SigningInProgress") {
            errorStr = "lc.signer.crashDuringSignErr".loc
            UserDefaults.standard.removeObject(forKey: "SigningInProgress")
        }
        
        guard let errorStr else {
            return
        }
        UserDefaults.standard.removeObject(forKey: "error")
        errorInfo = errorStr
        crashReportShow = true
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func checkTeamId() {
        if let certificateTeamId = UserDefaults.standard.string(forKey: "LCCertificateTeamId") {
            if DataManager.shared.model.multiLCStatus != 2 {
                return
            }
            
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryAnderStoreTeamId")
                return
            }
            if certificateTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
            return
        }
        
        guard let currentTeamId = LCSharedUtils.teamIdentifier() else {
            print("Failed to determine team id.")
            return
        }
        
        if DataManager.shared.model.multiLCStatus == 2 {
            guard let primaryLCTeamId = Bundle.main.infoDictionary?["PrimaryLiveContainerTeamId"] as? String else {
                print("Unable to find PrimaryAnderStoreTeamId")
                return
            }
            if currentTeamId != primaryLCTeamId {
                errorInfo = "lc.settings.multiLC.teamIdMismatch".loc
                errorShow = true
                return
            }
        }
        UserDefaults.standard.set(currentTeamId, forKey: "LCCertificateTeamId")
    }
    
    func checkAndSaveBundleId() {
        if DataManager.shared.model.multiLCStatus == 2 {
            let scheme = UserDefaults.lcAppUrlScheme() ?? ""
            LCUtils.appGroupUserDefault.set(Bundle.main.bundleIdentifier, forKey: "LCBundleID.\(scheme)")
        }
        
        if UserDefaults.standard.bool(forKey: "LCBundleIdChecked") {
            return
        }
        
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "application-identifier" as CFString, nil), let appIdentifier = value.takeRetainedValue() as? String else {
            errorInfo = "Unable to determine application-identifier"
            errorShow = true
            return
        }
        
        guard let bundleId = Bundle.main.bundleIdentifier else {
            return
        }
        
        var correctBundleId = ""
        if appIdentifier.count > 11 {
            let startIndex = appIdentifier.index(appIdentifier.startIndex, offsetBy: 11)
            correctBundleId = String(appIdentifier[startIndex...])
        }
        
        if(bundleId != correctBundleId) {
            errorInfo = "lc.settings.bundleIdMismatch %@ %@".localizeWithFormat(bundleId, correctBundleId)
            errorShow = true
        }
        UserDefaults.standard.set(true, forKey: "LCBundleIdChecked")
    }
    
    func checkGetTaskAllow() {
        let task = SecTaskCreateFromSelf(nil)
        guard let value = SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil), (value.takeRetainedValue() as? NSNumber)?.boolValue ?? false else {
            errorInfo = "lc.settings.notDevCert".loc
            errorShow = true
            return
        }
    }
    
    func checkPrivateContainerBookmark() {
        if sharedModel.multiLCStatus == 2 {
            return
        }
        if LCUtils.appGroupUserDefault.object(forKey: "LCLaunchExtensionPrivateDocBookmark") != nil {
            return
        }
        
        guard let bookmark = LCUtils.bookmark(for: LCPath.docPath) else {
            errorInfo = "Failed to create bookmark for Documents folder?"
            errorShow = true
            return
        }
        LCUtils.appGroupUserDefault.set(bookmark, forKey: "LCLaunchExtensionPrivateDocBookmark")
    }
}

// MARK: - AnderStore theme (ANDRESOT design tokens from web.andresot.ru)
enum AnderTheme {
    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let accentUI = rgb(205, 55, 130)
    static let backgroundUI = dynamic(light: rgb(255, 255, 255), dark: rgb(20, 18, 20))
    static let surfaceUI = dynamic(light: rgb(247, 245, 247), dark: rgb(23, 20, 23))
    static let cardUI = dynamic(light: rgb(255, 255, 255), dark: rgb(37, 32, 37))
    static let borderUI = dynamic(light: rgb(0, 0, 0, 0.08), dark: rgb(255, 255, 255, 0.08))

    static let accent = Color(uiColor: accentUI)
    static let background = Color(uiColor: backgroundUI)
    static let surface = Color(uiColor: surfaceUI)
    static let card = Color(uiColor: cardUI)
    static let border = Color(uiColor: borderUI)

    static let radiusButton: CGFloat = 12
    static let radiusCard: CGFloat = 16
    static let radiusModal: CGFloat = 20

    static func applyAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = surfaceUI
        tab.shadowColor = borderUI
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        UITabBar.appearance().tintColor = accentUI

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = backgroundUI
        nav.shadowColor = .clear
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().tintColor = accentUI

        UITableView.appearance().backgroundColor = backgroundUI
        UISwitch.appearance().onTintColor = accentUI
    }
}

// MARK: - AnderStore self-update check (server manifest with stable GitHub fallback)
enum AnderUpdateChecker {
    /// Stable catalog identity. The installed bundle ID may be rewritten during signing.
    static let bundleIdentifier = "com.kdt.livecontainer"
    static let updatesURL = URL(string: "https://store.andresot.uk/updates.json")!
    static let githubLatestURL = URL(string: "https://api.github.com/repos/ANDRESOTRU/AnderStore/releases/latest")!

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// true when version a is newer than version b (compares numbers: 1.0.12 > 1.0.9).
    static func isNewer(_ a: String, than b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Fetches both sources and chooses the newest valid stable version. A stale but otherwise
    /// valid server manifest must never hide a newer GitHub release.
    static func fetchLatest(completion: @escaping (_ version: String?, _ notes: String?) -> Void) {
        Task {
            async let serverData = fetch(updatesURL)
            async let githubData = fetch(githubLatestURL)
            let (serverResult, githubResult) = await (serverData, githubData)
            let update = AnderLatestUpdateParser.newest(
                serverResult.flatMap(AnderLatestUpdateParser.updatesManifest),
                githubResult.flatMap(AnderLatestUpdateParser.githubRelease)
            )
            await MainActor.run {
                completion(update?.version, update?.notes)
            }
        }
    }

    private static func fetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AnderStore/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    /// Checks at most every 6 hours; stores the result and notifies once per new version.
    static func checkIfNeeded(force: Bool = false) {
        let defaults = UserDefaults.standard
        let last = defaults.double(forKey: "anderLastUpdateCheck")
        guard force || Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "anderLastUpdateCheck")
        fetchLatest { version, notes in
            guard let version else { return }
            defaults.set(version, forKey: "anderLatestVersion")
            defaults.set(notes ?? "", forKey: "anderLatestNotes")
            guard isNewer(version, than: currentVersion),
                  defaults.string(forKey: "anderNotifiedVersion") != version else { return }
            defaults.set(version, forKey: "anderNotifiedVersion")
            let content = UNMutableNotificationContent()
            content.title = "lc.update.notificationTitle".loc
            content.body = String(format: "lc.update.notificationBody".loc, version)
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "anderstore.update.\(version)", content: content, trigger: nil))
        }
    }
}

// MARK: - AnderStore account tab (signature status, setup checklist, opens the built-in AnderStore Core)
enum AnderSignature {
    /// Expiration date of this app's own provisioning profile — when it passes, AnderStore stops launching.
    static func expirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    static func daysLeft(until date: Date) -> Int {
        max(0, Int(ceil(date.timeIntervalSinceNow / 86_400)))
    }

    static func scheduleReminders(expiration: Date, completion: ((Bool) -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async { completion?(granted) }
            guard granted else { return }

            let id = "anderstore.signature.2d"
            let legacyIDs = ["anderstore.signature.1d",
                          "sidestore-expiration-warning.24h",
                          "sidestore-expiration-warning.6h",
                          "sidestore-expiration-warning.0h"]
            center.removePendingNotificationRequests(withIdentifiers: legacyIDs)
            center.removeDeliveredNotifications(withIdentifiers: legacyIDs)

            let now = Date()
            guard expiration > now else { return }
            let token = AnderSignatureReminderPolicy.deliveryToken(expiration: expiration)
            let tokenKey = "anderSignatureReminderToken"
            let defaults = UserDefaults.standard
            // Repeated foreground checks keep the one request/delivered notification intact.
            guard defaults.string(forKey: tokenKey) != token else { return }
            center.removePendingNotificationRequests(withIdentifiers: [id])
            center.removeDeliveredNotifications(withIdentifiers: [id])

            let content = UNMutableNotificationContent()
            content.title = "lc.account.reminderTitle".loc
            content.body = "lc.account.reminderBody".loc
            content.sound = .default
            content.userInfo = ["anderAction": "renewSignature"]

            if AnderSignatureReminderPolicy.shouldDeliverImmediately(expiration: expiration, now: now) {
                defaults.set(token, forKey: tokenKey)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                return
            }

            defaults.set(token, forKey: tokenKey)
            let fireDate = AnderSignatureReminderPolicy.fireDate(expiration: expiration)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireDate.timeIntervalSince(now)),
                repeats: false
            )
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }
}

// MARK: - AnderStore Core (Apple ID, signature, self-update — all without leaving AnderStore)
// Core is a background process with no interface of its own. Every capability travels through
// one command envelope, so this file needs exactly three runtime lookups no matter how many
// commands exist: SideStoreSupport is loaded with dlopen and is not linked to this module.

/// A failure reported by Core. `kind` is stable; the message is only for the log.
struct AnderCoreFailure: Error {
    let kind: String
    let message: String

    init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }

    init(payload: [String: Any]) {
        self.kind = payload["kind"] as? String ?? "unknown"
        self.message = payload["message"] as? String ?? ""
    }

    static let unavailable = AnderCoreFailure(kind: "coreUnavailable", message: "")
}

enum AnderCertificateSyncResult: Equatable {
    case updated
    case unchanged
}

enum AnderAccountAPI {
    private static func method(_ name: String) -> (AnyClass, Selector, IMP)? {
        guard let bridge = NSClassFromString("AnderCoreBridgeHost"),
              let metaclass = object_getClass(bridge) else { return nil }
        let selector = NSSelectorFromString(name)
        guard class_respondsToSelector(metaclass, selector),
              let implementation = class_getMethodImplementation(metaclass, selector) else { return nil }
        return (bridge, selector, implementation)
    }

    // Looked up on every call, not cached: the framework may not be loaded yet the first
    // time a screen asks, and a cached miss would never recover.
    private static var availabilityMethod: (AnyClass, Selector, IMP)? { method("isAvailable") }
    private static var performMethod: (AnyClass, Selector, IMP)? { method("performRequest:onEvent:completion:") }
    private static var shutdownMethod: (AnyClass, Selector, IMP)? { method("shutdown") }

    static var isAvailable: Bool {
        guard let (bridge, selector, implementation) = availabilityMethod else { return false }
        typealias Function = @convention(c) (AnyClass, Selector) -> Bool
        return unsafeBitCast(implementation, to: Function.self)(bridge, selector)
    }

    /// Runs one Core command. Returns false when Core is not part of this build.
    @discardableResult
    static func perform(_ command: String,
                        params: [String: Any] = [:],
                        onEvent: @escaping ([String: Any]) -> Void = { _ in },
                        completion: @escaping ([String: Any]?, AnderCoreFailure?) -> Void) -> Bool {
        guard let (bridge, selector, implementation) = performMethod else { return false }
        typealias Function = @convention(c) (AnyClass, Selector, NSDictionary,
                                             @convention(block) (NSDictionary) -> Void,
                                             @convention(block) (NSDictionary?, NSDictionary?) -> Void) -> Void
        var request = params
        request["cmd"] = command
        let eventBlock: @convention(block) (NSDictionary) -> Void = { event in
            let payload = event as? [String: Any] ?? [:]
            DispatchQueue.main.async { onEvent(payload) }
        }
        let doneBlock: @convention(block) (NSDictionary?, NSDictionary?) -> Void = { response, error in
            let responsePayload = response as? [String: Any]
            let failure = (error as? [String: Any]).map(AnderCoreFailure.init(payload:))
            DispatchQueue.main.async { completion(responsePayload, failure) }
        }
        unsafeBitCast(implementation, to: Function.self)(bridge, selector, request as NSDictionary, eventBlock, doneBlock)
        return true
    }

    /// Lets Core save and quit. It refuses while an operation is running.
    static func shutdown() {
        guard let (bridge, selector, implementation) = shutdownMethod else { return }
        typealias Function = @convention(c) (AnyClass, Selector) -> Void
        unsafeBitCast(implementation, to: Function.self)(bridge, selector)
    }

    @discardableResult
    static func signIn(appleID: String, password: String,
                       onCode: @escaping (String) -> Void,
                       completion: @escaping (AnderCoreFailure?, String?) -> Void) -> Bool {
        perform("account.signIn",
                params: ["appleID": appleID, "password": password],
                onEvent: { event in
                    if event["kind"] as? String == "needsCode" {
                        onCode(event["prompt"] as? String ?? "")
                    }
                },
                completion: { response, failure in
                    completion(failure, response?["appleID"] as? String)
                })
    }

    static func submitCode(_ code: String) {
        perform("account.submitCode", params: ["code": code]) { _, _ in }
    }

    /// Clears the stored sign-in and the Apple provisioning data, keeping the certificate so
    /// installed apps keep launching. Recovery for a broken Apple token state.
    @discardableResult
    static func resetAnisette(completion: @escaping (AnderCoreFailure?) -> Void) -> Bool {
        perform("account.resetAnisette", params: ["keepCertificate": true]) { _, failure in
            completion(failure)
        }
    }

    static func status(completion: @escaping (String?, String?) -> Void) {
        let started = perform("account.status") { response, _ in
            completion(response?["appleID"] as? String, response?["team"] as? String)
        }
        if !started {
            completion(nil, nil)
        }
    }

    @discardableResult
    static func updateSelf(version: String,
                           stage: @escaping (String) -> Void = { _ in },
                           progress: @escaping (Double) -> Void,
                           completion: @escaping (Bool?, AnderCoreFailure?) -> Void) -> Bool {
        perform("self.update",
                params: ["version": version],
                onEvent: { event in
                    switch event["kind"] as? String {
                    case "progress":
                        if let value = event["value"] as? Double { progress(value) }
                    case "stage":
                        if let value = event["value"] as? String { stage(value) }
                    default:
                        break
                    }
                },
                completion: { response, failure in
                    completion(response?["updated"] as? Bool, failure)
                })
    }

    /// One answer per update: from Core, or from the watchdog — whichever comes first.
    private final class UpdateWatch: @unchecked Sendable {
        private let lock = NSLock()
        private let startedAt = Date().timeIntervalSince1970
        private var lastEventAt = Date().timeIntervalSince1970
        private var finished = false

        // lock()/unlock() rather than NSLock.withLock: the app still supports iOS 15.
        func touch() {
            lock.lock(); defer { lock.unlock() }
            lastEventAt = Date().timeIntervalSince1970
        }
        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }
        func finishOnce() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
        func hasExpired() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return AnderUpdateWatchdogPolicy.hasExpired(startedAt: startedAt,
                                                        lastEventAt: lastEventAt,
                                                        now: Date().timeIntervalSince1970)
        }
    }

    /// Before 1.6.29 an update Core could not finish showed a bar stuck near 0 % forever:
    /// nothing timed out. Now silence for three minutes (or 15 minutes in total) ends it.
    static func updateSelfAsync(version: String,
                                stage: @escaping (String) -> Void = { _ in },
                                progress: @escaping (Double) -> Void) async throws -> Bool {
        let watch = UpdateWatch()
        return try await withCheckedThrowingContinuation { continuation in
            let finish: (Result<Bool, Error>) -> Void = { result in
                guard watch.finishOnce() else { return }
                continuation.resume(with: result)
            }
            let started = updateSelf(version: version,
                                     stage: { value in watch.touch(); stage(value) },
                                     progress: { value in watch.touch(); progress(value) }) { updated, failure in
                if let failure {
                    finish(.failure(failure))
                } else {
                    finish(.success(updated ?? false))
                }
            }
            guard started else {
                finish(.failure(AnderVPNCoordinatorError.coreUnavailable))
                return
            }
            Task {
                while !watch.isFinished {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if watch.hasExpired() {
                        finish(.failure(AnderCoreFailure(kind: "updateTimedOut",
                                                         message: "AnderStore Core stopped reporting progress")))
                    }
                }
            }
        }
    }

    /// Asks Core whether it could re-sign AnderStore right now.
    static func updateBlocker() async -> AnderUpdateBlocker? {
        await withCheckedContinuation { continuation in
            let started = perform("update.readiness") { response, _ in
                guard let response else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: AnderUpdateBlocker.from(
                    signedIn: response["signedIn"] as? Bool ?? false,
                    hasCertificate: response["hasCertificate"] as? Bool ?? false
                ))
            }
            if !started { continuation.resume(returning: nil) }
        }
    }

    @discardableResult
    static func refresh(progress: @escaping (Double) -> Void,
                        completion: @escaping (AnderCoreFailure?) -> Void) -> Bool {
        perform("apps.refresh",
                onEvent: { event in
                    if event["kind"] as? String == "progress", let value = event["value"] as? Double {
                        progress(value)
                    }
                },
                completion: { _, failure in completion(failure) })
    }

    static func refreshAsync(progress: @escaping (Double) -> Void,
                             onStarted: @escaping () -> Void = {}) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let started = refresh(progress: progress) { failure in
                if let failure {
                    continuation.resume(throwing: failure)
                } else {
                    continuation.resume(returning: ())
                }
            }
            if !started {
                continuation.resume(throwing: AnderVPNCoordinatorError.coreUnavailable)
            } else {
                onStarted()
            }
        }
    }

    /// Copies the active Core certificate through the command channel. Core runs with a
    /// different default Keychain access group, so the host must not query its items directly.
    @discardableResult
    static func synchronizeCertificateFromCore(
        completion: @escaping (AnderCertificateSyncResult?, AnderCoreFailure?) -> Void
    ) -> Bool {
        perform("certificates.active") { response, failure in
            if let failure {
                completion(nil, failure)
                return
            }
            guard let encoded = response?["data"] as? String,
                  let certificate = Data(base64Encoded: encoded),
                  let password = response?["password"] as? String,
                  let serialNumber = response?["serialNumber"] as? String,
                  !serialNumber.isEmpty else {
                completion(nil, AnderCoreFailure(kind: "invalidCertificate",
                                                 message: "Core returned an invalid certificate payload"))
                return
            }

            // Validate first. Never replace the last working certificate with a corrupt P12.
            guard LCUtils.getCertTeamId(withKeyData: certificate, password: password) != nil else {
                completion(nil, AnderCoreFailure(kind: "invalidCertificate",
                                                 message: "The active Core certificate could not be decoded"))
                return
            }

            let digest = AnderCertificateSyncPolicy.digest(certificate)
            let defaults = LCUtils.appGroupUserDefault
            let oldData = LCUtils.certificateData()
            let oldDigest = oldData.map(AnderCertificateSyncPolicy.digest)
            let changed = AnderCertificateSyncPolicy.hasChanged(
                oldSerial: defaults.string(forKey: "anderCertificateSerial"),
                oldDigest: oldDigest,
                newSerial: serialNumber,
                newDigest: digest
            )

            if changed {
                defaults.set(certificate, forKey: "LCCertificateData")
                defaults.set(password, forKey: "LCCertificatePassword")
                defaults.set(NSDate.now, forKey: "LCCertificateUpdateDate")
            }
            defaults.set(serialNumber, forKey: "anderCertificateSerial")
            defaults.set(digest, forKey: "anderCertificateSHA256")
            defaults.set(Date().timeIntervalSince1970, forKey: "anderLastCertificateSync")
            completion(changed ? .updated : .unchanged, nil)
        }
    }

    /// Turns a failure from Core into a short hint. The `kind` decides — the wording of the
    /// technical message never does. Raw English from Core is never the headline: before
    /// 1.6.30 the screen showed «You are not signed in.» as is.
    static func friendly(_ failure: AnderCoreFailure,
                         context: AnderErrorText.Context = .operation) -> String {
        if let key = AnderErrorText.key(for: failure.kind, context: context)
            ?? AnderErrorText.key(forMessage: failure.message, context: context) {
            return key.loc
        }
        return generic(details: failure.message)
    }

    /// For errors that are not Core failures (Swift or system errors).
    static func friendlyError(_ error: Error) -> String {
        if let failure = error as? AnderCoreFailure { return friendly(failure) }
        // Already written for people (and translated) — keep the precise text.
        if let vpnError = error as? AnderVPNCoordinatorError { return vpnError.localizedDescription }
        if let key = AnderErrorText.key(forMessage: error.localizedDescription) { return key.loc }
        return generic(details: error.localizedDescription)
    }

    /// What to do first, then the technical text for support.
    static func generic(details: String) -> String {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "lc.common.genericError".loc }
        return "lc.common.genericError".loc + "\n\n" + String(format: "lc.common.errorDetails".loc, trimmed)
    }
}

struct AnderAccountView: View {
    private enum Phase: Equatable {
        case idle
        case signingIn
        case needsCode(String)
        case refreshing(Double)
        case updating(Double)
    }

    @AppStorage("anderLatestVersion") private var latestVersion = ""
    @AppStorage("anderLatestNotes") private var latestNotes = ""
    @State private var updateCheckState: String? = nil
    @AppStorage("anderSignInBlockedUntil") private var signInBlockedUntil = 0.0
    private var updateAvailable: Bool { !latestVersion.isEmpty && AnderUpdateChecker.isNewer(latestVersion, than: AnderUpdateChecker.currentVersion) }

    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("anderAppleID") private var savedAppleID = ""

    @ObservedObject private var state = AnderState.shared
    @ObservedObject private var vpnCoordinator = AnderVPNCoordinator.shared
    @State private var expiration: Date? = nil
    @State private var coreAvailable = true
    @State private var phase: Phase = .idle
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var message: String? = nil
    /// Kept alongside the message so the screen can offer the right recovery.
    @State private var lastFailureKind: String? = nil
    /// Confirmation text, as opposed to `message`, which is an error.
    @State private var notice: String? = nil
    @State private var showResetConfirm = false
    @State private var cooldownTick = 0
    @State private var showSignInForm = false
    @State private var showSetupInstructions = false
    /// What the running self-update is doing: vpn, catalog, install.
    @State private var updateStage: String? = nil

    private var signedIn: Bool { state.account.signedIn }
    /// The step-by-step list is for the very first setup only; afterwards the status card
    /// says everything, and a list of ticks next to red errors only confused people.
    private var firstSetup: Bool { state.readiness == .needsAccount || state.readiness == .needsCertificate }
    private var busy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    header
                    statusCard {
                        showSignInForm = true
                        withAnimation { proxy.scrollTo("account", anchor: .top) }
                    }
                    if vpnCoordinator.needsAttention || vpnCoordinator.state == .enabling || vpnCoordinator.state == .disabling {
                        vpnCard
                    }
                    if updateAvailable || isUpdating {
                        updateCard
                    }
                    signatureCard
                    updateCheckRow
                    accountCard.id("account")
                    if case .needsCode(let prompt) = phase {
                        codeCard(prompt: prompt)
                    }
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .anderCard()
                    }
                    if let message {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(message)
                                .font(.footnote)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if showsAnisetteRecovery {
                                Button("lc.account.resetSignInData".loc) {
                                    showResetConfirm = true
                                }
                                .font(.footnote.weight(.semibold))
                                .foregroundColor(AnderTheme.accent)
                            }
                        }
                        .anderCard()
                    }
                    if let resignSummary = state.resignSummary {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(resignSummary).font(.footnote)
                            Button("lc.common.retry".loc) {
                                state.certificateDidChange()
                            }
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(AnderTheme.accent)
                        }
                        .anderCard()
                    }
                    if firstSetup {
                        checklist
                    }
                    advancedRow
                    Button {
                        showSetupInstructions = true
                    } label: {
                        Label("lc.account.help".loc, systemImage: "questionmark.circle")
                            .foregroundColor(AnderTheme.accent)
                    }
                }
                .padding(16)
            }
            }
            .background(AnderTheme.background.ignoresSafeArea())
            .navigationTitle("lc.tabView.device".loc)
            .onAppear(perform: reload)
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                if signInBlockedUntil > Date().timeIntervalSince1970 {
                    cooldownTick &+= 1
                } else if cooldownTick != 0 {
                    cooldownTick = 0
                }
            }
            .alert("lc.account.resetSignInData".loc, isPresented: $showResetConfirm) {
                Button("lc.common.cancel".loc, role: .cancel) {}
                Button("lc.common.continue".loc, role: .destructive) { resetSignInData() }
            } message: {
                Text("lc.account.resetSignInDataDesc".loc)
            }
            .sheet(isPresented: $showSetupInstructions) {
                NavigationView { AnderSetupInstructionsView() }
            }
        }
    }

    private var isUpdating: Bool {
        if case .updating = phase { return true }
        return false
    }

    private enum StatusAction {
        case noAction
        case signIn
        case setup
        case installVPN
        case recheck
    }

    /// The first thing on the screen: what is going on and the one thing to do about it.
    private func statusCard(onSignIn: @escaping () -> Void) -> some View {
        let presentation: (icon: String, color: Color, text: String, detail: String?, action: StatusAction) = {
            switch state.readiness {
            case .checking:
                return ("hourglass", .secondary, "lc.readiness.checking".loc, nil, .noAction)
            case .needsAccount:
                return ("person.crop.circle.badge.exclamationmark", .orange, "lc.readiness.needsAccount".loc, nil, .signIn)
            case .needsCertificate:
                return ("key.slash", .orange, "lc.readiness.needsCertificate".loc, nil, .noAction)
            case .invalidCertificate:
                return ("xmark.seal", .red, "lc.readiness.invalidCertificate".loc, nil, .noAction)
            case .needsSignIn:
                return ("person.crop.circle.badge.exclamationmark", .orange, "lc.readiness.needsSignIn".loc, nil, .signIn)
            case .needsPairing:
                let key = state.pairingState == .missing
                    ? "lc.readiness.pairingMissing"
                    : "lc.readiness.pairingInvalid"
                return ("iphone.and.arrow.forward", .orange, key.loc, nil, .setup)
            case .needsWiFi:
                return ("wifi.slash", .orange, "lc.readiness.needsWiFi".loc, nil, .recheck)
            case .needsVPN:
                return ("shield.slash", .orange, "lc.readiness.needsVPN".loc, nil, .installVPN)
            case .needsJITLess:
                return ("bolt.slash", .orange, "lc.readiness.needsJITLess".loc, nil, .setup)
            case .ready:
                return ("checkmark.circle.fill", .green, "lc.readiness.ready".loc, "lc.readiness.readyDetail".loc, .noAction)
            }
        }()
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.icon)
                .font(.title2)
                .foregroundColor(presentation.color)
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.text).font(.body.weight(.medium))
                if let detail = presentation.detail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Group {
                    switch presentation.action {
                    case .noAction:
                        EmptyView()
                    case .signIn:
                        Button("lc.account.stepLoginAction".loc, action: onSignIn)
                    case .setup:
                        Button("lc.readiness.fix".loc) { showSetupInstructions = true }
                    case .installVPN:
                        Button("lc.vpn.install".loc) { vpnCoordinator.openStorePage() }
                    case .recheck:
                        Button("lc.vpn.retryCheck".loc) { state.refreshDeviceStatus() }
                    }
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(AnderTheme.accent)
            }
            Spacer()
        }
        .anderCard()
    }

    private func updateSelf() {
        guard coreAvailable else {
            message = "lc.account.errorNoExtension".loc
            return
        }
        message = nil
        phase = .updating(0)
        updateStage = nil
        Task { @MainActor in
            // Core must be able to re-sign AnderStore; otherwise say why before touching VPN.
            if let blocker = await AnderAccountAPI.updateBlocker() {
                phase = .idle
                state.refreshUpdateReadiness()
                message = AnderAccountAPI.friendly(AnderCoreFailure(kind: blocker.rawValue, message: ""))
                return
            }
            updateStage = "vpn"
            do {
                let updated = try await vpnCoordinator.withVPN(reason: .selfUpdate) {
                    try await AnderAccountAPI.updateSelfAsync(version: latestVersion,
                                                              stage: { value in updateStage = value },
                                                              progress: { value in phase = .updating(value) })
                }
                phase = .idle
                updateStage = nil
                if !updated {
                    // Core already lists this version as installed.
                    message = String(format: "lc.update.alreadyInstalled".loc, latestVersion)
                } else {
                    state.markDeviceConnectionReady()
                    message = "lc.update.installed".loc
                    latestNotes = ""
                }
            } catch let failure as AnderCoreFailure {
                phase = .idle
                updateStage = nil
                if AnderErrorText.requiresSignIn(failure.kind) {
                    state.markSignInNeeded()
                }
                message = AnderAccountAPI.friendly(failure)
            } catch {
                phase = .idle
                updateStage = nil
                message = AnderAccountAPI.friendlyError(error)
            }
        }
    }

    /// Text under the progress bar: what is happening now, not a silent 0 %.
    private var updateStageText: String {
        switch updateStage {
        case "vpn":
            return "lc.update.stageVPN".loc
        case "catalog":
            return "lc.update.stageCatalog".loc
        default:
            return "lc.update.inProgress".loc
        }
    }

    private func retryVPNOperation() {
        vpnCoordinator.refreshAvailability()
        guard vpnCoordinator.appInstalled else { return }
        switch vpnCoordinator.lastReason {
        case .selfUpdate:
            updateSelf()
        case .signatureRefresh, .appsRefresh:
            refresh()
        case .deviceOperation, .none:
            state.refreshDeviceStatus()
        }
    }

    private var vpnCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: vpnCoordinator.state == .missingApp ? "shield.slash" : "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    // While switching off the job is done — "VPN required" would read as a problem.
                    Text(vpnCoordinator.state == .disabling ? "lc.common.done".loc : "lc.vpn.requiredTitle".loc)
                        .font(.body.weight(.semibold))
                    switch vpnCoordinator.state {
                    case .missingApp:
                        Text("lc.vpn.missing".loc)
                    case .enabling:
                        Text("lc.vpn.enabling".loc)
                    case .disabling:
                        Text("lc.vpn.disabling".loc)
                    case .failed(let detail):
                        Text(detail)
                    default:
                        Text("lc.vpn.requiredBody".loc)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                Spacer()
            }

            if vpnCoordinator.state == .missingApp {
                Button("lc.vpn.install".loc) { vpnCoordinator.openStore() }
                    .buttonStyle(.borderedProminent)
                    .tint(AnderTheme.accent)
            } else if case .failed = vpnCoordinator.state {
                HStack {
                    Button("lc.common.retry".loc, action: retryVPNOperation)
                    Button("lc.vpn.open".loc) { vpnCoordinator.openVPNApp() }
                }
                .buttonStyle(.bordered)
                .tint(AnderTheme.accent)
            }
            if vpnCoordinator.state == .missingApp {
                Button("lc.vpn.retryCheck".loc, action: retryVPNOperation)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AnderTheme.accent)
            }
        }
        .anderCard()
    }

    private var updateCheckRow: some View {
        VStack(spacing: 8) {
            Button {
                updateCheckState = "lc.update.checking".loc
                AnderUpdateChecker.fetchLatest { version, notes in
                    guard let version else {
                        updateCheckState = "lc.update.checkFailed".loc
                        return
                    }
                    latestVersion = version
                    latestNotes = notes ?? ""
                    updateCheckState = AnderUpdateChecker.isNewer(version, than: AnderUpdateChecker.currentVersion)
                        ? nil
                        : String(format: "lc.update.upToDate".loc, AnderUpdateChecker.currentVersion)
                }
            } label: {
                HStack {
                    Label("lc.update.check".loc, systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text(AnderUpdateChecker.currentVersion).foregroundStyle(.secondary)
                }
                .font(.body)
                .foregroundColor(AnderTheme.accent)
            }
            if let updateCheckState {
                Text(updateCheckState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .anderCard()
    }

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.app.fill")
                    .font(.system(size: 28))
                    .foregroundColor(AnderTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lc.update.title".loc).font(.footnote).foregroundStyle(.secondary)
                    Text(String(format: "lc.update.available".loc, latestVersion))
                        .font(.title3.weight(.semibold))
                }
                Spacer()
            }
            if !latestNotes.isEmpty {
                Text(latestNotes).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
            }
            Text(String(format: "lc.update.current".loc, AnderUpdateChecker.currentVersion))
                .font(.caption)
                .foregroundStyle(.secondary)
            if case .updating(let value) = phase {
                ProgressView(value: value).tint(AnderTheme.accent)
                Text(updateStageText).font(.footnote).foregroundStyle(.secondary)
            } else {
                Button(action: updateSelf) {
                    Label("lc.update.button".loc, systemImage: "arrow.down.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(AnderTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusCard))
                }
                .disabled(busy || !state.certificateValid || state.updateBlocker != nil)
                if !state.certificateValid {
                    Text("lc.readiness.needsCertificate".loc).font(.caption).foregroundStyle(.secondary)
                } else if let blocker = state.updateBlocker {
                    // The in-app update re-signs inside Core. Without Core's session or
                    // certificate it cannot finish — say what to do instead of letting it spin.
                    Text(blocker == .signInRequired
                         ? "lc.update.blockedSignIn".loc
                         : "lc.certificateSync.notFound".loc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://store.andresot.uk/download")!) {
                        Label("lc.update.useInstaller".loc, systemImage: "desktopcomputer")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(AnderTheme.accent)
                    }
                }
            }
        }
        .anderCard()
        .onAppear { state.refreshUpdateReadiness() }
    }

    private func reload() {
        AnderUpdateChecker.checkIfNeeded()
        expiration = AnderSignature.expirationDate()
        coreAvailable = AnderAccountAPI.isAvailable
        // Paints from the cached snapshot; only goes to Core when that snapshot is old.
        if !vpnCoordinator.handleForeground() {
            state.handleForeground()
        }
        if email.isEmpty { email = savedAppleID }
        // The foreground coordinator may start Core for a local, network-free certificate sync.
    }

    // MARK: Actions

    /// `cooldownTick` is only read so SwiftUI recomputes this when the timer fires — without it
    /// the button stays disabled until some unrelated change redraws the screen.
    private var signInCooldown: Int {
        _ = cooldownTick
        return max(0, Int(signInBlockedUntil - Date().timeIntervalSince1970))
    }

    /// Only offer the reset where it actually helps: a broken Apple token state.
    private var showsAnisetteRecovery: Bool {
        guard let lastFailureKind else { return false }
        return lastFailureKind == "adiNotProvisioned" || lastFailureKind == "anisetteUnavailable"
    }

    private func resetSignInData() {
        message = nil
        notice = nil
        lastFailureKind = nil
        signInBlockedUntil = 0
        let started = AnderAccountAPI.resetAnisette { failure in
            if let failure {
                message = AnderAccountAPI.friendly(failure)
                lastFailureKind = failure.kind
                return
            }
            savedAppleID = ""
            password = ""
            showSignInForm = true
            state.clearAccountAfterSignOut()
            notice = "lc.account.resetSignInDataDone".loc
        }
        if !started {
            message = "lc.account.errorNoExtension".loc
        }
    }

    private func signIn() {
        let appleID = email.trimmingCharacters(in: .whitespaces)
        guard !appleID.isEmpty, !password.isEmpty else { return }
        if signInCooldown > 0 {
            let minutes = (signInCooldown + 59) / 60
            message = String(format: "lc.account.waitBeforeRetry".loc, minutes)
            return
        }
        guard coreAvailable else {
            message = "lc.account.errorNoExtension".loc
            return
        }
        message = nil
        notice = nil
        phase = .signingIn
        let started = AnderAccountAPI.signIn(appleID: appleID, password: password, onCode: { prompt in
            code = ""
            phase = .needsCode(prompt)
        }, completion: { failure, account in
            phase = .idle
            password = ""
            if let failure {
                message = AnderAccountAPI.friendly(failure, context: .signIn)
                lastFailureKind = failure.kind
                // Пауза только там, где она осмысленна: 30 минут — это ограничение Apple,
                // короткая задержка после неверного пароля бережёт от того же ограничения,
                // а за свои ошибки (нет VPN, отмена ввода кода) блокировать не за что.
                switch failure.kind {
                case "rateLimited":
                    signInBlockedUntil = Date().timeIntervalSince1970 + 30 * 60
                case "needsAuth":
                    signInBlockedUntil = Date().timeIntervalSince1970 + 15
                default:
                    signInBlockedUntil = 0
                }
                return
            }
            lastFailureKind = nil
            message = nil
            signInBlockedUntil = 0
            savedAppleID = account ?? appleID
            showSignInForm = false
            state.didSignIn()
            state.synchronizeCertificate(force: true) { syncState in
                if case .failed(let detail) = syncState { message = detail }
                if case .missing = syncState { message = "lc.certificateSync.notFound".loc }
            }
        })
        if !started {
            phase = .idle
            message = "lc.account.errorNoExtension".loc
        }
    }

    private func submitCode(cancel: Bool = false) {
        let value = cancel ? "" : code.trimmingCharacters(in: .whitespaces)
        phase = .signingIn
        AnderAccountAPI.submitCode(value)
    }

    private func refresh() {
        guard coreAvailable else {
            message = "lc.account.errorNoExtension".loc
            return
        }
        message = nil
        // The outcome is shown once, under the button (renewalStatus). Before 1.6.30 it was
        // also copied into a second card at the bottom of the screen.
        state.renewSignatures(manual: true) { _ in
            expiration = state.signatureExpiration ?? AnderSignature.expirationDate()
        }
    }

    // MARK: Views

    private var header: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(AnderTheme.accent)
                Text("A").font(.system(size: 34, weight: .semibold)).foregroundColor(.white)
            }
            .frame(width: 72, height: 72)
            Text("AnderStore").font(.title2.weight(.semibold))
            Text("lc.account.subtitle".loc)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }

    private var signatureCard: some View {
        let days = expiration.map { AnderSignature.daysLeft(until: $0) }
        let color: Color = {
            guard let days else { return .secondary }
            if days <= 1 { return .red }
            if days <= 3 { return .orange }
            return .green
        }()
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lc.account.signature".loc).font(.footnote).foregroundStyle(.secondary)
                    if let days {
                        Text(String(format: "lc.account.daysLeft".loc, days))
                            .font(.title3.weight(.semibold))
                            .foregroundColor(color)
                    } else {
                        Text("lc.account.daysUnknown".loc).font(.body.weight(.medium))
                    }
                }
                Spacer()
            }
            Text("lc.account.refreshHint".loc)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if state.notificationPermissionDenied {
                Text("lc.account.notificationsDisabled".loc)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if case .refreshing = state.renewalState {
                EmptyView()
            } else {
                certificateSyncStatus
                Button(action: refresh) {
                    Label("lc.account.refreshNow".loc, systemImage: "arrow.clockwise")
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AnderTheme.accent.opacity(0.16))
                        .foregroundColor(AnderTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
                }
                .disabled(busy || !signedIn)
                if !signedIn, state.renewalState == .idle {
                    Text("lc.account.signInFirst".loc).font(.caption).foregroundStyle(.secondary)
                }
            }
            renewalStatus
        }
        .anderCard()
    }

    @ViewBuilder
    private var certificateSyncStatus: some View {
        switch state.certificateSyncState {
        case .idle, .current:
            // "Already up to date" is not news: say something only when it matters.
            EmptyView()
        case .syncing:
            HStack(spacing: 8) {
                ProgressView()
                Text("lc.certificateSync.syncing".loc)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .updated:
            Text("lc.certificateSync.updated".loc).font(.footnote).foregroundStyle(.green)
        case .missing:
            Text("lc.certificateSync.notFound".loc).font(.footnote).foregroundStyle(.orange)
        case .failed(let detail):
            Text(detail).font(.footnote).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var renewalStatus: some View {
        switch state.renewalState {
        case .idle:
            EmptyView()
        case .refreshing(let value):
            ProgressView(value: value)
            Text("lc.account.refreshing".loc).font(.footnote).foregroundStyle(.secondary)
        case .needsVPN:
            Text("lc.readiness.needsVPN".loc).font(.footnote).foregroundStyle(.orange)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
        case .complete:
            Text("lc.readiness.renewed".loc).font(.footnote).foregroundStyle(.green)
        }
    }

    /// Certificates, App IDs, profiles and sign-out are for people who know what they are.
    /// One row here, the rest on its own screen — like «Для опытных» in Settings.
    private var advancedRow: some View {
        NavigationLink(destination: AnderDeviceAdvancedView()) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver").frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lc.settings.advanced".loc)
                    Text("lc.device.advancedDesc".loc).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundColor(AnderTheme.accent)
            .contentShape(Rectangle())
        }
        .anderCard()
    }

    @ViewBuilder
    private var accountCard: some View {
        if signedIn && !showSignInForm {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 28))
                    .foregroundColor(AnderTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lc.account.signedInAs".loc).font(.footnote).foregroundStyle(.secondary)
                    Text(savedAppleID).font(.body.weight(.medium))
                    if let team = state.account.team, !team.isEmpty {
                        Text(team).font(.caption).foregroundStyle(.secondary)
                    }
                    if state.account.isFreeAccount {
                        Text("lc.device.freeAccount".loc)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("lc.account.change".loc) {
                    email = savedAppleID
                    showSignInForm = true
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(AnderTheme.accent)
                .disabled(busy)
            }
            .anderCard()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("lc.account.signInTitle".loc).font(.headline)
                if !signedIn && !savedAppleID.isEmpty {
                    // Was signed in before: say why the form is back instead of looking broken.
                    Text("lc.account.sessionExpiredForm".loc).font(.footnote).foregroundStyle(.orange)
                } else {
                    Text("lc.account.signInDesc".loc).font(.footnote).foregroundStyle(.secondary)
                }
                TextField("lc.account.emailPlaceholder".loc, text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(AnderTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
                SecureField("lc.account.passwordPlaceholder".loc, text: $password)
                    .textContentType(.password)
                    .padding(12)
                    .background(AnderTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
                Button(action: signIn) {
                    HStack {
                        if case .signingIn = phase {
                            ProgressView().tint(.white)
                        }
                        Text(phase == .signingIn ? "lc.account.signingIn".loc : "lc.account.signInButton".loc)
                            .font(.body.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AnderTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusCard))
                }
                .disabled(busy || email.isEmpty || password.isEmpty || signInCooldown > 0)
                if signedIn {
                    // «Сменить» opened the form over a working sign-in: allow going back.
                    Button("lc.common.cancel".loc) {
                        password = ""
                        showSignInForm = false
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(AnderTheme.accent)
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
                }
                Text("lc.account.privacy".loc).font(.caption).foregroundStyle(.secondary)
            }
            .anderCard()
        }
    }

    private func codeCard(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.account.codeTitle".loc).font(.headline)
            Text(prompt == "trustedDevice" || prompt == "sms" ? "lc.account.codeDesc".loc : prompt)
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("000000", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(12)
                .background(AnderTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
            HStack(spacing: 12) {
                Button("lc.common.cancel".loc) { submitCode(cancel: true) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AnderTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
                Button("lc.account.codeConfirm".loc) { submitCode() }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(AnderTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
                    .disabled(code.count < 6)
            }
        }
        .anderCard()
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.account.setupTitle".loc).font(.headline)
            checklistRow(done: signedIn, number: 1, title: "lc.account.stepLogin".loc, detail: "lc.account.stepLoginDesc".loc)
            checklistRow(done: state.certificateValid, number: 2, title: "lc.account.stepCert".loc, detail: "lc.account.stepCertDesc".loc)
            checklistRow(done: state.vpnReady && state.pairingReady, number: 3, title: "lc.account.stepVPN".loc, detail: "lc.account.stepVPNDesc".loc,
                         action: "lc.account.stepVPNAction".loc) {
                showSetupInstructions = true
            }
            checklistRow(done: state.jitLessReady, number: 4, title: "lc.readiness.jitTitle".loc,
                         detail: "lc.readiness.jitText".loc,
                         action: "lc.readiness.fix".loc) {
                showSetupInstructions = true
            }
        }
        .anderCard()
    }

    private func checklistRow(done: Bool, number: Int, title: String, detail: String,
                              action: String? = nil, perform: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : AnderTheme.accent)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).strikethrough(done)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
                if !done, let action, let perform {
                    Button(action, action: perform)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(AnderTheme.accent)
                }
            }
            Spacer()
        }
    }
}

extension View {
    func anderCard() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AnderTheme.card)
            .overlay(RoundedRectangle(cornerRadius: AnderTheme.radiusCard).stroke(AnderTheme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusCard))
    }
}

// MARK: - AnderStore first-launch welcome
struct AnderWelcomeView: View {
    let onFinish: () -> Void
    @State private var page = 0

    private let pages: [(icon: String, title: String, text: String)] = [
        ("bag.fill", "lc.welcome.storeTitle".loc, "lc.welcome.storeText".loc),
        ("square.grid.2x2.fill", "lc.welcome.appsTitle".loc, "lc.welcome.appsText".loc),
        ("arrow.clockwise.circle.fill", "lc.welcome.refreshTitle".loc, "lc.welcome.refreshText".loc),
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { index in
                    VStack(spacing: 20) {
                        Spacer()
                        ZStack {
                            Circle().fill(AnderTheme.accent.opacity(0.16))
                            Image(systemName: pages[index].icon)
                                .font(.system(size: 52))
                                .foregroundColor(AnderTheme.accent)
                        }
                        .frame(width: 128, height: 128)
                        Text(pages[index].title)
                            .font(.title.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(pages[index].text)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Spacer()
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page < pages.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    onFinish()
                }
            } label: {
                Text(page < pages.count - 1 ? "lc.welcome.next".loc : "lc.welcome.start".loc)
                    .font(.body.weight(.medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AnderTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusCard))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(AnderTheme.background.ignoresSafeArea())
    }
}

// MARK: - About screen (required legal notices: AGPL-3.0 / MIT)
struct AnderAboutView: View {
    @State private var updateState: String? = nil

    private struct License: Identifiable {
        let id = UUID()
        let project: String
        let license: String
        let url: String
    }

    private let licenses = [
        License(project: "LiveContainer", license: "AGPL-3.0", url: "https://github.com/LiveContainer/LiveContainer"),
        License(project: "SideStore", license: "AGPL-3.0", url: "https://github.com/SideStore/SideStore"),
        License(project: "AltStore", license: "AGPL-3.0", url: "https://github.com/altstoreio/AltStore"),
        License(project: "litehook", license: "MIT", url: "https://github.com/LiveContainer/litehook"),
        License(project: "OpenSSL", license: "Apache-2.0", url: "https://github.com/krzyzanowskim/OpenSSL"),
        License(project: "ZSign", license: "MIT", url: "https://github.com/zhlynn/zsign"),
        License(project: "minimuxer", license: "MPL-2.0", url: "https://github.com/SideStore/minimuxer"),
        License(project: "SideSign", license: "AGPL-3.0", url: "https://github.com/SideStore/SideSign"),
        License(project: "Roxas", license: "BSD", url: "https://github.com/SideStore/Roxas"),
        License(project: "fishhook", license: "BSD", url: "https://github.com/facebook/fishhook"),
        License(project: "KeychainAccess", license: "MIT", url: "https://github.com/kishikawakatsumi/KeychainAccess"),
        License(project: "Nuke", license: "MIT", url: "https://github.com/kean/Nuke")
    ]

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(AnderTheme.accent)
                        Text("A").font(.system(size: 30, weight: .semibold)).foregroundColor(.white)
                    }
                    .frame(width: 64, height: 64)
                    Text("AnderStore").font(.title3.weight(.semibold))
                    Text(AnderUpdateChecker.currentVersion).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    updateState = "lc.update.checking".loc
                    AnderUpdateChecker.fetchLatest { version, _ in
                        guard let version else {
                            updateState = "lc.update.checkFailed".loc
                            return
                        }
                        updateState = AnderUpdateChecker.isNewer(version, than: AnderUpdateChecker.currentVersion)
                            ? String(format: "lc.update.available".loc, version) + " — " + "lc.tabView.device".loc
                            : String(format: "lc.update.upToDate".loc, AnderUpdateChecker.currentVersion)
                    }
                } label: {
                    Label("lc.update.check".loc, systemImage: "arrow.triangle.2.circlepath")
                }
                if let updateState {
                    Text(updateState).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button("andresot.ru") {
                    UIApplication.shared.open(URL(string: "https://andresot.ru")!)
                }
                Button("store.andresot.uk") {
                    UIApplication.shared.open(URL(string: "https://store.andresot.uk")!)
                }
            } header: {
                Text("ANDRESOT")
            }

            Section {
                Button("github.com/ANDRESOTRU/AnderStore") {
                    UIApplication.shared.open(URL(string: "https://github.com/ANDRESOTRU/AnderStore")!)
                }
                NavigationLink("lc.device.components".loc) {
                    AnderComponentsView()
                }
            } header: {
                Text("lc.about.sourceCode".loc)
            } footer: {
                Text("lc.about.sourceCodeDesc".loc)
            }

            Section {
                ForEach(licenses) { item in
                    Button {
                        UIApplication.shared.open(URL(string: item.url)!)
                    } label: {
                        HStack {
                            Text(item.project)
                            Spacer()
                            Text(item.license).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("lc.about.licenses".loc)
            } footer: {
                Text("lc.about.licensesDesc".loc)
            }
        }
        .navigationTitle("lc.settings.aboutApp".loc)
    }
}
