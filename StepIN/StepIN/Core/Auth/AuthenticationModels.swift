//
//  AuthenticationModels.swift
//  StepIN
//
//  Shared authentication state and user-facing auth errors.
//

import Foundation

enum AuthenticationProvider: String, Codable, Sendable {
    case email
    case apple
}

struct AuthenticatedUser: Sendable, Equatable {
    let id: String
    let email: String?
    let provider: AuthenticationProvider
}

struct AppleProfilePayload: Sendable {
    let userIdentifier: String
    let firstName: String?
    let lastName: String?
    let email: String?
}

enum StepINAuthenticationError: LocalizedError, Equatable {
    case backendUnavailable
    case emailAlreadyExists
    case incorrectCredentials
    case passwordResetUnavailable
    case invalidEmail
    case missingEmail
    case missingPassword
    case weakPassword(minimumLength: Int)
    case missingFirstName
    case missingLastName
    case appleCredentialUnavailable
    case appleAuthorizationFailed
    case appleCredentialRevoked
    case networkUnavailable

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            "Email and password accounts need an authentication backend before they can be used."
        case .emailAlreadyExists:
            "An account with this email already exists. Sign in instead."
        case .incorrectCredentials:
            "Email or password is incorrect."
        case .passwordResetUnavailable:
            "Password reset is not available for local prototype accounts."
        case .invalidEmail:
            "Enter a valid email address."
        case .missingEmail:
            "Enter your email address."
        case .missingPassword:
            "Enter your password."
        case .weakPassword(let minimumLength):
            "Password must be at least \(minimumLength) characters."
        case .missingFirstName:
            "Enter your first name."
        case .missingLastName:
            "Enter your last name."
        case .appleCredentialUnavailable:
            "Apple could not provide the sign-in credential."
        case .appleAuthorizationFailed:
            "Continue with Apple could not be completed. Try again."
        case .appleCredentialRevoked:
            "Your Apple sign-in session expired. Please sign in again."
        case .networkUnavailable:
            "Check your connection and try again."
        }
    }
}

extension String {
    var stepINTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var stepINNilIfBlank: String? {
        let value = stepINTrimmed
        return value.isEmpty ? nil : value
    }

    var stepINLooksLikeEmail: Bool {
        let value = stepINTrimmed
        guard let atIndex = value.firstIndex(of: "@"),
              atIndex != value.startIndex,
              atIndex != value.index(before: value.endIndex) else {
            return false
        }
        let domain = value[value.index(after: atIndex)...]
        return domain.contains(".") && !value.contains(" ")
    }
}
