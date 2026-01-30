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
            userBio: briefRequest.userBio
        )
        
        return BriefResponse(brief: brief, prompt: prompt)
    }
    
    // Enrich Person on Demand
    // Enrich Person on Demand
    app.post("enrich-person") { req async throws -> EnrichResponse in
        let enrichRequest = try req.content.decode(EnrichRequest.self)
        let requestID = UUID().uuidString
        req.logger.info("[\(requestID)] Received enrich request for: \(enrichRequest.email)")
        
        let result = await ServerResearchService.shared.processEnrichment(
            name: enrichRequest.name, 
            email: enrichRequest.email
        )
        
        if let co = result.companyName {
             req.logger.info("[\(requestID)]    -> Company: \(co)")
        }
        
        return EnrichResponse(
            companyName: result.companyName,
            researchSummary: result.researchSummary,
            requestID: requestID,
            linkedInTitle: result.linkedInTitle,
            linkedInUrl: result.linkedInUrl
        )
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

struct EnrichResponse: Content {
    let companyName: String?
    let researchSummary: String?
    let requestID: String
    let linkedInTitle: String?
    let linkedInUrl: String?
}
