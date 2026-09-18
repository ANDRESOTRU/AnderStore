//
//  XPCSignInHandler.swift
//  AnderStore
//
//  Sign-in handler for AnderStore: Core runs in the background (LiveProcess) without its own
//  interface, and every question (password, 2FA code) is answered by the AnderStore screen over XPC.
//

import Foundation
import SideSign

final class XPCSignInHandler: SignInHandler, AnisetteServerHandler, @unchecked Sendable {

    private let appleID: String
    private let password: String
    private let codeRequester: (String) -> Void

    private let lock = NSLock()
    private var codeContinuation: CheckedContinuation<String, Never>?

    init(appleID: String, password: String, codeRequester: @escaping (String) -> Void) {
        self.appleID = appleID
        self.password = password
        self.codeRequester = codeRequester
    }

    /// Called when the user typed the code in AnderStore. An empty string cancels sign-in.
    func submit(code: String) {
        lock.lock()
        let continuation = codeContinuation
        codeContinuation = nil
        lock.unlock()
        continuation?.resume(returning: code)
    }

    private func askForCode(_ prompt: String) async -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            codeContinuation = continuation
            lock.unlock()
            codeRequester(prompt)
        }
    }

    // MARK: SignInHandler

    func credentials() async throws -> (String, String) {
        (appleID, password)
    }

    func verificationCode(for request: TwoFactorRequest) async throws -> TwoFactorResponse {
        switch request {
        case .selectDeliveryMethod:
            // Always use trusted devices: the code arrives on the user's iPhone/Mac.
            return .requestTrustedDevice

        case .trustedDevice(let error):
            let prompt = error.flatMap { $0.isEmpty ? nil : $0 } ?? "trustedDevice"
            let code = await askForCode(prompt)
            return code.isEmpty ? .cancel : .verificationCode(code)

        case .sms(_, _, let error), .voice(_, _, let error):
            let prompt = error.flatMap { $0.isEmpty ? nil : $0 } ?? "sms"
            let code = await askForCode(prompt)
            return code.isEmpty ? .cancel : .verificationCode(code)
        }
    }

    func accountRepair(url: URL, message: String) async -> AccountRepairDecision {
        // Apple asks to accept new terms in the developer account; continuing usually works.
        .proceed
    }

    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async {}

    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam {
        if let free = teams.first(where: { $0.type == .free }) {
            return free
        }
        guard let first = teams.first else {
            throw OperationError.invalidOperationContext("No developer team found for this Apple ID")
        }
        return first
    }

    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision {
        .cancel
    }

    func resolvePostAuth() async {}

    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision {
        // Revoke only certificates created by AnderStore itself; keep certificates of other tools.
        let ours = certificates.filter { ($0.machineName ?? $0.name).lowercased().contains("anderstore") }
        return ours.isEmpty ? .keepExisting : .revokeSelected(ours)
    }

    func resolveResign(mismatchReason: CodeSignValidationReason, context: StandaloneOperationContext) async throws -> Bool {
        true
    }

    func complete() async {}

    // MARK: AnisetteServerHandler

    func warnOutdatedAnisetteServer() async throws -> Bool {
        true
    }
}
