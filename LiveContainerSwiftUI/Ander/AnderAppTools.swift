import Combine
import SwiftUI

@MainActor
final class AnderAppTools: ObservableObject {
    enum Tool { case ipa, installURL, web, sort }
    static let shared = AnderAppTools()
    @Published var pending: Tool?
}

struct AnderAppToolsView: View {
    @EnvironmentObject private var model: SharedModel
    @State private var sourcesShown = false
    var body: some View {
        List {
            Button { sourcesShown = true } label: { Label("lc.store.manageSources".loc, systemImage: "tray.full") }
            tool("lc.appList.installFromIpa", icon: "doc.badge.plus", .ipa)
            tool("lc.appList.installFromUrl", icon: "link.badge.plus", .installURL)
            tool("lc.appList.openLink", icon: "link", .web)
            tool("lc.tools.sort", icon: "arrow.up.arrow.down", .sort)
        }.navigationTitle("lc.tools.title".loc)
        .sheet(isPresented: $sourcesShown) { AnderSourceManagementView() }
    }
    private func tool(_ title: String, icon: String, _ action: AnderAppTools.Tool) -> some View {
        Button {
            model.selectedTab = .apps
            AnderAppTools.shared.pending = action
        } label: { Label(title.loc, systemImage: icon) }
    }
}

struct AnderAppSortSettings: View {
    @EnvironmentObject private var manager: LCAppSortManager
    var body: some View {
        Form {
            Picker("lc.tools.sort".loc, selection: $manager.appSortType) {
                ForEach(AppSortType.allCases, id: \.self) { type in
                    Label(type.displayName, systemImage: type.systemImage).tag(type)
                }
            }
            if manager.appSortType == .custom {
                NavigationLink("lc.appList.sort.customManage".loc) { LCCustomSortView() }
            }
        }.navigationTitle("lc.tools.sort".loc)
    }
}
