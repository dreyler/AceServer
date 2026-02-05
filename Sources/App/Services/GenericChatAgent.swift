import Vapor

struct GenericChatAgent {
    static let shared = GenericChatAgent()
    
    // Response from Gemini Logic
    struct AgentDecision: Codable {
        enum Intent: String, Codable {
            case briefPreference
            case notificationPreference
            case personMemory
            case featureRequest
            case generalChat
        }
        
        let intent: Intent
        let data: [String: String]? // Dynamic data payload
        let reply: String // Text to show user
    }
    
    func process(userId: String, message: String) async -> String {
        // 1. Construct Prompt
        let systemPrompt = """
        You are an intelligent assistant for the "Ace" executive briefing app.
        Your goal is to categorize the User's input into one of 5 intents and extract relevant data.
        
        INTENTS:
        1. briefPreference: User wants to change WHAT is in the meeting brief.
           - Example: "Include LinkedIn profiles", "Don't show internal meetings"
           - Data: {"preference": "The exact preference text"}
        
        2. notificationPreference: User wants to change HOW/WHEN they are notified.
           - Example: "Buzz me if Jim is in the meeting", "Silent notifications only"
           - Data: {"preference": "The exact preference text"}
        
        3. personMemory: User wants you to remember a fact about a person.
           - Example: "Jack likes the Raiders", "Remember that Susan is crucial for the Q3 deal"
           - Data: {"personName": "Jack", "memory": "Likes the Raiders"}
           - Note: Extract the person's name accurately.
        
        4. featureRequest: User asks for something the app can't do yet.
           - Example: "Can you summarize my emails?", " Integrate with Salesforce"
           - Data: {"request": "Summarize emails"}
        
        5. generalChat: General questions or small talk.
           - Example: "What are good questions for a sales meeting?", "Hello"
           - Data: {}
           
        OUTPUT FORMAT:
        Return ONLY a JSON object. Do not include markdown formatting.
        {
            "intent": "...",
            "data": { ... },
            "reply": "A helpful response confirming the action or answering the question."
        }
        """
        
        let userPrompt = "User Message: \"\(message)\""
        let combinedPrompt = systemPrompt + "\n\n" + userPrompt
        
        // 2. Call Gemini
        do {
            // Updated to match `generateJSON<T>(prompt: String, responseType: T.Type)`
            let decision = try await GeminiService.shared.generateJSON(
                prompt: combinedPrompt,
                responseType: AgentDecision.self
            )
            
            // 3. (Parsing handled by Service now)
            
            // 4. Act on Intent
            switch decision.intent {
            case .briefPreference:
                if let pref = decision.data?["preference"] {
                    // Update User Context
                    var currentPrefs = UserSessionManager.shared.getUserContext(userId: userId)?.briefPreferences ?? []
                    currentPrefs.append(pref)
                    UserSessionManager.shared.updateUserPreferences(userId: userId, briefPrefs: currentPrefs)
                    print("✅ Saved Brief Preference: \(pref)")
                }
                
            case .notificationPreference:
                if let pref = decision.data?["preference"] {
                    // Update User Context
                    var currentPrefs = UserSessionManager.shared.getUserContext(userId: userId)?.notificationPreferences ?? []
                    currentPrefs.append(pref)
                    UserSessionManager.shared.updateUserPreferences(userId: userId, notifPrefs: currentPrefs)
                    print("✅ Saved Notification Preference: \(pref)")
                }
                
            case .personMemory:
                if let name = decision.data?["personName"], let memory = decision.data?["memory"] {
                    // Update Person
                    savePersonMemory(name: name, memory: memory)
                    print("✅ Saved Memory for \(name): \(memory)")
                }
                
            case .featureRequest:
                if let req = decision.data?["request"] {
                    PersistenceService.shared.saveFeatureRequest(req, from: userId)
                    print("✅ Saved Feature Request: \(req)")
                }
                
            case .generalChat:
                break // Just return the reply
            }
            
            return decision.reply
            
        } catch {
            print("❌ GenericChatAgent Error: \(error)")
            return "I'm having trouble connecting to my brain right now. Try again?"
        }
    }
    
    // Helper to find/create person and save memory
    private func savePersonMemory(name: String, memory: String) {
        // Load all people
        var people = PersistenceService.shared.loadPeople() ?? []
        
        // Find best match (simple case-insensitive contains for now)
        if let index = people.firstIndex(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            var person = people[index]
            var memories = person.memories ?? []
            memories.append(memory)
            person.memories = memories
            people[index] = person
        } else {
            // Create new person stub if not found?
            // Risk: Creating duplicates if name varies.
            // Policy: Only add memory if person exists? Or create "Memory Stub"?
            // Let's create a stub for now so the memory isn't lost.
            var newPerson = Person(name: name, relationshipContext: nil, title: nil, companyName: nil)
            newPerson.memories = [memory]
            people.append(newPerson)
        }
        
        PersistenceService.shared.savePeople(people)
    }
}
