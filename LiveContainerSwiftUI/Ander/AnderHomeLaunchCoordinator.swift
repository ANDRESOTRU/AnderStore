import Combine
import Foundation
import SwiftUI
import UIKit

/// Launches are owned by the app, rather than by a tab's onAppear callback.
@MainActor
final class AnderHomeLaunchCoordinator: ObservableObject, LCAppModelDelegate {
    static let shared = AnderHomeLaunchCoordinator()
    @Published private(set) var app: LCAppModel?
    @Published var message: String?
    @Published private(set) var recovery = "device"
    @Published var needsContainerChoice = false
    @Published var needsMultitaskChoice = false
    @Published var jitPreparing = false
    private var gate = AnderHomeLaunchGate()
    private var task: Task<Void, Never>?
    private var choice: CheckedContinuation<Bool, Never>?
    private var advancedDelegate: LCAppModelDelegate?
    private var delegateReady: CheckedContinuation<Void, Never>?

    func registerAdvancedDelegate(_ delegate: LCAppModelDelegate) {
        advancedDelegate = delegate
        delegateReady?.resume()
        delegateReady = nil
    }

    func receive(_ url: URL, multitask: Bool? = nil) {
        guard let request = AnderHomeLaunchRequest(url: url) else {
            if task == nil { recovery = "store"; message = "lc.home.invalidLink".loc }
            return
        }
        guard gate.begin(request) else {
            if gate.active != request { recovery = "retry"; message = "lc.home.busy".loc }
            return
        }
        message = nil
        task = Task {
            defer {
                app = nil
                jitPreparing = false
                gate.finish()
                task = nil
            }
            let model = DataManager.shared.model
            let visible = model.apps
            let hidden = LCUtils.appGroupUserDefault.bool(forKey: "LCStrictHiding") && !model.isHiddenAppUnlocked
                ? [] : model.hiddenApps
            guard let target = (visible + hidden).first(where: { $0.appInfo.relativeBundlePath == request.bundleName }) else {
                recovery = "store"; message = "lc.home.missingApp".loc; return
            }
            if (target.appInfo.isLocked || target.appInfo.isHidden) && !model.isHiddenAppUnlocked {
                do { guard try await LCUtils.authenticateUser() else { return } }
                catch { recovery = "retry"; message = "lc.home.authentication".loc; return }
            }
            var container = request.container
            if let folder = container, !target.uiContainers.contains(where: { $0.folderName == folder }) {
                let allowed = await withCheckedContinuation { continuation in
                    choice = continuation
                    needsContainerChoice = true
                }
                guard allowed else { return }
                container = target.uiDefaultDataFolder
                if let folder = container, !target.uiContainers.contains(where: { $0.folderName == folder }) {
                    recovery = "retry"; message = "lc.home.missingContainer".loc; return
                }
                if container == nil, !target.uiContainers.isEmpty {
                    recovery = "retry"; message = "lc.home.missingContainer".loc; return
                }
            }
            guard !target.isAppRunning, !AnderInstaller.shared.isBusy else {
                recovery = "retry"; message = "lc.home.busy".loc; return
            }
            if target.appInfo.isJITNeeded || target.appInfo.is32bit || request.forceJIT == true {
                // Preserve the existing specialized JIT UI and its external-helper handoff.
                if advancedDelegate == nil {
                    await withCheckedContinuation { continuation in
                        delegateReady = continuation
                        model.selectedTab = .apps
                    }
                } else { model.selectedTab = .apps }
            }
            app = target
            let previousDelegate = target.delegate
            target.delegate = self
            defer { target.delegate = previousDelegate }
            do {
                try await target.runApp(multitask: multitask, containerFolderName: container, urlStr: request.openURL, forceJIT: request.forceJIT)
            } catch {
                recovery = "device"
                message = "lc.home.launchFailed".loc
            }
        }
    }

    func answer(_ allowed: Bool) {
        let continuation = choice
        choice = nil
        needsContainerChoice = false
        needsMultitaskChoice = false
        continuation?.resume(returning: allowed)
    }

    func closeNavigationView() {}
    func changeAppVisibility(app: LCAppModel) {}
    func showRunWhenMultitaskAlert() async -> Bool? {
        await withCheckedContinuation { continuation in
            choice = continuation
            needsMultitaskChoice = true
        }
    }
    func jitLaunch(appName: String, classicMode: UInt) async {
        jitPreparing = true
        await advancedDelegate?.jitLaunch(appName: appName, classicMode: classicMode)
        jitPreparing = false
    }
    func jitLaunch(withScript script: String, appName: String, classicMode: UInt) async {
        jitPreparing = true
        await advancedDelegate?.jitLaunch(withScript: script, appName: appName, classicMode: classicMode)
        jitPreparing = false
    }
    func jitLaunch(withPID pid: Int, withScript script: String?, appName: String) async {
        await advancedDelegate?.jitLaunch(withPID: pid, withScript: script, appName: appName)
    }

}

struct AnderHomeLaunchStatus: View {
    @ObservedObject var coordinator: AnderHomeLaunchCoordinator
    @ObservedObject var app: LCAppModel
    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.appInfo.iconIsDarkIcon(LCUtils.appGroupUserDefault.bool(forKey: "darkModeIcon")) {
                Image(uiImage: icon).resizable().scaledToFit().frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            VStack(alignment: .leading) {
                Text(app.displayName).font(.headline)
                Text((app.isSigningInProgress || coordinator.jitPreparing ? "lc.home.preparing" : "lc.home.opening").loc)
            }
            Spacer()
            ProgressView()
        }
        .padding().background(Color(uiColor: .secondarySystemBackground))
        .accessibilityElement(children: .combine)
    }
}
