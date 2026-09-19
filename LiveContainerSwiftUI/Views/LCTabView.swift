//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Foundation
import SwiftUI
import UserNotifications
import Security

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

// MARK: - AnderStore self-update check (reads store.andresot.uk, no Core needed)
enum AnderUpdateChecker {
    static let sourceURL = URL(string: "https://store.andresot.uk/source.json")!
    static let bundleIdentifier = "com.kdt.livecontainer"

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

    /// Fetches the newest AnderStore version from the store. Calls back on the main thread.
    static func fetchLatest(completion: @escaping (_ version: String?, _ notes: String?) -> Void) {
        var request = URLRequest(url: sourceURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, _ in
            var version: String?
            var notes: String?
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let apps = json["apps"] as? [[String: Any]],
               let app = apps.first(where: { ($0["bundleIdentifier"] as? String) == bundleIdentifier }) {
                if let versions = app["versions"] as? [[String: Any]], let latest = versions.first {
                    version = latest["version"] as? String
                    notes = latest["localizedDescription"] as? String
                } else {
                    version = app["version"] as? String
                }
            }
            DispatchQueue.main.async { completion(version, notes) }
        }.resume()
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

    static func scheduleReminders(expiration: Date) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            let ids = ["anderstore.signature.2d", "anderstore.signature.1d"]
            center.removePendingNotificationRequests(withIdentifiers: ids)
            for (id, daysBefore) in zip(ids, [2.0, 1.0]) {
                let fireDate = expiration.addingTimeInterval(-daysBefore * 86_400)
                guard fireDate > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "lc.account.reminderTitle".loc
                content.body = "lc.account.reminderBody".loc
                content.sound = .default
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    }
}

// MARK: - AnderStore Core (Apple ID, signature, self-update — all without leaving AnderStore)
// Core is a background process with no interface of its own. Every capability travels through
// one command envelope, so this file needs exactly three runtime lookups no matter how many
// commands exist: SideStoreSupport is loaded with dlopen and is not linked to this module.

/// A failure reported by Core. `kind` is stable; the message is only for the log.
struct AnderCoreFailure {
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

enum AnderAccountAPI {
    private static func method(_ name: String) -> (AnyClass, Selector, IMP)? {
        guard let bridge = NSClassFromString("AnderCoreBridgeHost"),
              let metaclass = object_getClass(bridge) else { return nil }
        let selector = NSSelectorFromString(name)
        guard class_respondsToSelector(metaclass, selector),
              let implementation = class_getMethodImplementation(metaclass, selector) else { return nil }
        return (bridge, selector, implementation)
    }

    private static let availabilityMethod = method("isAvailable")
    private static let performMethod = method("performRequest:onEvent:completion:")
    private static let shutdownMethod = method("shutdown")

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

    static func status(completion: @escaping (String?, String?) -> Void) {
        let started = perform("account.status") { response, _ in
            completion(response?["appleID"] as? String, response?["team"] as? String)
        }
        if !started {
            completion(nil, nil)
        }
    }

    @discardableResult
    static func updateSelf(progress: @escaping (Double) -> Void,
                           completion: @escaping (AnderCoreFailure?) -> Void) -> Bool {
        perform("self.update",
                onEvent: { event in
                    if event["kind"] as? String == "progress", let value = event["value"] as? Double {
                        progress(value)
                    }
                },
                completion: { _, failure in completion(failure) })
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

    /// Copies the signing certificate created by Core into AnderStore (same as "Import Certificate from AnderStore").
    @discardableResult
    static func importCertificateFromCore() -> Bool {
        func keychainData(_ account: String) -> Data? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecAttrService as String: "com.kdt.livecontainer",
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
            return item as? Data
        }
        guard let certificate = keychainData("signingCertificate") else { return false }
        let password = keychainData("signingCertificatePassword").flatMap { String(data: $0, encoding: .utf8) } ?? ""
        LCUtils.appGroupUserDefault.set(certificate, forKey: "LCCertificateData")
        LCUtils.appGroupUserDefault.set(password, forKey: "LCCertificatePassword")
        LCUtils.appGroupUserDefault.set(NSDate.now, forKey: "LCCertificateUpdateDate")
        return true
    }

    /// Turns a failure from Core into a short hint. The `kind` decides — the wording of the
    /// technical message never does.
    static func friendly(_ failure: AnderCoreFailure) -> String {
        switch failure.kind {
        case "rateLimited":
            return "lc.account.errorTooMany".loc
        case "cancelled":
            return "lc.account.errorCancelled".loc
        case "certificateRevoked":
            return "lc.account.errorRevoked".loc
        case "certificateLimit", "appIDLimit", "certificateExpired":
            return "lc.account.errorCertLimit".loc
        case "needsAuth":
            return "lc.account.errorPassword".loc
        case "noVPN", "needsMinimuxer", "noConnection", "needsPairing", "noDevice", "timedOut":
            return "lc.account.errorVPN".loc
        case "coreUnavailable", "noBundle", "notConnected", "terminated", "startTimeout", "unsupportedCommand":
            return "lc.account.errorNoExtension".loc
        default:
            return friendly(failure.message)
        }
    }

    /// Fallback for messages Core could not classify.
    static func friendly(_ error: String) -> String {
        let lower = error.lowercased()
        if lower.contains("429") || lower.contains("too many requests") {
            return "lc.account.errorTooMany".loc
        }
        if lower.contains("cancellationerror") || lower.contains("cancelled") || lower.contains("canceled") {
            return "lc.account.errorCancelled".loc
        }
        if lower.contains("revoked") {
            return "lc.account.errorRevoked".loc
        }
        if lower.contains("certificate") && (lower.contains("limit") || lower.contains("maximum")) {
            return "lc.account.errorCertLimit".loc
        }
        if lower.contains("password") || lower.contains("incorrect") || lower.contains("-22406") {
            return "lc.account.errorPassword".loc
        }
        if lower.contains("vpn") || lower.contains("connect") || lower.contains("timed out") || lower.contains("minimuxer") || lower.contains("heartbeat") {
            return "lc.account.errorVPN".loc
        }
        if lower.contains("liveprocess") || lower.contains("extension") {
            return "lc.account.errorNoExtension".loc
        }
        return error
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
    @AppStorage("anderLastAutoRefresh") private var lastAutoRefresh = 0.0
    @State private var updateCheckState: String? = nil
    @AppStorage("anderSignInBlockedUntil") private var signInBlockedUntil = 0.0
    private var updateAvailable: Bool { !latestVersion.isEmpty && AnderUpdateChecker.isNewer(latestVersion, than: AnderUpdateChecker.currentVersion) }

    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("anderVPNInstalled") private var vpnInstalled = false
    @AppStorage("anderAppleID") private var savedAppleID = ""

    @ObservedObject private var state = AnderState.shared
    @State private var expiration: Date? = nil
    @State private var certificateReady = false
    @State private var coreAvailable = true
    @State private var phase: Phase = .idle
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var message: String? = nil
    @State private var showSignInForm = false

    private var signedIn: Bool { !savedAppleID.isEmpty }
    private var allDone: Bool { signedIn && certificateReady && vpnInstalled }
    private var busy: Bool {
        if case .idle = phase { return false }
        return true
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if updateAvailable || isUpdating {
                        updateCard
                    }
                    signatureCard
                    updateCheckRow
                    accountCard
                    if case .needsCode(let prompt) = phase {
                        codeCard(prompt: prompt)
                    }
                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .anderCard()
                    }
                    if allDone {
                        doneCard
                    } else {
                        checklist
                    }
                    Button {
                        if let url = URL(string: "https://store.andresot.uk/help") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("lc.account.help".loc, systemImage: "questionmark.circle")
                            .foregroundColor(AnderTheme.accent)
                    }
                    if sharedModel.developerMode {
                        Button("lc.account.advanced".loc) {
                            LCUtils.openSideStore()
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .background(AnderTheme.background.ignoresSafeArea())
            .navigationTitle("lc.tabView.device".loc)
            .onAppear(perform: reload)
        }
    }

    private var isUpdating: Bool {
        if case .updating = phase { return true }
        return false
    }

    private func updateSelf() {
        guard coreAvailable else {
            message = "lc.account.errorNoExtension".loc
            return
        }
        message = nil
        phase = .updating(0)
        let started = AnderAccountAPI.updateSelf(progress: { value in
            phase = .updating(value)
        }, completion: { failure in
            phase = .idle
            if let failure {
                message = AnderAccountAPI.friendly(failure)
            } else {
                message = nil
                latestNotes = ""
            }
        })
        if !started {
            phase = .idle
            message = "lc.account.errorNoExtension".loc
        }
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
                Text("lc.update.inProgress".loc).font(.footnote).foregroundStyle(.secondary)
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
                .disabled(busy || !signedIn)
                if !signedIn {
                    Text("lc.update.needSignIn".loc).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .anderCard()
    }

    /// Продлевает подпись сама, когда осталось мало дней (не чаще раза в 6 часов).
    private func autoRefreshIfNeeded() {
        guard coreAvailable, signedIn, !busy,
              signInCooldown == 0,
              let expiration,
              AnderSignature.daysLeft(until: expiration) <= 3,
              Date().timeIntervalSince1970 - lastAutoRefresh > 6 * 3600
        else { return }
        lastAutoRefresh = Date().timeIntervalSince1970
        refresh()
    }

    private func reload() {
        AnderUpdateChecker.checkIfNeeded()
        certificateReady = LCSharedUtils.certificatePassword() != nil
        expiration = AnderSignature.expirationDate()
        coreAvailable = AnderAccountAPI.isAvailable
        if let expiration {
            AnderSignature.scheduleReminders(expiration: expiration)
        }
        // Paints from the cached snapshot; only goes to Core when that snapshot is old.
        state.refresh()
        autoRefreshIfNeeded()
        // Core is started only by the Sign in / Refresh buttons, never on opening the tab
    }

    // MARK: Actions

    private var signInCooldown: Int {
        max(0, Int(signInBlockedUntil - Date().timeIntervalSince1970))
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
        phase = .signingIn
        let started = AnderAccountAPI.signIn(appleID: appleID, password: password, onCode: { prompt in
            code = ""
            phase = .needsCode(prompt)
        }, completion: { failure, account in
            phase = .idle
            password = ""
            if let failure {
                message = AnderAccountAPI.friendly(failure)
                // Apple ограничивает вход при частых попытках — сами держим паузу
                let pause: TimeInterval = failure.kind == "rateLimited" ? 30 * 60 : 60
                signInBlockedUntil = Date().timeIntervalSince1970 + pause
                return
            }
            signInBlockedUntil = 0
            savedAppleID = account ?? appleID
            showSignInForm = false
            certificateReady = AnderAccountAPI.importCertificateFromCore() || certificateReady
            state.invalidate()
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
        phase = .refreshing(0)
        let started = AnderAccountAPI.refresh(progress: { value in
            phase = .refreshing(value)
        }, completion: { failure in
            phase = .idle
            if let failure {
                message = AnderAccountAPI.friendly(failure)
            } else {
                certificateReady = AnderAccountAPI.importCertificateFromCore() || certificateReady
                expiration = AnderSignature.expirationDate()
                state.invalidate()
            }
        })
        if !started {
            phase = .idle
            message = "lc.account.errorNoExtension".loc
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
            if case .refreshing(let value) = phase {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: value)
                        .tint(AnderTheme.accent)
                    Text("lc.account.refreshing".loc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
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
            }
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
                Text("lc.account.signInDesc".loc).font(.footnote).foregroundStyle(.secondary)
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
            checklistRow(done: certificateReady, number: 2, title: "lc.account.stepCert".loc, detail: "lc.account.stepCertDesc".loc)
            checklistRow(done: vpnInstalled, number: 3, title: "lc.account.stepVPN".loc, detail: "lc.account.stepVPNDesc".loc,
                         action: "lc.account.stepVPNAction".loc) {
                vpnInstalled = true
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

    private var doneCard: some View {
        HStack(spacing: 12) {
            Text("🎉").font(.system(size: 30))
            VStack(alignment: .leading, spacing: 2) {
                Text("lc.account.allDone".loc).font(.headline)
                Text("lc.account.allDoneDesc".loc).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .anderCard()
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
                    Text(LCUtils.getVersionInfo()).font(.footnote).foregroundStyle(.secondary)
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
                            ? String(format: "lc.update.available".loc, version) + " — " + "lc.tabView.account".loc
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
