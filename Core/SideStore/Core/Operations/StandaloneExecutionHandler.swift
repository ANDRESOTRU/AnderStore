//
//  StandaloneExecutionHandler.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

protocol AnisetteServerHandler: AnyObject {
    func warnOutdatedAnisetteServer() async throws -> Bool
}

enum ProvisioningErrorDecision {
    case retry
    case cancel
    /// Stop a non-interactive flow and preserve the underlying portal error.
    case fail
}

enum RevokeDecision {
    case keepExisting
    case revokeSelected([ALTX509Certificate])
}

protocol SignInHandler: AnyObject {
    var allowsSilentAuthentication: Bool { get }
    func credentials() async throws -> (String, String)
    func verificationCode(for request: TwoFactorRequest) async throws -> TwoFactorResponse
    func accountRepair(url: URL, message: String) async -> AccountRepairDecision
    func handleSignInResult(_ result: Result<(ALTAccount, ALTAppleAPISession), Error>) async
    func shouldRetryAuthentication(after error: Error) async -> Bool
    
    func resolveTeam(_ teams: [ALTTeam]) async throws -> ALTTeam
    func resolveProvisioningError(_ error: Error) async -> ProvisioningErrorDecision
    func resolvePostAuth() async
    
    func resolveRevocation(certificates: [ALTX509Certificate], teamType: ALTTeamType) async throws -> RevokeDecision
    func resolveResign(mismatchReason: CodeSignValidationReason, context: StandaloneOperationContext) async throws -> Bool
    
    func complete() async
}

extension SignInHandler {
    var allowsSilentAuthentication: Bool { true }

    /// Interactive handlers can ask for corrected credentials and retry. Headless handlers
    /// override this so one button press never hammers Apple's authentication endpoint.
    func shouldRetryAuthentication(after error: Error) async -> Bool { true }
}

