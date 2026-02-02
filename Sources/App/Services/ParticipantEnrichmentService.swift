import Vapor

/// Participant Enrichment Service - V2
/// Centralized enrichment logic with caching and smart invalidation
public class ParticipantEnrichmentService {
    
    public static let shared = ParticipantEnrichmentService()
    private let cache = ParticipantCache()
    
    private init() {}
    
    public struct EnrichmentInput {
        public let email: String
        public let displayName: String?
        public let accessToken: String
        
        public init(email: String, displayName: String?, accessToken: String) {
            self.email = email
            self.displayName = displayName
            self.accessToken = accessToken
        }
    }
    
    public struct EnrichmentOutput: Content {
        public let email: String
        public let name: String
        public let company: String
        public let companyDetails: String?
        public let linkedInDetails: String?
        public let linkedInTitle: String?
        public let linkedInUrl: String?
        
        // Debug info
        public let cacheHit: Bool
        public let wasInvalidated: Bool
        public let invalidationReason: String?
    }
    
    /// Main enrichment function - used by both /generate-brief and /enrich-person-v2
    public func enrichParticipant(
        input: EnrichmentInput,
        app: Application
    ) async -> EnrichmentOutput {
        
        let email = input.email.lowercased()
        app.logger.info("🔍 Enriching: \(email)")
        
        // Extract domain
        guard email.contains("@") else {
            app.logger.info("   ❌ Invalid email format")
            return EnrichmentOutput(
                email: email,
                name: input.displayName ?? "Unknown",
                company: "Unknown",
                companyDetails: nil,
                linkedInDetails: nil,
                linkedInTitle: nil,
                linkedInUrl: nil,
                cacheHit: false,
                wasInvalidated: false,
                invalidationReason: nil
            )
        }
        
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        
        // Step 1: Call Google People API first (to get potential company info even for gmail)
        app.logger.info("   📞 Calling Google People API...")
        let googlePeopleData = await ServerGooglePeopleService.shared.resolve(
            email: email,
            accessToken: input.accessToken
        )
        
        let currentName = googlePeopleData?.name ?? input.displayName ?? "Unknown"
        let currentCompany = googlePeopleData?.company
        
        app.logger.info("   👤 Google People: name='\(currentName)' company='\(currentCompany ?? "nil")'")

        // Step 2: Check if personal email - skip ONLY if we didn't find a company in Google People
        if ServerResearchService.personalDomains.contains(domain.lowercased()) {
             if currentCompany == nil {
                app.logger.info("   ⏭️  Skipping personal email (no company in contacts): \(email)")
                return EnrichmentOutput(
                    email: email,
                    name: currentName,
                    company: "Unknown",
                    companyDetails: nil,
                    linkedInDetails: nil,
                    linkedInTitle: nil,
                    linkedInUrl: nil,
                    cacheHit: false,
                    wasInvalidated: false,
                    invalidationReason: "Personal email domain"
                )
             } else {
                 app.logger.info("   ⚠️  Personal email '\(email)' has company in contacts: '\(currentCompany!)'. Continuing enrichment.")
             }
        }
        
        // Step 3: Check cache and invalidate if Google People data changed
        var wasInvalidated = false
        var invalidationReason: String? = nil
        
        if let cached = await cache.get(email) {
            app.logger.info("   💾 Found cached data for: \(email)")
            
            // Compare Google People data
            if cached.googlePeopleName != currentName {
                invalidationReason = "Name changed: '\(cached.googlePeopleName ?? "nil")' → '\(currentName)'"
                wasInvalidated = true
            } else if cached.googlePeopleCompany != currentCompany {
                invalidationReason = "Company changed: '\(cached.googlePeopleCompany ?? "nil")' → '\(currentCompany ?? "nil")'"
                wasInvalidated = true
            }
            
            if wasInvalidated {
                app.logger.warning("   ❌ Cache invalidated for: \(email) - \(invalidationReason!)")
                await cache.invalidate(email)
            } else {
                // Cache hit - return cached data
                app.logger.info("   ✅ Cache hit for: \(email)")
                return EnrichmentOutput(
                    email: email,
                    name: currentName,
                    company: cached.companyName ?? "Unknown",
                    companyDetails: cached.companyDetails,
                    linkedInDetails: cached.linkedInDetails,
                    linkedInTitle: cached.linkedInTitle,
                    linkedInUrl: cached.linkedInUrl,
                    cacheHit: true,
                    wasInvalidated: false,
                    invalidationReason: nil
                )
            }
        } else {
            app.logger.info("   ❌ No cache entry for: \(email)")
        }
        
        // Step 4: Determine company (from Google People or domain search)
        var companyName = currentCompany
        var companyDetails: String? = nil
        
        if companyName == nil || companyName == "Unknown" {
            // Check company cache first
            if let cachedCompany = await cache.getCompany(domain) {
                app.logger.info("   💾 Company cache hit for domain: \(domain)")
                companyName = cachedCompany.companyName
                companyDetails = cachedCompany.companyDetails
            } else {
                app.logger.info("   🔍 No company from Google People, searching domain: \(domain)")
                
                // Search for company using domain DIRECTLY (not extracted name)
                let companyQuery = domain
                app.logger.trace("   🔍 Company search: '\(companyQuery)'")
                let searchCache = ServerResearchService.ResearchCache()
                if let searchResults = await ServerResearchService.shared.performSearch(query: companyQuery, cache: searchCache) {
                    // Prioritize exact domain match
                    let exactMatch = searchResults.items.first { $0.link.contains(domain) }
                    let selectedResult = exactMatch ?? searchResults.items.first
                    
                    if let result = selectedResult {
                        let extracted = ServerResearchService.shared._extractCompanyName(title: result.title, domain: domain)
                        if !extracted.isEmpty {
                            companyName = extracted
                            app.logger.info("   ✅ Found company: '\(extracted)' from \(result.link)")
                            
                            // Use Title + Snippet + Link for maximum context
                            companyDetails = """
                            **\(result.title)**
                            \(result.snippet)
                            [Source](\(result.link))
                            """
                            
                            // Cache the company by domain
                            if let name = companyName {
                                let cachedCompany = ParticipantCache.CachedCompany(
                                    domain: domain,
                                    companyName: name,
                                    companyDetails: companyDetails,
                                    timestamp: Date()
                                )
                                await cache.setCompany(domain, company: cachedCompany)
                                app.logger.info("   💾 Cached company for domain: \(domain)")
                            }
                        }
                    }
                }
            }
                
            if companyName == nil {
                app.logger.warning("   ⚠️  No company found for domain: \(domain)")
                // Return early - can't enrich LinkedIn without company
                return EnrichmentOutput(
                    email: email,
                    name: currentName,
                    company: "No company found",
                    companyDetails: nil,
                    linkedInDetails: nil,
                    linkedInTitle: nil,
                    linkedInUrl: nil,
                    cacheHit: false,
                    wasInvalidated: wasInvalidated,
                    invalidationReason: invalidationReason
                )
            }
        } else {
            app.logger.info("   ✅ Using company from Google People: '\(companyName!)'")
            
            // Fix: Even if we have the name, we need the DETAILS (snippet/link)
            // We can't rely on the email domain (since it might be gmail), so we search by Company Name
            let companyQuery = companyName!
            app.logger.trace("   🔍 Enriching company details for: '\(companyQuery)'")
            let searchCache = ServerResearchService.ResearchCache()
            
            // Quick search to get details
            if let searchResults = await ServerResearchService.shared.performSearch(query: companyQuery, cache: searchCache),
               let result = searchResults.items.first {
                   
                companyDetails = """
                **\(result.title)**
                \(result.snippet)
                [Source](\(result.link))
                """
                app.logger.info("   📝 Found details for \(companyName!)")
            }
        }
        
        // Step 5: Search for LinkedIn profile (only if we have a valid name and company)
        var linkedInUrl: String? = nil
        var linkedInTitle: String? = nil
        var linkedInDetails: String? = nil
        
        if currentName != "Unknown" && !currentName.contains("@") {
            app.logger.info("   🔍 Searching LinkedIn for: '\(currentName)' at '\(companyName!)'")
            
            let linkedInQuery = "\(currentName) \(companyName!) linkedin"
            let searchCache = ServerResearchService.ResearchCache()
            if let linkedInResults = await ServerResearchService.shared.performSearch(query: linkedInQuery, cache: searchCache) {
                // Simple matching: look for LinkedIn URL
                for item in linkedInResults.items {
                    if item.link.contains("linkedin.com/in/") {
                        linkedInUrl = item.link
                        linkedInTitle = item.title
                        linkedInDetails = "**\(item.title)**\n\(item.snippet)"
                        app.logger.info("   ✅ Found LinkedIn: \(item.link)")
                        break
                    }
                }
                
                if linkedInUrl == nil {
                    app.logger.warning("   ⚠️  No LinkedIn profile found")
                }
            }
        }
        
        // Step 6: Cache the result
        let cachedParticipant = ParticipantCache.CachedParticipant(
            googlePeopleName: currentName,
            googlePeopleCompany: currentCompany,
            companyName: companyName,
            companyDetails: companyDetails,
            linkedInUrl: linkedInUrl,
            linkedInTitle: linkedInTitle,
            linkedInDetails: linkedInDetails,
            timestamp: Date()
        )
        
        await cache.set(email, participant: cachedParticipant)
        app.logger.info("   💾 Cached enrichment for: \(email)")
        
        return EnrichmentOutput(
            email: email,
            name: currentName,
            company: companyName ?? "Unknown",
            companyDetails: companyDetails,
            linkedInDetails: linkedInDetails,
            linkedInTitle: linkedInTitle,
            linkedInUrl: linkedInUrl,
            cacheHit: false,
            wasInvalidated: wasInvalidated,
            invalidationReason: invalidationReason
        )
    }
    
    // Expose cache clearing
    public func clearCache() async {
        app.logger.warning("🗑️ Clearing enrichment cache")
        await cache.clearAll()
    }
}
