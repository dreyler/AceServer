import Vapor
import Foundation

struct TokenRefreshResponse: Codable {
    let access_token: String
    let expires_in: Int
    let scope: String?
    let token_type: String?
}

class TokenRefreshService {
    static let shared = TokenRefreshService()
    
    // Hardcoded Client ID to match the iOS App
    private let clientID = "36577193528-uodq7s3c6r816pcpn35sno6864tauj38.apps.googleusercontent.com"
    private let tokenURL = "https://oauth2.googleapis.com/token"
    
    func refreshAccessToken(refreshToken: String, app: Application) async throws -> String {
        app.logger.info("🔄 Attempting to refresh Google Access Token...")
        
        guard let url = URL(string: tokenURL) else {
            throw Abort(.internalServerError, reason: "Invalid Token URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParams = [
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        
        request.httpBody = bodyParams.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown"
            app.logger.error("❌ Token Refresh Failed: \(errorMsg)")
            throw Abort(.unauthorized, reason: "Failed to refresh token")
        }
        
        let refreshResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
        return refreshResponse.access_token
    }
}
