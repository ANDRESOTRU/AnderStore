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
import MinimuxerCommon

@objc(AnderCoreBridge)
final class AnderCoreBridge: NSObject {

    /// The public AnderStore IPA keeps LiveContainer's bundle identifier. Core deliberately
    /// keeps its historical SideStore identifiers for Keychain/CoreData compatibility, so
    /// self-update must bridge the two identities explicitly instead of relying on the
    /// InstalledApp.storeApp relationship.
    private static let anderStoreCatalogBundleIdentifier = "com.kdt.livecontainer"

    /// Bumped together with AnderCoreService.protocolVersion when the envelope changes shape.
    private static let protocolVersion = 4

    private static let commands: [String] = [
        "handshake",
        "account.signIn",
        "account.submitCode",
        "account.status",
        "account.signOut",
        "account.resetAnisette",
        "snapshot",
        "self.update",
        "apps.refresh",
        "certificates.list",
        "certificates.active",
        "certificates.revoke",
        "certificates.importP12",
        "certificates.exportP12",
        "appIDs.list",
        "appIDs.delete",
        "profiles.list",
        "device.status",
        "update.readiness"
    ]

    nonisolated(unsafe) private static var activeSignIn: XPCSignInHandler?

    // MARK: - Envelope

    @objc(performRequest:requestID:onEvent:completion:)
    static func perform(_ request: [String: Any],
                        requestID: String,
                        onEvent: @escaping ([String: Any]) -> Void,
                        completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let command = request["cmd"] as? String ?? ""

        // Cheap and idempotent: make sure every command runs with AnderStore's own anisette
        // server, not the on-device ADI path that can never provision itself here.
        AnderAnisettePolicy.applyDefaults()
        Task { await AnderAnisettePolicy.seedServerListIfNeeded() }

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
            let keepCertificate = request["keepCertificate"] as? Bool ?? true
            AuthManager.shared.signOut(keepCertificate: keepCertificate)
            completion([:], nil)

        case "account.resetAnisette":
            // Recovery from a broken Apple token state: clears the stored sign-in and the
            // provisioning blob, keeps the signing certificate so installed apps still launch.
            AuthManager.shared.signOut(keepCertificate: request["keepCertificate"] as? Bool ?? true,
                                       keepAnisetteData: false)
            AnderAnisettePolicy.applyDefaults(force: true)
            Task { await AnderAnisettePolicy.seedServerListIfNeeded(force: true) }
            completion(["reset": true], nil)

        case "snapshot":
            let fields = Set(request["fields"] as? [String] ?? ["account", "certificate", "apps"])
            snapshot(fields: fields) { result in completion(result, nil) }

        case "self.update":
            updateSelf(expectedVersion: request["version"] as? String,
                       onEvent: onEvent,
                       completion: completion)

        case "apps.refresh":
            refreshApps(onEvent: onEvent, completion: completion)

        case "certificates.list":
            listCertificates(completion: completion)

        case "certificates.active":
            activeCertificate(completion: completion)

        case "certificates.revoke":
            guard let serialNumber = request["serialNumber"] as? String else {
                completion(nil, badParameters("serialNumber"))
                return
            }
            revokeCertificate(serialNumber: serialNumber, completion: completion)

        case "certificates.importP12":
            guard let encoded = request["data"] as? String,
                  let data = Data(base64Encoded: encoded) else {
                completion(nil, badParameters("data"))
                return
            }
            importCertificate(data: data,
                              password: request["password"] as? String,
                              completion: completion)

        case "certificates.exportP12":
            guard let serialNumber = request["serialNumber"] as? String,
                  let password = request["password"] as? String,
                  !password.isEmpty else {
                completion(nil, badParameters("serialNumber, password"))
                return
            }
            exportCertificate(serialNumber: serialNumber,
                              password: password,
                              completion: completion)

        case "appIDs.list":
            listAppIDs(completion: completion)

        case "appIDs.delete":
            guard let identifier = request["identifier"] as? String else {
                completion(nil, badParameters("identifier"))
                return
            }
            deleteAppID(identifier: identifier, completion: completion)

        case "profiles.list":
            listProfiles(completion: completion)

        case "device.status":
            deviceStatus(completion: completion)

        case "update.readiness":
            completion(updateReadiness(), nil)

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
                AuthManager.shared.markPortalSessionReady()
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
            var result: [String: Any] = [
                "signedIn": AuthManager.shared.isAuthenticated,
                "portalSessionState": AuthManager.shared.portalSessionState.rawValue
            ]
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
                var account: [String: Any] = [
                    "signedIn": AuthManager.shared.isAuthenticated,
                    "portalSessionState": AuthManager.shared.portalSessionState.rawValue
                ]
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

    /// Can Core re-sign AnderStore right now? Self-update is a re-sign inside Core: without an
    /// Apple session and an active certificate the pipeline cannot finish, and the user saw a
    /// progress bar stuck at 0 % instead of the reason (1.6.26 → 1.6.28, 25 September 2026).
    /// Cheap, local checks only — no network.
    private static func updateReadiness() -> [String: Any] {
        let signedIn = AuthManager.shared.isAuthenticated
        let hasCertificate = CertificateManager.shared.activeCertificate != nil
        var result: [String: Any] = ["signedIn": signedIn, "hasCertificate": hasCertificate]
        if !signedIn {
            result["blocker"] = "signInRequired"
        } else if !hasCertificate {
            result["blocker"] = "certificateNotFound"
        }
        return result
    }

    /// Updates AnderStore itself from the AnderStore source (store.andresot.uk/source.json).
    private static func updateSelf(expectedVersion: String?,
                                   onEvent: @escaping ([String: Any]) -> Void,
                                   completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        // Fail fast with the real reason instead of hanging somewhere in the install pipeline.
        let readiness = updateReadiness()
        if let blocker = readiness["blocker"] as? String {
            completion(nil, [
                "kind": blocker,
                "message": blocker == "signInRequired"
                    ? "Sign in to Apple ID in AnderStore before updating"
                    : "No active signing certificate is available in AnderStore Core"
            ])
            return
        }

        onEvent(["kind": "stage", "value": "catalog"])
        AppManager.shared.updateAllSources { sourceResult in
            DispatchQueue.main.async {
                if case .failure(let error) = sourceResult {
                    completion(nil, errorPayload(error))
                    return
                }

                let context = DatabaseManager.shared.viewContext
                let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), StoreApp.altstoreAppID)
                guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else {
                    completion(nil, ["kind": "notInstalled",
                                     "message": "AnderStore was not found in the list of installed apps"])
                    return
                }

                let catalogPredicate = NSPredicate(format: "%K == %@",
                                                   #keyPath(StoreApp.bundleIdentifier),
                                                   anderStoreCatalogBundleIdentifier)
                guard let catalogApp = StoreApp.first(satisfying: catalogPredicate, in: context) else {
                    completion(nil, ["kind": "updateNotFound",
                                     "message": "The official AnderStore catalog entry was not found"])
                    return
                }

                let targetVersion: AppVersion?
                if let expectedVersion, !expectedVersion.isEmpty {
                    targetVersion = catalogApp.versions.first { $0.version == expectedVersion }
                } else {
                    targetVersion = catalogApp.latestSupportedVersion
                }
                guard let targetVersion else {
                    completion(nil, ["kind": "updateNotFound",
                                     "message": "The requested AnderStore version is not available in the official catalog"])
                    return
                }
                guard targetVersion.version != installedApp.version else {
                    completion(["updated": false, "version": targetVersion.version], nil)
                    return
                }

                onEvent(["kind": "stage", "value": "install"])
                var observation: NSKeyValueObservation?
                let updateProgress = AppManager.shared.update(installedApp,
                                                               to: targetVersion,
                                                               presentingViewController: nil) { result in
                    observation?.invalidate()
                    switch result {
                    case .success:
                        completion(["updated": true, "version": targetVersion.version], nil)
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

    private static func refreshApps(onEvent: @escaping ([String: Any]) -> Void,
                                    completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        let context = DatabaseManager.shared.viewContext
        context.perform {
            let request: NSFetchRequest<InstalledApp> = InstalledApp.fetchRequest()
            let installed = (try? context.fetch(request)) ?? []
            guard !installed.isEmpty else {
                completion(nil, ["kind": "noInstalledApps", "message": "No installed apps"])
                return
            }

            let group = AppManager.shared.refresh(installed, presentingViewController: nil)
            var observation: NSKeyValueObservation?
            observation = group.progress.observe(\.fractionCompleted, options: [.new]) { _, change in
                if let value = change.newValue {
                    onEvent(["kind": "progress", "value": value])
                }
            }
            group.completionHandler = { results in
                observation?.invalidate()
                for result in results.values {
                    if case .failure(let error) = result {
                        completion(nil, errorPayload(error))
                        return
                    }
                }
                completion(["refreshed": results.count], nil)
            }
        }
    }

    private static func listCertificates(completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            let activeSerial = CertificateManager.shared.activeCertificate?.certificate.serialNumber
            let local = CertificateManager.shared.getAllLocalX509Certificates()
            let localSerials = Set(local.map(\.serialNumber))
            let privateKeySerials = Set(local.compactMap { certificate in
                CertificateManager.shared.getSignableCertificate(for: certificate.serialNumber) == nil
                    ? nil : certificate.serialNumber
            })

            var remote: [ALTX509Certificate] = []
            var portalFailure: [String: Any]?
            do {
                remote = try await DeveloperPortalProxy.shared.fetchCertificates()
            } catch {
                portalFailure = portalErrorPayload(error)
            }

            var payload = remote.map { certificate in
                var item: [String: Any] = [
                    "name": certificate.name,
                    "serialNumber": certificate.serialNumber,
                    "creationDate": certificate.creationDate,
                    "expiryDate": certificate.expiryDate,
                    "isActive": certificate.serialNumber == activeSerial,
                    "hasPrivateKey": privateKeySerials.contains(certificate.serialNumber),
                    "isLocal": localSerials.contains(certificate.serialNumber),
                    "isPortal": true
                ]
                if let identifier = certificate.identifier { item["identifier"] = identifier }
                return item
            }
            let remoteSerials = Set(remote.map(\.serialNumber))
            payload += local.filter { !remoteSerials.contains($0.serialNumber) }.map { certificate in
                [
                    "name": certificate.name,
                    "serialNumber": certificate.serialNumber,
                    "creationDate": certificate.creationDate,
                    "expiryDate": certificate.expiryDate,
                    "isActive": certificate.serialNumber == activeSerial,
                    "hasPrivateKey": privateKeySerials.contains(certificate.serialNumber),
                    "isLocal": true,
                    "isPortal": false
                ]
            }
            var response: [String: Any] = ["certificates": payload]
            if let portalFailure { response["portalFailure"] = portalFailure }
            completion(response, nil)
        }
    }

    /// Exports the active certificate to the AnderStore host through the existing in-memory
    /// command channel. The host cannot read the Core process' default Keychain access group.
    private static func activeCertificate(completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        guard let active = CertificateManager.shared.activeCertificate else {
            completion(nil, [
                "kind": "certificateNotFound",
                "message": "No active signing certificate is available in AnderStore Core"
            ])
            return
        }
        completion([
            "data": active.p12Data.base64EncodedString(),
            "password": active.password ?? "",
            "serialNumber": active.serialNumber
        ], nil)
    }

    private static func revokeCertificate(serialNumber: String,
                                          completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            do {
                let certificates = try await DeveloperPortalProxy.shared.fetchCertificates()
                guard let certificate = certificates.first(where: { $0.serialNumber == serialNumber }) else {
                    completion(nil, ["kind": "notFound", "message": "Certificate not found"])
                    return
                }
                _ = try await DeveloperPortalProxy.shared.revokeCertificate(certificate)
                if CertificateManager.shared.activeCertificate?.serialNumber == serialNumber {
                    CertificateManager.shared.clearActiveCertificate()
                }
                completion(["revoked": true], nil)
            } catch {
                completion(nil, portalErrorPayload(error))
            }
        }
    }

    private static func importCertificate(data: Data,
                                          password: String?,
                                          completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        do {
            let certificate = try CertificateManager.parse(data, password: password)
            try CertificateManager.shared.setActiveCertificate(certificate)
            CertificateManager.shared.saveCertificate(certificate)
            completion(["serialNumber": certificate.serialNumber], nil)
        } catch {
            completion(nil, errorPayload(error))
        }
    }

    private static func exportCertificate(serialNumber: String,
                                          password: String,
                                          completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        do {
            guard let certificate = CertificateManager.shared.getSignableCertificate(for: serialNumber) else {
                completion(nil, ["kind": "privateKeyMissing", "message": "Private key is unavailable"])
                return
            }
            let data = try CertificateManager.convert(certificate, password: password)
            completion(["data": data.base64EncodedString(), "filename": "certificate-\(certificate.serialNumber).p12"], nil)
        } catch {
            completion(nil, errorPayload(error))
        }
    }

    private static func listAppIDs(completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            do {
                let appIDs = try await DeveloperPortalProxy.shared.fetchAppIDs()
                let payload = appIDs.map { appID -> [String: Any] in
                    var item: [String: Any] = [
                        "name": appID.name,
                        "identifier": appID.identifier,
                        "bundleIdentifier": appID.bundleIdentifier
                    ]
                    if let expirationDate = appID.expirationDate { item["expirationDate"] = expirationDate }
                    return item
                }
                completion(["appIDs": payload], nil)
            } catch {
                completion(nil, portalErrorPayload(error))
            }
        }
    }

    private static func deleteAppID(identifier: String,
                                    completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            do {
                let appIDs = try await DeveloperPortalProxy.shared.fetchAppIDs()
                guard let appID = appIDs.first(where: { $0.identifier == identifier }) else {
                    completion(nil, ["kind": "notFound", "message": "App ID not found"])
                    return
                }
                _ = try await DeveloperPortalProxy.shared.deleteAppID(appID)
                completion(["deleted": true], nil)
            } catch {
                completion(nil, portalErrorPayload(error))
            }
        }
    }

    private static func listProfiles(completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            do {
                let profiles = try await DeveloperPortalProxy.shared.listProvisioningProfiles()
                let payload = profiles.map { profile -> [String: Any] in
                    var item: [String: Any] = [
                        "name": profile.name,
                        "uuid": profile.uuid.uuidString
                    ]
                    if let identifier = profile.identifier { item["identifier"] = identifier }
                    if let bundleIdentifier = profile.bundleIdentifier { item["bundleIdentifier"] = bundleIdentifier }
                    return item
                }
                completion(["profiles": payload], nil)
            } catch {
                completion(nil, portalErrorPayload(error))
            }
        }
    }

    /// When minimuxer was last restarted from `device.status`. Boot starts it once; if that
    /// start failed (no tunnel yet), nothing retried and every probe answered "not started".
    nonisolated(unsafe) private static var lastMinimuxerRestart = Date.distantPast
    private static let minimuxerRestartLock = NSLock()

    private static func shouldRestartMinimuxer() -> Bool {
        minimuxerRestartLock.lock()
        defer { minimuxerRestartLock.unlock() }
        guard Date().timeIntervalSince(lastMinimuxerRestart) > 20 else { return false }
        lastMinimuxerRestart = Date()
        return true
    }

    private static func deviceStatus(completion: @escaping ([String: Any]?, [String: Any]?) -> Void) {
        Task {
            let pairingState: String
            let pairingContents = PairingFileManager.shared.fetchPairingFile()
            if let contents = pairingContents {
                do {
                    _ = try PairingFileParser.parse(content: contents)
                    pairingState = "valid"
                } catch {
                    pairingState = "invalid"
                }
            } else {
                pairingState = "missing"
            }

            guard pairingState == "valid" else {
                completion([
                    "ready": false,
                    "pairingState": pairingState,
                    "vpnState": "checking",
                    "connectionState": "unreachable",
                    "pairingReady": false,
                    "vpnReady": false
                ], nil)
                return
            }

            var readiness = await isMinimuxerReady()
            if case .failure(let error) = readiness,
               case .notStarted = error,
               let pairingContents,
               shouldRestartMinimuxer() {
                try? await AppBootManager.shared.startMinimuxer(pairingFile: pairingContents)
                readiness = await isMinimuxerReady()
            }
            switch readiness {
            case .success(let ready):
                completion([
                    "ready": ready,
                    "pairingState": "valid",
                    "vpnState": ready ? "connected" : "checking",
                    "connectionState": ready ? "ready" : "starting",
                    "pairingReady": true,
                    "vpnReady": ready
                ], nil)
            case .failure(let error):
                let operationError = error.asOperationError
                let failure = errorPayload(operationError)
                let status: (pairing: String, vpn: String, connection: String)
                switch error {
                case .invalidPairing:
                    status = ("invalid", "connected", "unreachable")
                case .noConnection:
                    // minimuxer checks for Wi‑Fi: on mobile data it fails here even with the
                    // VPN connected. That is not a VPN problem and must not say so.
                    status = ("valid", "noWifi", "unreachable")
                case .noVPN, .invalidVPN:
                    status = ("valid", "disconnected", "unreachable")
                case .notStarted, .pairingNotLoaded:
                    status = ("valid", "checking", "starting")
                case .noDevice, .notReachable:
                    status = ("valid", "checking", "unreachable")
                default:
                    status = ("valid", "checking", "unreachable")
                }
                completion([
                    "ready": false,
                    "pairingState": status.pairing,
                    "vpnState": status.vpn,
                    "connectionState": status.connection,
                    "vpnReady": status.vpn == "connected",
                    "pairingReady": status.pairing == "valid",
                    "failure": failure
                ], nil)
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
            let nsError = error as NSError
            let diagnosticParts = [
                error.localizedDescription,
                String(reflecting: error),
                nsError.userInfo[NSUnderlyingErrorKey].map { String(describing: $0) } ?? "",
                nsError.userInfo[NSDebugDescriptionErrorKey].map { String(describing: $0) } ?? ""
            ]
            let text = diagnosticParts.joined(separator: " ").lowercased()
            // Apple token (anisette/ADI) failures first: the code is authoritative, the text is
            // only a fallback for when the library localizes its message.
            let underlyingCode = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            if nsError.code == -45061 || underlyingCode == -45061
                || text.contains("-45061") || text.contains("adiotprequest")
                || text.contains("not provisioned") {
                kind = "adiNotProvisioned"
            } else if text.contains("anisette") {
                kind = "anisetteUnavailable"
            } else if text.contains("too many requests") || text.contains("429") {
                kind = "rateLimited"
            } else if text.contains("cancel") {
                kind = "cancelled"
            } else if text.contains("incorrect") || text.contains("invalid password") || text.contains("-22406") {
                kind = "needsAuth"
            } else if text.contains("certificate") && (text.contains("limit") || text.contains("maximum")) {
                kind = "certificateLimit"
            } else if text.contains("active certificate is missing") {
                // VerifyCertificateOperation / ResignAppOperation: Core has no certificate.
                kind = "certificateNotFound"
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

    /// Portal commands use an existing token. If Apple rejects it, asking the user to re-enter
    /// credentials is different from reporting that the password they just typed was wrong.
    private static func portalErrorPayload(_ error: Error) -> [String: Any] {
        var payload = errorPayload(error)
        let nsError = error as NSError
        let diagnostic = [
            error.localizedDescription,
            String(reflecting: error),
            nsError.userInfo[NSUnderlyingErrorKey].map { String(describing: $0) } ?? ""
        ].joined(separator: " ").lowercased()
        if payload["kind"] as? String == "unknown",
           diagnostic.contains("unauthorized") || diagnostic.contains("authentication") ||
           diagnostic.contains("session") || diagnostic.contains("token") ||
           diagnostic.contains("http 401") || diagnostic.contains("status code: 401") ||
           diagnostic.contains("http 403") || diagnostic.contains("status code: 403") {
            payload["kind"] = "sessionExpired"
        }
        switch payload["kind"] as? String {
        case "needsAuth":
            AuthManager.shared.expirePortalSession()
            payload["kind"] = "sessionExpired"
        case "sessionExpired":
            AuthManager.shared.expirePortalSession()
        case "rateLimited":
            AuthManager.shared.expirePortalSession(rateLimited: true)
        default:
            break
        }
        return payload
    }
}
