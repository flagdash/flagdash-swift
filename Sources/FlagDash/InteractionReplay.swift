import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Explicit privacy-safe interaction timeline. It never captures pixels or native view trees.
public actor InteractionReplay {
    private let sdkKey: String
    private let baseURL: URL
    private let identity: String?
    private let release: String?
    private let metadata: [String: JSONValue]
    private let transport: any FlagDashTransport
    private let startedAt = Date()
    private var replayID: String?
    private var sequence = 0
    private var events: [[String: JSONValue]] = []
    private var lifecycleObservers: [NSObjectProtocol] = []

    public init(sdkKey: String, baseURL: URL = URL(string: "https://flagdash.io")!, identity: String? = nil,
                release: String? = nil, metadata: [String: JSONValue] = [:],
                transport: any FlagDashTransport = URLSessionTransport()) {
        precondition(!sdkKey.isEmpty, "sdkKey is required")
        self.sdkKey = sdkKey; self.baseURL = baseURL; self.identity = identity; self.release = release
        self.metadata = Self.sanitize(metadata); self.transport = transport
    }

    public func start() async -> Bool {
        let payload: [String: JSONValue] = ["type": .string("interaction"), "platform": .string("ios"),
            "sdk_name": .string("flagdash-swift"), "started_at": .string(Self.timestamp(startedAt)),
            "identity": identity.map(JSONValue.string) ?? .null, "release": release.map(JSONValue.string) ?? .null,
            "metadata": .object(metadata)]
        do {
            let (data, response) = try await api("/api/v1/replay-sessions/start", payload)
            if response.statusCode == 204 { return false }
            guard (200...299).contains(response.statusCode), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String else { return false }
            replayID = id; return true
        } catch { return false }
    }

    public func interaction(_ name: String, screen: String? = nil, category: String = "action",
                            properties: [String: JSONValue] = [:]) {
        guard replayID != nil, !name.isEmpty, events.count < 1_000 else { return }
        events.append(["name": .string(String(name.prefix(100))), "category": .string(String(category.prefix(40))),
            "timestamp": .string(Self.timestamp(Date())), "screen": screen.map { .string(String($0.prefix(200))) } ?? .null,
            "properties": .object(Self.sanitize(properties))])
    }
    public func screen(_ name: String, properties: [String: JSONValue] = [:]) { interaction("screen_viewed", screen: name, category: "navigation", properties: properties) }
    public func breadcrumb(_ message: String, properties: [String: JSONValue] = [:]) { interaction(message, category: "breadcrumb", properties: properties) }
    public func captureException(_ error: Error, properties: [String: JSONValue] = [:]) { interaction(String(describing: type(of: error)), category: "exception", properties: properties) }
    public func contextHeaders() -> [String: String] { replayID.map { ["x-flagdash-replay-id": $0] } ?? [:] }

    /// Observe iOS background transitions and flush pending interactions. Calling it more than once is harmless.
    public func observeLifecycle() {
        #if canImport(UIKit)
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                Task { _ = await self.flush() }
            })
        }
        #endif
    }

    public func flush() async -> Bool {
        guard let id = replayID else { return true }
        while !events.isEmpty {
            let batch = Array(events.prefix(100)); events.removeFirst(batch.count)
            guard let raw = try? JSONEncoder().encode(batch) else { return false }
            let payload: [String: JSONValue] = ["sequence": .number(Double(sequence)), "byte_size": .number(Double(raw.count)),
                "event_count": .number(Double(batch.count)), "content_encoding": .string("identity")]
            sequence += 1
            do {
                let (data, response) = try await api("/api/v1/replay-sessions/\(id)/chunks/presign", payload)
                guard (200...299).contains(response.statusCode),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let upload = root["upload"] as? [String: Any], let rawURL = upload["url"] as? String,
                      let url = URL(string: rawURL) else { return false }
                var request = URLRequest(url: url); request.httpMethod = "PUT"; request.httpBody = raw
                (upload["headers"] as? [String: String])?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
                let (_, uploaded) = try await transport.send(request)
                guard (200...299).contains(uploaded.statusCode) else { return false }
            } catch { return false }
        }
        return true
    }

    public func stop() async -> Bool {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        guard await flush() else { return false }
        guard let id = replayID else { return true }
        let payload: [String: JSONValue] = ["ended_at": .string(Self.timestamp(Date())),
            "duration_ms": .number(max(0, Date().timeIntervalSince(startedAt) * 1_000))]
        do { let (_, response) = try await api("/api/v1/replay-sessions/\(id)/complete", payload); return (200...299).contains(response.statusCode) }
        catch { return false }
    }

    private func api(_ path: String, _ payload: [String: JSONValue]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1\(path)")); request.httpMethod = "POST"
        request.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        return try await transport.send(request)
    }

    private static let sensitive = try! NSRegularExpression(pattern: "pass(word)?|secret|token|authorization|cookie|session|api[-_]?key|credit|card|cvv|cvc|otp|ssn", options: .caseInsensitive)
    private static func sanitize(_ values: [String: JSONValue], depth: Int = 0) -> [String: JSONValue] {
        if depth > 8 { return [:] }
        return Dictionary(uniqueKeysWithValues: values.prefix(500).map { key, value in
            let range = NSRange(key.startIndex..., in: key)
            return (key, sensitive.firstMatch(in: key, range: range) == nil ? sanitize(value, depth: depth + 1) : .string("[REDACTED]"))
        })
    }
    private static func sanitize(_ value: JSONValue, depth: Int) -> JSONValue {
        if depth > 8 { return .string("[REDACTED]") }
        switch value {
        case .string(let text): return .string(String(text.prefix(2_000)))
        case .object(let object): return .object(sanitize(object, depth: depth))
        case .array(let array): return .array(array.prefix(500).map { sanitize($0, depth: depth + 1) })
        default: return value
        }
    }
    private static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
