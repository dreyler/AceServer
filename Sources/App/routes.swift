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
        
        UserSessionManager.shared.register(
            userId: registerData.userId,
            token: registerData.accessToken,
            routines: registerData.routines,
            deviceToken: registerData.deviceToken
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
    app.post("enrich-person") { req async throws -> EnrichResponse in
        let enrichRequest = try req.content.decode(EnrichRequest.self)
        let requestID = UUID().uuidString
        req.logger.info("[\(requestID)] Received enrich request for: \(enrichRequest.email)")
        
        let enriched = await ServerResearchService.shared.processEnrichment(
            name: enrichRequest.name, 
            email: enrichRequest.email
        )
        
        // Build summary from separated fields
        var summaryBuilder = ""
        if let companyInfo = enriched.companyInfo {
            summaryBuilder += "**Company Info**\n\(companyInfo)\n\n"
        }
        if let linkedInInfo = enriched.linkedInInfo {
            summaryBuilder += "**LinkedIn Profile**\n\(linkedInInfo)"
        }
        
        let researchSummary = summaryBuilder.isEmpty ? nil : summaryBuilder
        
        return EnrichResponse(
            companyName: enriched.companyName,
            researchSummary: researchSummary,
            requestID: requestID,
            linkedInTitle: enriched.linkedInTitle,
            linkedInUrl: enriched.linkedInUrl
        )
    }
    
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
}

struct BriefResponse: Content {
    let brief: String
    let prompt: String
}

// Enrich Person DTOs
struct EnrichRequest: Codable {
    let name: String
    let email: String
    let accessToken: String
}

// V2 Enrich Request
struct EnrichRequestV2: Codable {
    let email: String
    let displayName: String?
    let accessToken: String
}

struct EnrichResponse: Content {
    let companyName: String?
    let researchSummary: String?
    let requestID: String
    let linkedInTitle: String?
    let linkedInUrl: String?
}
