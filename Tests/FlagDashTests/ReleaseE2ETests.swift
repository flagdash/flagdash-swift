import Foundation
import XCTest
@testable import FlagDash

final class ReleaseE2ETests: XCTestCase {
 func testLiveReleases() async throws {
  guard let path = ProcessInfo.processInfo.environment["FLAGDASH_RELEASE_CASES"] else { throw XCTSkip("Run through make e2e for a live server") }
  let cases = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  var results: [[String: JSONValue]?] = []
  for item in cases {
   let client = FlagDashClient(sdkKey: item["sdk_key"]!, baseURL: URL(string: item["base_url"]!)!)
   results.append(await client.aiConfigRelease(item["key"]!, userID: item["user_id"]!))
  }
  try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLAGDASH_RELEASE_OUTPUT"]!))
 }
}
