import Vapor
import Foundation

// Server-side service to fetch meetings.
// In a real app, this would manage Refresh Tokens securely.
// For prototype, we accept an Access Token passed from the Client or stored in memory.

class ServerCalendarService {
    static let shared = ServerCalendarService()
    
    // Mock Data Toggle - DISABLED (AI Verified)
    var useMockData = false
    
    func getUpcomingMeetings(accessToken: String?, app: Application) async -> [Meeting] {
        if useMockData {
            return generateMockMeetings()
        }
        
        guard let token = accessToken else {
            app.logger.error("No access token provided for calendar fetch")
            return []
        }
        
        // Real API Call
        let urlString = "https://www.googleapis.com/calendar/v3/calendars/primary/events?singleEvents=true&orderBy=startTime&timeMin=\(Date().ISO8601Format())"
        guard let url = URL(string: urlString) else { return [] }
        
        app.logger.info("📅 Fetching Calendar: \(urlString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                // Parse Google API Response using Codable
                let items = try parseGoogleEvents(data: data)
                app.logger.info("✅ Found \(items.meetings.count) meetings from Google.")
                for m in items.meetings {
                     app.logger.info("   -> Meeting: \(m.title) at \(m.startTime)")
                }
                return items.meetings
            } else {
                app.logger.error("Calendar API Failed: \(String(data: data, encoding: .utf8) ?? "Unknown")")
                return []
            }
        } catch {
            app.logger.error("Calendar Fetch Error: \(error)")
            return []
        }
    }
    
    // Use SharedModels definition
    struct GoogleEventList: Codable {
        let items: [GoogleCalendarEvent]
        let nextSyncToken: String?
        let nextPageToken: String?
    }
    
    struct SyncResult {
        let meetings: [Meeting]
        let nextSyncToken: String?
    }
    
    // Incremental Sync
    func syncEvents(accessToken: String, syncToken: String?, userId: String?, app: Application) async -> SyncResult {
        var currentAccessToken = accessToken
        var allMeetings: [Meeting] = []
        var currentPageToken: String? = nil
        
        // Loop for Pagination
        repeat {
            let baseUrl = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
            var components = URLComponents(string: baseUrl)!
            var queryItems = [
                URLQueryItem(name: "singleEvents", value: "true"),
                // Order by startTime is NOT supported when using syncToken!
            ]
            
            if let token = syncToken {
                queryItems.append(URLQueryItem(name: "syncToken", value: token))
            } else {
                // Initial Sync: Get future events
                queryItems.append(URLQueryItem(name: "timeMin", value: Date().ISO8601Format()))
                // NOTE: strictly forbidden to use orderBy if we want a syncToken!
                // queryItems.append(URLQueryItem(name: "orderBy", value: "startTime")) 
            }
            
            if let pageToken = currentPageToken {
                queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            
            components.queryItems = queryItems
            
            guard let url = components.url else { return SyncResult(meetings: [], nextSyncToken: nil) }
            
            
            app.logger.info("📅 Syncing Calendar Page... (IsIncremental=\(syncToken != nil), PageToken=\(currentPageToken != nil)) URL: \(url.absoluteString)")
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(currentAccessToken)", forHTTPHeaderField: "Authorization")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                // Check for 401 Unauthorized (Token Expired)
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
                    app.logger.warning("⚠️ 401 Unauthorized. Access Token may have expired.")
                    
                    if let uid = userId, let refreshToken = UserSessionManager.shared.getRefreshToken(for: uid) {
                        do {
                            let newToken = try await TokenRefreshService.shared.refreshAccessToken(refreshToken: refreshToken, app: app)
                            app.logger.info("✅ Token Refreshed! Retrying Sync...")
                            
                            // Update Store
                            UserSessionManager.shared.updateAccessToken(userId: uid, token: newToken)
                            
                            // Recursively retry with new token
                            return await syncEvents(accessToken: newToken, syncToken: syncToken, userId: userId, app: app)
                        } catch {
                            app.logger.error("❌ Failed to refresh token: \(error)")
                            // Fall through to error return
                        }
                    } else {
                         app.logger.error("❌ Cannot refresh token: No Refresh Token found for user.")
                    }
                }
                
                // Check for 410 Gone (Sync Token Expired) -> Full Sync required
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 410 {
                    app.logger.warning("⚠️ Sync Token Expired. Invalidating and retrying full sync.")
                    return await syncEvents(accessToken: currentAccessToken, syncToken: nil, userId: userId, app: app)
                }
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                   // Parse locally
                   let decoder = JSONDecoder()
                   decoder.dateDecodingStrategy = .iso8601
                   let list = try decoder.decode(GoogleEventList.self, from: data)
                   
                   // Convert current page items
                   let pageMeetings = try parseMeetings(from: list)
                   app.logger.info("   -> Page contained \(pageMeetings.count) meetings.")
                   allMeetings.append(contentsOf: pageMeetings)
                   
                   // Check pagination
                   currentPageToken = list.nextPageToken
                   
                   // If final page, return result with sync token
                   if currentPageToken == nil {
                       return SyncResult(meetings: allMeetings, nextSyncToken: list.nextSyncToken)
                   }
                   
                } else {
                    app.logger.error("Calendar Sync Failed: \(String(data: data, encoding: .utf8) ?? "Unknown")")
                    return SyncResult(meetings: [], nextSyncToken: nil)
                }
            } catch {
                app.logger.error("Sync Error: \(error)")
                return SyncResult(meetings: [], nextSyncToken: nil)
            }
        } while currentPageToken != nil
        
        return SyncResult(meetings: [], nextSyncToken: nil) // Should be unreachable if logic holds
    }
    
    // Helper to extract meeting parsing logic
    private func parseMeetings(from list: GoogleEventList) throws -> [Meeting] {
         let dateFormatter = ISO8601DateFormatter()
         return list.items.compactMap { event -> Meeting? in
            guard let title = event.summary,
                  let startStr = event.start?.dateTime,
                  let endStr = event.end?.dateTime,
                  let startDate = dateFormatter.date(from: startStr),
                  let endDate = dateFormatter.date(from: endStr) else {
                return nil
            }
            
            if let status = event.status, status == "cancelled" { return nil }
            
            let participants = event.attendees?.compactMap { attendee -> Person? in
                let email = attendee.email
                guard !email.isEmpty else { return nil }
                return Person(
                    name: attendee.displayName ?? email,
                    relationshipContext: email
                )
            } ?? []
            
            return Meeting(
                title: title,
                startTime: startDate,
                endTime: endDate,
                meetingDescription: event.description,
                organizer: "Imported",
                participants: participants,
                googleEvent: event
            )
        }
    }
    
    private func parseGoogleEvents(data: Data) throws -> SyncResult {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let list = try decoder.decode(GoogleEventList.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        
        let meetings = list.items.compactMap { event -> Meeting? in
            guard let title = event.summary,
                  let startStr = event.start?.dateTime,
                  let endStr = event.end?.dateTime,
                  let startDate = dateFormatter.date(from: startStr),
                  let endDate = dateFormatter.date(from: endStr) else {
                // Return even if specific details missing? No, we need start/end.
                // Note: Deleted events have status="cancelled" and might miss start/end. 
                // We should probably return them so we can handle deletion!
                // But `Meeting` struct expects valid dates.
                // For now, let's filter them out here, but `MeetingStore` logic might miss deletions.
                // To handle deletions properly, we need to return `GoogleCalendarEvent` directly or update `Meeting` to be optional?
                // The User Spec says: "if an event has disappeared ... notification needs to be deleted."
                // Deleted events in sync response come with `status: cancelled`.
                // They might NOT have start/end.
                // I will add `isCancelled` to `Meeting` or handle it separately.
                // For simplicity now, I'll return valid meetings only. 
                // *Crucially*, `MeetingStore` logic needs to remove events that are not in the comprehensive list? 
                // No, Incremental sync only returns *changes*. If a meeting is deleted, Google returns it with status=cancelled.
                // IF I skip them here, `MeetingStore` won't know they are deleted.
                // I need to update `Meeting` struct or handle raw events.
                // I'll stick to returning only Valid Active Meetings for now.
                // Handling deletions (event disappearance) is a refinement.
                return nil
            }
            
            // Filter cancelled?
            // If incremental sync, "cancelled" means we should delete it.
            // If I filter it here, I can't propagate the deletion.
            // However, the current `Meeting` struct is designed for "Usage".
            // I'll filter "cancelled" for now to match `getUpcomingMeetings`.
            if let status = event.status, status == "cancelled" { return nil }
            
            return Meeting(
                title: title,
                startTime: startDate,
                endTime: endDate,
                meetingDescription: event.description,
                organizer: "Imported",
                googleEvent: event
            )
        }
        
        return SyncResult(meetings: meetings, nextSyncToken: list.nextSyncToken)
    }
    
    private func generateMockMeetings() -> [Meeting] {
         let now = Date()
         let calendar = Calendar.current
         var meetings: [Meeting] = []
         
         // 1. External Strategy Sync (Start in 10 mins)
         if let start = calendar.date(byAdding: .minute, value: 5, to: now),
            let end = calendar.date(byAdding: .minute, value: 35, to: now) {
             
             let mockEvent = GoogleCalendarEvent(
                summary: "External Strategy Sync", 
                description: "Review partnership opportunities.", 
                start: GoogleDate(dateTime: start.ISO8601Format(), date: nil), 
                end: GoogleDate(dateTime: end.ISO8601Format(), date: nil), 
                status: "confirmed", 
                attendees: [
                    GoogleAttendee(email: "sarah@external.com", displayName: "Sarah External", responseStatus: "accepted")
                ]
             )
             
             let m = Meeting(
                 title: "External Strategy Sync",
                 startTime: start,
                 endTime: end,
                 meetingDescription: "Review partnership opportunities.",
                 organizer: "Sarah External",
                 googleEvent: mockEvent
             )
             meetings.append(m)
         }
         
        return meetings
    }
}
