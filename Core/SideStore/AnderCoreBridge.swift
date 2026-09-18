//
//  AnderCoreBridge.swift
//  AnderStore
//
//  Entry points used by AnderStore (SideStoreSupport/XPCClient.m) while Core runs in the background.
//  Looked up at runtime with NSClassFromString(@"AnderCoreBridge").
//

import Foundation
import SideSign

@objc(AnderCoreBridge)
final class AnderCoreBridge: NSObject {

    nonisolated(unsafe) private static var activeHandler: XPCSignInHandler?

    @objc(signInWithAppleID:password:codeRequester:completion:)
    static func signIn(appleID: String,
                       password: String,
                       codeRequester: @escaping (String) -> Void,
                       completion: @escaping (String?, String?) -> Void) {
        let handler = XPCSignInHandler(appleID: appleID, password: password, codeRequester: codeRequester)
        activeHandler = handler

        Task {
            do {
                try await AuthManager.shared.signIn(signInHandler: handler, anisetteServerHandler: handler)
                activeHandler = nil
                completion(nil, appleID)
            } catch {
                activeHandler = nil
                completion(error.localizedDescription, nil)
            }
        }
    }

    @objc(submitVerificationCode:)
    static func submitVerificationCode(_ code: String) {
        activeHandler?.submit(code: code)
    }

    @objc(accountStatusWithCompletion:)
    static func accountStatus(completion: @escaping (String?, String?) -> Void) {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.perform {
            let appleID = DatabaseManager.shared.activeAccount(in: context)?.appleID
            let team = DatabaseManager.shared.activeTeam(in: context)?.name
            completion(appleID, team)
        }
    }

    /// Updates AnderStore itself from the AnderStore source (store.andresot.uk/source.json).
    @objc(updateSelfWithProgress:completion:)
    static func updateSelf(progress: @escaping (Double) -> Void, completion: @escaping (String?) -> Void) {
        AppManager.shared.updateAllSources { _ in
            DispatchQueue.main.async {
                let context = DatabaseManager.shared.viewContext
                let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), StoreApp.altstoreAppID)
                guard let installedApp = InstalledApp.first(satisfying: predicate, in: context) else {
                    completion("AnderStore was not found in the list of installed apps")
                    return
                }
                guard installedApp.hasUpdate else {
                    completion(nil)
                    return
                }
                var observation: NSKeyValueObservation?
                let updateProgress = AppManager.shared.update(installedApp, presentingViewController: nil) { result in
                    observation?.invalidate()
                    switch result {
                    case .success:
                        completion(nil)
                    case .failure(let error):
                        completion(error.localizedDescription)
                    }
                }
                observation = updateProgress.observe(\Progress.fractionCompleted, options: [.new]) { _, change in
                    if let value = change.newValue {
                        progress(value)
                    }
                }
            }
        }
    }
}
