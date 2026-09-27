import SwiftUI

/// The same operation is rendered in a store row or above the other tabs.
struct AnderInstallStatus: View {
    @ObservedObject var installer: AnderInstaller
    let showName: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let op = installer.operation, !op.stage.isTerminal {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        if installer.canControlDownload {
                            Button { installer.toggleDownloadPause() } label: {
                                ZStack {
                                    if let fraction = op.fraction {
                                        Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3)
                                        Circle().trim(from: 0, to: fraction).stroke(AnderTheme.accent,
                                            style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                                    } else if op.stage == .downloading {
                                        ProgressView().scaleEffect(1.5)
                                    } else { Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 3) }
                                    Image(systemName: op.stage == .paused ? "play.fill" : "pause.fill")
                                        .font(.system(size: 13, weight: .bold)).foregroundStyle(AnderTheme.accent)
                                }.frame(width: 32, height: 32).frame(width: 44, height: 44)
                            }.buttonStyle(.plain)
                            .accessibilityLabel((op.stage == .paused ? "lc.store.resume" : "lc.store.pause").loc)
                            .accessibilityValue(op.fraction.map { "\(Int($0 * 100))%" } ?? ("lc.store.stage." + op.stage.rawValue).loc)
                        } else { ProgressView().frame(width: 44, height: 44) }
                        VStack(alignment: .leading, spacing: 3) {
                            if showName { Text(installer.operationName).font(.subheadline.bold()) }
                            Text(("lc.store.stage." + op.stage.rawValue).loc).font(.subheadline)
                            if op.stage.allowsDownloadControl, let fraction = op.fraction {
                                Text("\(Int(fraction * 100))% · " + ByteCountFormatter.string(fromByteCount: op.downloadedBytes, countStyle: .file)
                                     + " / " + ByteCountFormatter.string(fromByteCount: op.expectedBytes, countStyle: .file))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if installer.canControlDownload {
                            Button("lc.common.cancel".loc) { installer.cancelDownload() }
                                .font(.caption).frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    if op.isDelayed(now: context.date) {
                        Text("lc.store.delayed".loc).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct AnderInstallPresentation: ViewModifier {
    @ObservedObject private var installer = AnderInstaller.shared
    @EnvironmentObject private var model: SharedModel
    @AppStorage("anderAdvancedFunctions", store: LCUtils.appGroupUserDefault) private var advanced = false
    let downloader: DownloadHelper

    func body(content: Content) -> some View {
        content
            .onAppear { installer.downloader = downloader }
            .safeAreaInset(edge: .top) {
                if installer.isBusy && model.selectedTab != .sources {
                    AnderInstallStatus(installer: installer, showName: true).padding(.horizontal)
                        .background(Color(uiColor: .systemBackground))
                }
            }
            .alert("lc.common.error".loc, isPresented: Binding(get: { installer.errorMessage != nil },
                                                              set: { if !$0 { installer.errorMessage = nil } })) {
                if installer.errorRecovery == "device" {
                    Button("lc.home.goDevice".loc) { installer.errorMessage = nil; model.selectedTab = .account }
                }
                Button("lc.common.ok".loc, role: .cancel) { installer.errorMessage = nil }
            } message: {
                Text((installer.errorMessage ?? "") + (advanced ? "\n\n" + installer.errorDetails : ""))
            }
            .alert("lc.appList.installation".loc, isPresented: Binding(get: { !installer.conflictOptions.isEmpty },
                                                                       set: { if !$0 { installer.answerConflict(nil) } })) {
                ForEach(installer.conflictOptions, id: \.self) { option in
                    Button(option.isReplace ? String(format: "lc.store.replace".loc, option.appToReplace?.displayName ?? option.nameOfFolderToInstall)
                                            : "lc.appList.installAsNew".loc) {
                        installer.answerConflict(option)
                    }
                }
                Button("lc.common.cancel".loc, role: .cancel) { installer.answerConflict(nil) }
            } message: { Text("lc.appList.installReplaceTip".loc) }
            .alert("lc.shortcut.offerTitle".loc, isPresented: Binding(get: { installer.pendingShortcutApp != nil },
                                                                     set: { if !$0 { installer.consumeShortcutOffer() } })) {
                Button("lc.shortcut.add".loc) {
                    guard let app = installer.pendingShortcutApp else { return }
                    installer.consumeShortcutOffer()
                    Task { @MainActor in
                        if app.uiIsLocked || app.uiIsHidden {
                            guard (try? await LCUtils.authenticateUser()) == true else { return }
                        }
                        AnderHomeShortcutCoordinator.shared.show(app)
                    }
                }
                Button("lc.shortcut.later".loc, role: .cancel) { installer.consumeShortcutOffer() }
            } message: {
                Text(String(format: "lc.shortcut.offerMessage".loc, installer.pendingShortcutApp?.displayName ?? ""))
            }
    }
}

struct AnderStoreSheetHeight: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 16.0, *) { content.presentationDetents([.medium, .large]) }
        else { content }
    }
}
