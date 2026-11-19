import Foundation
import Foundation
import Combine
import SwiftUI
import AuthenticationServices
#if os(macOS)
import AppKit
#endif

@MainActor
final class OAuth2Manager: NSObject, ObservableObject {
    private static let userAgent: String = {
        let bid = Bundle.main.bundleIdentifier ?? "GitIssues"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "GitIssues/\(ver) (\(bid); build \(build))"
    }()

    // MARK: - Published state
    @Published var isAuthenticated: Bool = false
    @Published var isAuthenticating: Bool = false

    /// Used by UI to present the GitHub Device Flow prompt.
    @Published var deviceFlowUserCode: String? = nil
    @Published var deviceFlowVerificationURL: URL? = nil
    @Published var isShowingDeviceFlowPrompt: Bool = false

    /// Optional UI-friendly error message.
    @Published var lastAuthErrorMessage: String? = nil

    // MARK: - OAuth config (Spello Consulting OAuth App)
    private let clientID = "Ov23liaOKnz48P3xVdlv"
    private let tokenURL = "https://github.com/login/oauth/access_token"
    private let deviceCodeURL = "https://github.com/login/device/code"

    // MARK: - Scope selection (matches your Settings toggle)
    @AppStorage("allowPrivateRepoAccess") var allowPrivateRepoAccess: Bool = false
    
    override init() {
        super.init()
        if tokenStorage.loadAccessToken() != nil {
            isAuthenticated = true
        }
    }

    private var currentScope: String {
        // Minimal default vs private repo access.
        // Use `read:user` (read-only profile) to avoid requesting email addresses.
        allowPrivateRepoAccess ? "repo read:user" : "public_repo read:user"
    }

    // MARK: - Storage
    private let tokenStorage = TokenStorage()

    // MARK: - Errors
    enum OAuth2Error: Error, LocalizedError {
        case deviceFlowFailed(String)

        var errorDescription: String? {
            switch self {
            case .deviceFlowFailed(let msg):
                return msg
            }
        }
    }

    // MARK: - Public API

    /// Primary sign-in: GitHub Device Flow (no client secret required).
    func signIn() {
        AppLogger.shared.info("Sign-in started (device flow)")
        lastAuthErrorMessage = nil
        isAuthenticated = false
        isAuthenticating = true
        startDeviceFlow()
    }

    /// Call this after the user changes the "Private repo access" toggle.
    /// GitHub tokens do not "upgrade" scopes; we must re-authorize to obtain a new token.
    func reauthorizeForScopeChange() {
        AppLogger.shared.info("Re-authorizing for scope change (private access: \(allowPrivateRepoAccess))")
        tokenStorage.clear()
        IssueCacheStore.shared.clear() // visible repositories change with the granted scope
        isAuthenticated = false
        signIn()
    }

    func signOut() {
        AppLogger.shared.info("User signed out")
        tokenStorage.clear()
        IssueCacheStore.shared.clear() // don't leave the previous account's issues on disk
        isAuthenticated = false
        isAuthenticating = false
        deviceFlowUserCode = nil
        deviceFlowVerificationURL = nil
        isShowingDeviceFlowPrompt = false
        lastAuthErrorMessage = nil
    }

    // MARK: - Device Flow

    private func startDeviceFlow() {
        Task {
            do {
                let response = try await requestDeviceCode(scope: currentScope)

                // Publish info for UI.
                deviceFlowUserCode = response.userCode
                deviceFlowVerificationURL = URL(string: response.verificationUri)
                isShowingDeviceFlowPrompt = true

                // Optionally open the verification URL automatically.
                if let url = deviceFlowVerificationURL {
                    openInBrowser(url)
                }

                try await pollForDeviceToken(
                    deviceCode: response.deviceCode,
                    interval: response.interval,
                    expiresIn: response.expiresIn
                )
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                AppLogger.shared.error("Device flow authentication failed: \(msg)")
                lastAuthErrorMessage = msg
                isAuthenticating = false
                // keep the prompt visible so the user can retry/cancel as they wish
            }
        }
    }

    private func requestDeviceCode(scope: String) async throws -> GitHubDeviceCodeResponse {
        var request = URLRequest(url: URL(string: deviceCodeURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")

        request.httpBody = formURLEncoded([
            "client_id": clientID,
            "scope": scope
        ])

        let (data, _) = try await URLSession.shared.data(for: request)

        AppLogger.shared.debug("Requested device code (scope: \(scope))")

        return try JSONDecoder().decode(GitHubDeviceCodeResponse.self, from: data)
    }

    private func pollForDeviceToken(deviceCode: String, interval: Int, expiresIn: Int) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        var pollInterval = max(1, interval)

        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            var request = URLRequest(url: URL(string: tokenURL)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                             forHTTPHeaderField: "Content-Type")

            request.httpBody = formURLEncoded([
                "client_id": clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])

            let (data, _) = try await URLSession.shared.data(for: request)

            let decoded = try JSONDecoder().decode(GitHubTokenResponse.self, from: data)

            if let token = decoded.accessToken, !token.isEmpty {
                AppLogger.shared.info("Authentication succeeded")
                tokenStorage.saveAccessToken(token)
                isAuthenticated = true
                isAuthenticating = false
                isShowingDeviceFlowPrompt = false
                return
            }

            if let err = decoded.error {
                switch err {
                case "authorization_pending":
                    continue
                case "slow_down":
                    pollInterval += 5
                    continue
                case "access_denied":
                    throw OAuth2Error.deviceFlowFailed("User denied authorization.")
                case "expired_token":
                    throw OAuth2Error.deviceFlowFailed("Device code expired. Please try again.")
                default:
                    throw OAuth2Error.deviceFlowFailed(decoded.errorDescription ?? err)
                }
            }
        }

        throw OAuth2Error.deviceFlowFailed("Timed out waiting for authorization.")
    }

    private var authSession: ASWebAuthenticationSession?
    
    private func openInBrowser(_ url: URL) {
        // Use ASWebAuthenticationSession for App Store compliance.
        // Even though device flow doesn't use a callback, we still present
        // the GitHub page through ASWebAuthenticationSession.
        // The user will complete authentication in the session, and our polling
        // will detect when they're done.
        
        // We use a dummy callback URL scheme since device flow doesn't need one.
        let callbackScheme = "gitissues"
        
        authSession = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            // This completion handler may never be called with a valid callback
            // since device flow doesn't redirect back to the app.
            // Our polling mechanism will detect successful authentication.
            // Users can manually close the session window when they see "success" on GitHub.
            
            if let error = error as? ASWebAuthenticationSessionError {
                if error.code == .canceledLogin {
                    // User canceled - this is normal, they might close after seeing success
                    AppLogger.shared.debug("Authentication session canceled by user")
                } else {
                    AppLogger.shared.warning("Authentication session error: \(error.localizedDescription)")
                }
            }
        }
        
        // On macOS, we need to set the presentation context provider
        #if os(macOS)
        authSession?.presentationContextProvider = self
        authSession?.prefersEphemeralWebBrowserSession = false
        #endif
        
        if !authSession!.start() {
            AppLogger.shared.error("Failed to start ASWebAuthenticationSession")
        }
    }
    
    func getAccessToken() -> String? {
        tokenStorage.loadAccessToken()
    }

}

// MARK: - Models

private struct GitHubTokenResponse: Decodable {
    let accessToken: String?
    let tokenType: String?
    let scope: String?
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

// MARK: - Form encoding

private func formURLEncoded(_ params: [String: String]) -> Data {
    func esc(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    let body = params
        .map { "\(esc($0.key))=\(esc($0.value))" }
        .joined(separator: "&")
    return Data(body.utf8)
}

// MARK: - ASWebAuthenticationPresentationContextProviding

#if os(macOS)
extension OAuth2Manager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the key window on macOS
        // This method is called by the system and can access main-actor isolated properties
        return NSApplication.shared.windows.first { $0.isKeyWindow } ?? NSApplication.shared.windows.first!
    }
}
#endif

