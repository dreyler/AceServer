import Vapor
import Foundation

struct PersistenceService {
    static let shared = PersistenceService()
    
    private let workDir = FileManager.default.currentDirectoryPath
    
    // File Names
    private let usersFile = "ace_users.json"
    private let peopleFile = "ace_people.json"
    private let featuresFile = "ace_features.json"
    
    private let queue = DispatchQueue(label: "com.ace.persistence", attributes: .concurrent)
    
    // MARK: - Save Methods
    
    func saveUsers(_ users: [String: UserSessionManager.UserContext]) {
        queue.async(flags: .barrier) {
            self.saveHelper(data: users, filename: self.usersFile)
        }
    }
    
    func savePeople(_ people: [Person]) {
        // Person is Codable
        queue.async(flags: .barrier) {
            self.saveHelper(data: people, filename: self.peopleFile)
        }
    }
    
    func saveFeatureRequest(_ feature: String, from userId: String) {
        queue.async(flags: .barrier) {
            // Load existing, append, save
            var current = self.loadHelper(filename: self.featuresFile, type: [FeatureRequestEntry].self) ?? []
            current.append(FeatureRequestEntry(userId: userId, request: feature, date: Date()))
            self.saveHelper(data: current, filename: self.featuresFile)
        }
    }
    
    // MARK: - Load Methods
    
    func loadUsers() -> [String: UserSessionManager.UserContext]? {
        return queue.sync {
            return self.loadHelper(filename: self.usersFile, type: [String: UserSessionManager.UserContext].self)
        }
    }
    
    func loadPeople() -> [Person]? {
         return queue.sync {
            return self.loadHelper(filename: self.peopleFile, type: [Person].self)
        }
    }
    
    // MARK: - Helpers
    
    private func saveHelper<T: Encodable>(data: T, filename: String) {
        let url = URL(fileURLWithPath: workDir).appendingPathComponent(filename)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: url)
            // print("💾 Saved \(filename)")
        } catch {
            print("❌ Failed to save \(filename): \(error)")
        }
    }
    
    private func loadHelper<T: Decodable>(filename: String, type: T.Type) -> T? {
        let url = URL(fileURLWithPath: workDir).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            print("❌ Failed to load \(filename): \(error)")
            return nil
        }
    }
}

// Helper Structs
struct FeatureRequestEntry: Codable {
    let userId: String
    let request: String
    let date: Date
}
