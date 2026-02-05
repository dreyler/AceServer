import Vapor
import VaporAPNS
import APNS

class MeetingBriefControllerAgent {
    static let shared = MeetingBriefControllerAgent()
    
    func processLoop(app: Application) {
        // Run every 60 seconds
        app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(60)) { task in
            Task {
                app.logger.info("⏰ [Controller] Tick - Checking Users...")
                
                let sessions = UserSessionManager.shared.getAllSessions()
                
                if sessions.isEmpty { return }
                
                for (userId, token, routines, deviceToken, context) in sessions {
                    await self.processUser(
                        userId: userId,
                        token: token,
                        routines: routines,
                        deviceToken: deviceToken,
                        context: context,
                        app: app
                    )
                }
            }
        }
    }
    
    private func processUser(userId: String, token: String, routines: [Routine], deviceToken: String?, context: UserSessionManager.UserContext?, app: Application) async {
        
        // 1. Sync Calendar
        let currentSyncToken = MeetingStore.shared.getSyncToken(for: userId)
        app.logger.info("   [Sync State] User: \(userId) | Token: \(currentSyncToken?.prefix(10) ?? "NIL")")
        let syncResult = await ServerCalendarService.shared.syncEvents(accessToken: token, syncToken: currentSyncToken, userId: userId, app: app)
        
        // 2. Update Store
        if !syncResult.meetings.isEmpty {
            app.logger.info("   Inbox: \(syncResult.meetings.count) changed events for \(userId).")
            MeetingStore.shared.handleSyncedMeetings(userId: userId, meetings: syncResult.meetings)
        }
        
        if let nextToken = syncResult.nextSyncToken {
            app.logger.info("   🔖 New Sync Token: \(nextToken.prefix(10))...")
            MeetingStore.shared.setSyncToken(nextToken, for: userId)
        } else {
            app.logger.warning("   ⚠️ No Next Sync Token returned from Google!")
        }
        
        // 3. Check for Changes to Review
        let changedMeetings = MeetingStore.shared.getChangedMeetings(userId: userId)
        
        if !changedMeetings.isEmpty {
            app.logger.info("   🤖 Invoking Gemini for \(changedMeetings.count) meetings...")
            
            let prepRoutine = routines.first(where: { $0.type == .beforeMeeting })
            let userPrompt = prepRoutine?.customPrompt ?? "Send me a meeting brief as a silent push notification that will appear on my lock screen but not buzz my phone 10 minutes before each meeting in which there are participants other than only me."
            
            // FILTER: Only ask Agent about FUTURE meetings (ignore history backfill)
            let now = Date()
            let futureMeetings = changedMeetings.filter { $0.startTime > now }
            
            if !futureMeetings.isEmpty {
                app.logger.info("   🤖 Invoking Gemini for \(futureMeetings.count) future meetings (ignored \(changedMeetings.count - futureMeetings.count) past)...")
                await invokeAgent(userId: userId, meetings: futureMeetings, userPrompt: userPrompt, app: app)
            } else {
                app.logger.info("   d Skipping Gemini: No future meetings in changed set.")
            }
            
            // Mark reviewed
            let ids = changedMeetings.compactMap { $0.googleEvent.id ?? $0.id.uuidString }
            MeetingStore.shared.markReviewed(userId: userId, meetingIds: ids)
        }
        
        // 4. Dispatch Scheduled Notifications
        let pending = MeetingStore.shared.getPendingNotifications(userId: userId)
        if !pending.isEmpty {
            app.logger.info("   🚀 Dispatching \(pending.count) notifications...")
            for (meetingId, state) in pending {
                await dispatchNotification(userId: userId, meeting: state.meeting, type: state.notificationType ?? "active", token: token, deviceToken: deviceToken, context: context, app: app)
                MeetingStore.shared.markNotificationSent(userId: userId, meetingId: meetingId)
            }
        }
    }
    
    // MARK: - AI Agent Logic
    
    struct AgentResponse: Codable {
        struct Decision: Codable {
            let meetingId: String
            let shouldNotify: Bool
            let notificationTime: String? // ISO8601
            let notificationType: String?
        }
        let decisions: [Decision]
    }
    
    private func invokeAgent(userId: String, meetings: [Meeting], userPrompt: String, app: Application) async {
        // Prepare context
        // Simplified meeting list for token efficiency
        let condensedMeetings = meetings.map { m -> [String: Any] in
            return [
                "id": m.googleEvent.id ?? m.id.uuidString,
                "title": m.title,
                "description": m.meetingDescription ?? m.googleEvent.description ?? "",
                "start": m.startTime.ISO8601Format(),
                "organizer": m.organizer ?? "Unknown",
                "participants": (m.googleEvent.attendees ?? []).map { attendee in
                    return [
                        "email": attendee.email,
                        "name": attendee.displayName ?? "",
                        "status": attendee.responseStatus ?? "unknown"
                    ]
                }
            ]
        }
        
        guard let meetingsJsonData = try? JSONSerialization.data(withJSONObject: condensedMeetings),
              let meetingsJson = String(data: meetingsJsonData, encoding: .utf8) else { return }
        
        let systemPrompt = """
        You are an intelligent agent that decides when to trigger meeting briefs for users.
        Users have provided the context below on which meetings they want to be notified about.
        
        USER PROMPT:
        "\(userPrompt)"
        
        Here is the list of meetings that you might want to notify the user about.
        Each meeting includes title, description, and detailed participant list (email, status).
        Use the participant email domains to determine if they are internal (e.g. same company) or external.
        
        MEETINGS:
        \(meetingsJson)
        
        You need to respond with which meetings should be sent to the MeetingBriefAgent to generate the brief, as well as what time the notification should be sent and what type of notification to send.
        
        Respond ONLY with a JSON object following this schema:
        {
          "decisions": [
            {
              "meetingId": "ID from list",
              "shouldNotify": true/false,
              "notificationTime": "ISO8601 Date String (e.g. 2024-02-03T10:00:00Z)",
              "notificationType": "silent" or "active"
            }
          ]
        }
        If a notification should be deleted or not sent, set shouldNotify to false.
        For notificationTime, calculate the absolute time based on the user prompt (e.g. "10 mins before").
        """
        
        do {
            app.logger.info("🛑 [DEBUG] Gemini Prompt:\n\(systemPrompt)")
            let response = try await GeminiService.shared.generateJSON(prompt: systemPrompt, responseType: AgentResponse.self)
            
            app.logger.info("   🤖 Agent Decisions: \(response.decisions.count)")
            
            let isoFormatter = ISO8601DateFormatter()
            
            for decision in response.decisions {
                if decision.shouldNotify {
                    var date: Date? = nil
                    if let timeStr = decision.notificationTime {
                        date = isoFormatter.date(from: timeStr)
                    }
                    
                    if let validDate = date {
                         app.logger.info("      Scheduling '\(decision.meetingId)' for \(validDate)")
                         MeetingStore.shared.scheduleNotification(userId: userId, meetingId: decision.meetingId, time: validDate, type: decision.notificationType)
                    } else {
                         app.logger.warning("      Invalid Date format for '\(decision.meetingId)': \(decision.notificationTime ?? "nil")")
                    }
                } else {
                     app.logger.info("      Clearing notification for '\(decision.meetingId)'")
                     MeetingStore.shared.clearNotification(userId: userId, meetingId: decision.meetingId)
                }
            }
            
        } catch {
            app.logger.error("   ❌ Agent Decision Error: \(error)")
        }
    }
    
    // MARK: - Dispatcher
    private func dispatchNotification(userId: String, meeting: Meeting, type: String, token: String, deviceToken: String?, context: UserSessionManager.UserContext?, app: Application) async {
        app.logger.info("   🔔 Generating Brief for '\(meeting.title)'...")
        
        // Format Time
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
            userName: "User",
            userTitle: context?.title,
            userCompany: context?.company,
            userBio: context?.bio,
            userLocalTime: formattedTime,
            app: app
        )
        
        let title = "Prep: \(meeting.title)"
        let body = result.brief
        
        guard let dToken = deviceToken else {
             app.logger.warning("   🔕 No Device Token")
             return
        }
        
        _ = dToken
        
        // MOCK DISPATCH (Build Fix)
        app.logger.warning("   ⚠️ APNS Dispatch Mocked: \(title) - \(body)")
        app.logger.info("   ✅ Push Dispatched (Mock)")
    }
}
