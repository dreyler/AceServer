import Vapor

func routes(_ app: Application) throws {
    app.get { req async in
        "AceServer is running!"
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }
    
    // Register User & Token
    app.post("register") { req async throws -> HTTPStatus in
        let registerData = try req.content.decode(RegisterRequest.self)
        
        UserSessionManager.shared.register(
            userId: registerData.userId,
            token: registerData.accessToken,
            routines: registerData.routines,
            deviceToken: registerData.deviceToken
        )
        
        return .ok
    }
}
