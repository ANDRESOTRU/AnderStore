//
//  LCAltStoreSourcesView.swift
//  LiveContainerSwiftUI
//
//  Created by Stephen B on 2025/2/15.
//

import Foundation
import SwiftUI
import UIKit

struct LCSourcesView: View {
    @ObservedObject private var viewModel = AnderCatalogStore.shared
    @ObservedObject private var installer = AnderInstaller.shared
    @ObservedObject public var searchContext = SearchContext()
    @EnvironmentObject private var sharedModel: SharedModel
    @State private var confirmation: AnderStoreConfirmation?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.sources, id: \.id) { item in
                        if viewModel.sources.count > 1 {
                            Text(item.displayName).font(.headline).padding(.vertical, 12)
                        }
                        if let source = item.source {
                            ForEach(filteredApps(source)) { app in
                                LCSourceAppBanner(app: app, source: source, sourceURL: item.url,
                                                  installAction: { request(app, sourceURL: item.url) })
                                Divider().padding(.leading, 88)
                            }
                        }
                        if let error = item.error {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("lc.store.catalogError".loc).font(.subheadline)
                                Button("lc.store.retry".loc) { Task { await viewModel.refreshSource(item) } }
                                if item.source == nil { Text(error).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical)
                        } else if item.source == nil && item.isLoading {
                            ProgressView("lc.sources.loading".loc).padding(.vertical)
                        }
                    }
                    if !viewModel.isRefreshingAll && viewModel.sources.allSatisfy({ $0.source != nil && filteredApps($0.source!).isEmpty }) {
                        Text("lc.sources.section.noApps".loc)
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }.padding(.horizontal)
            }
            .refreshable { await viewModel.refreshAllSources() }
            .navigationTitle("lc.tabView.sources".loc)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))
        }
        .navigationViewStyle(.stack)
        .sheet(item: $confirmation) { choice in
            AnderStoreInstallConfirmation(choice: choice) {
                confirmation = nil
                Task { await installer.install(.storeApp(app: choice.app, sourceURL: choice.sourceURL)) }
            }
        }
        .alert("lc.common.error".loc, isPresented: Binding(get: { errorMessage != nil },
                                                         set: { if !$0 { errorMessage = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear { consumeLink() }
        .onChange(of: sharedModel.deepLink) { _ in consumeLink() }
    }

    private func filteredApps(_ source: AltStoreSource) -> [AltStoreSourceApp] {
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source.apps }
        return source.apps.filter {
            [$0.name, $0.subtitle ?? "", $0.developerName ?? "", $0.bundleIdentifier]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private func request(_ app: AltStoreSourceApp, sourceURL: URL) {
        guard !installer.isBusy else { return }
        let accessible = sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
        if let installed = AnderCatalog.installedApp(for: app.bundleIdentifier, in: accessible),
           !AnderCatalog.hasUpdate(for: app, in: accessible),
           let name = installed.appInfo.relativeBundlePath,
           let url = AnderHomeShortcutURL.make(bundleName: name,
                                               containerFolderName: installed.uiSelectedContainer?.folderName) {
            AnderHomeLaunchCoordinator.shared.receive(url)
            return
        }
        guard app.latestVersion != nil else { errorMessage = "lc.sources.error.missingDownload".loc; return }
        confirmation = AnderStoreConfirmation(app: app, sourceURL: sourceURL,
                                              updating: AnderCatalog.hasUpdate(for: app, in: accessible))
    }

    private func consumeLink() {
        guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
        sharedModel.deepLink = nil
        guard link.host == "source", let parts = URLComponents(url: link, resolvingAgainstBaseURL: false),
              let value = parts.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        Task { errorMessage = await viewModel.addSource(from: value) }
    }
}

struct AnderStoreConfirmation: Identifiable {
    let id = UUID()
    let app: AltStoreSourceApp
    let sourceURL: URL
    let updating: Bool
}

private struct AnderStoreInstallConfirmation: View {
    let choice: AnderStoreConfirmation
    let install: () -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var installer = AnderInstaller.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        SourceIconView(url: choice.app.iconURL).frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 17)).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(choice.app.name).font(.title2.bold())
                            if let developer = choice.app.developerName { Text(developer).foregroundStyle(.secondary) }
                            if let version = choice.app.latestVersion {
                                Text(version.version).font(.subheadline)
                                if let size = version.size {
                                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.subheadline)
                                }
                            }
                        }
                    }
                    Text("lc.store.installExplanation".loc).foregroundStyle(.secondary)
                    Button(action: install) {
                        Text(choice.updating ? "lc.sources.update".loc : "lc.common.install".loc)
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).disabled(installer.isBusy)
                }.padding()
            }
            .navigationTitle("AnderStore").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.cancel".loc) { dismiss() }
                }
            }
        }.navigationViewStyle(.stack).tint(AnderTheme.accent)
        .modifier(AnderStoreSheetHeight())
    }
}

struct AnderSourceManagementView: View {
    @ObservedObject private var catalog = AnderCatalogStore.shared
    @State private var presented = true
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ManageSourcesSheet(viewModel: catalog, isPresented: $presented) { value in
            error = await catalog.addSource(from: value)
            return error == nil
        }
        .onChange(of: presented) { if !$0 { dismiss() } }
        .alert("lc.common.error".loc, isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("lc.common.ok".loc, role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct ManageSourcesSheet: View {
    @ObservedObject var viewModel: AnderCatalogStore
    @Binding var isPresented: Bool
    let onAdd: (String) async -> Bool
    
    @State private var manualSourceValue = ""
    @State private var isAddingManual = false
    @State private var sourcePendingRemoval: AnderCatalogStore.SourceItem?
    @FocusState private var isManualFieldFocused: Bool
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    if viewModel.sources.isEmpty {
                        Text("lc.sources.empty".loc)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(viewModel.sources, id: \.id) { item in
                            HStack(alignment: .top, spacing: 12) {
                                SourceIconView(url: resolvedIconURL(for: item))
                                    .frame(width: 36, height: 36)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.displayName)
                                        .bold()
                                    Text(item.url.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    sourcePendingRemoval = item
                                } label: {
                                    Label("lc.sources.removeSource".loc, systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    Text("lc.sources.manage.current".loc)
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("https://example.com/source.json", text: $manualSourceValue)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .focused($isManualFieldFocused)
                        
                        Button {
                            attemptManualAdd()
                        } label: {
                            if isAddingManual {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("lc.sources.addSource".loc)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingManual)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("lc.sources.manage.manual".loc)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("lc.sources.addSource".loc)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("lc.common.close".loc) {
                        isPresented = false
                    }
                }
            }
        }
        .confirmationDialog(
            "lc.sources.removeConfirmation.title".loc,
            isPresented: Binding<Bool>(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }
            ),
            presenting: sourcePendingRemoval
        ) { item in
            Button("lc.common.remove".loc, role: .destructive) {
                viewModel.removeSource(item)
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: { item in
            Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(item.displayName))
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
    
    private func resolvedIconURL(for item: AnderCatalogStore.SourceItem) -> URL? {
        if let icon = item.primaryIconURL {
            return icon
        }
        if let existing = viewModel.sources.first(where: { $0.url == item.url }) {
            if let icon = existing.primaryIconURL {
                return icon
            }
        }
        return nil
    }
    
    private func attemptManualAdd() {
        let trimmed = manualSourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAddingManual else { return }
        isAddingManual = true
        Task {
            let success = await onAdd(trimmed)
            if success {
                manualSourceValue = ""
                isManualFieldFocused = false
            }
            isAddingManual = false
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let sourceURL: URL
    let installAction: () -> Void
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var installer = AnderInstaller.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    private var installedApps: [LCAppModel] {
        sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
    }
    private var isInstalling: Bool {
        installer.isBusy && installer.activeStoreBundleId == app.bundleIdentifier && installer.activeStoreSourceURL == sourceURL
    }
    private var actionTitle: String {
        if AnderCatalog.hasUpdate(for: app, in: installedApps) { return "lc.sources.update".loc }
        if AnderCatalog.installedApp(for: app.bundleIdentifier, in: installedApps) != nil { return "lc.sources.open".loc }
        return "lc.store.download".loc
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            NavigationLink {
                LCSourceAppDetail(app: app, source: source, sourceURL: sourceURL, action: installAction)
            } label: {
                SourceIconView(url: app.iconURL).frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).accessibilityLabel(app.name)
            VStack(alignment: .leading, spacing: 8) {
                NavigationLink {
                    LCSourceAppDetail(app: app, source: source, sourceURL: sourceURL, action: installAction)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.headline).foregroundStyle(.primary)
                        if let subtitle = app.subtitle ?? app.developerName, !subtitle.isEmpty {
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if app.isBeta { Text("lc.sources.badge.beta".loc).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                if isInstalling {
                    AnderInstallStatus(installer: installer, showName: false)
                } else {
                    Button(action: installAction) { Text(actionTitle).font(.headline).padding(.horizontal, 16).frame(minHeight: 44) }
                        .buttonStyle(.plain).foregroundStyle(AnderTheme.accent)
                        .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        .disabled(installer.isBusy)
                        .accessibilityLabel(app.name + ", " + actionTitle)
                }
            }
        }.padding(.vertical, typeSize.isAccessibilitySize ? 20 : 16)
    }
}

private struct LCSourceAppDetail: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let sourceURL: URL
    let action: () -> Void

    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var installer = AnderInstaller.shared

    private var installedApps: [LCAppModel] {
        sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
    }
    private var installed: LCAppModel? {
        AnderCatalog.installedApp(for: app.bundleIdentifier, in: installedApps)
    }
    private var hasUpdate: Bool { AnderCatalog.hasUpdate(for: app, in: installedApps) }
    private var actionTitle: String {
        if hasUpdate { return "lc.sources.update".loc }
        if installed != nil { return "lc.sources.open".loc }
        return "lc.store.download".loc
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: 96, height: 96)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.title2.bold())
                        if let developer = app.developerName { Text(developer).foregroundStyle(.secondary) }
                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if installer.isBusy && installer.activeStoreBundleId == app.bundleIdentifier && installer.activeStoreSourceURL == sourceURL {
                    AnderInstallStatus(installer: installer, showName: false)
                } else {
                    Button(action: action) { Text(actionTitle).bold().frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).disabled(installer.isBusy)
                }

                if !app.screenshots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(app.screenshots, id: \.self) { url in
                                AsyncImage(url: url) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: { ProgressView() }
                                .frame(height: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }
                        }
                    }
                }

                if let description = app.description, !description.isEmpty {
                    Text("lc.sources.description".loc).font(.headline)
                    Text(description)
                }

                if let latest = app.latestVersion {
                    Text("lc.sources.versionDetails".loc).font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(latest.buildVersion.map { "\(latest.version) (\($0))" } ?? latest.version)
                        if let date = latest.releaseDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                        if let size = latest.size {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if let notes = latest.localizedDescription, !notes.isEmpty {
                            Text(notes).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SourceIconView: View {
    let url: URL?
    
    var body: some View {
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }
    
    private var placeholder: some View {
        Image("DefaultIcon")
            .resizable()
            .scaledToFill()
    }
}
