import Foundation
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
}
