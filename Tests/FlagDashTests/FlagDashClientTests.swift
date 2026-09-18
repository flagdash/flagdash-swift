import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import FlagDash

private struct MockTransport: FlagDashTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: String
        switch request.url!.path {
        case "/api/v1/flags": body = #"{"flags":{"checkout":true,"theme":"violet"}}"#
        case "/api/v1/flags/checkout": body = #"{"key":"checkout","value":true,"reason":"rule_match","variation_key":"on"}"#
        case "/api/v1/configs/theme": body = #"{"key":"theme","value":"violet"}"#
        case "/api/v1/configs": body = #"{"configs":[{"key":"theme","value":"violet"}]}"#
        case "/api/v1/ai-configs/agent.md": body = #"{"ai_config":{"file_name":"agent.md","content":"Be useful"}}"#
        case "/api/v1/ai-configs": body = #"{"ai_configs":[{"file_name":"agent.md","content":"Be useful"}]}"#
        default: body = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}

final class FlagDashClientTests: XCTestCase {
    func testReadsTypedResources() async {
        let client = FlagDashClient(sdkKey: "sk_test", baseURL: URL(string: "https://example.test")!, region: "eu", transport: MockTransport())
        let flag = await client.flag("checkout")
        let detail = await client.flagDetail("checkout", context: EvaluationContext(userID: "alice"))
        let config = await client.config("theme")
        let aiConfig = await client.aiConfig("agent.md")
        let configs = await client.listConfigs()
        let aiConfigs = await client.listAIConfigs()
        XCTAssertEqual(flag, .bool(true))
        XCTAssertEqual(detail.reason, "rule_match")
        XCTAssertEqual(config, .string("violet"))
        XCTAssertEqual(aiConfig?["content"], .string("Be useful"))
        XCTAssertEqual(configs.first?["value"], .string("violet"))
        XCTAssertEqual(aiConfigs.first?["file_name"], .string("agent.md"))
    }

    func testInteractionReplayUploadsRedactedTimeline() async {
        let transport = ReplayMockTransport()
        let replay = InteractionReplay(sdkKey: "sk_test", baseURL: URL(string: "https://example.test")!, transport: transport)
        let started = await replay.start()
        XCTAssertTrue(started)
        await replay.interaction("checkout_tapped", screen: "Checkout", properties: ["password": .string("hidden"), "item": .string("book")])
        let headers = await replay.contextHeaders()
        XCTAssertEqual(headers["x-flagdash-replay-id"], "rpl_swift")
        let stopped = await replay.stop()
        XCTAssertTrue(stopped)
        let uploaded = await transport.uploadedBody()
        XCTAssertTrue(String(data: uploaded, encoding: .utf8)!.contains("checkout_tapped"))
        XCTAssertFalse(String(data: uploaded, encoding: .utf8)!.contains("hidden"))
    }
}

private actor ReplayStore {
    var upload = Data()
    func set(_ data: Data) { upload = data }
}

private struct ReplayMockTransport: FlagDashTransport {
    private let store = ReplayStore()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let body: String
        let status: Int
        if path.hasSuffix("/replay-sessions/start") { body = #"{"id":"rpl_swift"}"#; status = 201 }
        else if path.hasSuffix("/chunks/presign") { body = #"{"upload":{"url":"https://storage.test/upload","headers":{}}}"#; status = 200 }
        else if path == "/upload" { await store.set(request.httpBody ?? Data()); body = "{}"; status = 200 }
        else { body = "{}"; status = 200 }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func uploadedBody() async -> Data { await store.upload }
}
