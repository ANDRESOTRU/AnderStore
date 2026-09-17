//
//  TabView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

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
            if UserDefaults.sideStoreExist() {
                AnderAccountView()
                    .tabItem {
                        Label("lc.tabView.account".loc, systemImage: "person.crop.circle.fill")
                    }
                    .tag(LCTabIdentifier.account)
            }
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
        .onAppear { AnderTheme.applyAppearance() }
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

struct AnderAccountView: View {
    @EnvironmentObject private var sharedModel: SharedModel
    @AppStorage("anderVPNInstalled") private var vpnInstalled = false
    @State private var expiration: Date? = nil
    @State private var certificateReady = false

    private var allDone: Bool { certificateReady && vpnInstalled }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    signatureCard
                    if allDone {
                        doneCard
                    } else {
                        checklist
                    }
                    Button {
                        LCUtils.openSideStore()
                    } label: {
                        Label("lc.account.open".loc, systemImage: "person.crop.circle")
                            .font(.body.weight(.medium))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AnderTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusCard))
                    }
                    Button {
                        if let url = URL(string: "https://store.andresot.uk/help") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("lc.account.help".loc, systemImage: "questionmark.circle")
                            .foregroundColor(AnderTheme.accent)
                    }
                    .padding(.top, 4)
                }
                .padding(16)
            }
            .background(AnderTheme.background.ignoresSafeArea())
            .navigationTitle("lc.tabView.account".loc)
            .onAppear(perform: reload)
        }
    }

    private func reload() {
        certificateReady = LCSharedUtils.certificatePassword() != nil
        expiration = AnderSignature.expirationDate()
        if let expiration {
            AnderSignature.scheduleReminders(expiration: expiration)
        }
    }

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
            Button {
                LCUtils.openSideStore()
            } label: {
                Label("lc.account.refreshNow".loc, systemImage: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(AnderTheme.accent.opacity(0.16))
                    .foregroundColor(AnderTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: AnderTheme.radiusButton))
            }
        }
        .anderCard()
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("lc.account.setupTitle".loc).font(.headline)
            checklistRow(done: certificateReady, number: 1, title: "lc.account.stepLogin".loc, detail: "lc.account.stepLoginDesc".loc, action: "lc.account.stepLoginAction".loc) {
                LCUtils.openSideStore()
            }
            checklistRow(done: certificateReady, number: 2, title: "lc.account.stepCert".loc, detail: "lc.account.stepCertDesc".loc, action: "lc.account.stepCertAction".loc) {
                sharedModel.selectedTab = .settings
            }
            checklistRow(done: vpnInstalled, number: 3, title: "lc.account.stepVPN".loc, detail: "lc.account.stepVPNDesc".loc, action: "lc.account.stepVPNAction".loc) {
                vpnInstalled = true
            }
        }
        .anderCard()
    }

    private func checklistRow(done: Bool, number: Int, title: String, detail: String, action: String, perform: @escaping () -> Void) -> some View {
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
                if !done {
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
