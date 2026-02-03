import VaporAPNS

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
        try app.apns.configuration = .init(
            authenticationMethod: .jwt(
                key: .private(filePath: apnsKeyPath),
                keyIdentifier: apnsKeyId,
                teamIdentifier: apnsTeamId
            ),
            topic: apnsTopic,
            environment: .sandbox // Use .production for App Store
        )
    } else {
        app.logger.warning("⚠️ APNs Key not found at \(apnsKeyPath). Push notifications will be simulated.")
    }
    
    // Start Background Agent Loop
    app.logger.info("🚀 AceServer Agent Starting...")
    
    // Run every 60 seconds
    app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(5), delay: .seconds(60)) { task in
        Task {
            app.logger.info("⏰ Agent Tick - Checking Users...")
            
            let sessions = UserSessionManager.shared.getAllSessions()
            
            if sessions.isEmpty {
                app.logger.info("   No active users.")
                return 
            }
            
            for (userId, token, routines, deviceToken, context) in sessions {
                app.logger.info("   Processing User: \(userId) (HasToken: \(deviceToken != nil))")
                
                // 1. Fetch Meetings
                let meetings = await ServerCalendarService.shared.getUpcomingMeetings(accessToken: token, app: app)
                
                // 2. Process
                await ServerNotificationAgent.shared.process(meetings: meetings, routines: routines, userId: userId, token: token, deviceToken: deviceToken, context: context, app: app)
            }
        }
    }
}
