import Foundation
import CryptoKit
import Observation
import SwiftData

/// The signed-in Budgy user.
struct UserProfile: Codable, Equatable {
    var name: String
    var email: String
    var isTestAccount: Bool
    var createdAt: Date

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? name }
}

/// Budgy accounts. For now these live only on this iPhone: the profile in UserDefaults and a
/// salted, hashed password in the Keychain. Swap this for a server or Sign in with Apple later
/// without changing the screens that use it.
@Observable
final class AccountStore {
    private(set) var currentUser: UserProfile?
    private(set) var hasCompletedOnboarding: Bool

    static let testAccountEmail = "test@budgy.app"

    private enum Keys {
        static let profile = "signedInUser"
        static let onboarding = "hasCompletedOnboarding"
        static func credential(_ email: String) -> String { "account.\(email)" }
    }

    enum AccountError: LocalizedError {
        case invalidEmail, weakPassword, missingName, accountExists, wrongCredentials

        var errorDescription: String? {
            switch self {
            case .invalidEmail: "Enter a valid email address."
            case .weakPassword: "Use at least 8 characters for your password."
            case .missingName: "Enter your name."
            case .accountExists: "An account with that email already exists on this iPhone. Sign in instead."
            case .wrongCredentials: "That email and password don't match an account on this iPhone."
            }
        }
    }

    private struct Credential: Codable {
        var name: String
        var salt: Data
        var hash: Data
        var createdAt: Date
    }

    init() {
        let defaults = UserDefaults.standard
        hasCompletedOnboarding = defaults.bool(forKey: Keys.onboarding)
        if let data = defaults.data(forKey: Keys.profile) {
            currentUser = try? JSONDecoder().decode(UserProfile.self, from: data)
        }
    }

    // MARK: Sign up / sign in

    func signUp(name: String, email: String, password: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = normalize(email)
        guard !name.isEmpty else { throw AccountError.missingName }
        guard isValidEmail(email) else { throw AccountError.invalidEmail }
        guard password.count >= 8 else { throw AccountError.weakPassword }
        guard loadCredential(email) == nil else { throw AccountError.accountExists }

        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let credential = Credential(name: name, salt: salt, hash: Self.hash(password, salt: salt), createdAt: .now)
        if let data = try? JSONEncoder().encode(credential) {
            Keychain.save(data.base64EncodedString(), for: Keys.credential(email))
        }
        setUser(UserProfile(name: name, email: email, isTestAccount: false, createdAt: credential.createdAt))
    }

    func signIn(email: String, password: String) throws {
        let email = normalize(email)
        guard let credential = loadCredential(email),
              Self.hash(password, salt: credential.salt) == credential.hash else {
            throw AccountError.wrongCredentials
        }
        setUser(UserProfile(name: credential.name, email: email, isTestAccount: false, createdAt: credential.createdAt))
    }

    /// A throwaway account for testing; delete it from Settings → Account.
    func signInWithTestAccount() {
        setUser(UserProfile(name: "Test User", email: Self.testAccountEmail, isTestAccount: true, createdAt: .now))
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Keys.onboarding)
    }

    /// Signs out and returns to the welcome screen. Your data stays on this iPhone.
    func signOut() {
        setUser(nil)
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Keys.onboarding)
    }

    /// Deletes the account and everything Budgy has stored on this iPhone.
    func deleteAccount(context: ModelContext, sync: SyncService) {
        if let email = currentUser?.email {
            Keychain.save("", for: Keys.credential(email))
        }
        sync.disconnectDemoBank(context: context)
        for model in BudgySchema.models {
            try? context.delete(model: model)
        }
        try? context.save()
        SampleData.ensureDefaultCategories(context: context)
        SyncService.performHousekeeping(context: context)
        signOut()
    }

    // MARK: Helpers

    private func setUser(_ user: UserProfile?) {
        currentUser = user
        if let user, let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: Keys.profile)
        } else {
            UserDefaults.standard.removeObject(forKey: Keys.profile)
        }
    }

    private func loadCredential(_ email: String) -> Credential? {
        guard let stored = Keychain.read(Keys.credential(email)), !stored.isEmpty,
              let data = Data(base64Encoded: stored) else { return nil }
        return try? JSONDecoder().decode(Credential.self, from: data)
    }

    private func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isValidEmail(_ email: String) -> Bool {
        email.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }

    /// Salted SHA-256, stretched with repeated rounds so stolen hashes are slow to guess.
    private static func hash(_ password: String, salt: Data) -> Data {
        var digest = Data(SHA256.hash(data: salt + Data(password.utf8)))
        for _ in 0..<10_000 {
            digest = Data(SHA256.hash(data: digest + salt))
        }
        return digest
    }
}
