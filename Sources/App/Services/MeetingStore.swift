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
    
    // Cleanup / Debug
    func clear(userId: String) {
        queue.async(flags: .barrier) {
            self.store[userId] = nil
            self.syncTokens[userId] = nil
        }
    }
}
