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
                app.logger.info("✅ Found \(items.count) meetings from Google.")
                for m in items {
                     app.logger.info("   -> Meeting: \(m.title) at \(m.startTime)")
                }
                return items
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
    }
    
    private func parseGoogleEvents(data: Data) throws -> [Meeting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let list = try decoder.decode(GoogleEventList.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        
        return list.items.compactMap { event -> Meeting? in
            guard let title = event.summary,
                  let startStr = event.start?.dateTime,
                  let endStr = event.end?.dateTime,
                  let startDate = dateFormatter.date(from: startStr),
                  let endDate = dateFormatter.date(from: endStr) else {
                // Skip all-day events (date only) or missing data for now
                return nil
            }
            
            // Filter cancelled
            if let status = event.status, status == "cancelled" { return nil }
            
            return Meeting(
                title: title,
                startTime: startDate,
                endTime: endDate,
                meetingDescription: event.description,
                organizer: "Imported",
                googleEvent: event // Store Raw Data
            )
        }
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
