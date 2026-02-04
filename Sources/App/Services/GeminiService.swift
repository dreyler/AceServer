import Vapor
import Foundation

struct GeminiConfig {
    static let apiKey = Environment.get("GEMINI_API_KEY") ?? ""
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
        return try await _generate(prompt: prompt, jsonMode: false)
    }
    
    public func generateJSON<T: Codable>(prompt: String, responseType: T.Type) async throws -> T {
        let jsonString = try await _generate(prompt: prompt, jsonMode: true)
        
        guard let data = jsonString.data(using: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to convert AI response to Data")
        }
        
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("❌ JSON Decode Error: \(error). RESPONSE: \(jsonString)")
            throw Abort(.internalServerError, reason: "AI returned invalid JSON: \(error)")
        }
    }
    
    private func _generate(prompt: String, jsonMode: Bool) async throws -> String {
        guard let url = URL(string: GeminiConfig.endpoint + "?key=" + GeminiConfig.apiKey) else {
            throw Abort(.internalServerError, reason: "Invalid Gemini URL")
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 120 // Increase timeout to 120s
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]
        
        if jsonMode {
            requestBody["generationConfig"] = [
                "responseMimeType": "application/json"
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        print("➡️ [Gemini] Sending Request to \(url.absoluteString)...")
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
        
        print("🛑 [DEBUG] Gemini Response:\n\(text)")
        
        // Log to File
        logToFile(prompt: prompt, response: text)
        
        return text
    }
    
    private func logToFile(prompt: String, response: String) {
        let logEntry = """
        ---
        TIMESTAMP: \(Date().ISO8601Format())
        PROMPT:
        \(prompt)
        
        RESPONSE:
        \(response)
        --------------------------------------------------
        
        """
        
        let fileUrl = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("gemini_debug.log")
        
        if let data = logEntry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: fileUrl.path) {
                if let fileHandle = try? FileHandle(forWritingTo: fileUrl) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: fileUrl)
            }
        }
    }
}
