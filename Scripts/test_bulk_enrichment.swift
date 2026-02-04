import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// --- Configuration ---
let serverUrl = URL(string: "http://localhost:8080/enrich-person-v2")!
let csvPath = "/Users/davideyler/.gemini/antigravity/scratch/my enrichment - participants - good run on client side.csv"
let outputLimit = 100 // Limit to first 100 for speed, or remove for full run

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
        if values.count == headers.count {
            var row:[String:String] = [:]
            for (i, header) in headers.enumerated() {
                row[header] = values[i]
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

// --- Main Test Logic ---
print("🚀 Starting Bulk Enrichment Test...")
print("📂 Reading CSV: \(csvPath)")

let rows = parseCSV(at: csvPath)
print("📊 Found \(rows.count) rows.")

var passed = 0
var failed = 0
var skipped = 0

let semaphore = DispatchSemaphore(value: 0)

// Loop through rows
for (index, row) in rows.enumerated() {
    if index >= outputLimit { break }
    
    let email = row["Email"] ?? ""
    let name = row["Name"] ?? ""
    let expectedUrl = row["URL"] ?? "N/A"
    
    // Skip if expected URL is N/A (unless we want to test negative cases)
    if expectedUrl == "N/A" {
        skipped += 1
        continue
    }
    
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
            print("❌ Request Error: \(error)")
            failed += 1
            return
        }
        
        guard let data = data else { return }
        
        do {
            let result = try JSONDecoder().decode(EnrichmentResponse.self, from: data)
            let actualUrl = result.linkedInUrl ?? "N/A"
            
            // Loose comparison (ignore tracking params, matching just the profile ID part)
            // e.g. https://www.linkedin.com/in/daveeyler vs https://www.linkedin.com/in/daveeyler/
            let cleanExpected = expectedUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let cleanActual = actualUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            
            if cleanActual == cleanExpected {
                print("✅ [PASS] \(email) -> \(actualUrl)")
                passed += 1
            } else {
                // Strict check might fail on aliases or different profile versions, but let's log it
                // Also check if we found *nothing* vs *something wrong*
                if actualUrl == "N/A" {
                     print("❌ [FAIL] \(email): Expected \(expectedUrl), Got NIL")
                } else {
                     print("⚠️ [DIFF] \(email): Expected \(expectedUrl), Got \(actualUrl)")
                }
                failed += 1
            }
            
        } catch {
            print("❌ Decoder Error: \(error) - Body: \(String(data: data, encoding: .utf8) ?? "?")")
            failed += 1
        }
    }
    
    task.resume()
    semaphore.wait()
    
    // Rate limit kindness
    Thread.sleep(forTimeInterval: 0.1)
}

print("\n--- Summary ---")
print("✅ Passed: \(passed)")
print("❌ Failed: \(failed)")
print("⏭️ Skipped: \(skipped)")
print("Total Checked: \(passed + failed)")
