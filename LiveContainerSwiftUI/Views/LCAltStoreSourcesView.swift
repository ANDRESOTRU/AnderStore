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
    @State private var errorMessage: String?
    @State private var sourcePendingRemoval: AnderCatalogStore.SourceItem?
    @ObservedObject public var searchContext: SearchContext = SearchContext()
    @State private var expandedSources: Set<URL> = []
    @State private var isManagingSources = false
    
    @EnvironmentObject private var sharedModel : SharedModel
    
    @State private var isViewAppeared = false
    
    var body: some View {
        NavigationView {
            Group {
                if viewModel.sources.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("lc.sources.empty".loc)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            ForEach(viewModel.sources, id: \.id) { item in
                                let apps = filteredApps(for: item)
                                AltStoreSourceSectionView(
                                    item: item,
                                    filteredApps: apps,
                                    isFiltering: isFiltering,
                                    isExpanded: expandedSources.contains(item.id),
                                    onRefresh: { Task { await viewModel.refreshSource(item) } },
                                    onInstall: { app in install(app: app, sourceURL: item.url) },
                                    onRemove: { sourcePendingRemoval = item },
                                    toggleExpanded: { toggleExpansion(for: item.id) }
                                )
                                .padding(.horizontal)
                                .animation(.easeInOut, value: apps.count)
                            }
                            
                            if totalFilteredAppCount == 0 {
                                VStack(spacing: 8) {
                                    Text("lc.sources.section.noApps".loc)
                                        .foregroundStyle(.gray)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 160, alignment: .center)
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("lc.tabView.sources".loc)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.isRefreshingAll {
                        ProgressView()
                    } else {
                        Button("lc.sources.refreshAll".loc, systemImage: "arrow.clockwise") {
                            Task { await viewModel.refreshAllSources() }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("lc.sources.addSource".loc, systemImage: "plus") {
                        isManagingSources = true
                    }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("lc.common.error".loc, isPresented: Binding<Bool>(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
        ) {
            Button("lc.common.ok".loc, role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("lc.sources.removeConfirmation.title".loc, isPresented: Binding(
            get: { sourcePendingRemoval != nil },
            set: { if !$0 { sourcePendingRemoval = nil } })
        ) {
            Button("lc.common.remove".loc, role: .destructive) {
                if let sourcePendingRemoval {
                    viewModel.removeSource(sourcePendingRemoval)
                }
                sourcePendingRemoval = nil
            }
            Button("lc.common.cancel".loc, role: .cancel) {
                sourcePendingRemoval = nil
            }
        } message: {
            if let name = sourcePendingRemoval?.displayName {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(name))
            } else {
                Text("lc.sources.removeConfirmation.message %@".localizeWithFormat(""))
            }
        }
        .sheet(isPresented: $isManagingSources) {
            if #available(iOS 16.0, *) {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
                .presentationDetents([.large])
            } else {
                ManageSourcesSheet(
                    viewModel: viewModel,
                    isPresented: $isManagingSources,
                    onAdd: { rawValue in
                        await handleAddSource(rawValue)
                    }
                )
            }
        }
        .searchable(text: $searchContext.query, placement: .navigationBarDrawer(displayMode: .always))

        .onAppear {
            expandedSources = []
            if !isViewAppeared {
                guard sharedModel.selectedTab == .sources, let link = sharedModel.deepLink else { return }
                sharedModel.deepLink = nil
                handleURL(url: link)
                isViewAppeared = true
            }
        }
        .onChange(of: viewModel.sources) { newSources in
            let newSet = Set(newSources.map { $0.id })
            expandedSources = expandedSources.intersection(newSet)
        }
        .onChange(of: sharedModel.deepLink) { link in
            guard sharedModel.selectedTab == .sources, let link else { return }
            sharedModel.deepLink = nil
            handleURL(url: link)
        }
    }
    
    private var isFiltering: Bool {
        !searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var totalFilteredAppCount: Int {
        viewModel.sources.reduce(0) { partialResult, item in
            partialResult + filteredApps(for: item).count
        }
    }
    
    private func filteredApps(for item: AnderCatalogStore.SourceItem) -> [AltStoreSourceApp] {
        guard let source = item.source else { return [] }
        let query = searchContext.debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return source.apps
        }
        return source.apps.filter { app in
            let lower = query.lowercased()
            if app.name.lowercased().contains(lower) {
                return true
            }
            if app.bundleIdentifier.lowercased().contains(lower) {
                return true
            }
            if let developer = app.developerName?.lowercased(), developer.contains(lower) {
                return true
            }
            if let subtitle = app.subtitle?.lowercased(), subtitle.contains(lower) {
                return true
            }
            return false
        }
    }
    
    @MainActor
    private func handleAddSource(_ rawValue: String) async -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let error = await viewModel.addSource(from: trimmed)
        if let error {
            errorMessage = error
            return false
        }
        return true
    }
    
    @MainActor
    private func install(app: AltStoreSourceApp, sourceURL: URL) {
        guard app.latestVersion != nil else {
            errorMessage = "lc.sources.error.missingDownload".loc
            return
        }
        let accessibleApps = sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
        if let installed = AnderCatalog.installedApp(for: app.bundleIdentifier, in: accessibleApps),
           !AnderCatalog.hasUpdate(for: app, in: accessibleApps) {
            Task {
                do {
                    try await installed.runApp()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            return
        }
        Task {
            _ = await AnderInstaller.shared.install(.storeApp(app: app, sourceURL: sourceURL))
        }
    }
    
    private func toggleExpansion(for id: URL) {
        withAnimation(.easeInOut) {
            if expandedSources.contains(id) {
                expandedSources.remove(id)
            } else {
                expandedSources.insert(id)
            }
        }
    }
    
    func handleURL(url : URL) {
        if url.host == "source" {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                var sourceUrl : String? = nil
                for queryItem in components.queryItems ?? [] {
                    if queryItem.name == "url", let installUrl1 = queryItem.value {
                        sourceUrl = installUrl1
                    }
                }
                if let sourceUrl {
                    DataManager.shared.model.selectedTab = .sources
                    Task { await handleAddSource(sourceUrl) }
                }
            }
        }
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

private struct AltStoreSourceSectionView: View {
    let item: AnderCatalogStore.SourceItem
    let filteredApps: [AltStoreSourceApp]
    let isFiltering: Bool
    let isExpanded: Bool
    let onRefresh: () -> Void
    let onInstall: (AltStoreSourceApp) -> Void
    let onRemove: () -> Void
    let toggleExpanded: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 10) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .foregroundStyle(.secondary)
                        SourceIconView(url: item.primaryIconURL)
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(item.source?.name ?? item.displayName)
                            .font(.system(.title2).bold())
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                if item.isLoading {
                    ProgressView()
                } else {
                    Menu {
                        Button("lc.sources.refresh".loc, systemImage: "arrow.clockwise", action: onRefresh)
                        // AnderStore: the official store cannot be removed
                        if item.url.absoluteString != "https://store.andresot.uk/source.json" {
                            Button("lc.sources.removeSource".loc, systemImage: "trash", role: .destructive, action: onRemove)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if let subtitle = item.source?.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if item.source == nil, let host = item.url.host {
                Text(host)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if let error = item.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("lc.sources.section.error".loc)
                        .font(.subheadline)
                        .bold()
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("lc.sources.refresh".loc, action: onRefresh)
                        .font(.footnote)
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(uiColor: UIColor.secondarySystemBackground))
                )
            } else if let source = item.source, isExpanded || isFiltering {
                VStack(spacing: 12) {
                    ForEach(filteredApps[0..<min(50, filteredApps.count)]) { app in
                        LCSourceAppBanner(app: app, source: source, installAction: onInstall)
                    }
                    if filteredApps.isEmpty {
                        if source.apps.isEmpty || isFiltering {
                            Text("lc.sources.section.noApps".loc)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if filteredApps.count > 50 {
                        Text("lc.sources.section.tooManyApps".loc)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if item.isLoading {
                ProgressView("lc.sources.loading".loc)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct LCSourceAppBanner: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
    let installAction: (AltStoreSourceApp) -> Void

    @AppStorage("dynamicColors") private var dynamicColors = true
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject private var sharedModel: SharedModel
    @ObservedObject private var installer = AnderInstaller.shared

    private var installedApps: [LCAppModel] {
        sharedModel.apps + (sharedModel.isHiddenAppUnlocked ? sharedModel.hiddenApps : [])
    }

    private var isInstalling: Bool {
        installer.activeStoreBundleId == app.bundleIdentifier
    }

    private var isInstalled: Bool {
        AnderCatalog.installedApp(for: app.bundleIdentifier, in: installedApps) != nil
    }

    private var hasUpdate: Bool {
        AnderCatalog.hasUpdate(for: app, in: installedApps)
    }

    private var actionTitle: String {
        if hasUpdate { return "lc.sources.update".loc }
        if isInstalled { return "lc.sources.open".loc }
        return "lc.common.install".loc
    }
    
    private var primaryColor: Color {
        guard dynamicColors else { return Color("FontColor") }
        return app.tintColor ?? source.tintColor ?? Color("FontColor")
    }
    
    private var textColor: Color {
        _ = colorScheme == .dark // trigger refresh
        let color = dynamicColors ? primaryColor : Color("FontColor")
        return color.readableTextColor()
    }
    
    private var backgroundColor: Color {
        dynamicColors ? primaryColor.opacity(0.5) : Color("AppBannerBG")
    }
    
    private var metadataText: String {
        guard let latest = app.latestVersion else {
            return app.bundleIdentifier
        }
        if let build = latest.buildVersion, !build.isEmpty {
            return "\(latest.version) (\(build)) • \(app.bundleIdentifier)"
        }
        return "\(latest.version) • \(app.bundleIdentifier)"
    }
    
    private var subtitleText: String {
        if let subtitle = app.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        if let developer = app.developerName, !developer.isEmpty {
            return developer
        }
        return ""
    }
    
    var body: some View {
        HStack {
            NavigationLink {
                LCSourceAppDetail(app: app, source: source, action: { installAction(app) })
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    SourceIconView(url: app.iconURL)
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(app.name)
                                .font(.system(size: 16)).bold()
                            if app.isBeta {
                                Text("lc.sources.badge.beta".loc.uppercased())
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.orange))
                            }
                        }
                        Text(metadataText)
                            .font(.system(size: 12))
                            .foregroundColor(textColor)
                            .lineLimit(1)
                        if !subtitleText.isEmpty {
                            Text(subtitleText)
                                .font(.system(size: 11))
                                .foregroundColor(textColor)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                installAction(app)
            } label: {
                Group {
                    if isInstalling {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Text(actionTitle)
                            .bold()
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.1)
                    }
                }
                .frame(height: 32)
            }
            .disabled(installer.progressVisible)
            .buttonStyle(BasicButtonStyle())
            .padding()
            .frame(idealWidth: 70)
            .frame(height: 32)
            .fixedSize()
            .background(
                Capsule().fill(dynamicColors ? primaryColor : Color("FontColor"))
            )
            .clipShape(Capsule())
        }
        .padding()
        .frame(height: 88)
        .background {
            RoundedRectangle(cornerSize: CGSize(width: 22, height: 22))
                .fill(backgroundColor)
        }
    }
}

private struct LCSourceAppDetail: View {
    let app: AltStoreSourceApp
    let source: AltStoreSource
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
        return "lc.common.install".loc
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

                Button(action: action) {
                    if installer.activeStoreBundleId == app.bundleIdentifier {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(actionTitle).bold().frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installer.isBusy)

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
