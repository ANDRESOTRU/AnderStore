//
//  SideStore.swift
//  SideStoreSupport
//
//  Created by s s on 2025/7/20.
//

import Foundation
import AppIntents
import UserNotifications

@available(iOS 17.0, *)
func performIntentRefresh(identifier: String, mangledTypeName: String, intentProgress: Progress) async throws {
    intentProgress.totalUnitCount = 100
    if UserDefaults.isSideStore() {
        try await SideStoreIntentCaller.shared.callRefreshIntent(mangledTypeName: mangledTypeName)
    } else {
        RefreshHandler.shared.progress = intentProgress
        try await RefreshHandler.shared.startRefresh(identifier: identifier, mangledName: mangledTypeName)
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsWidgetIntent: AppIntent, ProgressReportingIntent
{
    public static var title: LocalizedStringResource { "Refresh Apps via Widget" }
    public static var isDiscoverable: Bool { false } // Don't show in Shortcuts or Spotlight.
    
    public init() {}
    
    public func perform() async throws -> some IntentResult
    {
        try await performIntentRefresh(identifier: "RefreshAllAppsWidgetIntent", mangledTypeName: "9SideStore26RefreshAllAppsWidgetIntentV", intentProgress: progress)
        return .result()
    }
}

@available(iOS 17.0, *)
public struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    public static let intentClassName = "RefreshAllIntent"
    
    public static var title: LocalizedStringResource = "Refresh All Apps"
    public static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring.")
    
    public init() {}
    
    public static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    public static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    public func perform() async throws -> some IntentResult & ProvidesDialog
    {
        try await performIntentRefresh(identifier: "RefreshAllIntent", mangledTypeName: "9SideStore20RefreshAllAppsIntentV", intentProgress: progress)
        return .result(dialog: "All apps have been refreshed.")
    }
    
}


class RefreshHandler: NSObject, RefreshServer {
    var c: UnsafeContinuation<(), any Error>? = nil
    var launchContinuation: UnsafeContinuation<(), any Error>? = nil
    var progress: Progress? = nil
    var listener: NSXPCListener? = nil
    var sideStorePid: Int32 = 0
    var client: RefreshClient? = nil
    var ext: NSExtension? = nil
    
    static var shared = RefreshHandler()
    
    func startRefresh(identifier: String, mangledName: String) async throws {
        if sideStorePid <= 0 || getpgid(sideStorePid) <= 0, let c {
            c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))
            self.c = nil
        }
        
        if c != nil {
            throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another refresh task is in progress."])
        }
        
        try await ensureCoreRunning()
        self.client?.refreshAllApps(withIdentifier: identifier, mangledTypeName: mangledName)
        
        try await withUnsafeThrowingContinuation { c in
            self.c = c
        }
        
    }
    
    /// Starts AnderStore Core in the background (LiveProcess) if it is not running yet.
    func ensureCoreRunning() async throws {
        if listener == nil {
            guard let listener = startAnonymousListener(self) else {
                return
            }
            self.listener = listener
        }
        guard let listener = self.listener else {
            return
        }

        // launch SideStore if it's not running
        if (sideStorePid <= 0 || getpgid(sideStorePid) <= 0) && launchContinuation == nil {
            let lcHome = String(cString:getenv("LC_HOME_PATH"))
            let sideStoreHomeURL = URL(fileURLWithPath: lcHome).appendingPathComponent("Documents/SideStore")
            let bookmarkData = bookmarkForURL(sideStoreHomeURL)!

            // start LiveProcess
            let extensionItem = NSExtensionItem()
            extensionItem.userInfo = [
                "selected": "builtinSideStore",
                "bookmarks": [bookmarkData],
                "endpoint": listener.endpoint
            ]

            guard let liveProcessURL = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex"),
                  let liveProcessBundle = Bundle(url: liveProcessURL)
            else {
                NSLog("Unable to locate LiveProcess bundle")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to locate LiveProcess bundle. To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use PlumeImpactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            
            var ext : NSExtension?
            do {
                ext = try NSExtension(identifier: liveProcessBundle.bundleIdentifier)
            } catch {
                NSLog("Failed to start extension \(error)")
                throw NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to start extension \(error). To use the Refresh All Apps shortcut, reinstall LiveContainer+SideStore with LiveProcess installed. If you use SideStore, choose \"Keep App Extensions (Use Main Profile)\". If you use Impactor, choose \"Only Register Main Bundle\". For other sideloaders, select keep all extensions, i.e. DO NOT Remove any extension."])
            }
            guard let ext else {
                return
            }
            self.ext = ext
            
            ext.setRequestInterruptionBlock { uuid in
                self.c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore quit unexpectedly"]))
                self.c = nil
                self.sideStorePid = 0
                self.launchContinuation = nil
                self.signInFinished("AnderStore Core quit unexpectedly", account: nil)
            }
            
            let uuid = await ext.beginRequest(withInputItems: [extensionItem])
            sideStorePid = ext.pid(forRequestIdentifier: uuid)
            
            try await withUnsafeThrowingContinuation { c in
                self.launchContinuation = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                    if let c = self.launchContinuation {
                        c.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Built-in SideStore failed to start in reasonable time"]))
                        self.launchContinuation = nil
                        ext._kill(9)
                    }
                }
            }
        }
    }

    // MARK: AnderStore sign-in callbacks (from the background Core)

    var codeHandler: ((String) -> Void)? = nil
    var signInCompletion: ((String?, String?) -> Void)? = nil
    var statusCompletion: ((String?, String?) -> Void)? = nil

    func needsVerificationCode(_ prompt: String) {
        DispatchQueue.main.async { self.codeHandler?(prompt) }
    }

    func signInFinished(_ error: String?, account appleID: String?) {
        DispatchQueue.main.async {
            let completion = self.signInCompletion
            self.signInCompletion = nil
            self.codeHandler = nil
            completion?(error, appleID)
        }
    }

    func accountStatus(appleID: String?, team: String?) {
        DispatchQueue.main.async {
            let completion = self.statusCompletion
            self.statusCompletion = nil
            completion?(appleID, team)
        }
    }

    func updateProgress(_ value: Double) {
        progress?.completedUnitCount = Int64(value*100)
    }
    
    func finish(_ error: String?) {
        if let error {
            c?.resume(throwing: NSError(domain: "SideStore", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))
            c = nil
        } else {
            c?.resume()
            c = nil
        }
    }
    
    func onConnection(_ connection: NSXPCConnection!) {
        connection.remoteObjectInterface = NSXPCInterface(with: RefreshClient.self)
        client = connection.remoteObjectProxy as? RefreshClient
    }
    
    func finishedLaunching() {
        launchContinuation?.resume()
        launchContinuation = nil
    }

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add SideStore notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    
}


// MARK: - AnderStore account API for the main screen
// Called from LiveContainerSwiftUI through the Objective-C runtime (NSClassFromString("AnderAccountBridge")).

@available(iOS 17.0, *)
@objc(AnderAccountBridge)
public final class AnderAccountBridge: NSObject {

    /// true when the background Core (LiveProcess extension) is installed with the app.
    @objc public static func isAvailable() -> Bool {
        guard let url = UserDefaults.lcMainBundle().builtInPlugInsURL?.appendingPathComponent("LiveProcess.appex") else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @objc(signInWithAppleID:password:onCode:completion:)
    public static func signIn(appleID: String,
                              password: String,
                              onCode: @escaping (String) -> Void,
                              completion: @escaping (String?, String?) -> Void) {
        Task { @MainActor in
            let handler = RefreshHandler.shared
            do {
                try await handler.ensureCoreRunning()
            } catch {
                completion(error.localizedDescription, nil)
                return
            }
            guard let client = handler.client else {
                completion("AnderStore Core is not connected", nil)
                return
            }
            handler.codeHandler = onCode
            handler.signInCompletion = completion
            client.signIn(appleID: appleID, password: password)
        }
    }

    /// Sends the 6-digit code typed by the user. An empty string cancels sign-in.
    @objc(submitCode:)
    public static func submitCode(_ code: String) {
        RefreshHandler.shared.client?.submitVerificationCode(code)
    }

    @objc(statusWithCompletion:)
    public static func status(completion: @escaping (String?, String?) -> Void) {
        Task { @MainActor in
            let handler = RefreshHandler.shared
            do {
                try await handler.ensureCoreRunning()
            } catch {
                completion(nil, nil)
                return
            }
            guard let client = handler.client else {
                completion(nil, nil)
                return
            }
            handler.statusCompletion = completion
            client.requestAccountStatus()
        }
    }

    /// Refreshes the signature of AnderStore and every app (same as the "Refresh All Apps" shortcut).
    @objc(refreshWithProgress:completion:)
    public static func refresh(progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        Task { @MainActor in
            let tracker = Progress(totalUnitCount: 100)
            let observation = tracker.observe(.fractionCompleted, options: [.new]) { _, change in
                if let value = change.newValue {
                    DispatchQueue.main.async { progress(value) }
                }
            }
            RefreshHandler.shared.progress = tracker
            do {
                try await RefreshHandler.shared.startRefresh(identifier: "RefreshAllIntent", mangledName: "9SideStore20RefreshAllAppsIntentV")
                observation.invalidate()
                completion(nil)
            } catch {
                observation.invalidate()
                completion(error.localizedDescription)
            }
        }
    }
}
