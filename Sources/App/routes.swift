import Vapor

func routes(_ app: Application) throws {
    app.get { req async in
        "AceServer is running!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }
    
    // Register User & Token
    app.post("register") { req async throws -> HTTPStatus in
        let registerData = try req.content.decode(RegisterRequest.self)
        
        // Extract context
        let context = UserSessionManager.UserContext(
            title: registerData.userTitle,
            company: registerData.userCompany,
            bio: registerData.userBio,
            localTime: registerData.userLocalTime
        )
        
        UserSessionManager.shared.register(
            userId: registerData.userId,
            token: registerData.accessToken,
            routines: registerData.routines,
            deviceToken: registerData.deviceToken,
            context: context
        )
        
        return .ok
    }
    
    // Generate Brief on Demand
    app.post("generate-brief") { req async throws -> BriefResponse in
        let briefRequest = try req.content.decode(BriefRequest.self)
        
        app.logger.info("📲 On-Demand Brief Request for: \(briefRequest.meeting.summary ?? "Unknown")")
        
        let (brief, prompt) = await MeetingBriefAgent.generateBrief(
            meeting: briefRequest.meeting,
            accessToken: briefRequest.accessToken,
            userEmail: briefRequest.userEmail ?? "",
            userName: briefRequest.userName ?? "",
            userTitle: briefRequest.userTitle,
            userCompany: briefRequest.userCompany,
            userBio: briefRequest.userBio,
            userLocalTime: briefRequest.userLocalTime,
            app: app
        )
        
        return BriefResponse(brief: brief, prompt: prompt)
    }
    
    // Enrich Person V2 - Centralized enrichment with caching
    app.post("enrich-person-v2") { req async throws -> ParticipantEnrichmentService.EnrichmentOutput in
        let enrichRequest = try req.content.decode(EnrichRequestV2.self)
        
        let input = ParticipantEnrichmentService.EnrichmentInput(
            email: enrichRequest.email,
            displayName: enrichRequest.displayName,
            accessToken: enrichRequest.accessToken
        )
        
        return await ParticipantEnrichmentService.shared.enrichParticipant(input: input, app: app)
    }
    
    // Enrich Person on Demand (OLD - deprecated)
    // Enrich Person on Demand
    // Clear Cache
    app.post("cache", "clear") { req async throws -> HTTPStatus in
        app.logger.info("🗑️ Clearing caches requested by client")
        await ParticipantEnrichmentService.shared.clearCache()
        return .ok
    }
}
// Helpers removed (now in Service)



// Request/Response Models
struct BriefRequest: Codable {
    let meeting: GoogleCalendarEvent
    let accessToken: String
    let userEmail: String?
    let userName: String?
    let userTitle: String?
    let userCompany: String?
    let userBio: String?
    let userLocalTime: String? // Formatted meeting time in user's timezone
}

struct BriefResponse: Content {
    let brief: String
    let prompt: String
}

// V2 Enrich Request
struct EnrichRequestV2: Codable {
    let email: String
    let displayName: String?
    let accessToken: String
}
