import Vapor

// configures your application
public func configure(_ app: Application) throws {
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

    // register routes
    try routes(app)
    
    // DISABLED: Background agent was wasting API quota by running every 60s
    // Re-enable only for production with proper throttling (15+ min intervals)
    /*
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
            
            for (userId, token, routines, deviceToken) in sessions {
                app.logger.info("   Processing User: \(userId) (HasToken: \(deviceToken != nil))")
                
                // 1. Fetch Meetings
                let meetings = await ServerCalendarService.shared.getUpcomingMeetings(accessToken: token, app: app)
                
                // 2. Process
                await ServerNotificationAgent.shared.process(meetings: meetings, routines: routines, token: token, app: app)
            }
        }
    }
    */
}
