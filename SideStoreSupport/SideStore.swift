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
        await MainActor.run { AnderCoreService.shared.progress = intentProgress }
        try await AnderCoreService.shared.performLegacyRefresh(identifier: identifier, mangledName: mangledTypeName)
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


/// The Core process reports everything through this object. It keeps no state of its own:
/// AnderCoreService owns the connection, the lifetime and the requests in flight.
class RefreshHandler: NSObject, RefreshServer {

    static var shared = RefreshHandler()

    /// Assigned on the XPC queue the moment Core connects, so a request can go out immediately.
    var client: RefreshClient? = nil

    func onConnection(_ connection: NSXPCConnection!) {
        let interface = NSXPCInterface(with: RefreshClient.self)
        anderConfigureClientInterface(interface)
        connection.remoteObjectInterface = interface
        client = connection.remoteObjectProxy as? RefreshClient
        connection.interruptionHandler = {
            Task { @MainActor in AnderCoreService.shared.handleConnectionLost() }
        }
        connection.invalidationHandler = {
            Task { @MainActor in AnderCoreService.shared.handleConnectionLost() }
        }
    }

    func finishedLaunching() {
        Task { @MainActor in AnderCoreService.shared.handleFinishedLaunching() }
    }

    // MARK: Command envelope

    func request(_ requestID: String, didEmitEvent event: [String: Any]) {
        Task { @MainActor in
            AnderCoreService.shared.handleEvent(requestID: requestID, event: event)
        }
    }

    func request(_ requestID: String, didFinishWithResponse response: [String: Any]?, error: [String: Any]?) {
        Task { @MainActor in
            AnderCoreService.shared.handleFinish(requestID: requestID, response: response, error: error)
        }
    }

    func willShutdown(reason: String) {
        Task { @MainActor in AnderCoreService.shared.handleWillShutdown(reason: reason) }
    }

    // MARK: Legacy "Refresh All Apps" intent path

    func updateProgress(_ value: Double) {
        Task { @MainActor in AnderCoreService.shared.handleLegacyProgress(value) }
    }

    func finish(_ error: String?) {
        Task { @MainActor in AnderCoreService.shared.handleLegacyFinish(error) }
    }

    // MARK: Notifications raised by Core

    func add(_ request: UNNotificationRequest) {
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Failed to add AnderStore Core notification: \(error)")
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
    }

}


// MARK: - The one entry point the AnderStore interface calls
// Reached from LiveContainerSwiftUI through the Objective-C runtime
// (NSClassFromString("AnderCoreBridgeHost")), because this framework is loaded at runtime.

@available(iOS 17.0, *)
@objc(AnderCoreBridgeHost)
public final class AnderCoreBridgeHost: NSObject {

    /// true when the background Core (LiveProcess extension) shipped with the app.
    @objc public static func isAvailable() -> Bool {
        AnderCoreService.isInstalled
    }

    /// Runs one command. `request` carries "cmd" plus that command's parameters; `onEvent`
    /// receives progress and questions while it runs; `completion` gets either a response
    /// dictionary or a structured error.
    @objc(performRequest:onEvent:completion:)
    public static func perform(_ request: [String: Any],
                               onEvent: @escaping ([String: Any]) -> Void,
                               completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let command = request["cmd"] as? String ?? ""
        var params = request
        params.removeValue(forKey: "cmd")

        Task { @MainActor in
            do {
                let response = try await AnderCoreService.shared.perform(command, params: params) { event in
                    onEvent(event)
                }
                completion(response, nil)
            } catch let error as AnderCoreError {
                completion(nil, error.payload)
            } catch {
                completion(nil, AnderCoreError(kind: "unknown", message: error.localizedDescription).payload)
            }
        }
    }

    /// Lets Core save and quit, for example when the interface is done with it.
    @objc(shutdown)
    public static func shutdown() {
        Task { @MainActor in AnderCoreService.shared.shutdown(reason: "requested") }
    }
}
