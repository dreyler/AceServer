import Vapor

class MeetingStore {
    static let shared = MeetingStore()
    
    struct MeetingState {
        var meeting: Meeting
        var changedSinceLastReview: Bool
        // We will store the Agent's decision here later (e.g. notificationTime)
        var scheduledNotificationTime: Date?
        var notificationType: String? // "silent", "alert", etc.
        var isNotificationSent: Bool = false
    }
    
    // Key: UserID
    // Value: [MeetingID : MeetingState]
    private var store: [String: [String: MeetingState]] = [:]
    
    // Key: UserID, Value: Google Sync Token
    private var syncTokens: [String: String] = [:]
    
    private let queue = DispatchQueue(label: "com.ace.meetingStore", attributes: .concurrent)
    
    // MARK: - Sync Token
    func getSyncToken(for userId: String) -> String? {
        queue.sync { syncTokens[userId] }
    }
    
    func setSyncToken(_ token: String?, for userId: String) {
        queue.async(flags: .barrier) {
            self.syncTokens[userId] = token
        }
    }
    
    // MARK: - Meetings
    func handleSyncedMeetings(userId: String, meetings: [Meeting]) {
        queue.async(flags: .barrier) {
            if self.store[userId] == nil { self.store[userId] = [:] }
            
            for meeting in meetings {
                // Use Google ID if available, else UUID
                let key = meeting.googleEvent.id ?? meeting.id.uuidString
                
                var state = self.store[userId]?[key] ?? MeetingState(meeting: meeting, changedSinceLastReview: true)
                state.meeting = meeting
                state.changedSinceLastReview = true // Mark as changed!
                
                self.store[userId]?[key] = state
            }
        }
    }
    
    func getChangedMeetings(userId: String) -> [Meeting] {
        queue.sync {
            guard let userStore = store[userId] else { return [] }
            return userStore.values
                .filter { $0.changedSinceLastReview }
                .map { $0.meeting }
        }
    }
    
    func markReviewed(userId: String, meetingIds: [String]) {
        queue.async(flags: .barrier) {
            guard var userStore = self.store[userId] else { return }
            
            for id in meetingIds {
                if var state = userStore[id] {
                    state.changedSinceLastReview = false
                    userStore[id] = state
                }
            }
            self.store[userId] = userStore
        }
    }
    
    // MARK: - Notification Scheduling
    func scheduleNotification(userId: String, meetingId: String, time: Date?, type: String?) {
        queue.async(flags: .barrier) {
            guard var userStore = self.store[userId], var state = userStore[meetingId] else { return }
            
            // Only update if changes (Optional optimization)
            state.scheduledNotificationTime = time
            state.notificationType = type
            state.isNotificationSent = false // Reset sent status on update/schedule
            
            userStore[meetingId] = state
            self.store[userId] = userStore
        }
    }
    
    // Returns tuples of (MeetingID, State) for notifications that are due
    func getPendingNotifications(userId: String) -> [(String, MeetingState)] {
        queue.sync {
            guard let userStore = store[userId] else { return [] }
            let now = Date()
            return userStore.filter { (id, state) in
                guard let time = state.scheduledNotificationTime else { return false }
                // Ready if time <= now AND Not yet sent
                return time <= now && !state.isNotificationSent
            }.map { ($0.key, $0.value) }
        }
    }
    
    func markNotificationSent(userId: String, meetingId: String) {
        queue.async(flags: .barrier) {
            guard var userStore = self.store[userId], var state = userStore[meetingId] else { return }
            state.isNotificationSent = true
            state.scheduledNotificationTime = nil // Allow cleanup? Or keep record? 
            // Specs says "no meeting can ever have more than 1 notification set"
            // If we keep it, it's fine.
            userStore[meetingId] = state
            self.store[userId] = userStore
        }
    }
    
    func clearNotification(userId: String, meetingId: String) {
        queue.async(flags: .barrier) {
            guard var userStore = self.store[userId], var state = userStore[meetingId] else { return }
            state.scheduledNotificationTime = nil
            state.notificationType = nil
            state.isNotificationSent = false
            userStore[meetingId] = state
            self.store[userId] = userStore
        }
    }
    
    // MARK: - Participant History
    
    struct ParticipantHistory {
        let meetingCount: Int
        let lastMeetings: [Meeting] // Last 3 sorted desc
    }
    
    func getParticipantHistory(
        userId: String, 
        participantEmail: String, 
        excludingMeetingId: String? = nil
    ) -> ParticipantHistory {
        return queue.sync {
             print("   🔍 getParticipantHistory called for \(participantEmail). ExcludeID: \(excludingMeetingId ?? "nil")") 
            guard let userStore = store[userId] else { return ParticipantHistory(meetingCount: 0, lastMeetings: []) }
            
            let now = Date()
            let emailLower = participantEmail.lowercased()
            
            let history = userStore.values
                .map { $0.meeting }
                .filter { meeting in
                    // 1. Exclude by ID
                    if let excludeId = excludingMeetingId {
                        let currentId = meeting.googleEvent.id ?? "nil" // Use Google ID if available
                         // print("   🔍 Comparing Exclude: '\(excludeId)' vs Candidate: '\(currentId)'") // Debug Only
                        if currentId == excludeId {
                             // print("   🚫 Filtering out current meeting from history: \(currentId)")
                             return false
                        }
                    }
                    
                    // Must be in the past
                    guard meeting.startTime < now else { return false }
                    
                    // Check participants (case insensitive check)
                    let pMatches = meeting.participants.contains { p in
                        // Use relationshipContext (email) for matching
                        (p.relationshipContext ?? "").lowercased() == emailLower
                    }
                    
                    // Also check organizer
                    let orgLower = (meeting.organizer ?? "").lowercased()
                    let oMatches = orgLower == emailLower || orgLower.contains(emailLower)
                    
                    return pMatches || oMatches
                }
                .sorted { $0.startTime > $1.startTime }
            
            // LOGGING
            if !history.isEmpty {
                print("   🔎 [History] Found \(history.count) past meetings for '\(participantEmail)'")
            } else {
                 // print("   🔎 [History] No past meetings for '\(participantEmail)' (Store size: \(userStore.count))")
            }
                
            return ParticipantHistory(
                meetingCount: history.count,
                lastMeetings: Array(history.prefix(3))
            )
        }
    }

    // Cleanup / Debug
    func clear(userId: String) {
        queue.async(flags: .barrier) {
            self.store[userId] = nil
            self.syncTokens[userId] = nil
        }
    }
}
