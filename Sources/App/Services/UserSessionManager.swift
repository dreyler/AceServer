import Vapor

/// Manages active user sessions (in-memory).
/// In a real production app, this would be a Database.
class UserSessionManager {
    static let shared = UserSessionManager()
    
    // Key: UserID (Email or Unique ID), Value: Google Access Token
    private var activeSessions: [String: String] = [:]
    private var usersRoutines: [String: [Routine]] = [:]
    
    // Key: UserID (Email or Unique ID), Value: deviceToken (Optional)
    private var userDeviceTokens: [String: String] = [:]
    
    // Thread safety
    private let queue = DispatchQueue(label: "com.ace.sessionManager", attributes: .concurrent)
    
    func register(userId: String, token: String, routines: [Routine], deviceToken: String?) {
        queue.async(flags: .barrier) {
            self.activeSessions[userId] = token
            self.usersRoutines[userId] = routines
            if let dt = deviceToken {
                self.userDeviceTokens[userId] = dt
            }
            print("✅ User Registered: \(userId) (DeviceToken: \(deviceToken != nil ? "Yes" : "No"))")
        }
    }
    
    func getAllSessions() -> [(userId: String, token: String, routines: [Routine], deviceToken: String?)] {
        return queue.sync {
            activeSessions.map { (inputs) in
                let (userId, token) = inputs
                // Default routines if missing (shouldn't happen with correct flow)
                let routines = usersRoutines[userId] ?? []
                let deviceToken = userDeviceTokens[userId]
                return (userId, token, routines, deviceToken)
            }
        }
    }
}
