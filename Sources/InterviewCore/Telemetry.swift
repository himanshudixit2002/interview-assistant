import Foundation

/// Operational event with no content: names, categories, timings, counters and hashes only (plan §14.4).
public struct TelemetryEvent: Codable, Sendable, Equatable {
    public var time: Date
    public var name: String
    public var category: String
    public var durationMs: Double?
    public var attributes: [String: String]
    public init(name: String, category: String, durationMs: Double? = nil, attributes: [String: String] = [:], time: Date = Date()) {
        self.time = time; self.name = name; self.category = category; self.durationMs = durationMs; self.attributes = attributes
    }
}

public protocol TelemetrySink: AnyObject, Sendable {
    func record(_ event: TelemetryEvent)
}

public final class InMemoryTelemetry: TelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TelemetryEvent] = []
    public init() {}
    public func record(_ event: TelemetryEvent) { lock.lock(); storage.append(event); lock.unlock() }
    public var events: [TelemetryEvent] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// JSON-lines file sink with day-based rotation. Attribute values are redacted if they look like content.
public final class FileTelemetrySink: TelemetrySink, @unchecked Sendable {
    private let directory: URL
    private let retentionDays: Int
    private let lock = NSLock()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    public init(directory: URL, retentionDays: Int = 14) {
        self.directory = directory
        self.retentionDays = retentionDays
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        pruneOldFiles()
    }

    public func record(_ event: TelemetryEvent) {
        var safe = event
        safe.attributes = event.attributes.mapValues { $0.count > 120 ? "<redacted:\($0.count)>" : $0 }
        guard let data = try? encoder.encode(safe) else { return }
        let day = ISO8601DateFormatter.dayString(event.time)
        let url = directory.appendingPathComponent("telemetry-\(day).jsonl")
        lock.lock(); defer { lock.unlock() }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); handle.write("\n".data(using: .utf8)!); try? handle.close()
        } else {
            try? (data + "\n".data(using: .utf8)!).write(to: url)
        }
    }

    public func pruneOldFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for f in files where f.lastPathComponent.hasPrefix("telemetry-") {
            if let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }
}

extension ISO8601DateFormatter {
    static func dayString(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
