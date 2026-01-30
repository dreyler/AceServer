import Vapor
import Foundation

struct GoogleSearchConfig {
    static let apiKey = Environment.get("GOOGLE_SEARCH_API_KEY") ?? ""
    static let searchEngineId = "82d10108f578a48ea" 
}

public class ServerResearchService {
    public static let shared = ServerResearchService()
    
    private init() {}
    
    public struct ResearchResult: Codable {
        let title: String
        let snippet: String
        let link: String
        let source: String // "Company" or "LinkedIn"
    }
    
    public struct EnrichmentResult {
        public let companyName: String?
        public let researchSummary: String?
        public let linkedInTitle: String?
        public let linkedInUrl: String?
    }
    
    // Unified logic used by both API and Agent
    public func processEnrichment(name: String, email: String) async -> EnrichmentResult {
        // 1. Resolve via Server Logic
        let research = await self.enrich(name: name, emailContext: email)
        
        // 2. Extract domain
        var domain = ""
        if email.contains("@") {
            domain = email.split(separator: "@").last.map(String.init) ?? ""
        }
        
        var companyName: String? = nil
        
        // 3. Attempt to extract Company Name from results
        if let companyHit = research.first(where: { $0.source == "Company" }) {
            companyName = _extractCompanyName(title: companyHit.title, domain: domain)
        } else if !domain.isEmpty {
            // Fallback to domain ONLY if not personal
            let personal = ["gmail.com", "yahoo.com", "hotmail.com", "icloud.com", "outlook.com", "aol.com"]
            if !personal.contains(domain.lowercased()) {
                companyName = domain
            }
        }
        
        // Build summary
        var summaryBuilder = ""
        
        if let companyHit = research.first(where: { $0.source == "Company" }) {
            summaryBuilder += "**Company Info**\n"
            summaryBuilder += "\(companyHit.title)\n\(companyHit.snippet)\n[Source](\(companyHit.link))\n\n"
        }
        
        var linkedInTitle: String?
        var linkedInUrl: String?
        
        if let linkedInHit = research.first(where: { $0.source == "LinkedIn" }) {
            summaryBuilder += "**LinkedIn Profile**\n"
            summaryBuilder += "\(linkedInHit.title)\n\(linkedInHit.snippet)\n[Source](\(linkedInHit.link))"
            
            linkedInTitle = linkedInHit.title
            linkedInUrl = linkedInHit.link
            
            // Attempt to extract Company from LinkedIn Title if currently nil
            if companyName == nil {
                companyName = _extractCompanyFromLinkedIn(title: linkedInHit.title, personName: name)
            }
        }
        
        var researchSummary: String?
        if !summaryBuilder.isEmpty {
            researchSummary = summaryBuilder
        }
        
        return EnrichmentResult(
            companyName: companyName,
            researchSummary: researchSummary,
            linkedInTitle: linkedInTitle,
            linkedInUrl: linkedInUrl
        )
    }

    // Finds LinkedIn profile and Company Info
    public func enrich(name: String, companyContext: String? = nil, emailContext: String? = nil) async -> [ResearchResult] {
        var results: [ResearchResult] = []
        
        // 1. Construct Queries
        var queryName = name
        // Heuristic: If name is email, extract username
        if queryName.contains("@") {
            queryName = queryName.split(separator: "@").first.map(String.init) ?? queryName
        }
        
        // Domain Context
        var domain = ""
        if let email = emailContext, email.contains("@") {
             domain = email.split(separator: "@").last.map(String.init) ?? ""
             // Exclude personal domains (simple check)
             let personal = ["gmail.com", "yahoo.com", "hotmail.com", "icloud.com"]
             if personal.contains(domain.lowercased()) { domain = "" }
        }
        
        var context = companyContext ?? domain
        
        // PRE-SEARCH (Legacy): If context is empty, extract company from domain first.
        if companyContext == nil && !domain.isEmpty {
             print("   First: Searching for company using domain '\(domain)'")
             if let coData = await performSearch(query: domain) {
                 if let first = coData.items.first {
                     let extractedName = _extractCompanyName(title: first.title, domain: domain)
                     print("   🧠 Extracted Company Name: '\(extractedName)'")
                     if !extractedName.isEmpty {
                         context = extractedName
                     }
                 }
             }
             
             }


        
        // FALLBACK (Global): If context is still domain (e.g. "madrona.com"),
        // convert domain to Name (e.g. "Madrona") for better LinkedIn Search results.
        if context == domain {
            let base = domain.components(separatedBy: ".").first?.capitalized ?? domain
            if base.count >= 3 {
                print("   ⚠️ Context is raw domain. Converting to Base: '\(base)'")
                context = base
            }
        }
        
        // Query 1: LinkedIn with validation + Fallback Retry
        // "First Last Company linkedin" (Handle empty context)
        let liQuery = context.isEmpty ? "\(queryName) linkedin" : "\(queryName) \(context) linkedin"
        print("🔍 LinkedIn Search: '\(liQuery)'")
        
        var bestProfile: GoogleSearchResponse.Item? = nil
        
        if let liData = await performSearch(query: liQuery) {
            // Filter for /in/
            let profiles = liData.items.filter { $0.link.contains("linkedin.com/in/") }
            
            // NEW: Validate each profile against search name
            for profile in profiles {
                let (isValid, reason) = validateProfileMatch(
                    searchName: queryName,
                    domain: context,
                    item: profile
                )
                
                if isValid {
                    print("   ✅ Matched: \(profile.title)")
                    bestProfile = profile
                    break // Take first valid match
                } else {
                    print("   ❌ Rejected: \(profile.title.prefix(40))... - \(reason)")
                }
            }
        }
        
        // FALLBACK: If initial search failed and context != domain, retry with domain
        // This handles cases where company name extraction was wrong (e.g. "Airship" instead of "Apptimize")
        if bestProfile == nil && !domain.isEmpty {
            let contextWasNotDomain = !context.lowercased().contains(domain.lowercased())
            
            if contextWasNotDomain {
                print("   ⚠️ Initial search failed. Retrying with domain: '\(domain)'")
                
                let fallbackQuery = "\(queryName) \(domain) linkedin"
                
                if let fbData = await performSearch(query: fallbackQuery) {
                    let fbProfiles = fbData.items.filter { $0.link.contains("linkedin.com/in/") }
                    
                    for profile in fbProfiles {
                        let (isValid, reason) = validateProfileMatch(
                            searchName: queryName,
                            domain: domain,
                            item: profile
                        )
                        
                        if isValid {
                            print("   ✅ Found via domain fallback: \(profile.title)")
                            bestProfile = profile
                            break
                        } else {
                            print("   ❌ Fallback rejected: \(profile.title.prefix(30))... - \(reason)")
                        }
                    }
                }
            }
        }
        
        // Add profile if found
        if let profile = bestProfile {
            results.append(ResearchResult(
                title: profile.title, 
                snippet: profile.snippet, 
                link: profile.link, 
                source: "LinkedIn"
            ))
        } else {
            print("   ❌ No valid profile found")
        }
        
        // Query 2: Company Info
        var companySearchQuery = context
        
        // If context was empty (e.g. personal email), try to extract company from found LinkedIn profile
        if companySearchQuery.isEmpty, let profile = bestProfile {
             if let extracted = _extractCompanyFromLinkedIn(title: profile.title, personName: queryName) {
                 companySearchQuery = extracted
                 print("   🧠 Discovered Company from LinkedIn: \(extracted)")
             }
        }
        
        if !companySearchQuery.isEmpty, let coData = await performSearch(query: companySearchQuery) {
             if let first = coData.items.first {
                 results.append(ResearchResult(
                    title: first.title, 
                    snippet: first.snippet, 
                    link: first.link, 
                    source: "Company"
                ))
             }
        }
        
        return results
    }
    
    // PORTED from client ResearchService.validateProfileMatch()
    // REVISED: Relaxed logic to match legacy behavior more closely
    private func validateProfileMatch(searchName: String, domain: String, item: GoogleSearchResponse.Item) -> (Bool, String) {
        let cleanSearch = cleanNameForValidation(searchName)
        let searchParts = cleanSearch.split(separator: " ")
        
        let separators = CharacterSet(charactersIn: "-|")
        guard let titleName = item.title.components(separatedBy: separators).first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return (false, "Could not parse title name")
        }
        
        let cleanedTitle = cleanLinkedInName(titleName)
        let resultParts = cleanedTitle.split(separator: " ")
        
        // Case A: Single Name Search (e.g. "Brittany")
        if searchParts.count == 1 {
            let searchNameStr = searchParts.first?.lowercased() ?? ""
            let resultNameStr = resultParts.first?.lowercased() ?? ""
            
            // 1. Name Check: Exact or Prefix Match
            if !resultNameStr.hasPrefix(searchNameStr) {
                // Email username heuristic (e.g. "ablue" matches "Allen Blue")
                var isEmailMatch = false
                if searchNameStr.count > 3 && resultParts.count >= 2 {
                    let rFirstInitial = resultParts.first?.prefix(1).lowercased() ?? ""
                    let rLastName = resultParts.last?.lowercased() ?? ""
                    
                    if searchNameStr.hasPrefix(rFirstInitial) && searchNameStr.contains(rLastName) {
                        isEmailMatch = true
                    }
                }
                
                if !isEmailMatch {
                    return (false, "Name mismatch: Expected start with '\(searchNameStr)', got '\(resultNameStr)'")
                }
            }
            
            // 2. Domain Check (ONLY for single-name searches, per legacy behavior)
            let domainPrefix = String(domain.prefix(6)).lowercased()
            let combinedText = (item.title + " " + item.snippet).lowercased().replacingOccurrences(of: " ", with: "")
            
            if !combinedText.contains(domainPrefix) {
                return (false, "Domain context fail: '\(domainPrefix)' not found")
            }
            
            return (true, "Match (Single Name + Context)")
        }
        
        // Case B: Full Name Search (e.g. "Ted Kummert")
        guard resultParts.count >= 2 else {
            return (false, "Result name has too few parts")
        }
        
        let sFirstStr = searchParts.first?.lowercased() ?? ""
        let rFirstStr = resultParts.first?.lowercased() ?? ""
        let sLastStr = searchParts.last?.lowercased() ?? ""
        let rLastStr = resultParts.last?.lowercased() ?? ""
        
        // 1. First Name Check (2-char prefix)
        if sFirstStr.count >= 2 && rFirstStr.count >= 2 {
            let sPrefix = sFirstStr.prefix(2)
            let rPrefix = rFirstStr.prefix(2)
            if sPrefix != rPrefix {
                return (false, "First name mismatch (strict 2-char): Expected '\(sPrefix)', got '\(rPrefix)'")
            }
        } else {
            // Fallback to 1 char
            if sFirstStr.prefix(1) != rFirstStr.prefix(1) {
                return (false, "First initial mismatch")
            }
        }
        
        // 2. Last Name Check (2-char prefix)
        if sLastStr.count >= 2 && rLastStr.count >= 2 {
            let sPrefix = sLastStr.prefix(2)
            let rPrefix = rLastStr.prefix(2)
            
            if sPrefix != rPrefix {
                // Check for containment (hyphenated names)
                if rLastStr.contains(sLastStr) {
                    // Allowed
                } else if item.title.localizedCaseInsensitiveContains(sLastStr) {
                    // Maiden/Alt name found in raw title
                    return (true, "Match (Maiden/Alt Name Found in Title)")
                } else {
                    return (false, "Last name mismatch (strict 2-char): Expected '\(sPrefix)', got '\(rPrefix)'")
                }
            }
        } else {
            // Fallback to 1 char
            if sLastStr.prefix(1) != rLastStr.prefix(1) {
                return (false, "Last initial mismatch")
            }
        }
        
        // NO domain check for full names (legacy behavior)
        return (true, "Match (Initials Verified)")
    }
    
    // PORTED: cleanLinkedInName
    private func cleanLinkedInName(_ rawName: String) -> String {
        var cleaned = rawName
        
        // Strip common titles/suffixes
        let titlesToStrip = ["PHD", "MD", "MBA", "ESQ", "JR", "SR", "II", "III", "IV"]
        
        // Remove trailing numeric sequences
        if let range = cleaned.range(of: "\\s+\\d{3,}$", options: .regularExpression) {
            cleaned.removeSubrange(range)
        }
        
        var words = cleaned.components(separatedBy: " ")
        
        words = words.filter { word in
            let w = word.trimmingCharacters(in: .punctuationCharacters)
            if titlesToStrip.contains(w.uppercased()) { return false }
            
            // Filter junk codes
            let letters = w.filter { $0.isLetter }
            let numbers = w.filter { $0.isNumber }
            if !letters.isEmpty && !numbers.isEmpty && w.count > 5 {
                return false
            }
            
            return true
        }
        
        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // PORTED: cleanNameForValidation
    private func cleanNameForValidation(_ rawName: String) -> String {
        var name = rawName
        
        // Remove parentheses content
        if let range = name.range(of: "\\(.*?\\)", options: .regularExpression) {
             name.removeSubrange(range)
        }
        
        // Remove brackets content
        if let range = name.range(of: "\\[.*?\\]", options: .regularExpression) {
             name.removeSubrange(range)
        }
        
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle "Last, First" format
        if name.contains(",") {
            let parts = name.split(separator: ",")
            if parts.count == 2 {
                let last = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let first = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(first) \(last)"
            }
        }
        
        return name
    }
    
    // Helper: Extract company from LinkedIn title (Heuristic)
    private func _extractCompanyFromLinkedIn(title: String, personName: String) -> String? {
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
        
        // Return last segment
        return segments.last
    }

    public func performSearch(query: String) async -> GoogleSearchResponse? {
        guard var components = URLComponents(string: "https://www.googleapis.com/customsearch/v1") else { return nil }
        
        components.queryItems = [
            URLQueryItem(name: "key", value: GoogleSearchConfig.apiKey),
            URLQueryItem(name: "cx", value: GoogleSearchConfig.searchEngineId),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: "5") // Get more results for validation
        ]
        
        guard let url = components.url else { return nil }
        
        // Simple retry logic
        for _ in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("⚠️ CSE Error: \(String(data: data, encoding: .utf8) ?? "?")")
                    continue 
                }
                
                let result = try JSONDecoder().decode(GoogleSearchResponse.self, from: data)
                return result
                
            } catch {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        
        return nil
    }
    
    // Minimal Models for CSE
    public struct GoogleSearchResponse: Codable {
        public let items: [Item]
        
        public struct Item: Codable {
            public let title: String
            public let snippet: String
            public let link: String
        }
    }

    // Helper: Extract company name from Title using Domain as verification
    private func _extractCompanyName(title: String, domain: String) -> String {
        let separators = CharacterSet(charactersIn: "-|:•·–—")
        let segments = title.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        if segments.count == 1 {
            if let range = title.range(of: " with ", options: .caseInsensitive) {
                return String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        
        var domainBase = domain.components(separatedBy: ".").first?.lowercased() ?? domain.lowercased()
        let parts = domain.components(separatedBy: ".")
        if parts.count >= 3 {
            if parts.last == "edu" || parts.last == "gov" {
                if parts.count >= 3 { domainBase = parts[parts.count - 2].lowercased() }
            } else {
                if let first = parts.first, first.count <= 3, parts.count > 2 { domainBase = parts[1].lowercased() }
            }
        }
        
        if let first = segments.first, first.lowercased().hasPrefix(domain.lowercased()) { return domain }
        
        for segment in segments {
            let cleanSegment = segment.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
            let checkLength = min(5, domainBase.count)
            let prefix = String(domainBase.prefix(checkLength))
            if cleanSegment.hasPrefix(prefix) { return segment }
        }
        
        if let first = segments.first {
            let commonWords = ["welcome", "login", "home", "signin", "sign in", "portal", "dashboard"]
            let isCommon = commonWords.contains { first.lowercased().hasPrefix($0) }
            if isCommon && segments.count > 1 { return segments[1] }
        }
        
        return segments.first ?? title
    }
}
