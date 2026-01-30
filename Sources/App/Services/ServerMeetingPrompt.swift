import Foundation

/// Server-side meeting prompt template (ported from client)
struct ServerMeetingPrompt {
    static let template = """
    You are an executive assistant helping the user prepare for a meeting.

    **Meeting Context**:
    - Name: {{MEETING_TITLE}}
    - Description: {{MEETING_DESCRIPTION}}
    - Time: {{MEETING_TIME}}
    - Time: {{MEETING_TIME}}
    - Participants:
    {{PARTICIPANT_LIST}}

    **User Context**:
    {{USER_CONTEXT}}

    **Participants**:
    {{PARTICIPANTS_DATA}}

    **Instructions**:
    Construct a pre-meeting brief to help the user prepare for the meeting

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
    
    static func construct(
        meeting: GoogleCalendarEvent,
        participants: [(name: String, email: String, company: String?, linkedin: String?)],
        userEmail: String,
        userName: String,
        userTitle: String?,
        userCompany: String?,
        userBio: String?
    ) -> String {
        var prompt = template
        
        // Replace meeting details
        prompt = prompt.replacingOccurrences(of: "{{MEETING_TITLE}}", with: meeting.summary ?? "Unknown Meeting")
        prompt = prompt.replacingOccurrences(of: "{{MEETING_DESCRIPTION}}", with: meeting.description ?? "No description")
        prompt = prompt.replacingOccurrences(of: "{{MEETING_TIME}}", with: meeting.start?.dateTime ?? "Unknown time")
        
        // Build User Context
        var userContext = ""
        // Use user supplied logic
        if !userName.isEmpty || userTitle != nil || userCompany != nil {
             userContext += "Name: \(userName.isEmpty ? "Unknown" : userName)\n"
             userContext += "Email: \(userEmail)\n"
             if let t = userTitle, !t.isEmpty { userContext += "Title: \(t)\n" }
             if let c = userCompany, !c.isEmpty { userContext += "Company: \(c)\n" }
             
             if let s = userBio, !s.isEmpty {
                 userContext += "\nPREPARER BACKGROUND RESEARCH:\n\(s)"
             }
        } else {
            userContext = "User details: \(userEmail) (Not fully verified)"
        }
        
        prompt = prompt.replacingOccurrences(of: "{{USER_CONTEXT}}", with: userContext)
        
        // Build participant list
        let participantNames = participants.map { $0.name }.joined(separator: ", ")
        prompt = prompt.replacingOccurrences(of: "{{PARTICIPANT_LIST}}", with: participantNames)
        
        // Build detailed participant data
        var participantsData = ""
        for p in participants {
            participantsData += "- **\(p.name)** (\(p.email))\n"
            if let company = p.company, company != "Unknown" {
                participantsData += "  Company: \(company)\n"
            }
            if let linkedin = p.linkedin {
                participantsData += "  LinkedIn: \(linkedin)\n"
            }
            participantsData += "\n"
        }
        prompt = prompt.replacingOccurrences(of: "{{PARTICIPANTS_DATA}}", with: participantsData)
        
        return prompt
    }
}
