import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// --- Configuration ---
let serverUrl = URL(string: "http://localhost:8080/enrich-person-v2")!
let csvPath = "/Users/davideyler/.gemini/antigravity/scratch/my enrichment - participants - good run on client side.csv"
let outputPath = "/Users/davideyler/.gemini/antigravity/scratch/AceServer/enrichment_validation_results.txt"

// --- Models ---
struct EnrichmentRequest: Codable {
    let email: String
    let displayName: String
    let accessToken: String // Mock token
}

struct EnrichmentResponse: Codable {
    let email: String
    let name: String
    let company: String
    let linkedInUrl: String?
}

// --- CSV Parser ---
func parseCSV(at path: String) -> [[String: String]] {
    guard let content = try? String(contentsOfFile: path) else {
        print("❌ Could not read CSV file at \(path)")
        exit(1)
    }
    
    var rows:[[String:String]] = []
    let lines = content.components(separatedBy: .newlines)
    guard let headerLine = lines.first else { return [] }
    let headers = parseCSVLine(headerLine)
    
    for (index, line) in lines.enumerated() {
        if index == 0 || line.isEmpty { continue }
        let values = parseCSVLine(line)
        if values.count >= headers.count { // Allow >= in case of trailing commas
             var row:[String:String] = [:]
             for (i, header) in headers.enumerated() {
                 if i < values.count {
                     row[header] = values[i]
                 }
             }
             rows.append(row)
        }
    }
    return rows
}

func parseCSVLine(_ line: String) -> [String] {
    var result: [String] = []
    var current = ""
    var inQuotes = false
    
    for char in line {
        if char == "\"" {
            inQuotes.toggle()
        } else if char == "," && !inQuotes {
            result.append(current)
            current = ""
        } else {
            current.append(char)
        }
    }
    result.append(current)
    return result
}

// --- logging Helper ---
func log(_ message: String, to fileHandle: FileHandle?) {
    print(message)
    if let data = (message + "\n").data(using: .utf8) {
        fileHandle?.write(data)
    }
}

// --- Main Test Logic ---
print("🚀 Starting Bulk Enrichment Test (Continuous Logging)...")
print("📂 Input: \(csvPath)")
print("📄 Output: \(outputPath)")

// Prepare Output File
FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
let fileHandle = FileHandle(forWritingAtPath: outputPath)

let rows = parseCSV(at: csvPath)
log("📊 Found \(rows.count) rows to process.", to: fileHandle)

var passed = 0
var failed = 0
let semaphore = DispatchSemaphore(value: 0)

// Loop through rows - NO LIMIT
for (index, row) in rows.enumerated() {
    
    let email = row["Email"] ?? ""
    let name = row["Name"] ?? ""
    let expectedUrlRaw = row["URL"] ?? "N/A"
    
    // Construct Request
    let requestBody = EnrichmentRequest(
        email: email, 
        displayName: name, 
        accessToken: "mock_token"
    )
    
    var request = URLRequest(url: serverUrl)
    request.httpMethod = "POST"
    request.addValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONEncoder().encode(requestBody)
    
    // Async Request (using Semaphore to keep it serial script)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        
        if let error = error {
            log("❌ [ERROR] Request failed for \(email): \(error)", to: fileHandle)
            failed += 1
            return
        }
        
        guard let data = data else { return }
        
        do {
            let result = try JSONDecoder().decode(EnrichmentResponse.self, from: data)
            let actualUrl = result.linkedInUrl ?? "N/A"
            let expectedUrl = (expectedUrlRaw.isEmpty || expectedUrlRaw == "N/A") ? "N/A" : expectedUrlRaw
            
            // Loose comparison (ignore tracking params, matching just the profile ID part)
            let cleanExpected = expectedUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanActual = actualUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            if cleanActual == cleanExpected {
                // PASS
                if cleanExpected == "N/A" {
                    log("✅ [PASS-NEG] \(email) -> Correctly returned NIL", to: fileHandle)
                } else {
                    log("✅ [PASS] \(email) -> \(actualUrl)", to: fileHandle)
                }
                passed += 1
            } else {
                // FAIL
                if cleanExpected == "N/A" {
                     log("❌ [FAIL-FALSE_POS] \(email): Expected NIL, Got \(actualUrl)", to: fileHandle)
                } else if cleanActual == "N/A" {
                     log("❌ [FAIL-MISS] \(email): Expected \(expectedUrl), Got NIL", to: fileHandle)
                } else {
                     log("⚠️ [FAIL-DIFF] \(email): Expected \(expectedUrl), Got \(actualUrl)", to: fileHandle)
                }
                failed += 1
            }
            
        } catch {
            log("❌ [ERROR] Decoder Error for \(email): \(error)", to: fileHandle)
            failed += 1
        }
    }
    
    task.resume()
    semaphore.wait()
    
    // Basic progress indicator every 10 rows
    if index % 10 == 0 {
        print("... processed \(index + 1)/\(rows.count)")
    }
    
    // Rate limit kindness
    Thread.sleep(forTimeInterval: 0.1)
}

log("\n--- Final Summary ---", to: fileHandle)
log("✅ Passed: \(passed)", to: fileHandle)
log("❌ Failed: \(failed)", to: fileHandle)
log("Total: \(passed + failed)", to: fileHandle)

fileHandle?.closeFile()
