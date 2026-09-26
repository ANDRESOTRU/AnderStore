//
//  LCAppGridCell.swift
//  AnderStore
//
//  The apps tab as a home screen: icon, name, tap to launch, long press for everything else.
//  What the old wide banner also showed — version, bundle identifier, remark, badges — moved
//  into the long-press menu and the app's own settings, because a 74 pt cell cannot hold it
//  and a home screen does not try.
//

import SwiftUI
import UIKit

enum LCAppGridMetrics {
    static let iconSize: CGFloat = 60
    static let cellWidth: CGFloat = 74
    static let labelHeight: CGFloat = 30
    /// Matches the superellipse ratio iOS uses for home screen icons.
    static var iconCornerRadius: CGFloat { iconSize * 0.2667 }
}

/// Icons are produced by the system icon service and written into the app bundle on first use.
/// One banner at a time could afford to do that on the main thread; a grid asks for twenty at
/// once, so generation is serialised here, shared between callers asking for the same icon, and
/// remembered afterwards.
final class LCAppIconCache {

    static let shared = LCAppIconCache()

    private let queue = DispatchQueue(label: "uk.andresot.anderstore.appicon")
    private let lock = NSLock()
    private var images: [String: UIImage] = [:]
    private var waiting: [String: [(UIImage?) -> Void]] = [:]

    private init() {}

    static func key(for appInfo: LCAppInfo, darkModeIcon: Bool) -> String {
        "\(appInfo.relativeBundlePath ?? appInfo.bundlePath() ?? "")|\(darkModeIcon)"
    }

    func cached(_ key: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return images[key]
    }

    func icon(key: String,
              generate: @escaping () -> UIImage?,
              completion: @escaping (UIImage?) -> Void) {
        if let image = cached(key) {
            completion(image)
            return
        }
        lock.lock()
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            lock.unlock()
            return
        }
        waiting[key] = [completion]
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let image = generate()
            self.lock.lock()
            if let image {
                self.images[key] = image
            }
            let callbacks = self.waiting.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                callbacks.forEach { $0(image) }
            }
        }
    }

    /// Call whenever an app's icon on disk changes, or the grid keeps showing the old one.
    func invalidate(appInfo: LCAppInfo) {
        lock.lock()
        defer { lock.unlock() }
        for darkMode in [true, false] {
            images.removeValue(forKey: Self.key(for: appInfo, darkModeIcon: darkMode))
        }
    }
}

struct LCAppGridCell: View {

    @ObservedObject var model: LCAppModel
    let darkModeIcon: Bool
    let hasUpdate: Bool
    let launch: (Bool?) -> Void
    let selectContainer: (LCContainer) -> Void
    let openDataFolder: () -> Void
    let addToHomeScreen: () -> Void
    let openSettings: () -> Void
    let uninstall: () -> Void

    @State private var icon: UIImage?

    private var displayName: String {
        model.appInfo.displayName() ?? model.displayName
    }

    private var iconKey: String {
        LCAppIconCache.key(for: model.appInfo, darkModeIcon: darkModeIcon)
    }

    var body: some View {
        Button {
            launch(nil)
        } label: {
            VStack(spacing: 6) {
                iconView
                Text(displayName)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                    .frame(width: LCAppGridMetrics.cellWidth,
                           height: LCAppGridMetrics.labelHeight,
                           alignment: .top)
                // The container decides which data launches, so it is the one extra fact worth
                // the space — and only when there is a choice to be wrong about.
                if model.uiContainers.count > 1, let container = model.uiSelectedContainer {
                    Text(container.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: LCAppGridMetrics.cellWidth)
                }
            }
            .frame(width: LCAppGridMetrics.cellWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAppRunning)
        .contextMenu { contextMenu }
        .onAppear(perform: loadIcon)
        .onChange(of: darkModeIcon) { _ in loadIcon() }
    }

    // MARK: - Icon

    private var iconView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: LCAppGridMetrics.iconCornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: LCAppGridMetrics.iconCornerRadius,
                                                style: .continuous))
            }
            if model.isSigningInProgress {
                RoundedRectangle(cornerRadius: LCAppGridMetrics.iconCornerRadius, style: .continuous)
                    .fill(Color.black.opacity(0.45))
                Circle()
                    .trim(from: 0, to: max(0.02, CGFloat(model.signProgress)))
                    .stroke(AnderTheme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: LCAppGridMetrics.iconSize - 18,
                           height: LCAppGridMetrics.iconSize - 18)
            }
        }
        .frame(width: LCAppGridMetrics.iconSize, height: LCAppGridMetrics.iconSize)
        .overlay(alignment: .topTrailing) {
            if hasUpdate {
                Circle()
                    .fill(AnderTheme.accent)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    .offset(x: 4, y: -4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let badge = badgeSymbol {
                Image(systemName: badge)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.black.opacity(0.55)))
                    .offset(x: 2, y: 2)
            }
        }
    }

    /// One glyph at most, and only for things that change what a tap does.
    private var badgeSymbol: String? {
        if model.appInfo.is32bit { return "square.grid.2x2" }
        if model.uiIsJITNeeded { return "bolt.fill" }
        if model.uiIsShared { return "arrowshape.turn.up.left.fill" }
        return nil
    }

    private func loadIcon() {
        let key = iconKey
        if let cached = LCAppIconCache.shared.cached(key) {
            icon = cached
            return
        }
        let appInfo = model.appInfo
        let darkMode = darkModeIcon
        LCAppIconCache.shared.icon(key: key) {
            appInfo.iconIsDarkIcon(darkMode)
        } completion: { image in
            if let image { self.icon = image }
        }
    }

    // MARK: - Long press

    @ViewBuilder
    private var contextMenu: some View {
        // Listed flat rather than in a submenu: a nested Menu inside a context menu is
        // unreliable on iOS 15, which this app still supports.
        if model.uiContainers.count > 1 {
            ForEach(model.uiContainers, id: \.folderName) { container in
                Button {
                    selectContainer(container)
                } label: {
                    if container.folderName == model.uiSelectedContainer?.folderName {
                        Label(container.name, systemImage: "checkmark")
                    } else {
                        Text(container.name)
                    }
                }
            }
        }
        if #available(iOS 16.0, *), !model.appInfo.is32bit {
            Button {
                launch(!model.shouldLaunchInMultitaskMode)
            } label: {
                Label("lc.appBanner.multitask".loc, systemImage: "macwindow.on.rectangle")
            }
        }
        if !model.uiIsShared, model.uiSelectedContainer != nil {
            Button {
                openDataFolder()
            } label: {
                Label("lc.appBanner.openDataFolder".loc, systemImage: "folder")
            }
        }
        Button {
            addToHomeScreen()
        } label: {
            Label("lc.appBanner.addToHomeScreen".loc, systemImage: "plus.app")
        }
        Button {
            openSettings()
        } label: {
            Label("lc.tabView.settings".loc, systemImage: "gearshape")
        }
        if !model.uiIsShared {
            Button(role: .destructive) {
                uninstall()
            } label: {
                Label("lc.appBanner.uninstall".loc, systemImage: "trash")
            }
        }
    }
}

/// Stands in for a hidden app before authentication: it takes no model, so nothing about the
/// app can leak through it.
struct LCAppGridSkeletonCell: View {
    var body: some View {
        VStack(spacing: 6) {
            RoundedRectangle(cornerRadius: LCAppGridMetrics.iconCornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: LCAppGridMetrics.iconSize, height: LCAppGridMetrics.iconSize)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: LCAppGridMetrics.cellWidth - 12, height: 10)
        }
        .frame(width: LCAppGridMetrics.cellWidth,
               height: LCAppGridMetrics.iconSize + LCAppGridMetrics.labelHeight + 6,
               alignment: .top)
    }
}
