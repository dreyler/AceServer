import Foundation

/// Actor-based cache for participant enrichment data
/// Key: Email address
public actor ParticipantCache {
    
    public struct CachedParticipant {
        // Google People API data (source of truth for invalidation)
        public let googlePeopleName: String?
        public let googlePeopleCompany: String?
        
        // Enrichment data
        public let companyName: String?
        public let companyDetails: String?
        public let linkedInUrl: String?
        public let linkedInTitle: String?
        public let linkedInDetails: String?
        
        public let timestamp: Date
    }
    
    public struct CachedCompany {
        public let domain: String
        public let companyName: String
        public let companyDetails: String?
        public let timestamp: Date
    }
    
    private var cache: [String: CachedParticipant] = [:]
    private var companyCache: [String: CachedCompany] = [:]
    
    public init() {}
    
    /// Get cached participant data
    public func get(_ email: String) -> CachedParticipant? {
        return cache[email.lowercased()]
    }
    
    /// Store participant data
    public func set(_ email: String, participant: CachedParticipant) {
        cache[email.lowercased()] = participant
    }
    
    /// Invalidate cache for a participant
    public func invalidate(_ email: String) {
        cache.removeValue(forKey: email.lowercased())
    }
    
    /// Get cached company data by domain
    public func getCompany(_ domain: String) -> CachedCompany? {
        return companyCache[domain.lowercased()]
    }
    
    /// Store company data by domain
    public func setCompany(_ domain: String, company: CachedCompany) {
        companyCache[domain.lowercased()] = company
    }
    
    /// Clear entire cache
    public func clearAll() {
        cache.removeAll()
        companyCache.removeAll()
    }
}
