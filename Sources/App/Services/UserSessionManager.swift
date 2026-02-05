import Vapor

/// Manages active user sessions (in-memory).
/// In a real production app, this would be a Database.
class UserSessionManager {
    static let shared = UserSessionManager()
    
    // User Context Storage
    public struct UserContext: Codable {
        let title: String?
        let company: String?
        let bio: String?
        let localTime: String?
        
        // NEW: Persisted Preferences for Agents
        var briefPreferences: [String]? // e.g. "Include LinkedIn profiles"
        var notificationPreferences: [String]? // e.g. "Buzz me for Jim Smith"
        
        // NEW: Persisted Tokens for Server Restart Auto-Resume
        var accessToken: String?
        var refreshToken: String?
    }
    
    // Key: UserID, Value: UserContext
    private var userContexts: [String: UserContext] = [:]
    
    private var activeSessions: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]
    private var usersRoutines: [String: [Routine]] = [:]
    private var userDeviceTokens: [String: String] = [:]
    
    private let queue = DispatchQueue(label: "com.ace.sessionManager", attributes: .concurrent)
    
    private init() {
        // Load from Disk on Startup
        if let loaded = PersistenceService.shared.loadUsers() {
            self.userContexts = loaded
            
            // Hydrate Active Sessions from Disk
            for (userId, ctx) in loaded {
                if let token = ctx.accessToken {
                    self.activeSessions[userId] = token
                    print("   🔄 Restored Session for \(userId)")
                }
                if let rToken = ctx.refreshToken {
                    self.refreshTokens[userId] = rToken
                }
            }
            
            print("💾 Loaded \(loaded.count) User Contexts from Disk")
        }
    }
    
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
            
            // Merge Context: If exists on disk, keep preferences, update bio/title if provided
            if var existing = self.userContexts[userId] {
                // Keep existing prefs/tokens, override with new
                existing = UserContext(
                    title: context?.title ?? existing.title,
                    company: context?.company ?? existing.company,
                    bio: context?.bio ?? existing.bio,
                    localTime: context?.localTime ?? existing.localTime,
                    briefPreferences: existing.briefPreferences,
                    notificationPreferences: existing.notificationPreferences,
                    accessToken: token, // Persist new token
                    refreshToken: refreshToken ?? existing.refreshToken
                )
                self.userContexts[userId] = existing
                self.saveToDisk()
            } else {
                // Create new
                var newCtx = context ?? UserContext(title: nil, company: nil, bio: nil, localTime: nil, briefPreferences: nil, notificationPreferences: nil, accessToken: nil, refreshToken: nil)
                newCtx.accessToken = token
                newCtx.refreshToken = refreshToken
                self.userContexts[userId] = newCtx
                self.saveToDisk()
            }
            
            print("✅ User Registered: \(userId)")
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
    
    func updateUserPreferences(userId: String, briefPrefs: [String]? = nil, notifPrefs: [String]? = nil) {
        queue.async(flags: .barrier) {
            if var ctx = self.userContexts[userId] {
                if let b = briefPrefs { ctx.briefPreferences = b }
                if let n = notifPrefs { ctx.notificationPreferences = n }
                self.userContexts[userId] = ctx
                self.saveToDisk()
                print("💾 Saved Preferences for \(userId)")
            } else {
                // Create minimal context if missing
                let newCtx = UserContext(title: nil, company: nil, bio: nil, localTime: nil, briefPreferences: briefPrefs, notificationPreferences: notifPrefs)
                self.userContexts[userId] = newCtx
                self.saveToDisk()
            }
        }
    }
    
    func getUserContext(userId: String) -> UserContext? {
        queue.sync { userContexts[userId] }
    }
    
    private func saveToDisk() {
        // Must be called inside barrier
        let snapshot = self.userContexts
        PersistenceService.shared.saveUsers(snapshot)
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
