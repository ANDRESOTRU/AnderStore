//
//  ContentView.swift
//  LiveContainerSwiftUI
//
//  Created by s s on 2024/8/21.
//

import Combine
import SwiftUI
import UniformTypeIdentifiers

private struct AnderUpdateRow: View {
    let candidate: AnderUpdateCandidate
    let action: () -> Void
    @ObservedObject private var installer = AnderInstaller.shared

    var body: some View {
        HStack(spacing: 12) {
            if let iconURL = candidate.storeApp.iconURL {
                AsyncImage(url: iconURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image("DefaultIcon").resizable().scaledToFill()
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            } else {
                Image("DefaultIcon")
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.storeApp.name).bold()
                Text("\(candidate.installedApp.version) → \(candidate.version.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("lc.sources.update".loc, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(installer.isBusy)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18)
            .fill(Color(uiColor: .secondarySystemBackground)))
    }
}

class SearchContext: ObservableObject {
    @Published var query: String = ""
    @Published var debouncedQuery: String = ""
    @Published var isTyping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    init() {
        $query
            .debounce(for: .seconds(0.2), scheduler: DispatchQueue.main)
            .sink { [weak self] value in
                self?.isTyping = true
                self?.debouncedQuery = value
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self?.isTyping = false
                }
            }
            .store(in: &cancellables)
    }
}

struct AppReplaceOption : Hashable {
    var isReplace: Bool
    var nameOfFolderToInstall: String
    var appToReplace: LCAppModel?
}

struct LCAppListView : View, LCAppBannerDelegate, LCAppModelDelegate {
    @State var didAppear = false
    // ipa choosing stuff
    @State var choosingIPA = false
    @State var errorShow = false
    @State var errorInfo = ""
    
    // ipa installing stuff
    @ObservedObject var installer = AnderInstaller.shared
    @ObservedObject private var catalog = AnderCatalogStore.shared
    
    @State var installOptions: [AppReplaceOption]
    @StateObject var installReplaceAlert = AlertHelper<AppReplaceOption>()
    
    @State var webViewOpened = false
    @State var webViewURL : URL = URL(string: "about:blank")!
    @StateObject private var webViewUrlInput = InputHelper()
    
    @EnvironmentObject var downloadHelper: DownloadHelper
    @StateObject private var installUrlInput = InputHelper()
    
    @State private var jitLog = ""
    @StateObject private var jitAlert = YesNoHelper()
    
    @StateObject private var runWhenMultitaskAlert = YesNoHelper()
    
    @StateObject private var generatedIconStyleSelector = AlertHelper<GeneratedIconStyle>()
    
    
    @State private var navigateTo : AnyView?
    @State private var isNavigationActive = false
    
    
    @State private var customSortViewPresent = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    @EnvironmentObject private var sharedAppSortManager : LCAppSortManager
    
    @AppStorage("LCMultitaskMode", store: LCUtils.appGroupUserDefault) var multitaskMode: MultitaskMode = .virtualWindow
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false
    
    @State private var isViewAppeared = false
    @State private var updateSummary: String?
    @State private var isUpdatingAll = false
    /// Long-press → uninstall, confirmed in two steps like the old banner did.
    @State private var uninstallTarget: LCAppModel?
    @State private var uninstallDataTarget: LCAppModel?
    @State private var shortcutOffer: LCAppModel?
    
    @ObservedObject var searchContext: SearchContext = SearchContext()
    var sortedApps: [LCAppModel] {
        return sharedAppSortManager.sortedApps
    }
    
    var sortedHiddenApps: [LCAppModel] {
        return sharedAppSortManager.sortedHiddenApps
    }
    
    var filteredApps: [LCAppModel] {
        let apps = sortedApps
        if searchContext.debouncedQuery.isEmpty {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }
    
    var filteredHiddenApps: [LCAppModel] {
        let apps = sortedHiddenApps
        if searchContext.debouncedQuery.isEmpty || !sharedModel.isHiddenAppUnlocked {
            return apps
        } else {
            return apps.filter { app in
                app.appInfo.displayName().localizedCaseInsensitiveContains(searchContext.debouncedQuery) ||
                app.appInfo.bundleIdentifier()!.localizedCaseInsensitiveContains(searchContext.debouncedQuery)
            }
        }
    }

    private var updateCandidates: [AnderUpdateCandidate] {
        var visibleApps = sharedModel.apps
        if sharedModel.isHiddenAppUnlocked {
            visibleApps += sharedModel.hiddenApps
        }
        return AnderCatalog.updateCandidates(from: catalog.sources, apps: visibleApps)
    }
    
    init() {
        _installOptions = State(initialValue: [])
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                NavigationLink(
                    destination: navigateTo,
                    isActive: $isNavigationActive,
                    label: {
                        EmptyView()
                })
                .hidden()
                
                LazyVStack {
                    if searchContext.debouncedQuery.isEmpty && !updateCandidates.isEmpty {
                        HStack {
                            Text("lc.updates.title".loc)
                                .font(.system(.title2).bold())
                            Spacer()
                            Button("lc.updates.updateAll".loc) {
                                Task { await updateAllApps() }
                            }
                            .disabled(installer.isBusy || isUpdatingAll)
                        }
                        ForEach(updateCandidates) { candidate in
                            AnderUpdateRow(candidate: candidate) {
                                Task { await update(candidate) }
                            }
                        }
                        Divider().padding(.vertical, 4)
                    }

                    appGrid(filteredApps)
                }
                .padding()
                .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredApps)

                VStack {
                    if LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                        if sharedModel.isHiddenAppUnlocked {
                            LazyVStack {
                                HStack {
                                    Text("lc.appList.hiddenApps".loc)
                                        .font(.system(.title2).bold())
                                    Spacer()
                                }
                                
                                appGrid(filteredHiddenApps)
                                
                            }
                            .padding()
                            .transition(.opacity)
                            .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                            
                            if sharedModel.hiddenApps.count == 0 {
                                Text("lc.appList.hideAppTip".loc)
                                    .foregroundStyle(.gray)
                            }
                        }
                    } else if sharedModel.hiddenApps.count > 0 {
                        LazyVStack {
                            HStack {
                                Text("lc.appList.hiddenApps".loc)
                                    .font(.system(.title2).bold())
                                Spacer()
                            }
                            Group {
                                if sharedModel.isHiddenAppUnlocked {
                                    appGrid(filteredHiddenApps)
                                } else {
                                    LazyVGrid(columns: Self.gridColumns, spacing: 16) {
                                        // The cell takes no model, so nothing about a hidden app
                                        // reaches the screen before authentication.
                                        ForEach(filteredHiddenApps, id: \.self) { _ in
                                            LCAppGridSkeletonCell()
                                        }
                                    }
                                }
                            }
                            .animation(.easeInOut, value: sharedModel.isHiddenAppUnlocked)
                            .onTapGesture {
                                Task { await authenticateUser() }
                            }
                        }
                        .padding()
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: filteredHiddenApps)
                    }

                    let appCount = sharedModel.isHiddenAppUnlocked ? filteredApps.count + filteredHiddenApps.count : filteredApps.count
                    Text(appCount > 0 || searchContext.debouncedQuery != "" ? "lc.appList.appCounter %lld".localizeWithFormat(appCount) : (sharedModel.multiLCStatus == 2 ? "lc.appList.convertToSharedToShowInLC2".loc : "lc.appList.installTip".loc))
                        .padding(.horizontal)
                        .foregroundStyle(.gray)
                        .animation(searchContext.isTyping ? nil : .easeInOut, value: appCount)
                        .onTapGesture(count: 3) {
                            Task { await authenticateUser() }
                        }
                }.animation(searchContext.isTyping ? nil : .easeInOut, value: LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding"))

                if sharedModel.multiLCStatus == 2 {
                    Text("lc.appList.manageInPrimaryTip".loc).foregroundStyle(.gray).padding()
                }

            }
            .navigationBarProgressBar(show: $installer.progressVisible, progress: $installer.progressValue)
            .coordinateSpace(name: "scroll")
            .onAppear {
                bindInstaller()
                if !didAppear {
                    onAppear()
                }
            }
            .onReceive(installer.$errorMessage.compactMap { $0 }) { message in
                errorInfo = message
                errorShow = true
                installer.errorMessage = nil
            }
            .onReceive(installer.$pendingShortcutApp.compactMap { $0 }) { app in
                shortcutOffer = app
            }
            
            .navigationTitle("lc.tabView.apps".loc)
            .navigationBarTitleDisplayMode(.inline)

        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: $errorShow){
            Button("lc.common.ok".loc, action: {
            })
            Button("lc.common.copy".loc, action: {
                copyError()
            })
        } message: {
            Text(errorInfo)
        }
        .alert("lc.updates.summaryTitle".loc,
               isPresented: Binding(get: { updateSummary != nil },
                                    set: { if !$0 { updateSummary = nil } })) {
            Button("lc.common.ok".loc) { updateSummary = nil }
        } message: {
            Text(updateSummary ?? "")
        }
        .alert("lc.appBanner.confirmUninstallTitle".loc,
               isPresented: Binding(get: { uninstallTarget != nil },
                                    set: { if !$0 { uninstallTarget = nil } })) {
            Button("lc.appBanner.uninstall".loc, role: .destructive) {
                guard let app = uninstallTarget else { return }
                uninstallTarget = nil
                // Offer to take the data too, but only when there is any.
                if app.appInfo.containers.isEmpty {
                    performUninstall(app, removeData: false)
                } else {
                    uninstallDataTarget = app
                }
            }
            Button("lc.common.cancel".loc, role: .cancel) { uninstallTarget = nil }
        } message: {
            Text("lc.appBanner.confirmUninstallMsg %@".localizeWithFormat(uninstallTarget?.appInfo.displayName() ?? ""))
        }
        .alert("lc.appBanner.deleteDataTitle".loc,
               isPresented: Binding(get: { uninstallDataTarget != nil },
                                    set: { if !$0 { uninstallDataTarget = nil } })) {
            Button("lc.common.delete".loc, role: .destructive) {
                guard let app = uninstallDataTarget else { return }
                uninstallDataTarget = nil
                performUninstall(app, removeData: true)
            }
            Button("lc.common.no".loc, role: .cancel) {
                guard let app = uninstallDataTarget else { return }
                uninstallDataTarget = nil
                performUninstall(app, removeData: false)
            }
        } message: {
            Text("lc.appBanner.deleteDataMsg %@".localizeWithFormat(uninstallDataTarget?.appInfo.displayName() ?? ""))
        }
        .alert("lc.shortcut.offerTitle".loc,
               isPresented: Binding(get: { shortcutOffer != nil },
                                    set: { if !$0 { shortcutOffer = nil; installer.consumeShortcutOffer() } })) {
            Button("lc.shortcut.add".loc) {
                guard let app = shortcutOffer else { return }
                shortcutOffer = nil
                installer.consumeShortcutOffer()
                Task { await createHomeScreenShortcut(for: app) }
            }
            Button("lc.shortcut.later".loc, role: .cancel) {
                shortcutOffer = nil
                installer.consumeShortcutOffer()
            }
        } message: {
            Text(String(format: "lc.shortcut.offerMessage".loc, shortcutOffer?.displayName ?? ""))
        }
        .betterFileImporter(isPresented: $choosingIPA, types: [.ipa, .tipa], multiple: false, callback: { fileUrls in
            Task { await installer.install(.fileURL(fileUrls[0])) }
        }, onDismiss: {
            choosingIPA = false
        })
        .alert("lc.appList.installation".loc, isPresented: $installReplaceAlert.show) {
            ForEach(installOptions, id: \.self) { installOption in
                Button(role: installOption.isReplace ? .destructive : nil, action: {
                    installReplaceAlert.close(result: installOption)
                }, label: {
                    Text(installOption.isReplace ? installOption.nameOfFolderToInstall : "lc.appList.installAsNew".loc)
                })
            
            }
            Button(role: .cancel, action: {
                installReplaceAlert.close(result: nil)
            }, label: {
                Text("lc.appList.abortInstallation".loc)
            })
        } message: {
            Text("lc.appList.installReplaceTip".loc)
        }
        .alert("lc.webView.runApp".loc, isPresented: $runWhenMultitaskAlert.show) {
            Button(role: .destructive) {
                runWhenMultitaskAlert.close(result: true)
            } label: {
                Text("lc.common.continue".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                runWhenMultitaskAlert.close(result: false)
            }
        } message: {
            Text("lc.appBanner.confirmRunWhenMultitasking".loc)
        }
        .alert("lc.appList.generatedIconStyleSelector.title".loc, isPresented:$generatedIconStyleSelector.show) {
            Button {
                generatedIconStyleSelector.close(result: .Light)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.light".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Dark)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.dark".loc)
            }
            Button {
                generatedIconStyleSelector.close(result: .Original)
            } label: {
                Text("lc.appList.generatedIconStyleSelector.original".loc)
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                generatedIconStyleSelector.close(result: nil)
            }
        }
        .textFieldAlert(
            isPresented: $webViewUrlInput.show,
            title:  "lc.appList.enterUrlTip".loc,
            text: $webViewUrlInput.initVal,
            placeholder: "scheme://",
            action: { newText in
                webViewUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                webViewUrlInput.close(result: nil)
            }
        )
        .textFieldAlert(
            isPresented: $installUrlInput.show,
            title:  "lc.appList.installUrlInputTip".loc,
            text: $installUrlInput.initVal,
            placeholder: "https://",
            action: { newText in
                installUrlInput.close(result: newText)
            },
            actionCancel: {_ in
                installUrlInput.close(result: nil)
            }
        )
        .sheet(isPresented: $jitAlert.show, onDismiss: {
            jitAlert.close(result: false)
        }) {
            JITEnablingModal
        }
        .onChange(of: jitAlert.show) { newValue in
            sharedModel.isJITModalOpen = newValue
        }
        .fullScreenCover(isPresented: $webViewOpened) {
            LCWebView(url: $webViewURL, isPresent: $webViewOpened, itmsServicesHandler: { urlStr in
                await installFromPlist(urlStr: urlStr)
            })
        }
        .sheet(isPresented: $customSortViewPresent) {
            LCCustomSortView()
        }
        .onAppear() {
            if !isViewAppeared {
                if let webpageUrlStr = UserDefaults.standard.string(forKey: "webPageToOpen") {
                    Task { await openWebView(urlString: webpageUrlStr) }
                    UserDefaults.standard.set(nil, forKey: "webPageToOpen")
                }
                
                guard sharedModel.selectedTab == .apps, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .apps, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
        .onDrop(of: [.url], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url else { return }
                Task {
                    guard let urlToOpen = await webViewUrlInput.open(initVal: url.absoluteString), urlToOpen != "" else {
                        return
                    }
                    await openWebView(urlString: urlToOpen)
                }
            }
            return true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.InstallAppNotification)) { obj in
            if let obj2 = obj.object as? [String: Any], let installUrl = obj2["url"] as? URL {
                Task { await installer.install(.remoteURL(installUrl)) }
            }
        }
        .onReceive(AnderAppTools.shared.$pending) { _ in consumeAppTool() }
        .onAppear { consumeAppTool() }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))

    }

    @MainActor
    private func consumeAppTool() {
        guard sharedModel.selectedTab == .apps,
              LCUtils.appGroupUserDefault.bool(forKey: "anderAdvancedFunctions"),
              let tool = AnderAppTools.shared.pending else { return }
        AnderAppTools.shared.pending = nil
        switch tool {
        case .ipa: choosingIPA = true
        case .installURL: Task { await startInstallFromUrl() }
        case .web: Task { await onOpenWebViewTapped() }
        case .sort: openNavigationView(view: AnyView(AnderAppSortSettings()))
        }
    }

    @MainActor
    private func update(_ candidate: AnderUpdateCandidate) async -> Bool {
        await installer.install(.storeApp(app: candidate.storeApp, sourceURL: candidate.sourceURL),
                                mode: .replace(candidate.installedApp))
    }

    @MainActor
    private func updateAllApps() async {
        guard !isUpdatingAll else { return }
        isUpdatingAll = true
        let pending = updateCandidates
        let results = await installer.installSequentially(pending)
        let succeeded = results.filter { $0.succeeded }.count
        let failures = results.filter { !$0.succeeded }.map { $0.candidate.storeApp.name }
        isUpdatingAll = false
        var summary = String(format: "lc.updates.summary".loc, succeeded, failures.count)
        if !failures.isEmpty {
            summary += "\n" + String(format: "lc.updates.failed".loc, failures.joined(separator: ", "))
        }
        updateSummary = summary
    }
    
    var JITEnablingModal : some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    Text("lc.appBanner.waitForJitMsg".loc)
                        .padding(.vertical)
                        .id(0)
                    
                    HStack {
                        Text(jitLog)
                            .font(.system(size: 12).monospaced())
                            .fixedSize(horizontal: false, vertical: false)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal)
                .onAppear {
                    proxy.scrollTo(0)
                }
            }
            .navigationTitle("lc.appBanner.waitForJitTitle".loc)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("lc.common.cancel".loc, role: .cancel) {
                        jitAlert.close(result: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        jitAlert.close(result: true)
                    } label: {
                        Text("lc.appBanner.jitLaunchNow".loc)
                    }
                }
            }
        }
    }
    
    func onOpenWebViewTapped() async {
        guard let urlToOpen = await webViewUrlInput.open(), urlToOpen != "" else {
            return
        }
        await openWebView(urlString: urlToOpen)
        
    }
    func onAppear() {
        for app in sharedModel.apps {
            app.delegate = self
        }
        for app in sharedModel.hiddenApps {
            app.delegate = self
        }
        AnderHomeLaunchCoordinator.shared.registerAdvancedDelegate(self)
        didAppear = true
    }
    
    
    func openWebView(urlString: String) async {
        guard var urlToOpen = URLComponents(string: urlString), urlToOpen.url != nil else {
            errorInfo = "lc.appList.urlInvalidError".loc
            errorShow = true
            return
        }
        if urlToOpen.scheme == nil || urlToOpen.scheme! == "" {
            urlToOpen.scheme = "https"
        }
        
        if urlToOpen.scheme?.lowercased() == "itms-services" {
            await installFromPlist(urlStr: urlString)
            return
        }
        
        if urlToOpen.scheme != "https" && urlToOpen.scheme != "http" {
            var appToLaunch : LCAppModel? = nil
            var appListsToConsider = [sharedModel.apps]
            if sharedModel.isHiddenAppUnlocked || !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
                appListsToConsider.append(sharedModel.hiddenApps)
            }
            appLoop:
            for appList in appListsToConsider {
                for app in appList {
                    if let schemes = app.appInfo.urlSchemes() {
                        for scheme in schemes {
                            if let scheme = scheme as? String, scheme == urlToOpen.scheme {
                                appToLaunch = app
                                break appLoop
                            }
                        }
                    }
                }
            }


            guard let appToLaunch = appToLaunch else {
                errorInfo = "lc.appList.schemeCannotOpenError %@".localizeWithFormat(urlToOpen.scheme!)
                errorShow = true
                return
            }
            
            if appToLaunch.appInfo.isLocked && !sharedModel.isHiddenAppUnlocked {
                do {
                    if !(try await LCUtils.authenticateUser()) {
                        return
                    }
                } catch {
                    errorInfo = error.localizedDescription
                    errorShow = true
                    return
                }
            }
            
            do {
                try await appToLaunch.runApp(urlStr: urlToOpen.url!.absoluteString)
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
            }
            
            return
        }
        webViewURL = urlToOpen.url!
        if webViewOpened {
            webViewOpened = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: {
                webViewOpened = true
            })
        } else {
            webViewOpened = true
        }
    }


    
    /// The installer runs outside this screen, but only this screen can ask the user whether to
    /// replace an installed app or add a second copy, and only it owns the download sheet.
    func bindInstaller() {
        installer.downloader = downloadHelper
        installer.conflictResolver = { options in
            installOptions = options
            return await installReplaceAlert.open()
        }
    }

    func startInstallFromUrl() async {
        guard let installUrlStr = await installUrlInput.open(), installUrlStr.count > 0 else {
            return
        }
        await installer.install(urlString: installUrlStr)
    }

    func installFromUrl(urlStr: String) async {
        await installer.install(urlString: urlStr)
    }

    func installFromPlist(urlStr: String) async {
        await installer.install(urlString: urlStr)
    }

    // MARK: - Grid

    /// Four across on a phone, more on a wider screen — the home screen's own behaviour.
    private static let gridColumns = [GridItem(.adaptive(minimum: 74, maximum: 96), spacing: 14)]

    @ViewBuilder
    private func appGrid(_ apps: [LCAppModel]) -> some View {
        LazyVGrid(columns: Self.gridColumns, spacing: 16) {
            ForEach(apps, id: \.self) { app in
                LCAppGridCell(model: app,
                              darkModeIcon: darkModeIcon,
                              hasUpdate: appsWithUpdates.contains(app),
                              launch: { multitask in Task { await launch(app, multitask: multitask) } },
                              selectContainer: { container in app.uiSelectedContainer = container },
                              openDataFolder: { openDataFolder(for: app) },
                              addToHomeScreen: { Task { await createHomeScreenShortcut(for: app) } },
                              openSettings: { openNavigationView(view: AnyView(LCAppSettingsView(model: app))) },
                              uninstall: { uninstallTarget = app })
            }
        }
    }

    /// Which apps the updates section above is offering, so the grid can mark them.
    private var appsWithUpdates: Set<LCAppModel> {
        Set(updateCandidates.map { $0.installedApp })
    }

    /// The same sequence the old banner used: ask for Face ID when the app is locked, then
    /// launch. Returning to an already open multitask window is handled inside runApp.
    @MainActor
    private func launch(_ app: LCAppModel, multitask: Bool? = nil) async {
        guard let name = app.appInfo.relativeBundlePath,
              let url = AnderHomeShortcutURL.make(bundleName: name, containerFolderName: app.uiSelectedContainer?.folderName) else { return }
        AnderHomeLaunchCoordinator.shared.receive(url, multitask: multitask)
    }

    private func openDataFolder(for app: LCAppModel) {
        guard let folder = app.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folder)") else { return }
        UIApplication.shared.open(url)
    }

    /// Ported from the banner: remove the bundle, then offer to remove the data with it.
    @MainActor
    private func performUninstall(_ app: LCAppModel, removeData: Bool) {
        let appInfo = app.appInfo
        let containers = appInfo.containers
        do {
            guard let bundlePath = appInfo.bundlePath() else { throw CocoaError(.fileNoSuchFile) }
            let fileManager = FileManager.default
            try fileManager.removeItem(atPath: bundlePath)
            removeApp(app: app)
            if removeData {
                for container in containers {
                    let dataUUID = container.folderName
                    try? fileManager.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
                    LCUtils.removeAppKeychain(dataUUID: dataUUID)
                    DataManager.shared.model.appDataFolderNames.removeAll { $0 == dataUUID }
                }
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
    }

    func removeApp(app: LCAppModel) {
        DispatchQueue.main.async {
            sharedModel.apps.removeAll { now in
                return app == now
            }
            sharedModel.hiddenApps.removeAll { now in
                return app == now
            }
            
        }
    }
    
    func changeAppVisibility(app: LCAppModel) {
        DispatchQueue.main.async {
            if app.appInfo.isHidden {
                sharedModel.apps.removeAll { now in
                    return app == now
                }
                if !sharedModel.hiddenApps.contains(app) {
                    sharedModel.hiddenApps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .removeObjects(in: app.appInfo.urlSchemes() as! [Any])
            } else {
                sharedModel.hiddenApps.removeAll { now in
                    return app == now
                }
                if !sharedModel.apps.contains(app) {
                    sharedModel.apps.append(app)
                }
                UserDefaults.lcShared().mutableArrayValue(forKey: "LCGuestURLSchemes")
                    .addObjects(from: app.appInfo.urlSchemes() as! [Any])
            }
            
        }
    }
    
    func launchAppWithBundleId(bundleId : String, container : String?, urlStr: String? = nil, forceJIT: Bool? = nil) async {
        if bundleId == "" {
            return
        }
        var appFound : LCAppModel? = nil
        var isFoundAppLocked = false
        for app in sharedModel.apps {
            if app.appInfo.relativeBundlePath == bundleId {
                appFound = app
                if app.appInfo.isLocked {
                    isFoundAppLocked = true
                }
                break
            }
        }
        if appFound == nil && !LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") {
            for app in sharedModel.hiddenApps {
                if app.appInfo.relativeBundlePath == bundleId {
                    appFound = app
                    isFoundAppLocked = true
                    break
                }
            }
        }
        
        if appFound == nil && bundleId == "builtinSideStore" {
            appFound = LCAppModel(appInfo: BuiltInSideStoreAppInfo.shared)
        }
        
        if isFoundAppLocked && !sharedModel.isHiddenAppUnlocked {
            do {
                let result = try await LCUtils.authenticateUser()
                if !result {
                    return
                }
            } catch {
                errorInfo = error.localizedDescription
                errorShow = true
                return
            }
        }
        
        guard let appFound else {
            errorInfo = "lc.appList.appNotFoundError".loc
            errorShow = true
            return
        }

        do {
            try await appFound.runApp(multitask: nil, containerFolderName: container, urlStr: urlStr, forceJIT: forceJIT)
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
        }
        
    }
    
    func authenticateUser() async {
        do {
            if !(try await LCUtils.authenticateUser()) {
                return
            }
        } catch {
            errorInfo = error.localizedDescription
            errorShow = true
            return
        }
    }
    
    func jitLaunch(appName: String, classicMode: UInt) async {
        await jitLaunch(withScript: "", appName: appName, classicMode: classicMode)
    }

    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        await MainActor.run {
            jitLog = ""
        }
        let enableJITTask = Task {
            
            let _ = await LCUtils.askForJIT(withScript: script, appName: appName, classicMode: classicMode) { newMsg in
                Task { await MainActor.run {
                    self.jitLog += "\(newMsg)\n"
                }}
            }
            guard let _ = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) else {
                return
            }
        }
        guard let result = await jitAlert.open(), result else {
            UserDefaults.standard.removeObject(forKey: "selected")
            enableJITTask.cancel()
            return
        }
        LCSharedUtils.launchToGuestApp(withClassicMode: classicMode)

    }
    
    func jitLaunch(withPID pid: Int, withScript script: String? = nil, appName: String) async {
        await MainActor.run {
            let encodedData = script?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                
            
            if let jitEnabler = JITEnablerType(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCJITEnablerType")) {
                if jitEnabler == .StosDebug || jitEnabler == .StosDebugLC {
                    let encoded = encodedData.map { "&script=\($0)" } ?? ""
                    if jitEnabler == .StosDebugLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stosdebug") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&relaunchApp=false& forcePID=true\(encoded)") {
                                Task { await openWebView(urlString: url.absoluteString) }
                            }
                        } else {
                            errorInfo = "StosDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        if var url = URL(string: "stosdebug://enableJIT?bundleId=\(Bundle.main.bundleIdentifier!)&appName=\(appName)&pid=\(pid)&forcePID=true\(encoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    return
                }
                
                let encoded = encodedData.map { "&script-data=\($0)" } ?? ""
                if let url = URL(string: "stikjit://enable-jit?bundle-id=\(Bundle.main.bundleIdentifier!)&pid=\(pid)\(encoded)") {
                    if jitEnabler == .StikJITLC {
                        if let app = sharedModel.apps.first(where: { app in
                            return app.appInfo.urlSchemes().contains("stikjit") &&
                            (sharedModel.multiLCStatus != 2 || app.appInfo.isShared)
                        }) {
                            Task { await openWebView(urlString: url.absoluteString) }
                        } else {
                            errorInfo = "StikDebug is not found. Please install it first and switch it to shared app."
                            errorShow = true
                            return
                        }
                    } else {
                        UIApplication.shared.open(url)
                    }
                }
            }
        }
    }

    func showRunWhenMultitaskAlert() async -> Bool? {
        return await runWhenMultitaskAlert.open()
    }
    
    func showHomeShortcut(app: LCAppModel) {
        Task { await createHomeScreenShortcut(for: app) }
    }

    @MainActor
    private func createHomeScreenShortcut(for app: LCAppModel) async {
        if (app.appInfo.isLocked || app.appInfo.isHidden) && !sharedModel.isHiddenAppUnlocked {
            guard (try? await LCUtils.authenticateUser()) == true else { return }
        }
        AnderHomeShortcutCoordinator.shared.show(app)
    }

    func openNavigationView(view: AnyView) {
        navigateTo = view
        isNavigationActive = true
    }
    
    func promptForGeneratedIconStyle() async -> GeneratedIconStyle? {
        if #available(iOS 18.0, *) {
            return await generatedIconStyleSelector.open()
        } else {
            return .Light
        }
        
    }
    
    func closeNavigationView() {
        isNavigationActive = false
        navigateTo = nil
    }
    
    func copyError() {
        UIPasteboard.general.string = errorInfo
    }
    
    func handleURL(url : URL) {
        if url.isFileURL {
            Task { await installFromUrl(urlStr: url.absoluteString) }
            return
        }
        
        if url.scheme == "sidestore" && UserDefaults.sideStoreExist() {
            UserDefaults.standard.setValue(url.absoluteString, forKey: "launchAppUrlScheme")
            LCUtils.openSideStore(delegate: self)
            return
        }
        
        if url.host == "open-web-page" || url.host == "open-url" {
            if let urlComponent = URLComponents(url: url, resolvingAgainstBaseURL: false), let queryItem = urlComponent.queryItems?.first {
                if queryItem.value?.isEmpty ?? true {
                    return
                }
                
                if let decodedData = Data(base64Encoded: queryItem.value ?? ""),
                   let decodedUrl = String(data: decodedData, encoding: .utf8) {
                    Task { await openWebView(urlString: decodedUrl) }
                }
            }
        } else if url.host == "livecontainer-launch" {
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "bundle-name" })?.value
            if name == "builtinSideStore", let request = AnderHomeLaunchRequest(url: url) {
                Task { await launchAppWithBundleId(bundleId: request.bundleName, container: request.container, urlStr: request.openURL, forceJIT: request.forceJIT) }
            } else if name != "ui" { AnderHomeLaunchCoordinator.shared.receive(url) }
        } else if url.host == "install" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var installUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        installUrl = installUrl1
                    }
                }
                if let installUrl {
                    Task { await installFromUrl(urlStr: installUrl) }
                }
            }
        }
    }
    
}

extension View {
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V { block(self) }
}
