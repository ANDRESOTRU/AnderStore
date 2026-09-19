//
//  AnderCoreBridge.swift
//  AnderStore
//
//  Everything AnderStore asks Core to do arrives here, as one command envelope over XPC
//  (SideStoreSupport/XPCClient.m). Core has no interface of its own: questions go back to
//  AnderStore as events, answers come back as replies.
//  Looked up at runtime with NSClassFromString(@"AnderCoreBridge").
//

import Foundation
import CoreData
import SideSign

@objc(AnderCoreBridge)
final class AnderCoreBridge: NSObject {

    /// Bumped together with AnderCoreService.protocolVersion when the envelope changes shape.
    private static let protocolVersion = 1

    private static let commands: [String] = [
        "handshake",
        "account.signIn",
        "account.submitCode",
        "account.status",
        "account.signOut",
        "snapshot",
        "self.update"
    ]

    nonisolated(unsafe) private static var activeSignIn: XPCSignInHandler?

    // MARK: - Envelope

    @objc(performRequest:requestID:onEvent:completion:)
    static func perform(_ request: [String: Any],
                        requestID: String,
                        onEvent: @escaping ([String: Any]) -> Void,
                        completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let command = request["cmd"] as? String ?? ""
        switch command {
        case "handshake":
            completion([
                "protocolVersion": protocolVersion,
                "coreVersion": coreVersion,
                "supportedCommands": commands
            ], nil)

        case "account.signIn":
            guard let appleID = request["appleID"] as? String,
                  let password = request["password"] as? String else {
                completion(nil, badParameters("appleID, password"))
                return
            }
            signIn(appleID: appleID, password: password, onEvent: onEvent, completion: completion)

        case "account.submitCode":
            let code = request["code"] as? String ?? ""
            activeSignIn?.submit(code: code)
            completion([:], nil)

        case "account.status":
            accountStatus { status in completion(status, nil) }

        case "account.signOut":
            AuthManager.shared.signOut()
            completion([:], nil)

        case "snapshot":
            let fields = Set(request["fields"] as? [String] ?? ["account", "certificate", "apps"])
            snapshot(fields: fields) { result in completion(result, nil) }

        case "self.update":
            updateSelf(onEvent: onEvent, completion: completion)

        default:
            completion(nil, ["kind": "unsupportedCommand", "message": command])
        }
    }

    @objc(cancelRequestWithID:)
    static func cancelRequest(id: String) {
        // Sign-in is the only cancellable operation so far: an empty code ends it.
        activeSignIn?.submit(code: "")
    }

    /// AnderStore asks before stopping Core. Refuse while an app operation is running —
    /// killing Core mid-signing can leave a revoked certificate and an app that will not start.
    @objc(prepareForShutdownWithReason:completion:)
    static func prepareForShutdown(reason: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            if AppManager.shared.isActivelyManagingAnyApp || activeSignIn != nil {
                completion(false)
                return
            }
            let context = DatabaseManager.shared.viewContext
            if context.hasChanges {
                try? context.save()
            }
            completion(true)
        }
    }

    // MARK: - Commands

    private static func signIn(appleID: String,
                               password: String,
                               onEvent: @escaping ([String: Any]) -> Void,
                               completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        if activeSignIn != nil {
            completion(nil, ["kind": "busy", "message": "A sign-in is already in progress"])
            return
        }
        let handler = XPCSignInHandler(appleID: appleID, password: password) { prompt in
            onEvent(["kind": "needsCode", "prompt": prompt])
        }
        activeSignIn = handler

        Task {
            do {
                try await AuthManager.shared.signIn(signInHandler: handler, anisetteServerHandler: handler)
                activeSignIn = nil
                completion(["appleID": appleID], nil)
            } catch {
                activeSignIn = nil
                completion(nil, errorPayload(error))
            }
        }
    }

    private static func accountStatus(completion: @escaping ([String: Any]) -> Void) {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.perform {
            var result: [String: Any] = ["signedIn": AuthManager.shared.isAuthenticated]
            if let appleID = DatabaseManager.shared.activeAccount(in: context)?.appleID {
                result["appleID"] = appleID
            }
            if let team = DatabaseManager.shared.activeTeam(in: context) {
                result["team"] = team.name
                result["teamType"] = team.type.rawValue
            }
            completion(result)
        }
    }

    /// One read of everything the interface shows. Deliberately local only: no Apple API calls,
    /// no minimuxer — AnderStore paints its screens from this without a network round trip.
    private static func snapshot(fields: Set<String>, completion: @escaping ([String: Any]) -> Void) {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.perform {
            var result: [String: Any] = [:]

            if fields.contains("account") {
                var account: [String: Any] = ["signedIn": AuthManager.shared.isAuthenticated]
                if let appleID = DatabaseManager.shared.activeAccount(in: context)?.appleID {
                    account["appleID"] = appleID
                }
                if let team = DatabaseManager.shared.activeTeam(in: context) {
                    account["team"] = team.name
                    account["teamType"] = team.type.rawValue
                    account["teamIdentifier"] = team.identifier
                }
                result["account"] = account
            }

            if fields.contains("certificate") {
                var certificate: [String: Any] = [:]
                if let active = CertificateManager.shared.activeCertificate {
                    certificate["present"] = true
                    certificate["serialNumber"] = active.certificate.serialNumber
                } else {
                    certificate["present"] = false
                }
                result["certificate"] = certificate
            }

            if fields.contains("apps") {
                var apps: [[String: Any]] = []
                let request: NSFetchRequest<InstalledApp> = InstalledApp.fetchRequest()
                if let installed = try? context.fetch(request) {
                    for app in installed {
                        var entry: [String: Any] = [
                            "bundleIdentifier": app.bundleIdentifier,
                            "name": app.name,
                            "version": app.version,
                            "buildVersion": app.buildVersion,
                            "isActive": app.isActive,
                            "hasUpdate": app.hasUpdate,
                            "refreshedDate": app.refreshedDate,
                            "expirationDate": app.expirationDate
                        ]
                        if let serial = app.certificateSerialNumber {
                            entry["certificateSerialNumber"] = serial
                        }
                        apps.append(entry)
                    }
                }
                result["apps"] = apps
            }

            result["capturedAt"] = Date()
            completion(result)
        }
    }

    /// Updates AnderStore itself from the AnderStore source (store.andresot.uk/source.json).
    private static func updateSelf(onEvent: @escaping ([String: Any]) -> Void,
                                   completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        AppManager.shared.updateAllSources { _ in
            DispatchQueue.main.async {
                let context = DatabaseManager.shared.viewContext
                let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), StoreApp.altstoreAppID)
                guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else {
                    completion(nil, ["kind": "notInstalled",
                                     "message": "AnderStore was not found in the list of installed apps"])
                    return
                }
                guard installedApp.hasUpdate else {
                    completion(["updated": false], nil)
                    return
                }
                var observation: NSKeyValueObservation?
                let updateProgress = AppManager.shared.update(installedApp, presentingViewController: nil) { result in
                    observation?.invalidate()
                    switch result {
                    case .success:
                        completion(["updated": true], nil)
                    case .failure(let error):
                        completion(nil, errorPayload(error))
                    }
                }
                observation = updateProgress.observe(\Progress.fractionCompleted, options: [.new]) { _, change in
                    if let value = change.newValue {
                        onEvent(["kind": "progress", "value": value])
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static var coreVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func badParameters(_ expected: String) -> [String: Any] {
        ["kind": "invalidParameters", "message": expected]
    }

    /// Turns a Core error into a stable `kind` the interface can act on, so the wording of a
    /// message never decides what AnderStore shows.
    private static func errorPayload(_ error: Error) -> [String: Any] {
        var kind = "unknown"

        if error is CancellationError {
            kind = "cancelled"
        } else if let operationError = error as? OperationError {
            switch operationError {
            case .noConnection, .notReachable, .connectionFailed, .serverNotFound:
                kind = "noConnection"
            case .noVPN, .invalidVPN:
                kind = "noVPN"
            case .noDevice, .unknownUDID:
                kind = "noDevice"
            case .invalidPairingFile, .pairingNotComplete:
                kind = "needsPairing"
            case .minimuxerNotStarted:
                kind = "needsMinimuxer"
            case .notAuthenticated:
                kind = "needsAuth"
            case .maximumAppIDLimitReached:
                kind = "appIDLimit"
            case .certificateRevoked, .customCertificateRevoked:
                kind = "certificateRevoked"
            case .certificateExpired, .customCertificateExpired:
                kind = "certificateExpired"
            case .timedOut:
                kind = "timedOut"
            default:
                kind = "unknown"
            }
        }

        if kind == "unknown" {
            let text = error.localizedDescription.lowercased()
            if text.contains("too many requests") || text.contains("429") {
                kind = "rateLimited"
            } else if text.contains("cancel") {
                kind = "cancelled"
            } else if text.contains("certificate") && (text.contains("limit") || text.contains("maximum")) {
                kind = "certificateLimit"
            }
        }

        let nsError = error as NSError
        return [
            "kind": kind,
            "message": error.localizedDescription,
            "domain": nsError.domain,
            "code": nsError.code
        ]
    }
}
