import UIKit
import AuthenticationServices
import CryptoKit
import Security

enum GoogleConfig {
    static let clientID = "397274218673-kmou0kr0jps679em2kbj2571378jf9k2.apps.googleusercontent.com"
    static let redirectScheme = "com.googleusercontent.apps.397274218673-kmou0kr0jps679em2kbj2571378jf9k2"
    static let redirectURI = "\(redirectScheme):/oauth2redirect"
    static let scope = "https://www.googleapis.com/auth/drive.appdata"
}

enum GoogleError: LocalizedError {
    case cancelled
    case badResponse
    case notSignedIn
    case noBackup
    case driveFailed(Int)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .badResponse: return "Google sent an unexpected response."
        case .notSignedIn: return "Sign in with Google first."
        case .noBackup: return "There is no backup in Google Drive yet."
        case .driveFailed(let code): return "Google Drive returned error \(code)."
        }
    }
}

/// Signs in with Google (OAuth with PKCE). The refresh token is kept in the Keychain.
@MainActor
final class GoogleAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleAuth()

    private let keychainAccount = "google.refresh.token"
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var session: ASWebAuthenticationSession?

    var isSignedIn: Bool { loadRefreshToken() != nil }

    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    func signIn() async throws {
        let verifier = Self.randomString(64)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleConfig.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let authURL = comps.url!

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let s = ASWebAuthenticationSession(url: authURL,
                                               callbackURLScheme: GoogleConfig.redirectScheme) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? GoogleError.cancelled)
                }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            self.session = s
            s.start()
        }

        guard let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GoogleError.badResponse
        }
        let tokens = try await tokenRequest([
            "code": code,
            "code_verifier": verifier,
            "client_id": GoogleConfig.clientID,
            "redirect_uri": GoogleConfig.redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let refresh = tokens.refresh_token else { throw GoogleError.badResponse }
        saveRefreshToken(refresh)
        accessToken = tokens.access_token
        accessExpiry = Date().addingTimeInterval(Double(tokens.expires_in))
    }

    func validAccessToken() async throws -> String {
        if let token = accessToken, accessExpiry > Date().addingTimeInterval(60) {
            return token
        }
        guard let refresh = loadRefreshToken() else { throw GoogleError.notSignedIn }
        let tokens = try await tokenRequest([
            "refresh_token": refresh,
            "client_id": GoogleConfig.clientID,
            "grant_type": "refresh_token",
        ])
        accessToken = tokens.access_token
        accessExpiry = Date().addingTimeInterval(Double(tokens.expires_in))
        return tokens.access_token
    }

    func signOut() {
        deleteRefreshToken()
        accessToken = nil
        accessExpiry = .distantPast
    }

    // MARK: - Token requests

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleError.badResponse
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Keychain

    private func saveRefreshToken(_ token: String) {
        deleteRefreshToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: Data(token.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadRefreshToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteRefreshToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Helpers

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).map { _ in chars.randomElement()! })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
