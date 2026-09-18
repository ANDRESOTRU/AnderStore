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
}
