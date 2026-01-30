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
        
        let brief = await MeetingBriefAgent.generateBrief(
            meeting: briefRequest.meeting,
            accessToken: briefRequest.accessToken
        )
        
        return BriefResponse(brief: brief)
    }
    
    // Enrich Person on Demand
    // Enrich Person on Demand
    app.post("enrich-person") { req async throws -> EnrichResponse in
        let enrichRequest = try req.content.decode(EnrichRequest.self)
        let requestID = UUID().uuidString
        req.logger.info("[\(requestID)] Received enrich request for: \(enrichRequest.email)")
        
        // 1. Resolve via Server Logic
        let research = await ServerResearchService.shared.enrich(
            name: enrichRequest.name,
            emailContext: enrichRequest.email
        )
        
        // 2. Extract domain for helper
        var domain = ""
        if enrichRequest.email.contains("@") {
            domain = enrichRequest.email.split(separator: "@").last.map(String.init) ?? ""
        }
        
        var companyName: String? = nil
        
        // 3. Attempt to extract Company Name from results
        if let companyHit = research.first(where: { $0.source == "Company" }) {
            companyName = extractCompanyName(title: companyHit.title, domain: domain)
        } else if !domain.isEmpty {
            // Fallback to domain ONLY if not personal
            let personal = ["gmail.com", "yahoo.com", "hotmail.com", "icloud.com", "outlook.com", "aol.com"]
            if !personal.contains(domain.lowercased()) {
                companyName = domain
            }
        }
        
        // Build summary with both Company and LinkedIn results (like client does)
        var summaryBuilder = ""
        
        if let companyHit = research.first(where: { $0.source == "Company" }) {
            summaryBuilder += "**Company Info**\n"
            summaryBuilder += "\(companyHit.title)\n\(companyHit.snippet)\n[Source](\(companyHit.link))\n\n"
            print("[\(requestID)]    -> Found Company: \(companyHit.title)")
        }
        
        var linkedInTitle: String?
        var linkedInUrl: String?
        
        if let linkedInHit = research.first(where: { $0.source == "LinkedIn" }) {
            summaryBuilder += "**LinkedIn Profile**\n"
            summaryBuilder += "\(linkedInHit.title)\n\(linkedInHit.snippet)\n[Source](\(linkedInHit.link))"
            print("[\(requestID)]    -> Found LinkedIn: \(linkedInHit.title)")
            
            linkedInTitle = linkedInHit.title
            linkedInUrl = linkedInHit.link
            
            // Attempt to extract Company from LinkedIn Title if currently nil
            if companyName == nil {
                companyName = extractCompanyFromLinkedIn(title: linkedInHit.title, personName: enrichRequest.name)
            }
        }
        
        var researchSummary: String?
        if !summaryBuilder.isEmpty {
            researchSummary = summaryBuilder
        }
        
        return EnrichResponse(
            companyName: companyName,
            researchSummary: researchSummary,
            requestID: requestID,
            linkedInTitle: linkedInTitle,
            linkedInUrl: linkedInUrl
        )
    }
}

// Helper: Extract company name from search result title
// Ported from client ResearchService.extractCompanyName()
func extractCompanyName(title: String, domain: String) -> String {
    // Includes standard hyphen (-), pipe (|), colon (:), bullet (•), middle dot (·), en dash (–), em dash (—)
    let separators = CharacterSet(charactersIn: "-|:•·–—")
    let segments = title.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    
    // Rule 4: " with " (Single Segment)
    if segments.count == 1 {
        if let range = title.range(of: " with ", options: .caseInsensitive) {
            return String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    
    // Clean the domain base: "allegrocredit.com" -> "allegrocredit"
    var domainBase = domain.components(separatedBy: ".").first?.lowercased() ?? domain.lowercased()
    
    let parts = domain.components(separatedBy: ".")
    if parts.count >= 3 {
        if parts.last == "edu" || parts.last == "gov" {
            if parts.count >= 3 {
                domainBase = parts[parts.count - 2].lowercased() // "columbia"
            }
        } else {
            if let first = parts.first, first.count <= 3, parts.count > 2 {
                domainBase = parts[1].lowercased()
            }
        }
    }
    
    // Rule 2: Full Domain Prefix on First Segment
    if let first = segments.first, first.lowercased().hasPrefix(domain.lowercased()) {
        return domain
    }
    
    // Rule 1: Segment Inspection (Domain Base Match)
    for segment in segments {
        let cleanSegment = segment.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
        
        // Fuzzy Logic: 5 chars or full domainBase length if shorter
        let checkLength = min(5, domainBase.count)
        let prefix = String(domainBase.prefix(checkLength))
        
        if cleanSegment.hasPrefix(prefix) {
            return segment
        }
    }
    
    // Default Fallback: First Segment (with "Common Word" Exception)
    if let first = segments.first {
        let commonWords = ["welcome", "login", "home", "signin", "sign in", "portal", "dashboard"]
        let isCommon = commonWords.contains { first.lowercased().hasPrefix($0) }
        
        if isCommon && segments.count > 1 {
            return segments[1]
        }
    }
    
    return segments.first ?? title
}

// Helper: Extract company from LinkedIn title (Heuristic)
func extractCompanyFromLinkedIn(title: String, personName: String) -> String? {
    let separators = CharacterSet(charactersIn: "-|:•·–—")
    var segments = title.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    
    // Remove "LinkedIn"
    segments.removeAll { $0.lowercased().contains("linkedin") }
    
    // Remove Person Name (fuzzy match)
    let lowerName = personName.lowercased()
    segments.removeAll { segment in
        let s = segment.lowercased()
        return s.contains(lowerName) || lowerName.contains(s)
    }
    
    // Filter empty
    segments = segments.filter { !$0.isEmpty }
    
    // Return last segment (Company is usually last: "Name - Title - Company")
    return segments.last
}

// Request/Response Models
struct BriefRequest: Codable {
    let meeting: GoogleCalendarEvent
    let accessToken: String
}

struct BriefResponse: Content {
    let brief: String
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
