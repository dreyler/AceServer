import Vapor
import Foundation

public class ServerGooglePeopleService {
    public static let shared = ServerGooglePeopleService()
    
    private init() {}
    
    public struct PersonInfo {
        public let name: String
        public let company: String?
        
        public init(name: String, company: String?) {
            self.name = name
            self.company = company
        }
    }
    
    // Resolve "Unknown" email to Name/Company using Google Contacts (Connections & Other)
    public func resolve(email: String, accessToken: String) async -> PersonInfo? {
        // 1. Search 'people:searchContacts' (best source)
        // Note: Requires "contacts.readonly" scope which we have.
        
        guard let url = URL(string: "https://people.googleapis.com/v1/people:searchContacts?query=\(email)&readMask=names,emailAddresses,organizations&pageSize=1") else { return nil }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("⚠️ People API Error: \(String(data: data, encoding: .utf8) ?? "?")")
                return nil
            }
            
            // Parse
            let result = try JSONDecoder().decode(SearchResponse.self, from: data)
            
            if let person = result.results?.first?.person {
                let name = person.names?.first?.displayName ?? email
                let company = person.organizations?.first?.name
                return PersonInfo(name: name, company: company)
            }
            
        } catch {
            print("⚠️ People API Exception: \(error)")
        }
        
        return nil
    }
    
    // Models
    struct SearchResponse: Codable {
        let results: [SearchResult]?
    }
    struct SearchResult: Codable {
        let person: PersonResource
    }
    struct PersonResource: Codable {
        let names: [Name]?
        let organizations: [Org]?
    }
    struct Name: Codable {
        let displayName: String?
    }
    struct Org: Codable {
        let name: String?
    }
}
