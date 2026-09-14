import Foundation

enum Diagnostics {
    private static let started = ProcessInfo.processInfo.systemUptime
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--diagnostics")

    static func emit(_ event: String, since: TimeInterval? = nil, details: [String: Any] = [:]) {
        guard enabled else { return }
        let origin = since ?? started
        let elapsed = max(0, (ProcessInfo.processInfo.systemUptime - origin) * 1_000)
        var data: [String: Any] = details
        data["event"] = event; data["elapsed_ms"] = elapsed; data["pid"] = ProcessInfo.processInfo.processIdentifier
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
           let json = String(data: encoded, encoding: .utf8) {
            FileHandle.standardError.write(Data("FROG_DIAGNOSTIC \(json)\n".utf8))
        }
    }
}
