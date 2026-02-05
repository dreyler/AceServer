import Vapor

// Participant info after enrichment
struct ParticipantInfo {
    let name: String
    let email: String
    let company: String
    let companyDetails: String?  // Company info only
    let linkedInDetails: String?  // LinkedIn info only
    let history: MeetingStore.ParticipantHistory? // NEW
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
        userBio: String? = nil,
        userLocalTime: String? = nil,
        briefPreferences: [String]? = nil,
        app: Application
    ) async -> (brief: String, prompt: String) {
        
        print("🤖 MeetingBriefAgent: Starting generation for '\(meeting.summary ?? "Unknown")'")
        
        // 1. Parse Participants & Enrich
        let attendees = meeting.attendees ?? []
        
        // Limit to 50 participants (safe now with caching)
        let maxParticipants = 50
        
        print("[TRACE] MeetingBriefAgent: 🚀 Processing \(attendees.count) attendees (Max \(maxParticipants))...")
        
        let meetingId = meeting.id
        
        // Concurrent Processing using TaskGroup - NEW V2 Enrichment
        let participantsInfo: [ParticipantInfo] = await withTaskGroup(of: ParticipantInfo?.self) { group in
            for attendee in attendees.prefix(maxParticipants) {
                let email = attendee.email
                let displayName = attendee.displayName
                
                group.addTask {
                    // Use NEW centralized enrichment service
                    let input = ParticipantEnrichmentService.EnrichmentInput(
                        email: email,
                        displayName: displayName,
                        accessToken: accessToken
                    )
                    
                    // This handles ALL enrichment: Google People, caching, company search, LinkedIn
                    let enriched = await ParticipantEnrichmentService.shared.enrichParticipant(
                        input: input,
                        app: app
                    )
                    
                    return ParticipantInfo(
                        name: enriched.name,
                        email: enriched.email,
                        company: enriched.company,
                        companyDetails: enriched.companyDetails,
                        linkedInDetails: enriched.linkedInDetails,
                        history: MeetingStore.shared.getParticipantHistory(
                            userId: userEmail, 
                            participantEmail: email,
                            excludingMeetingId: meetingId // Might be nil from Client
                        )
                    )
                }
            }
            
            // Collect results
            var results: [ParticipantInfo] = []
            for await result in group {
                if let participant = result {
                    results.append(participant)
                }
            }
            return results
        }
        
        // 2. Build Context Block - Split into Known vs Unknown Companies
        var participantContext = ""
        
        // Group participants by company
        var companiesMap: [String: (details: String?, participants: [ParticipantInfo])] = [:]
        var unknownCompanyParticipants: [ParticipantInfo] = []
        
        for p in participantsInfo {
            if p.company == "Unknown" || p.company == "No company found" {
                unknownCompanyParticipants.append(p)
            } else {
                if companiesMap[p.company] == nil {
                    companiesMap[p.company] = (details: p.companyDetails, participants: [])
                }
                companiesMap[p.company]?.participants.append(p)
            }
        }
        
        // --- SECTION 1: KNOWN COMPANIES ---
        if !companiesMap.isEmpty {
            participantContext += "<participants_from_known_companies>\n"
            
            // Sort companies alphabetically
            let sortedCompanies = companiesMap.keys.sorted()
            
            for company in sortedCompanies {
                guard let group = companiesMap[company] else { continue }
                
                participantContext += "  <company>\n"
                participantContext += "    <company_name>\(company)</company_name>\n"
                
                // Show company details once (if available)
                if let details = group.details {
                    participantContext += "    <company_details>\n\(details)\n    </company_details>\n"
                }
                
                participantContext += "    <people>\n"
                // List all participants from this company
                for p in group.participants {
                    participantContext += "      <person>\n"
                    participantContext += "        <email>\(p.email)</email>\n"
                    participantContext += "        <name>\(p.name)</name>\n"
                    
                    // Show LinkedIn details if available (per-person)
                    if let linkedIn = p.linkedInDetails {
                        participantContext += "        <research>\n\(linkedIn)\n        </research>\n"
                    }
                    
                    participantContext += formatParticipantHistory(p.history)
                    
                    participantContext += "      </person>\n"
                }
                participantContext += "    </people>\n"
                participantContext += "  </company>\n"
            }
            participantContext += "</participants_from_known_companies>\n"
        }
        
        // --- SECTION 2: UNKNOWN COMPANIES ---
        if !unknownCompanyParticipants.isEmpty {
            participantContext += "<participants_from_unknown_companies>\n"
            for p in unknownCompanyParticipants {
                participantContext += "  <person>\n"
                participantContext += "    <email>\(p.email)</email>\n"
                participantContext += "    <name>\(p.name)</name>\n"
                // No company info to show
                if let linkedIn = p.linkedInDetails {
                     participantContext += "    <research>\n\(linkedIn)\n    </research>\n"
                }

                participantContext += formatParticipantHistory(p.history)

                participantContext += "  </person>\n"
            }
            participantContext += "</participants_from_unknown_companies>\n"
        }

        
        // 3. Build User Bio Section (if provided)
        var userBioSection = ""
        userBioSection += "<logged_in_user>\n"
        userBioSection += "  <name>\(userName)</name>\n"
        userBioSection += "  <email>\(userEmail)</email>\n"
        if let title = userTitle { userBioSection += "  <title>\(title)</title>\n" }
        if let company = userCompany { userBioSection += "  <company>\(company)</company>\n" }
        if let bio = userBio, !bio.isEmpty { userBioSection += "  <bio>\(bio)</bio>\n" }
        userBioSection += "</logged_in_user>"
        
        // PREFERENCES
        var preferencesSection = ""
        if let prefs = briefPreferences, !prefs.isEmpty {
            preferencesSection = """
            
            <user_preferences>
            \(prefs.joined(separator: "\n"))
            </user_preferences>
            """
        }
        
        // 4. Assemble Prompt for Gemini
        let prompt = """
        You are an executive assistant helping the user prepare for a meeting. Construct a pre-meeting brief to help the user prepare for the meeting
        
        <meeting_details>
          <title>\(meeting.summary ?? "Unknown")</title>
          <date>\(userLocalTime ?? meeting.start?.dateTime ?? "")</date>
          <description>\(meeting.description ?? "No description provided")</description>
          <organizer>\(meeting.organizer?.displayName ?? meeting.organizer?.email ?? "Unknown")</organizer>
        </meeting_details>
        
        \(userBioSection)
        
        <participants>
        \(participantContext)
        </participants>

        \(preferencesSection)

        Rules:
        1. In general, use your own knowledge as well as the provided context to provide the best meeting brief
        2. However, there is a section labeled <participants_from_unknown_companies>, and you should not use your own knowledge or attempt to guess about this information as you are likely to guess wrong and provide incorrect information
        3. Make sure not to get confused and think that the logged in user is a participant
        4. Don't provide any information about the logged in user - the user already knows that
        5. If the user asks for links, only provide them if you have them in the provided context - don't generate your own links
        6. Include company details, such as strategy and recent news, but not about anything in <participants_from_unknown_companies>
        7. End with 1 short, strategic suggestion for the user to ask you a follow up question get more prepared for the meeting. put this question, but not the whole response, in italics
        8. The brief must fit on single iPhone screen (no scrolling), and be dense with value.
        """
        
        print("🤖 Gemini Request: Prompt length \(prompt.count)")
        
        let brief = (try? await GeminiService.shared.generateContent(prompt: prompt)) ?? "Error generating brief"
        
        return (brief: brief, prompt: prompt)
    }
    
    private static func formatParticipantHistory(_ history: MeetingStore.ParticipantHistory?) -> String {
        guard let history = history, history.meetingCount > 0 else { return "" }
        
        var output = "        <past_meetings_last_6months_count>\(history.meetingCount)</past_meetings_last_6months_count>\n"
        var historyCtx = ""
        // Use consistent header label if needed, or just list
        // Based on user request "Last 3 Meetings:" was in one but not the other?
        // Let's standardise to "Last 3 Meetings:"
        if !history.lastMeetings.isEmpty {
             historyCtx = "Last 3 Meetings:\n"
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        
        for m in history.lastMeetings {
            let dateStr = formatter.string(from: m.startTime)
            historyCtx += "- \(m.title) (\(dateStr))\n"
        }
        output += "        <historical_context>\n\(historyCtx)        </historical_context>\n"
        return output
    }
}
