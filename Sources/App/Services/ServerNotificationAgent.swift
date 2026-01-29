import Vapor

class ServerNotificationAgent {
    static let shared = ServerNotificationAgent()
    
    // In-memory state
    private var currentLockScreenItemID: UUID?
    
    func process(meetings: [Meeting], routines: [Routine], app: Application) async {
        let now = Date()
        
        // 1. Candidate Generation
        var candidates: [Candidate] = []
        app.logger.info("🕵️ Evaluating \(meetings.count) meetings against \(routines.count) routines...")
        
        for meeting in meetings {
            for routine in routines where routine.isEnabled {
                if let candidate = evaluate(routine: routine, meeting: meeting, now: now) {
                    app.logger.info("   -> Candidate Found: \(candidate.title) (Type: \(candidate.type))")
                    candidates.append(candidate)
                }
            }
        }
        
        app.logger.info("✅ Total Candidates: \(candidates.count)")
        
        // 2. Selection
        candidates.sort { c1, c2 in
            if c1.type == .active && c2.type != .active { return true }
            if c1.type != .active && c2.type == .active { return false }
            return c1.meeting.startTime < c2.meeting.startTime
        }
        
        let winner = candidates.first
        
        // 3. Execution (Server Logic)
        if let winner = winner {
            // Log skipped
            for candidate in candidates where candidate.meeting.id != winner.meeting.id {
                 app.logger.info("Skipped candidate: \(candidate.title)")
            }
            
            if winner.meeting.id != currentLockScreenItemID {
                app.logger.info("💡 Setting Lock Screen to: \(winner.title)")
                
                // MOCKED PUSH
                sendSilentClearPush(app: app)
                sendVisiblePush(title: winner.title, body: winner.body, app: app)
                
                currentLockScreenItemID = winner.meeting.id
            }
        } else {
            if currentLockScreenItemID != nil {
                app.logger.info("🗑 Clearing Lock Screen")
                
                // MOCKED PUSH
                sendSilentClearPush(app: app)
                
                currentLockScreenItemID = nil
            }
        }
    }
    
    // --- Mock Push Helpers ---
    
    private func sendSilentClearPush(app: Application) {
        app.logger.notice("🔔 [PUSH] [SILENT CLEAR] Sending request to clear lock screen...")
    }
    
    private func sendVisiblePush(title: String, body: String, app: Application) {
        app.logger.notice("🔔 [PUSH] [VISIBLE] Title: '\(title)' Body: '\(body)'")
    }
    
    private func evaluate(routine: Routine, meeting: Meeting, now: Date) -> Candidate? {
        let calendar = Calendar.current
        
        if routine.type == .beforeMeeting {
            // User requested 0-12 hours lookahead
            let minutesUntilStart = calendar.dateComponents([.minute], from: now, to: meeting.startTime).minute ?? 0
            if minutesUntilStart >= 0 && minutesUntilStart <= 720 {
                return Candidate(
                    meeting: meeting,
                    routine: routine,
                    title: "Prep: \(meeting.title)",
                    body: "Starts in \(minutesUntilStart) min. Review materials.",
                    type: .passive
                )
            }
        }
        
        if routine.type == .dontBeLate {
             let minutesUntilStart = calendar.dateComponents([.minute], from: now, to: meeting.startTime).minute ?? 0
            if minutesUntilStart > 0 && minutesUntilStart <= 2 {
                 return Candidate(
                    meeting: meeting,
                    routine: routine,
                    title: "Hurry! \(meeting.title)",
                    body: "Starts in \(minutesUntilStart) min.",
                    type: .active
                )
            }
        }
        
        return nil
    }
    
    struct Candidate {
        let meeting: Meeting
        let routine: Routine
        let title: String
        let body: String
        let type: AceNotification.NotificationType
    }
}
