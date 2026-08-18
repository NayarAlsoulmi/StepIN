//
//  AuthenticationView.swift
//  StepIN
//
//  Reusable sign-up/sign-in screen. Email/password stays provider-backed.
//

import SwiftData
import SwiftUI
import UIKit

struct AuthenticationView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var profiles: [UserProfile]

    private let authenticationService: AuthenticationServiceProtocol

    @State private var mode: AuthenticationMode = .signUp
    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var keyboardIsVisible = false

    @FocusState private var focusedField: Field?

    init(authenticationService: AuthenticationServiceProtocol = StepINAuthenticationService(), startsInSignIn: Bool = false) {
        self.authenticationService = authenticationService
        _mode = State(initialValue: startsInSignIn ? .signIn : .signUp)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: StepINSpacing.lg) {
                    header
                    form
                    actions
                }
                .padding(.horizontal, StepINSpacing.screenH)
                .padding(.top, StepINSpacing.xl)
                .padding(.bottom, StepINSpacing.xxl)
            }
            .background(StepINScreenBackground())
            .navigationBarTitleDisplayMode(.inline)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                keyboardIsVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                keyboardIsVisible = false
            }
        }
    }

    private var header: some View {
        VStack(spacing: StepINSpacing.xs) {
            RobotView(state: .idle, presentation: .compact, size: 112)
                .padding(.bottom, StepINSpacing.xxs)
            Text(mode.title)
                .font(StepINFont.h1)
                .foregroundStyle(StepINColor.textPrimary)
            Text(mode.subtitle)
                .font(StepINFont.body2)
                .foregroundStyle(StepINColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.sm) {
            if mode == .signUp {
                HStack(alignment: .top, spacing: StepINSpacing.sm) {
                    AuthTextField(
                        label: "First Name",
                        placeholder: "First name",
                        text: $firstName,
                        focusedField: $focusedField,
                        field: .firstName
                    )
                    .textContentType(.givenName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .lastName }
                    AuthTextField(
                        label: "Last Name",
                        placeholder: "Last name",
                        text: $lastName,
                        focusedField: $focusedField,
                        field: .lastName
                    )
                    .textContentType(.familyName)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .email }
                }
            }

            AuthTextField(
                label: "Email",
                placeholder: "name@example.com",
                text: $email,
                focusedField: $focusedField,
                field: .email
            )
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.next)
            .onSubmit { focusedField = .password }

            passwordField

            if let errorMessage {
                Text(errorMessage)
                    .font(StepINFont.caption)
                    .foregroundStyle(StepINColor.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.xs) {
            Text("Password")
                .font(StepINFont.body4)
                .foregroundColor(StepINColor.textSecondary)

            HStack(spacing: StepINSpacing.xs) {
                Group {
                    if isPasswordVisible {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textContentType(mode == .signUp ? .newPassword : .password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .password)
                .submitLabel(.go)
                .onSubmit { submitPrimary() }

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StepINColor.textTertiary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPasswordVisible ? "Hide password" : "Show password")
            }
            .font(StepINFont.bodyRegular)
            .foregroundStyle(StepINColor.textPrimary)
            .padding(.leading, StepINSpacing.md)
            .padding(.trailing, StepINSpacing.xs)
            .frame(height: 50)
            .background(StepINColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous)
                    .stroke(focusedField == .password ? StepINColor.primaryDark : StepINColor.border, lineWidth: focusedField == .password ? 1.15 : 1)
            )
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = .password }
    }

    private var actions: some View {
        VStack(spacing: StepINSpacing.sm) {
            AuthPrimaryButton(title: mode.primaryButtonTitle, isLoading: isLoading, isEnabled: !isLoading) {
                submitPrimary()
            }

            if mode == .signIn {
                Button("Forgot Password?") {
                    sendPasswordReset()
                }
                .font(StepINFont.body4)
                .foregroundStyle(StepINColor.primary)
                .disabled(isLoading)
            }

            modeSwitch
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 4) {
            Text(mode.switchPrompt)
                .font(StepINFont.body4)
                .foregroundStyle(StepINColor.textSecondary)
            Button(mode.switchActionTitle) {
                withAnimation(StepINMotion.springStandard) {
                    mode = mode == .signUp ? .signIn : .signUp
                    password = ""
                    errorMessage = nil
                    focusedField = mode == .signUp ? .firstName : .email
                }
            }
            .font(StepINFont.body4.weight(.semibold))
            .foregroundStyle(StepINColor.primary)
            .disabled(isLoading)
        }
        .multilineTextAlignment(.center)
    }

    private func submitPrimary() {
        guard !isLoading else { return }
        errorMessage = nil

        do {
            try validateForm()
        } catch let error as StepINAuthenticationError {
            errorMessage = error.localizedDescription
            return
        } catch {
            errorMessage = StepINAuthenticationError.networkUnavailable.localizedDescription
            return
        }

        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let user: AuthenticatedUser
                if mode == .signUp {
                    user = try await authenticationService.signUpWithEmail(
                        firstName: firstName.stepINTrimmed,
                        lastName: lastName.stepINTrimmed,
                        email: email.stepINTrimmed,
                        password: password
                    )
                    upsertProfile(firstName: firstName, lastName: lastName, email: email)
                } else {
                    user = try await authenticationService.signInWithEmail(email: email.stepINTrimmed, password: password)
                }
                await completeAuthentication(user)
            } catch let error as StepINAuthenticationError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = StepINAuthenticationError.networkUnavailable.localizedDescription
            }
        }
    }

    private func completeAuthentication(_ user: AuthenticatedUser) async {
        await prepareForRootAuthenticationSwitch()
        await Task.yield()
        appState.authenticate(user)
    }

    private func prepareForRootAuthenticationSwitch() async {
        focusedField = nil
        let shouldWaitForKeyboard = keyboardIsVisible

        if shouldWaitForKeyboard {
            await waitForKeyboardDismissal()
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            await Task.yield()
        }
    }

    private func waitForKeyboardDismissal() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var didResume = false
            var observer: NSObjectProtocol?

            func resumeOnce() {
                guard !didResume else { return }
                didResume = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                continuation.resume()
            }

            observer = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                keyboardIsVisible = false
                resumeOnce()
            }

            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

            DispatchQueue.main.async {
                if !keyboardIsVisible {
                    resumeOnce()
                }
            }
        }
    }

    private func sendPasswordReset() {
        guard !isLoading else { return }
        errorMessage = nil
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                try await authenticationService.sendPasswordReset(email: email)
                errorMessage = "Check your email for reset instructions."
            } catch let error as StepINAuthenticationError {
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = StepINAuthenticationError.networkUnavailable.localizedDescription
            }
        }
    }

    private func validateForm() throws {
        if mode == .signUp {
            guard !firstName.stepINTrimmed.isEmpty else { throw StepINAuthenticationError.missingFirstName }
            guard !lastName.stepINTrimmed.isEmpty else { throw StepINAuthenticationError.missingLastName }
        }
        guard !email.stepINTrimmed.isEmpty else { throw StepINAuthenticationError.missingEmail }
        guard email.stepINLooksLikeEmail else { throw StepINAuthenticationError.invalidEmail }
        guard !password.isEmpty else { throw StepINAuthenticationError.missingPassword }
        guard password.count >= authenticationService.passwordMinimumLength else {
            throw StepINAuthenticationError.weakPassword(minimumLength: authenticationService.passwordMinimumLength)
        }
    }

    private func upsertProfile(firstName: String?, lastName: String?, email: String?) {
        let profile = profiles.first ?? UserProfile(firstName: firstName?.stepINNilIfBlank ?? "")
        if profiles.first == nil {
            context.insert(profile)
        }

        if profile.firstName.stepINTrimmed.isEmpty, let firstName = firstName?.stepINNilIfBlank {
            profile.firstName = firstName
        }
        if profile.lastName?.stepINNilIfBlank == nil, let lastName = lastName?.stepINNilIfBlank {
            profile.lastName = lastName
        }
        if profile.email?.stepINNilIfBlank == nil, let email = email?.stepINNilIfBlank {
            profile.email = email
        }
        profile.updatedAt = .now
        appState.hasProfile = !profile.firstName.stepINTrimmed.isEmpty
    }
}

private enum AuthenticationMode {
    case signUp
    case signIn

    var title: String {
        switch self {
        case .signUp: "Create your account"
        case .signIn: "Welcome back"
        }
    }

    var subtitle: String {
        switch self {
        case .signUp: "Save your progress and keep practicing anywhere."
        case .signIn: "Continue your practice where you left off."
        }
    }

    var primaryButtonTitle: String {
        switch self {
        case .signUp: "Create Account"
        case .signIn: "Sign In"
        }
    }

    var switchPrompt: String {
        switch self {
        case .signUp: "Already have an account?"
        case .signIn: "Don't have an account?"
        }
    }

    var switchActionTitle: String {
        switch self {
        case .signUp: "Sign In"
        case .signIn: "Sign Up"
        }
    }
}

private enum Field: Hashable {
    case firstName
    case lastName
    case email
    case password
}

private struct AuthTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    let focusedField: FocusState<Field?>.Binding
    let field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: StepINSpacing.xs) {
            Text(label)
                .font(StepINFont.body4)
                .foregroundColor(StepINColor.textSecondary)

            TextField(placeholder, text: $text)
                .focused(focusedField, equals: field)
                .font(StepINFont.bodyRegular)
                .foregroundStyle(StepINColor.textPrimary)
                .padding(.horizontal, StepINSpacing.md)
                .frame(height: 50)
                .background(StepINColor.surface)
                .clipShape(RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous)
                        .stroke(isFocused ? StepINColor.primaryDark : StepINColor.border, lineWidth: isFocused ? 1.15 : 1)
                )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focusedField.wrappedValue = field }
    }

    private var isFocused: Bool {
        focusedField.wrappedValue == field
    }
}

private struct AuthPrimaryButton: View {
    let title: String
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button {
            guard isEnabled && !isLoading else { return }
            action()
        } label: {
            HStack(spacing: StepINSpacing.xs) {
                if isLoading {
                    ProgressView()
                        .tint(StepINColor.onPrimary)
                } else {
                    Text(title)
                }
            }
            .font(StepINFont.button)
            .foregroundStyle(StepINColor.onPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(StepINColor.primaryDark)
            .clipShape(RoundedRectangle(cornerRadius: StepINRadius.small, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(StepINPressStyle())
        .disabled(!isEnabled || isLoading)
        .accessibilityLabel(Text(title))
    }
}

#Preview("Sign Up") {
    AuthenticationView()
        .environment(AppState(hasProfile: false, hasCompletedOnboarding: true, isAuthenticated: false, currentUser: nil))
        .modelContainer(PreviewData.emptyAuthContainer)
}

#Preview("Sign In") {
    AuthenticationView(startsInSignIn: true)
        .environment(AppState(hasProfile: false, hasCompletedOnboarding: true, isAuthenticated: false, currentUser: nil))
        .modelContainer(PreviewData.emptyAuthContainer)
}
