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
    public static func generateBrief(
        meeting: GoogleCalendarEvent, 
        accessToken: String, 
        userEmail: String, 
        userName: String,
        userTitle: String? = nil,
        userCompany: String? = nil,
        userBio: String? = nil
    ) async -> (brief: String, prompt: String) {
        
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
            
            // B. Enrich via Research Service using UNIFIED Logic
            // Skip research for self (naive check)
            if !name.lowercased().contains("you") {
                let enriched = await ServerResearchService.shared.processEnrichment(name: name, email: email)
                
                if let co = enriched.companyName {
                    company = co
                }
                if let summary = enriched.researchSummary {
                    researchSnippet = summary
                    print("   -> Enriched '\(name)': Found Company/LinkedIn")
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
        
        // Use provided email or fallback
        let finalUserEmail = userEmail.isEmpty ? "user@example.com" : userEmail
        let finalUserName = userName.isEmpty ? "User" : userName
        
        let prompt = ServerMeetingPrompt.construct(
            meeting: meeting,
            participants: participantsForPrompt,
            userEmail: finalUserEmail,
            userName: finalUserName,
            userTitle: userTitle,
            userCompany: userCompany,
            userBio: userBio
        )
        
        print("🤖 Gemini Request: Prompt length \(prompt.count)")
        
        // 3. Generate
        do {
            let insight = try await GeminiService.shared.generateContent(prompt: prompt)
            print("✨ Generated Insight: \(insight.prefix(50))...")
            return (insight, prompt)
        } catch {
            print("❌ Gemini Gen Failed: \(error)")
            return ("Meeting starts soon.", prompt)
        }
    }
}
