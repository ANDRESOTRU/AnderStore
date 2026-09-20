//
//  AnderCatalog.swift
//  AnderStore
//
//  Ties an entry in the store to the copy installed inside AnderStore, so a row can say
//  "Install", "Update" or "Installed" instead of always offering to install again.
//

import Foundation

struct AnderUpdateCandidate: Identifiable {
    let installedApp: LCAppModel
    let storeApp: AltStoreSourceApp
    let sourceURL: URL
    let version: AltStoreSourceAppVersion

    var id: String { installedApp.appInfo.relativeBundlePath ?? installedApp.bundleIdentifier }
}

enum AnderCatalog {

    static func installedApp(for storeBundleId: String, in apps: [LCAppModel]) -> LCAppModel? {
        // Apps installed from the store carry where they came from. Older installs do not,
        // so fall back to the bundle identifier.
        if let match = apps.first(where: { $0.appInfo.anderStoreBundleId == storeBundleId }) {
            return match
        }
        return apps.first(where: { $0.appInfo.bundleIdentifier() == storeBundleId })
    }

    static func hasUpdate(for app: AltStoreSourceApp, in apps: [LCAppModel]) -> Bool {
        guard let installed = installedApp(for: app.bundleIdentifier, in: apps),
              let latest = app.latestVersion?.version, !latest.isEmpty else {
            return false
        }
        // The version recorded at install time is authoritative; the bundle's own version is
        // a fallback for apps installed before AnderStore started recording it.
        let current: String? = installed.appInfo.anderStoreVersion ?? installed.appInfo.version()
        guard let current, !current.isEmpty else { return false }
        return isNewer(version: latest,
                       build: app.latestVersion?.buildVersion,
                       than: current,
                       currentBuild: installed.appInfo.anderStoreBuildVersion ?? installed.appInfo.buildVersion())
    }

    static func isNewer(version: String,
                        build: String?,
                        than currentVersion: String,
                        currentBuild: String?) -> Bool {
        AnderVersioning.isNewer(version: version,
                                build: build,
                                than: currentVersion,
                                currentBuild: currentBuild)
    }

    /// Automatic updates intentionally require exact provenance. Bundle-ID fallback is useful
    /// for painting a store row, but is unsafe when the user has multiple copies installed.
    static func updateCandidates(from sources: [AnderCatalogStore.SourceItem],
                                 apps: [LCAppModel]) -> [AnderUpdateCandidate] {
        var candidates: [AnderUpdateCandidate] = []
        for installed in apps {
            guard let sourceString = installed.appInfo.anderSourceURL,
                  let storeBundleID = installed.appInfo.anderStoreBundleId,
                  let sourceItem = sources.first(where: { $0.url.absoluteString == sourceString }),
                  let source = sourceItem.source,
                  let storeApp = source.apps.first(where: {
                      AnderProvenanceIdentity.matches(installedSourceURL: sourceString,
                                                      installedBundleID: storeBundleID,
                                                      sourceURL: sourceItem.url.absoluteString,
                                                      bundleID: $0.bundleIdentifier)
                  }),
                  let latest = storeApp.latestVersion,
                  let currentVersion = installed.appInfo.anderStoreVersion ?? installed.appInfo.version(),
                  isNewer(version: latest.version,
                          build: latest.buildVersion,
                          than: currentVersion,
                          currentBuild: installed.appInfo.anderStoreBuildVersion ?? installed.appInfo.buildVersion()) else {
                continue
            }
            candidates.append(AnderUpdateCandidate(installedApp: installed,
                                                    storeApp: storeApp,
                                                    sourceURL: sourceItem.url,
                                                    version: latest))
        }
        return candidates.sorted {
            $0.storeApp.name.localizedStandardCompare($1.storeApp.name) == .orderedAscending
        }
    }
}
