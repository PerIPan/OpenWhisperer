import Foundation
import OpenWhispererKit

/// `--mcp-stdio`: a thin stdio⇄HTTP bridge for MCP clients that can only launch stdio
/// servers (Claude Desktop). Each newline-delimited JSON-RPC frame from stdin is forwarded
/// to the running menubar app's `POST /mcp`, so synthesis and playback happen there; the
/// response body is written back to stdout. If the app isn't running, requests get a
/// JSON-RPC error (MCPBridge) and notifications are dropped, per JSON-RPC.
enum MCPStdioMode {
    static func run() {
        let port = ProcessInfo.processInfo.environment["TTS_PORT"].flatMap { UInt16($0) } ?? 8000
        let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
        let out = FileHandle.standardOutput

        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let body = Data(line.utf8)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            request.timeoutInterval = 120  // speak synthesis on a cold model can be slow

            let done = DispatchSemaphore(value: 0)
            var reply: Data?
            URLSession.shared.dataTask(with: request) { data, response, _ in
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let data, !data.isEmpty {
                    reply = data
                }
                // 202 (notification ack) and errors both leave reply nil.
                done.signal()
            }.resume()
            done.wait()

            if let frame = reply ?? MCPBridge.transportFailureResponse(for: body) {
                out.write(frame)
                out.write(Data("\n".utf8))
            }
        }
    }
}
