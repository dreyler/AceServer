import Vapor

/// Manages active user sessions (in-memory).
/// In a real production app, this would be a Database.
class UserSessionManager {
    static let shared = UserSessionManager()
    
    // User Context Storage
    public struct UserContext {
        let title: String?
        let company: String?
        let bio: String?
        let localTime: String? // Last known local time format/zone string (or just passed on register)
    }
    
    // Key: UserID, Value: UserContext
    private var userContexts: [String: UserContext] = [:]
    
    private var activeSessions: [String: String] = [:]
    private var refreshTokens: [String: String] = [:] // NEW: Store Refresh Tokens
    private var usersRoutines: [String: [Routine]] = [:]
    private var userDeviceTokens: [String: String] = [:]
    
    private let queue = DispatchQueue(label: "com.ace.sessionManager", attributes: .concurrent)
    
    func register(userId: String, token: String, refreshToken: String?, routines: [Routine], deviceToken: String?, context: UserContext? = nil) {
        queue.async(flags: .barrier) {
            self.activeSessions[userId] = token
            if let rToken = refreshToken {
                self.refreshTokens[userId] = rToken
            }
            self.usersRoutines[userId] = routines
            if let dt = deviceToken {
                self.userDeviceTokens[userId] = dt
            }
            if let ctx = context {
                self.userContexts[userId] = ctx
            }
            print("✅ User Registered: \(userId) (DeviceToken: \(deviceToken != nil ? "Yes" : "No"), RefreshToken: \(refreshToken != nil ? "Yes" : "No"))")
        }
    }
    
    func updateAccessToken(userId: String, token: String) {
        queue.async(flags: .barrier) {
            self.activeSessions[userId] = token
            print("🔄 Updated Access Token for \(userId)")
        }
    }
    
    func getRefreshToken(for userId: String) -> String? {
        queue.sync { refreshTokens[userId] }
    }
    
    func getAllSessions() -> [(userId: String, token: String, routines: [Routine], deviceToken: String?, context: UserContext?)] {
        return queue.sync {
            activeSessions.map { (inputs) in
                let (userId, token) = inputs
                let routines = usersRoutines[userId] ?? []
                let deviceToken = userDeviceTokens[userId]
                let context = userContexts[userId]
                return (userId, token, routines, deviceToken, context)
            }
        }
    }
}
