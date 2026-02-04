import Vapor
import VaporAPNS
import APNS

class ServerNotificationAgent {
    static let shared = ServerNotificationAgent()
    
    // In-memory state
    private var currentLockScreenItemID: UUID?
    
    func process(meetings: [Meeting], routines: [Routine], userId: String, token: String, deviceToken: String?, context: UserSessionManager.UserContext?, app: Application) async {
        let now = Date()
        
        // 1. Candidate Generation
        var candidates: [Candidate] = []
        app.logger.info("🕵️ Evaluating \(meetings.count) meetings against \(routines.count) routines...")
        
        for meeting in meetings {
            for routine in routines where routine.isEnabled {
                // Await the async evaluation (now includes AI generation)
                if let candidate = await evaluate(routine: routine, meeting: meeting, userId: userId, token: token, context: context, now: now, app: app) {
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
                sendVisiblePush(title: winner.title, body: winner.body, token: deviceToken, app: app)
                
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
        // TODO: Implement silent push to clear notifications if needed
    }
    
    private func sendVisiblePush(title: String, body: String, token: String?, app: Application) {
        guard let deviceToken = token else {
            app.logger.warning("🔕 Cannot send push: No device token.")
            return
        }
        
        _ = deviceToken
        
        app.logger.notice("🔔 [PUSH] [VISIBLE] Sending to APNs: Title='\(title)'")
        
            // MOCK DISPATCH (Build Fix)
            // try await app.apns.client.send(...)
             app.logger.warning("   ⚠️ APNS Dispatch Mocked: \(title) - \(body)")
             app.logger.info("   ✅ Push sent successfully (Mock).")
    }
    
    private func evaluate(routine: Routine, meeting: Meeting, userId: String, token: String, context: UserSessionManager.UserContext?, now: Date, app: Application) async -> Candidate? {
        let calendar = Calendar.current
        
        if routine.type == .beforeMeeting {
            // User requested 0-12 hours lookahead
            let minutesUntilStart = calendar.dateComponents([.minute], from: now, to: meeting.startTime).minute ?? 0
            if minutesUntilStart >= 0 && minutesUntilStart <= 720 {
                
                // TRIGGER AI GENERATION (Only if close enough)
                app.logger.info("🤖 Generating Brief for '\(meeting.title)'...")
                
                // Format Time using User's TimeZone Identifier (if provided)
                var formattedTime: String? = nil
                if let tzID = context?.localTime, let tz = TimeZone(identifier: tzID) {
                     let formatter = DateFormatter()
                     formatter.dateStyle = .medium
                     formatter.timeStyle = .short
                     formatter.timeZone = tz
                     formattedTime = formatter.string(from: meeting.startTime)
                }
                
                let result = await MeetingBriefAgent.generateBrief(
                    meeting: meeting.googleEvent,
                    accessToken: token,
                    userEmail: userId, 
                    userName: "User", // Defaults to generic if not captured
                    userTitle: context?.title,
                    userCompany: context?.company,
                    userBio: context?.bio,
                    userLocalTime: formattedTime,
                    app: app
                )
                
                let brief = result.brief
                
                return Candidate(
                    meeting: meeting,
                    routine: routine,
                    title: "Prep: \(meeting.title)",
                    body: brief, // Use AI Brief
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
