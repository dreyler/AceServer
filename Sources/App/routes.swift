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
        
        // Extract context
        let context = UserSessionManager.UserContext(
            title: registerData.userTitle,
            company: registerData.userCompany,
            bio: registerData.userBio,
            localTime: registerData.userLocalTime
        )
        
        UserSessionManager.shared.register(
            userId: registerData.userId,
            token: registerData.accessToken,
            refreshToken: registerData.refreshToken,
            routines: registerData.routines,
            deviceToken: registerData.deviceToken,
            context: context
        )
        
        // FORCE SYNC: Trigger immediate calendar sync to backfill history
        Task.detached {
            app.logger.info("⚡️ Triggering Immediate Sync for \(registerData.userId)...")
            let currentSyncToken = MeetingStore.shared.getSyncToken(for: registerData.userId)
            let syncResult = await ServerCalendarService.shared.syncEvents(
                accessToken: registerData.accessToken,
                syncToken: currentSyncToken,
                userId: registerData.userId,
                app: app
            )
            
            if !syncResult.meetings.isEmpty {
                app.logger.info("   ⚡️ Immediate Sync: fetched \(syncResult.meetings.count) meetings.")
                MeetingStore.shared.handleSyncedMeetings(userId: registerData.userId, meetings: syncResult.meetings)
            }
            
            if let nextToken = syncResult.nextSyncToken {
                MeetingStore.shared.setSyncToken(nextToken, for: registerData.userId)
            }
        }
        
        return .ok
    }
    
    // Generate Brief on Demand
    app.post("generate-brief") { req async throws -> BriefResponse in
        let briefRequest = try req.content.decode(BriefRequest.self)
        
        app.logger.info("📲 On-Demand Brief Request for: \(briefRequest.meeting.summary ?? "Unknown")")
        
        // Fetch User Context for Preferences
        var briefPreferences: [String]? = nil
        if let email = briefRequest.userEmail, let context = UserSessionManager.shared.getUserContext(userId: email) {
            briefPreferences = context.briefPreferences
        }
        
        let (brief, prompt) = await MeetingBriefAgent.generateBrief(
            meeting: briefRequest.meeting,
            accessToken: briefRequest.accessToken,
            userEmail: briefRequest.userEmail ?? "",
            userName: briefRequest.userName ?? "",
            userTitle: briefRequest.userTitle,
            userCompany: briefRequest.userCompany,
            userBio: briefRequest.userBio,
            userLocalTime: briefRequest.userLocalTime,
            briefPreferences: briefPreferences,
            app: app
        )
        
        return BriefResponse(brief: brief, prompt: prompt)
    }
    
    // Enrich Person V2 - Centralized enrichment with caching
    app.post("enrich-person-v2") { req async throws -> ParticipantEnrichmentService.EnrichmentOutput in
        let enrichRequest = try req.content.decode(EnrichRequestV2.self)
        
        let input = ParticipantEnrichmentService.EnrichmentInput(
            email: enrichRequest.email,
            displayName: enrichRequest.displayName,
            accessToken: enrichRequest.accessToken
        )
        
        return await ParticipantEnrichmentService.shared.enrichParticipant(input: input, app: app)
    }
    
    // Enrich Person on Demand (OLD - deprecated)
    // Enrich Person on Demand
    // Clear Cache
    app.post("cache", "clear") { req async throws -> HTTPStatus in
        app.logger.info("🗑️ Clearing caches requested by client")
        await ParticipantEnrichmentService.shared.clearCache()
        return .ok
    }
    // Debug Route for Gemini Logs
    app.get("debug", "gemini") { req async throws -> Response in
        let fileUrl = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("gemini_debug.log")
        
        guard let data = try? Data(contentsOf: fileUrl) else {
            return Response(status: .notFound, body: .init(string: "No debug log found."))
        }
        
        let jsSafeLog = data.base64EncodedString()
        
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <title>Gemini Debug Log</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #1e1e1e; color: #d4d4d4; padding: 20px; margin: 0; }
                /* ... styles continue ... */
                h1 { border-bottom: 2px solid #333; padding-bottom: 10px; display: flex; justify-content: space-between; align-items: center; }
                .entry { background: #252526; border-radius: 8px; margin-bottom: 30px; padding: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.3); border: 1px solid #333; }
                .meta { color: #888; font-size: 0.9em; margin-bottom: 15px; font-family: monospace; display: flex; justify-content: space-between; }
                table { width: 100%; border-collapse: collapse; margin-top: 15px; background: #1e1e1e; border-radius: 6px; overflow: hidden; }
                th, td { text-align: left; padding: 12px; border-bottom: 1px solid #333; }
                th { background: #333; color: #fff; font-weight: 600; font-size: 0.9em; text-transform: uppercase; letter-spacing: 0.05em; }
                tr:last-child td { border-bottom: none; }
                .status-notify { color: #4ec9b0; font-weight: bold; background: rgba(78, 201, 176, 0.1); border-radius: 4px; padding: 4px 8px; display: inline-block;}
                .status-skip { color: #6a9955; opacity: 0.7; padding: 4px 8px; }
                .decision-row:hover { background: #2a2d2e; }
                .raw-toggle { color: #007acc; cursor: pointer; text-decoration: underline; font-size: 0.9em; margin-top: 10px; display: inline-block; }
                .raw-content { display: none; margin-top: 10px; padding: 15px; background: #111; border-radius: 4px; font-family: monospace; white-space: pre-wrap; font-size: 0.85em; color: #ce9178; border: 1px solid #444; }
                .timestamp { color: #569cd6; font-weight: bold; }
                
                /* Meeting Details */
                .meeting-title { font-weight: 600; color: #fff; display: block; margin-bottom: 2px; }
                .meeting-sub { font-size: 0.85em; color: #aaa; }
                .participants-badge { background: #0e639c; color: white; padding: 2px 6px; border-radius: 10px; font-size: 0.8em; }
                .participants-none { background: #333; color: #888; padding: 2px 6px; border-radius: 10px; font-size: 0.8em; }
            </style>
        </head>
        <body>
            <h1>
                <span>🧠 Gemini Intelligence History</span>
                <button onclick="location.reload()" style="background:#0e639c; color:white; border:none; padding:8px 16px; border-radius:4px; cursor:pointer;">Refresh</button>
            </h1>
            <div id="container"></div>

            <script>
                // Decode Base64 safely (handles UTF-8)
                const b64 = "\(jsSafeLog)";
                const binString = atob(b64);
                const bytes = Uint8Array.from(binString, c => c.charCodeAt(0));
                const rawLog = new TextDecoder().decode(bytes);
                
                const container = document.getElementById('container');

                function parseLog(log) {
                    // Split and Reverse to show newest first
                    const entries = log.split('--------------------------------------------------').filter(e => e.trim()).reverse();
                    
                    entries.forEach(entryText => {
                        const entryDiv = document.createElement('div');
                        entryDiv.className = 'entry';

                        // Extract Timestamp
                        const timeMatch = entryText.match(/TIMESTAMP: (.*)/);
                        const timestamp = timeMatch ? timeMatch[1] : 'Unknown Time';

                        // Extract Prompt JSON (List of Meetings)
                        let inputMeetings = {};
                        try {
                            const promptMarker = "PROMPT:";
                            const responseMarker = "RESPONSE:";
                            const promptStart = entryText.indexOf(promptMarker);
                            const responseStart = entryText.indexOf(responseMarker);
                            
                            if (promptStart !== -1 && responseStart !== -1) {
                                let promptText = entryText.substring(promptStart + promptMarker.length, responseStart);
                                
                                // Robust JSON extraction using bracket balancing
                                // The text contains multiple arrays (Prompt Meetings + Schema Example).
                                // We want the first valid array after "Here is the list of meetings" or just the first array.
                                
                                const start = promptText.indexOf('[');
                                if (start !== -1) {
                                    let balance = 0;
                                    let end = -1;
                                    for (let i = start; i < promptText.length; i++) {
                                        if (promptText[i] === '[') balance++;
                                        else if (promptText[i] === ']') {
                                            balance--;
                                            if (balance === 0) {
                                                end = i;
                                                break;
                                            }
                                        }
                                    }
                                    
                                    if (end !== -1) {
                                        const jsonStr = promptText.substring(start, end + 1);
                                        try {
                                            const meetings = JSON.parse(jsonStr);
                                            meetings.forEach(m => {
                                                const id = m.id || m.googleEvent?.id;
                                                if (id) inputMeetings[id] = m;
                                            });
                                        } catch (e) {
                                             console.warn("Found candidate JSON block but failed to parse:", jsonStr.substring(0, 50) + "..."); 
                                        }
                                    }
                                }
                            }
                        } catch (e) { console.error('Failed to parse input meetings', e); }

                        // Extract Response JSON (Decisions)
                        let decisions = [];
                        let isBriefGeneration = false;
                        let briefDetails = {};
                        let isGenericChat = false;
                        let genericDetails = {};
                        
                        try {
                            // MODE 1 & 3: JSON DECISIONS / GENERIC AGENT
                            const responseMarker = "RESPONSE:";
                            const responseStart = entryText.indexOf(responseMarker);
                            if (responseStart !== -1) {
                                let responseText = entryText.substring(responseStart + responseMarker.length);
                                const jsonStart = responseText.indexOf('{');
                                const jsonEnd = responseText.lastIndexOf('}');
                                if (jsonStart !== -1 && jsonEnd !== -1) {
                                    const jsonStr = responseText.substring(jsonStart, jsonEnd + 1);
                                    try {
                                        const parsed = JSON.parse(jsonStr);
                                        if (parsed.decisions) {
                                            decisions = parsed.decisions;
                                        } else if (parsed.intent) {
                                            isGenericChat = true;
                                            genericDetails = parsed;
                                        }
                                    } catch(e) {}
                                }
                            }
                            
                            // MODE 2: XML PROMPT (Brief Agent)
                            const promptMarker = "PROMPT:";
                            const pStart = entryText.indexOf(promptMarker);
                            if (pStart !== -1 && decisions.length === 0 && !isGenericChat) {
                                const promptText = entryText.substring(pStart + promptMarker.length);
                                
                                if (promptText.includes('<meeting_details>')) {
                                    isBriefGeneration = true;
                                    
                                    // Extract simple details via Regex
                                    const titleMatch = promptText.match(/<title>(.*?)<\\/title>/);
                                    const userMatch = promptText.match(/<logged_in_user>\\s*<name>(.*?)<\\/name>/s);
                                    const dateMatch = promptText.match(/<date>(.*?)<\\/date>/);
                                    
                                    briefDetails = {
                                        title: titleMatch ? titleMatch[1] : 'Unknown Meeting',
                                        user: userMatch ? userMatch[1].trim() : 'Unknown User',
                                        date: dateMatch ? dateMatch[1] : ''
                                    };
                                }
                            }
                        } catch (e) { console.error('Failed to parse decisions/brief', e); }

                        // Render
                        const dateOpts = { weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: '2-digit', minute: '2-digit' };
                        const timestampStr = new Date(timestamp).toLocaleString([], dateOpts);
                        
                        // DETERMINE AGENT TYPE & SUMMARY
                        let agentType = "Unknown Agent";
                        let agentColor = "#888"; // Gray
                        let requestSummary = "";
                        
                        if (isGenericChat) {
                            agentType = "🤖 Generic Chat Agent";
                            agentColor = "#4ec9b0"; // Cyan
                            requestSummary = genericDetails.intent ? `Intent: ${genericDetails.intent}` : "Processing User Message";
                        } else if (isBriefGeneration) {
                            agentType = "📝 Meeting Brief Agent";
                            agentColor = "#c586c0"; // Purple
                            requestSummary = `Generating Brief for: ${briefDetails.title || 'Unknown Meeting'}`;
                        } else if (decisions.length > 0) {
                            agentType = "🔔 Notification Controller";
                            agentColor = "#569cd6"; // Blue
                            const meetingCount = Object.keys(inputMeetings).length;
                            requestSummary = `Evaluating ${meetingCount} Meeting${meetingCount === 1 ? '' : 's'}`;
                        } else {
                            agentType = "🔍 Analysis System";
                            agentColor = "#dcdcaa"; // Yellow
                            const meetingCount = Object.keys(inputMeetings).length;
                            requestSummary = meetingCount > 0 ? `Checking ${meetingCount} Meeting${meetingCount === 1 ? '' : 's'} (No Action)` : "System Check";
                        }

                        // RENDER HEADER
                        let html = `<div class="meta" style="border-bottom: 1px solid #333; padding-bottom: 10px; margin-bottom: 15px; display:flex; align-items:center; justify-content:space-between;">
                            <div style="display:flex; align-items:center; gap:12px;">
                                <div style="background:${agentColor}; color:#1e1e1e; font-weight:bold; padding:4px 10px; border-radius:4px; font-size:0.9em;">
                                    ${agentType}
                                </div>
                                <div style="color:#ddd; font-weight:500;">
                                    ${requestSummary}
                                </div>
                            </div>
                            <div style="text-align:right;">
                                <span class="timestamp" style="color:#666;">${timestampStr}</span>
                            </div>
                        </div>`;
                        
                        // Prompt Display (Collapsed by default)
                        let promptDisplay = '';
                        const promptMarker = "PROMPT:";
                        const responseMarker = "RESPONSE:";
                        const pStart = entryText.indexOf(promptMarker);
                        const rStart = entryText.indexOf(responseMarker);
                        if (pStart !== -1 && rStart !== -1) {
                            let rawPrompt = entryText.substring(pStart + promptMarker.length, rStart).trim();
                             promptDisplay = `<div style="margin-bottom:15px;">
                                <details>
                                    <summary style="cursor:pointer; color:#569cd6; font-weight:bold; outline:none;">Show Agent Prompt Context</summary>
                                    <div class="raw-content" style="display:block; margin-top:5px; border-left: 3px solid #569cd6;">${rawPrompt}</div>
                                </details>
                             </div>`;
                        }
                        html += promptDisplay;
                
                if (decisions.length > 0) {
                     // ... existing table render ...
                } else if (isGenericChat) {
                    // Render Generic Agent Card
                    const intentColor = '#4ec9b0';
                    html += `<div style="background: #252526; padding: 15px; border-radius: 6px; border-left: 4px solid ${intentColor}; margin-top:10px;">
                        <div style="font-weight:bold; color: ${intentColor}; margin-bottom: 8px;">🤖 Generic Chat Agent</div>
                        <div style="display:grid; grid-template-columns: 100px 1fr; gap: 10px; font-size: 0.9em;">
                            <div style="color:#888;">Intent:</div>
                            <div style="color:#fff; font-weight:600;">${genericDetails.intent}</div>
                            
                            <div style="color:#888;">Data:</div>
                            <div style="color:#ce9178; font-family:monospace;">${JSON.stringify(genericDetails.data)}</div>
                            
                            <div style="color:#888;">Reply:</div>
                            <div style="color:#d4d4d4; white-space: pre-wrap;">${genericDetails.reply}</div>
                        </div>
                    </div>`;

                } else if (isBriefGeneration) {
                     // ... existing brief render ...
                } else {
                     // ... Warning ...
                }

                        // Raw Toggle
                        html += `<div class="raw-toggle" onclick="this.nextElementSibling.style.display = this.nextElementSibling.style.display === 'block' ? 'none' : 'block'">Show Raw Log</div>`;
                        html += `<div class="raw-content">${entryText.replace(/</g, '&lt;')}</div>`;

                        entryDiv.innerHTML = html;
                        container.appendChild(entryDiv);
                    });
                }

                parseLog(rawLog);
            </script>
        </body>
        </html>
        """
        
        return Response(status: .ok, headers: ["Content-Type": "text/html"], body: .init(string: html))
    }
    // Generic Chat Agent Route
    app.post("chat") { req async throws -> ChatResponse in
        let chatReq = try req.content.decode(ChatRequest.self)
        
        let responseText = await GenericChatAgent.shared.process(
            userId: chatReq.userId,
            message: chatReq.message
        )
        
        return ChatResponse(reply: responseText)
    }
}

// Request/Response Models

struct ChatRequest: Codable {
    let userId: String
    let message: String
}

struct ChatResponse: Content {
    let reply: String
}

struct BriefRequest: Codable {
    let meeting: GoogleCalendarEvent
    let accessToken: String
    let userEmail: String?
    let userName: String?
    let userTitle: String?
    let userCompany: String?
    let userBio: String?
    let userLocalTime: String? // Formatted meeting time in user's timezone
}

struct BriefResponse: Content {
    let brief: String
    let prompt: String
}

// V2 Enrich Request
struct EnrichRequestV2: Codable {
    let email: String
    let displayName: String?
    let accessToken: String
}
