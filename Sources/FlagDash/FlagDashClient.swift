import Foundation

public struct EvaluationContext: Sendable {
    public var userID: String?
    public var unitID: String?
    public var attributes: [String: String]

    public init(userID: String? = nil, unitID: String? = nil, attributes: [String: String] = [:]) {
        self.userID = userID
        self.unitID = unitID
        self.attributes = attributes
    }

    var query: [URLQueryItem] {
        var values = attributes.map { URLQueryItem(name: $0.key, value: $0.value) }
        if let userID { values.append(URLQueryItem(name: "user_id", value: userID)) }
        if let unitID { values.append(URLQueryItem(name: "unit_id", value: unitID)) }
        return values
    }
}

public struct FlagDetail: Sendable, Equatable {
    public let key: String
    public let value: JSONValue
    public let reason: String
    public let variationKey: String?
}

public enum JSONValue: Sendable, Equatable, Codable {
    case bool(Bool), string(String), number(Double), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .bool(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

public protocol FlagDashTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: FlagDashTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw FlagDashError.invalidResponse }
        return (data, response)
    }
}

public enum FlagDashError: Error { case invalidURL, invalidResponse, http(Int) }

public actor FlagDashClient {
    private struct FlagsEnvelope: Decodable { let flags: [String: JSONValue] }
    private struct WireFlag: Decodable {
        let key: String
        let value: JSONValue
        let reason: String?
        let variationKey: String?
        enum CodingKeys: String, CodingKey {
            case key, value, reason, variationKey = "variation_key"
        }
    }
    private struct ConfigEnvelope: Decodable { let value: JSONValue }
    private struct ConfigsEnvelope: Decodable { let configs: [[String: JSONValue]] }
    private struct AIEnvelope: Decodable { let aiConfig: [String: JSONValue]; enum CodingKeys: String, CodingKey { case aiConfig = "ai_config" } }
    private struct AIConfigsEnvelope: Decodable { let aiConfigs: [[String: JSONValue]]; enum CodingKeys: String, CodingKey { case aiConfigs = "ai_configs" } }
    private struct CacheEntry { let value: JSONValue; let expires: TimeInterval }

    private let sdkKey: String
    private let baseURL: URL
    private let timeout: TimeInterval
    private let cacheTTL: TimeInterval
    private let region: String?
    private let transport: any FlagDashTransport
    private var cache: [String: CacheEntry] = [:]

    public init(sdkKey: String, baseURL: URL = URL(string: "https://flagdash.io")!, timeout: TimeInterval = 5,
                cacheTTL: TimeInterval = 60, region: String? = nil,
                transport: any FlagDashTransport = URLSessionTransport()) {
        precondition(!sdkKey.isEmpty, "sdkKey is required")
        self.sdkKey = sdkKey
        self.baseURL = baseURL
        self.timeout = timeout
        self.cacheTTL = cacheTTL
        self.region = region ?? Self.detectRegion()
        self.transport = transport
    }

    public func flag(_ key: String, default defaultValue: JSONValue = .bool(false), context: EvaluationContext? = nil) async -> JSONValue {
        if let context { return await flagDetail(key, default: defaultValue, context: context).value }
        if let cached = cached("flag:\(key)") { return cached }
        return await allFlags()[key] ?? defaultValue
    }

    public func flagDetail(_ key: String, default defaultValue: JSONValue = .null, context: EvaluationContext? = nil) async -> FlagDetail {
        do {
            let flag: WireFlag = try await get("/flags/\(segment(key))", context: context)
            return FlagDetail(key: flag.key, value: flag.value,
                              reason: flag.reason ?? "default", variationKey: flag.variationKey)
        } catch {
            return FlagDetail(key: key, value: defaultValue, reason: "default", variationKey: nil)
        }
    }

    public func allFlags(context: EvaluationContext? = nil) async -> [String: JSONValue] {
        do {
            let envelope: FlagsEnvelope = try await get("/flags", context: context)
            if context == nil { for (key, value) in envelope.flags { put("flag:\(key)", value) } }
            return envelope.flags
        } catch { return [:] }
    }

    public func config(_ key: String, default defaultValue: JSONValue = .null) async -> JSONValue {
        if let cached = cached("config:\(key)") { return cached }
        do {
            let envelope: ConfigEnvelope = try await get("/configs/\(segment(key))")
            let value = envelope.value
            put("config:\(key)", value)
            return value
        } catch { return defaultValue }
    }

    public func listConfigs() async -> [[String: JSONValue]] {
        do {
            let envelope: ConfigsEnvelope = try await get("/configs")
            return envelope.configs
        }
        catch { return [] }
    }

    public func aiConfig(_ fileName: String) async -> [String: JSONValue]? {
        do { let envelope: AIEnvelope = try await get("/ai-configs/\(segment(fileName))"); return envelope.aiConfig }
        catch { return nil }
    }

    public func listAIConfigs() async -> [[String: JSONValue]] {
        do {
            let envelope: AIConfigsEnvelope = try await get("/ai-configs")
            return envelope.aiConfigs
        }
        catch { return [] }
    }

    public func clearCache() { cache.removeAll() }

    private func get<T: Decodable>(_ path: String, context: EvaluationContext? = nil) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1\(path)"), resolvingAgainstBaseURL: false)
        var query = context?.query ?? []
        if let region { query.append(URLQueryItem(name: "region", value: region)) }
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw FlagDashError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer \(sdkKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200...299).contains(response.statusCode) else { throw FlagDashError.http(response.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func cached(_ key: String) -> JSONValue? {
        guard let entry = cache[key], entry.expires > ProcessInfo.processInfo.systemUptime else { cache.removeValue(forKey: key); return nil }
        return entry.value
    }
    private func put(_ key: String, _ value: JSONValue) { cache[key] = CacheEntry(value: value, expires: ProcessInfo.processInfo.systemUptime + cacheTTL) }
    private func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value }
    private static func detectRegion() -> String? {
        ["FLAGDASH_REGION", "FLY_REGION", "AWS_REGION", "AWS_DEFAULT_REGION", "VERCEL_REGION", "GOOGLE_CLOUD_REGION", "RAILWAY_REPLICA_REGION", "RENDER_REGION"]
            .compactMap { ProcessInfo.processInfo.environment[$0] }.first
    }
}
