import Vapor
import Foundation

struct GoogleSearchConfig {
    static let apiKey = "REDACTED_SEARCH_KEY"
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
        
        // Basic Length Check
        guard resultParts.count >= 2 else {
             // Allow single name match if search matches exact
             if searchParts.count == 1 && cleanedTitle.lowercased().contains(cleanSearch.lowercased()) {
                 return (true, "Match (Single Name Exact)")
             }
             return (false, "Result too short")
        }
        
        // Name Match Logic (Permissive)
        let sFirst = searchParts.first?.lowercased() ?? ""
        let sLast = searchParts.last?.lowercased() ?? ""
        let resultStr = cleanedTitle.lowercased()
        
        // 1. Check if full search name is contained in result
        if resultStr.contains(sFirst) && resultStr.contains(sLast) {
             // Additional check: If domain context exists, use it. If not (personal email), trust the name match.
             // Additional check: If domain context exists, use it.
             // REVERTED: This check is too strict. Google search usually ranks correctly for corporate domains.
             // If we search "ted madrona.com" and get "Ted Kummert", we should accept it even if snippet doesn't say Madrona.
             // Additional check: If domain context exists, use it.
             if !domain.isEmpty {
                 let domainPrefix = String(domain.prefix(6)).lowercased()
                 let combinedText = (item.title + " " + item.snippet).lowercased().replacingOccurrences(of: " ", with: "")
                 
                 // 1. Strict Prefix Check (e.g. "madrona.com" matches "madrona")
                 if combinedText.contains(domainPrefix) {
                     // Pass
                 } 
                 // 2. Domain Base Check (Legacy Fallback: "sky.uk" -> "sky" matches "Sky")
                 else {
                     let domainBase = domain.components(separatedBy: ".").first?.lowercased() ?? ""
                     if !domainBase.isEmpty, combinedText.contains(domainBase) {
                        // Pass
                     } else {
                        return (false, "Name match but Domain fail")
                     }
                 }
             }
             return (true, "Match (Permissive Containment)")
        }
        
        return (false, "Name mismatch")
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
