import Foundation
import Vapor

// Pure Codable versions of the App's models

struct Person: Codable {
    var id: UUID = UUID()
    var name: String
    var relationshipContext: String? // Email
    var title: String?
    var companyName: String?
    
    // Logic Helpers
    var isColleague: Bool {
        // Simplified server-side logic (e.g. domain check)
        return false // Placeholder
    }
}

struct Meeting: Codable {
    var id: UUID = UUID()
    var title: String
    var startTime: Date
    var endTime: Date
    var meetingDescription: String?
    var organizer: String?
    var participants: [Person] = []
    
    enum MeetingStatus: String, Codable {
        case accepted, declined, tentative, needsAction
    }
}

struct Routine: Codable {
    enum RoutineType: String, Codable {
        case beforeMeeting = "Before Meeting Prep"
        case dontBeLate = "Don't Be Late"
        case afterMeeting = "After Meeting Actions"
    }
    
    var id: UUID = UUID()
    var type: RoutineType
    var isEnabled: Bool = true
    var routineDescription: String // NL Configuration
}

struct AceNotification: Codable {
    enum NotificationType: String, Codable {
        case active, passive
    }
    
    var id: UUID = UUID()
    var title: String
    var body: String
    var sentDate: Date
    var type: NotificationType
    var relatedMeetingID: UUID?
}

struct RegisterRequest: Codable {
    let userId: String // Email usually
    let accessToken: String
    let routines: [Routine]
    let deviceToken: String? // Hex string of APNs token
}
