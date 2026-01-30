import Vapor
import Foundation

// Data structure for participant info
private struct ParticipantInfo {
    let name: String
    let email: String
    let company: String
    let researchSnippet: String?
}

public struct MeetingBriefAgent {
    
    // Generates a notification body with AI insight
    // Orchestrates: Google People -> Research Service -> Gemini
    public static func generateBrief(meeting: GoogleCalendarEvent, accessToken: String) async -> String {
        
        print("🤖 MeetingBriefAgent: Starting generation for '\(meeting.summary)'")
        
        // 1. Parse Participants & Enrich
        let attendees = meeting.attendees ?? []
        var participantsInfo: [ParticipantInfo] = []
        
        // Limit to 5 participants for speed/cost
        let maxParticipants = 5
        
        for attendee in attendees.prefix(maxParticipants) {
            let email = attendee.email
            var name = attendee.displayName ?? email
            var company = "Unknown"
            var researchSnippet: String? = nil
            
            // A. Resolve Name via Google People (if "Unknown" or email)
            if name.contains("@") || name == "Unknown" {
                if let resolved = await ServerGooglePeopleService.shared.resolve(email: email, accessToken: accessToken) {
                    name = resolved.name
                    if let c = resolved.company { company = c }
                    print("   -> Resolved '\(email)' to '\(name)'")
                }
            }
            
            // B. Enrich via Research Service (LinkedIn/Company)
            // Skip research for self (using simple 'you' check - naive)
            if !name.lowercased().contains("you") {
                let research = await ServerResearchService.shared.enrich(name: name, companyContext: company, emailContext: email)
                if let hit = research.first {
                    researchSnippet = "\(hit.title) - \(hit.snippet) (\(hit.source))"
                    print("   -> Enriched '\(name)': \(hit.title)")
                }
            }
            
            participantsInfo.append(ParticipantInfo(
                name: name,
                email: email,
                company: company,
                researchSnippet: researchSnippet
            ))
        }
        
        // 2. Construct Prompt using ServerMeetingPrompt template
        let participantsForPrompt = participantsInfo.map { info in
            return (
                name: info.name,
                email: info.email,
                company: info.company != "Unknown" ? info.company : nil,
                linkedin: info.researchSnippet
            )
        }
        
        // Extract user email from access token context (simplified - in real app would decode JWT)
        // For now, use a placeholder
        let userEmail = "user@example.com" // TODO: Extract from session/token
        
        let prompt = ServerMeetingPrompt.construct(
            meeting: meeting,
            participants: participantsForPrompt,
            userEmail: userEmail
        )
        
        print("🤖 Gemini Request: Prompt length \(prompt.count)")
        
        // 3. Generate
        do {
            let insight = try await GeminiService.shared.generateContent(prompt: prompt)
            print("✨ Generated Insight: \(insight.prefix(50))...")
            return insight
        } catch {
            print("❌ Gemini Gen Failed: \(error)")
            return "Meeting starts soon."
        }
    }
}
