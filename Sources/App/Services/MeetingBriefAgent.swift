import Vapor

// Participant info after enrichment
struct ParticipantInfo {
    let name: String
    let email: String
    let company: String
    let companyDetails: String?  // Company info only
    let linkedInDetails: String?  // LinkedIn info only
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
        app: Application
    ) async -> (brief: String, prompt: String) {
        
        print("🤖 MeetingBriefAgent: Starting generation for '\(meeting.summary ?? "Unknown")'")
        
        // 1. Parse Participants & Enrich
        let attendees = meeting.attendees ?? []
        
        // Limit to 20 participants for speed/cost
        let maxParticipants = 20
        
        print("[TRACE] MeetingBriefAgent: 🚀 Processing \(attendees.count) attendees (Max \(maxParticipants))...")
        
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
                        linkedInDetails: enriched.linkedInDetails
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
        
        // 2. Build Context Block - Group by Company
        var participantContext = ""
        
        // Group participants by company
        var companiesMap: [String: (details: String?, participants: [ParticipantInfo])] = [:]
        for p in participantsInfo {
            if companiesMap[p.company] == nil {
                companiesMap[p.company] = (details: p.companyDetails, participants: [])
            }
            companiesMap[p.company]?.participants.append(p)
        }
        
        // Sort companies (put "Unknown" last)
        let sortedCompanies = companiesMap.keys.sorted { c1, c2 in
            if c1 == "Unknown" { return false }
            if c2 == "Unknown" { return true }
            return c1 < c2
        }
        
        // Build grouped output with numbered companies
        var companyNumber = 1
        for company in sortedCompanies {
            guard let group = companiesMap[company] else { continue }
            
            participantContext += "Company #\(companyNumber): \(company)\n"
            
            // Show company details once (if available)
            if let details = group.details {
                participantContext += "\(details)\n"
            }
            
            // List all participants from this company
            for p in group.participants {
                participantContext += "email: \(p.email)\n"
                participantContext += "name: \(p.name)\n"
                
                // Show LinkedIn details if available (per-person)
                if let linkedIn = p.linkedInDetails {
                    participantContext += "research: \(linkedIn)\n"
                }
            }
            
            participantContext += "\n"
            companyNumber += 1
        }

        
        // 3. Build User Bio Section (if provided)
        var userBioSection = ""
        if let bio = userBio, !bio.isEmpty {
            userBioSection = """
            **You (The Meeting Owner)**:
            - Name: \(userName) (\(userEmail))
            \(userTitle != nil ? "- Title: \(userTitle!)\n" : "")\(userCompany != nil ? "- Company: \(userCompany!)\n" : "")- Bio: \(bio)
            
            """
        } else {
            userBioSection = """
            **You (The Meeting Owner)**:
            - Name: \(userName) (\(userEmail))
            \(userTitle != nil ? "- Title: \(userTitle!)\n" : "")\(userCompany != nil ? "- Company: \(userCompany!)\n" : "")
            """
        }
        
        // 4. Assemble Prompt for Gemini
        let prompt = """
        You are an executive assistant helping the user prepare for a meeting. Construct a pre-meeting brief to help the user prepare for the meeting
        
        **Meeting Details**:
        - **Title**: \(meeting.summary ?? "Unknown")
        - **Date/Time**: \(meeting.start?.dateTime ?? "")
        
        \(userBioSection)
        
        **Participants**:
        \(participantContext)

        Rules:
        1. For companies, you can use your own knowledge, as well as the provided context
        2. For participants, do not use your own knowledge, only use the provided context, to avoid giving incorrect information
        3. Make sure not to get confused and think that the logged in user is a participant
        4. Don't provide company information about the company that the logged in user works at
        5. Sometimes in the description listed above, there will be boilerplate about how to connect to the meeting with google / microsoft / webex / zoom etc. don't get confused and think that is who is hosting the meeting or that those are participants. those organizations are only participating if they are mentioned in the research
        6. Include company details, such as strategy and recent news
        7. End with 1 short, strategic suggestion for the user to ask you a follow up question get more prepared for the meeting. put this question, but not the whole response, in italics
        8. The brief must fit on single iPhone screen (no scrolling), and be dense with value.
        """
        
        print("🤖 Gemini Request: Prompt length \(prompt.count)")
        
        let brief = (try? await GeminiService.shared.generateContent(prompt: prompt)) ?? "Error generating brief"
        
        return (brief: brief, prompt: prompt)
    }
}
