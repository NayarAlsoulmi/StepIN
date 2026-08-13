//
//  AuthenticationService.swift
//  StepIN
//
//  Authentication boundary. Email/password is local prototype auth backed by
//  Keychain credential verifiers; Apple uses the native Apple credential.
//

import AuthenticationServices
import CryptoKit
import Foundation

protocol AuthenticationServiceProtocol {
    var passwordMinimumLength: Int { get }
    func restoreSession() -> AuthenticatedUser?
    func signUpWithEmail(firstName: String, lastName: String, email: String, password: String) async throws -> AuthenticatedUser
    func signInWithEmail(email: String, password: String) async throws -> AuthenticatedUser
    func sendPasswordReset(email: String) async throws
    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws -> (AuthenticatedUser, AppleProfilePayload)
    func validateAppleCredentialIfNeeded(for user: AuthenticatedUser) async throws
    func signOut()
}

final class StepINAuthenticationService: AuthenticationServiceProtocol {
    let passwordMinimumLength = 8

    private let accountsKey = "stepin.localAuthentication.accounts.v1"
    private let providerKey = "currentProvider"
    private let userIDKey = "currentUserID"
    private let emailKey = "currentEmail"
    private let appleUserIDKey = "appleUserIdentifier"
    private let passwordIterations = 120_000

    func restoreSession() -> AuthenticatedUser? {
        guard let providerValue = StepINKeychain.string(for: providerKey),
              let provider = AuthenticationProvider(rawValue: providerValue),
              let userID = StepINKeychain.string(for: userIDKey) else {
            return nil
        }
        let email = StepINKeychain.string(for: emailKey) ?? account(id: userID)?.email
        return AuthenticatedUser(id: userID, email: email, provider: provider)
    }

    func signUpWithEmail(firstName: String, lastName: String, email: String, password: String) async throws -> AuthenticatedUser {
        try validateEmailPassword(email: email, password: password)
        let trimmedFirstName = firstName.stepINTrimmed
        let trimmedLastName = lastName.stepINTrimmed
        let trimmedEmail = email.stepINTrimmed
        guard !trimmedFirstName.isEmpty else { throw StepINAuthenticationError.missingFirstName }
        guard !trimmedLastName.isEmpty else { throw StepINAuthenticationError.missingLastName }

        var accounts = loadAccounts()
        let normalizedEmail = normalizeEmail(trimmedEmail)
        guard !accounts.contains(where: { $0.provider == .email && $0.normalizedEmail == normalizedEmail }) else {
            throw StepINAuthenticationError.emailAlreadyExists
        }

        let account = LocalAccount(
            id: UUID().uuidString,
            firstName: trimmedFirstName,
            lastName: trimmedLastName,
            email: trimmedEmail,
            normalizedEmail: normalizedEmail,
            provider: .email,
            createdAt: .now
        )
        accounts.append(account)
        try saveAccounts(accounts)
        try storePasswordVerifier(password, accountID: account.id)

        let user = AuthenticatedUser(id: account.id, email: account.email, provider: .email)
        try persistSession(user: user)
        return user
    }

    func signInWithEmail(email: String, password: String) async throws -> AuthenticatedUser {
        try validateEmailPassword(email: email, password: password)
        let normalizedEmail = normalizeEmail(email)
        guard let account = loadAccounts().first(where: { $0.provider == .email && $0.normalizedEmail == normalizedEmail }) else {
            throw StepINAuthenticationError.incorrectCredentials
        }
        guard verifyPassword(password, accountID: account.id) else {
            throw StepINAuthenticationError.incorrectCredentials
        }

        let user = AuthenticatedUser(id: account.id, email: account.email, provider: .email)
        try persistSession(user: user)
        return user
    }

    func sendPasswordReset(email: String) async throws {
        let trimmedEmail = email.stepINTrimmed
        guard !trimmedEmail.isEmpty else { throw StepINAuthenticationError.missingEmail }
        guard trimmedEmail.stepINLooksLikeEmail else { throw StepINAuthenticationError.invalidEmail }
        throw StepINAuthenticationError.passwordResetUnavailable
    }

    func signInWithApple(credential: ASAuthorizationAppleIDCredential) async throws -> (AuthenticatedUser, AppleProfilePayload) {
        let appleUserIdentifier = credential.user.stepINTrimmed
        guard !appleUserIdentifier.isEmpty else { throw StepINAuthenticationError.appleCredentialUnavailable }

        let payload = AppleProfilePayload(
            userIdentifier: appleUserIdentifier,
            firstName: credential.fullName?.givenName?.stepINNilIfBlank,
            lastName: credential.fullName?.familyName?.stepINNilIfBlank,
            email: credential.email?.stepINNilIfBlank
        )

        let account = try appleAccount(for: appleUserIdentifier, payload: payload)
        let user = AuthenticatedUser(id: account.id, email: account.email, provider: .apple)
        try persistSession(user: user)
        try StepINKeychain.set(appleUserIdentifier, for: appleUserIDKey)
        return (user, payload)
    }

    func validateAppleCredentialIfNeeded(for user: AuthenticatedUser) async throws {
        guard user.provider == .apple,
              let appleUserIdentifier = StepINKeychain.string(for: appleUserIDKey) else {
            return
        }

        let state = await ASAuthorizationAppleIDProvider().stepINCredentialState(forUserID: appleUserIdentifier)
        switch state {
        case .authorized:
            return
        case .revoked, .notFound, .transferred:
            signOut()
            throw StepINAuthenticationError.appleCredentialRevoked
        @unknown default:
            return
        }
    }

    func signOut() {
        StepINKeychain.remove(providerKey)
        StepINKeychain.remove(userIDKey)
        StepINKeychain.remove(emailKey)
    }

    private func appleAccount(for appleUserIdentifier: String, payload: AppleProfilePayload) throws -> LocalAccount {
        let mappingKey = appleAccountMappingKey(for: appleUserIdentifier)
        var accounts = loadAccounts()

        if let localID = StepINKeychain.string(for: mappingKey),
           let existing = accounts.first(where: { $0.id == localID && $0.provider == .apple }) {
            return existing
        }

        let account = LocalAccount(
            id: UUID().uuidString,
            firstName: payload.firstName,
            lastName: payload.lastName,
            email: payload.email,
            normalizedEmail: payload.email.map(normalizeEmail),
            provider: .apple,
            createdAt: .now
        )
        accounts.append(account)
        try saveAccounts(accounts)
        try StepINKeychain.set(account.id, for: mappingKey)
        return account
    }

    private func persistSession(user: AuthenticatedUser) throws {
        try StepINKeychain.set(user.provider.rawValue, for: providerKey)
        try StepINKeychain.set(user.id, for: userIDKey)
        if let email = user.email?.stepINNilIfBlank {
            try StepINKeychain.set(email, for: emailKey)
        } else {
            StepINKeychain.remove(emailKey)
        }
    }

    private func validateEmailPassword(email: String, password: String) throws {
        let trimmedEmail = email.stepINTrimmed
        guard !trimmedEmail.isEmpty else { throw StepINAuthenticationError.missingEmail }
        guard trimmedEmail.stepINLooksLikeEmail else { throw StepINAuthenticationError.invalidEmail }
        guard !password.isEmpty else { throw StepINAuthenticationError.missingPassword }
        guard password.count >= passwordMinimumLength else {
            throw StepINAuthenticationError.weakPassword(minimumLength: passwordMinimumLength)
        }
    }

    private func loadAccounts() -> [LocalAccount] {
        guard let data = UserDefaults.standard.data(forKey: accountsKey) else { return [] }
        return (try? JSONDecoder().decode([LocalAccount].self, from: data)) ?? []
    }

    private func saveAccounts(_ accounts: [LocalAccount]) throws {
        let data = try JSONEncoder().encode(accounts)
        UserDefaults.standard.set(data, forKey: accountsKey)
    }

    private func account(id: String) -> LocalAccount? {
        loadAccounts().first { $0.id == id }
    }

    private func normalizeEmail(_ email: String) -> String {
        email.stepINTrimmed.lowercased()
    }

    private func passwordKey(for accountID: String) -> String {
        "emailPasswordVerifier.\(accountID)"
    }

    private func appleAccountMappingKey(for appleUserIdentifier: String) -> String {
        "appleAccount.\(SHA256.hash(data: Data(appleUserIdentifier.utf8)).hexString)"
    }

    private func storePasswordVerifier(_ password: String, accountID: String) throws {
        let salt = try secureRandomData(count: 32)
        let verifier = derivePasswordVerifier(password: password, salt: salt, iterations: passwordIterations)
        let value = PasswordCredential(iterations: passwordIterations, salt: salt.base64EncodedString(), verifier: verifier.base64EncodedString())
        let encoded = try JSONEncoder().encode(value)
        guard let string = String(data: encoded, encoding: .utf8) else { throw StepINAuthenticationError.networkUnavailable }
        try StepINKeychain.set(string, for: passwordKey(for: accountID))
    }

    private func verifyPassword(_ password: String, accountID: String) -> Bool {
        guard let string = StepINKeychain.string(for: passwordKey(for: accountID)),
              let data = string.data(using: .utf8),
              let credential = try? JSONDecoder().decode(PasswordCredential.self, from: data),
              let salt = Data(base64Encoded: credential.salt),
              let expected = Data(base64Encoded: credential.verifier) else {
            return false
        }
        let candidate = derivePasswordVerifier(password: password, salt: salt, iterations: credential.iterations)
        return constantTimeEquals(candidate, expected)
    }

    private func derivePasswordVerifier(password: String, salt: Data, iterations: Int) -> Data {
        var material = Data(password.utf8)
        material.append(salt)
        var digest = Data(SHA256.hash(data: material))
        for _ in 1..<iterations {
            var round = Data(password.utf8)
            round.append(salt)
            round.append(digest)
            digest = Data(SHA256.hash(data: round))
        }
        return digest
    }

    private func secureRandomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        return Data(bytes)
    }

    private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

private struct LocalAccount: Codable {
    let id: String
    var firstName: String?
    var lastName: String?
    var email: String?
    var normalizedEmail: String?
    let provider: AuthenticationProvider
    let createdAt: Date
}

private struct PasswordCredential: Codable {
    let iterations: Int
    let salt: String
    let verifier: String
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension ASAuthorizationAppleIDProvider {
    func stepINCredentialState(forUserID userID: String) async -> ASAuthorizationAppleIDProvider.CredentialState {
        await withCheckedContinuation { continuation in
            getCredentialState(forUserID: userID) { state, _ in
                continuation.resume(returning: state)
            }
        }
    }
}
