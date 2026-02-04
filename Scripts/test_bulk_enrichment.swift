import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// --- Configuration ---
let serverUrl = URL(string: "http://localhost:8080/enrich-person-v2")!
let csvPath = "/Users/davideyler/.gemini/antigravity/scratch/my enrichment - participants - good run on client side.csv"
// Generate Timestamped Output Filename
let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
let timestamp = dateFormatter.string(from: Date())
let outputPath = "/Users/davideyler/.gemini/antigravity/scratch/AceServer/enrichment_validation_results_\(timestamp).csv"

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
    // Print to console (formatted nicely)
    print(message)
    // Write to file (CSV format - assuming message is already CSV line)
    if let data = (message + "\n").data(using: .utf8) {
        fileHandle?.write(data)
    }
}

func logCSV(_ fields: [String], to fileHandle: FileHandle?) {
    // Escape quotes and wrap in quotes
    let csvLine = fields.map { field in
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }.joined(separator: ",")
    
    if let data = (csvLine + "\n").data(using: .utf8) {
        fileHandle?.write(data)
    }
    
    // Also print a readable summary to console
    let status = fields.last ?? "?"
    let email = fields.first ?? "?"
    print("[\(status)] \(email)")
}

// --- Main Test Logic ---
print("🚀 Starting Bulk Enrichment Test (Continuous CSV Output)...")
print("📂 Input: \(csvPath)")
print("📄 Output: \(outputPath)")

// Prepare Output File
FileManager.default.createFile(atPath: outputPath, contents: nil, attributes: nil)
let fileHandle = FileHandle(forWritingAtPath: outputPath)

// Write Header
logCSV(["Email", "Name", "Expected URL", "Actual URL", "Status Code", "Result"], to: fileHandle)

let rows = parseCSV(at: csvPath)
print("📊 Found \(rows.count) rows to process.")

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
        
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        let statusStr = "\(httpStatus)"
        
        if let error = error {
            logCSV([email, name, expectedUrlRaw, "ERROR: \(error.localizedDescription)", statusStr, "FAIL"], to: fileHandle)
            failed += 1
            return
        }
        
        guard let data = data else { return }
        
        if httpStatus == 429 {
             logCSV([email, name, expectedUrlRaw, "RATE LIMITED", statusStr, "FAIL"], to: fileHandle)
             failed += 1
             return
        }
        
        do {
            let result = try JSONDecoder().decode(EnrichmentResponse.self, from: data)
            let actualUrl = result.linkedInUrl ?? "N/A"
            let expectedUrl = (expectedUrlRaw.isEmpty || expectedUrlRaw == "N/A") ? "N/A" : expectedUrlRaw
            
            // Loose comparison (ignore tracking params, matching just the profile ID part)
            let cleanExpected = expectedUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanActual = actualUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            if cleanActual == cleanExpected {
                // PASS
                logCSV([email, name, expectedUrl, actualUrl, statusStr, "PASS"], to: fileHandle)
                passed += 1
            } else {
                // FAIL
                logCSV([email, name, expectedUrl, actualUrl, statusStr, "FAIL"], to: fileHandle)
                failed += 1
            }
            
        } catch {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown Data"
            // If it's a 500 or 400, strictly log it
            logCSV([email, name, expectedUrlRaw, "DECODE Error / API Error: \(errorMsg.prefix(50))", statusStr, "FAIL"], to: fileHandle)
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

print("\n--- Final Summary ---")
print("Passed: \(passed)")
print("Failed: \(failed)")
print("Total: \(passed + failed)")

fileHandle?.closeFile()
