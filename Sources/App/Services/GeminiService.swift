import Vapor
import Foundation

struct GeminiConfig {
    static let apiKey = "REDACTED_GEMINI_KEY"
    static let modelName = "gemini-3-flash-preview"
    static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent"
}

public class GeminiService {
    public static let shared = GeminiService()
    
    // We need an HTTP Client. Vapor provides one, but this singleton pattern
    // makes it hard to inject the Application context easily.
    // For simplicity, we will use URLSession to avoid coupling to Vapor's Request object in shared context,
    // or we could accept a 'Client' parameter.
    // Given the architecture, using URLSession with Linux foundation is fine for outbound calls.
    
    private init() {}
    
    public func generateContent(prompt: String) async throws -> String {
        guard let url = URL(string: GeminiConfig.endpoint + "?key=" + GeminiConfig.apiKey) else {
            throw Abort(.internalServerError, reason: "Invalid Gemini URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        // Debug
        print("🤖 Gemini Request: Prompt length \(prompt.count)")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Abort(.badGateway, reason: "Invalid response from Gemini")
        }
        
        if httpResponse.statusCode != 200 {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Error"
            print("❌ Gemini Error \(httpResponse.statusCode): \(errorMsg)")
            throw Abort(.badRequest, reason: "Gemini API Error: \(httpResponse.statusCode)")
        }
        
        // Parse Response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let firstPart = parts.first,
              let text = firstPart["text"] as? String else {
            
            print("❌ Failed to parse Gemini response")
            throw Abort(.internalServerError, reason: "Failed to parse AI response")
        }
        
        return text
    }
}
