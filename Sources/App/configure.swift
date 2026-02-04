import Vapor
import VaporAPNS
import APNS

// configures your application
public func configure(_ app: Application) throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // register routes
    try routes(app)
    
    // Configure APNs
    // Note: User must replace these placeholders and provide the p8 file.
    let apnsKeyId = Environment.get("APNS_KEY_ID") ?? "YOUR_KEY_ID"
    let apnsTeamId = Environment.get("APNS_TEAM_ID") ?? "YOUR_TEAM_ID"
    let apnsTopic = Environment.get("APNS_TOPIC") ?? "com.ace.app" // Bundle ID
    let apnsKeyPath = Environment.get("APNS_KEY_PATH") ?? app.directory.workingDirectory + "AuthKey.p8"
    
    // Check if key file exists before enabling APNs to avoid crash on startup
    if FileManager.default.fileExists(atPath: apnsKeyPath) {
        app.logger.info("🔔 Configuring APNs with key at \(apnsKeyPath)")
        /*
        app.apns.configuration = APNSwiftConfiguration(
            authenticationMethod: .jwt(
                key: .private(filePath: apnsKeyPath),
                keyIdentifier: apnsKeyId,
                teamIdentifier: apnsTeamId
            ),
            topic: apnsTopic,
            environment: .sandbox
        )
        */
        app.logger.warning("⚠️ APNs Configuration Disabled due to dependency issues. Notifications will be mocked.")
    } else {
        app.logger.warning("⚠️ APNs Key not found at \(apnsKeyPath). Push notifications will be simulated.")
    }
    
    // Start Background Agent Loop
    app.logger.info("🚀 AceServer Controller Agent Starting...")
    
    // Use the new Controller Agent Loop
    MeetingBriefControllerAgent.shared.processLoop(app: app)
}
