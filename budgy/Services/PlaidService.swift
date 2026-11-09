import Foundation
import Security

/// Talks to your Budgy relay server (see /Server). Never talks to Plaid directly.
struct PlaidService {
    var baseURL: URL
    var appToken: String

    enum ServiceError: LocalizedError {
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Add your relay server URL and app token in Settings → Bank Connections."
            case .server(let message): message
            }
        }
    }

    /// Builds a service from saved settings, or nil if you haven't set up the server yet.
    static var configured: PlaidService? {
        let urlString = UserDefaults.standard.string(forKey: SettingsKeys.serverURL) ?? ""
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              let token = Keychain.read(SettingsKeys.appToken), !token.isEmpty else { return nil }
        return PlaidService(baseURL: url, appToken: token)
    }

    // MARK: Endpoints

    struct HealthResponse: Decodable { let ok: Bool; let env: String? }

    struct LinkSession: Decodable {
        let link_token: String
        let hosted_link_url: String
        let is_investments: Bool
    }

    struct LinkedItem: Decodable {
        let item_id: String
        let institution_name: String
        let is_investments: Bool
    }

    struct RemoteAccount: Decodable {
        let item_id: String
        let institution_name: String
        let account_id: String
        let name: String
        let official_name: String?
        let mask: String?
        let type: String
        let subtype: String?
        let current: Double?
        let available: Double?
        let limit: Double?
    }

    struct ItemError: Decodable { let item_id: String; let error: String }

    struct RemoteTransaction: Decodable {
        let transaction_id: String
        let account_id: String
        let amount: Double
        let date: String
        let name: String
        let merchant_name: String?
        let pending: Bool
        let category_primary: String
        let category_detailed: String
    }

    struct ItemSync: Decodable {
        let item_id: String
        let added: [RemoteTransaction]
        let modified: [RemoteTransaction]
        let removed: [String]
        let next_cursor: String
        let error: String?
    }

    func health() async throws -> HealthResponse {
        try await post("/health", body: [String: String]())
    }

    func createLink(investments: Bool) async throws -> LinkSession {
        try await post("/link/create", body: ["kind": investments ? "investments" : "bank"])
    }

    func completeLink(_ session: LinkSession) async throws -> [LinkedItem] {
        struct Body: Encodable { let link_token: String; let is_investments: Bool }
        struct Response: Decodable { let items: [LinkedItem] }
        let response: Response = try await post("/link/complete", body: Body(link_token: session.link_token, is_investments: session.is_investments))
        return response.items
    }

    func accounts() async throws -> (accounts: [RemoteAccount], errors: [ItemError]) {
        struct Response: Decodable { let accounts: [RemoteAccount]; let errors: [ItemError] }
        let response: Response = try await post("/accounts", body: [String: String]())
        return (response.accounts, response.errors)
    }

    func syncTransactions(cursors: [String: String]) async throws -> [ItemSync] {
        struct Body: Encodable { let cursors: [String: String] }
        struct Response: Decodable { let items: [ItemSync] }
        let response: Response = try await post("/transactions/sync", body: Body(cursors: cursors))
        return response.items
    }

    func removeItem(_ itemID: String) async throws {
        struct Response: Decodable { let removed: Bool }
        let _: Response = try await post("/items/remove", body: ["item_id": itemID])
    }

    // MARK: Transport

    private struct ErrorBody: Decodable { let error: String }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Server returned \(status)"
            throw ServiceError.server(message)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

// MARK: - Settings keys

enum SettingsKeys {
    static let serverURL = "plaidServerURL"
    static let appToken = "plaidAppToken"
    static let faceIDEnabled = "faceIDEnabled"
    static let notificationsEnabled = "notificationsEnabled"
    static let hasSeededSampleData = "hasSeededSampleData"
    static let lastSync = "lastPlaidSync"
    static let usePrivateCloudCompute = "usePrivateCloudCompute"
    static let demoBankEnabled = "demoBankEnabled"
    static let appearance = "appearance"
    static let themeColor = "themeColor"
}

// MARK: - Keychain

/// Minimal Keychain wrapper for the relay server's app token.
enum Keychain {
    private static let service = "com.budgy.app"

    static func save(_ value: String, for key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
