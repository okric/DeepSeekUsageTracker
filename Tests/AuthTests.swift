import Foundation
import XCTest
@testable import DeepseekUsageTracker

final class AuthTests: XCTestCase {
    func testRFC7636PKCEVector() {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            PKCE.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testAllowedBrowserDestinations() {
        XCTAssertTrue(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "https://platform.deepseek.com/dsh/authorize?authorize_id=abc")!))
        XCTAssertTrue(DeepSeekAuth.isAllowedCompletionURL(
            URL(string: "https://platform.deepseek.com/dsh/authorized?login_source=desktop")!))

        XCTAssertFalse(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "https://evil.example/dsh/authorize")!))
        XCTAssertFalse(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "http://platform.deepseek.com/dsh/authorize")!))
        XCTAssertFalse(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "https://platform.deepseek.com/other")!))
        XCTAssertFalse(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "https://platform.deepseek.com/dsh/authorize#fragment")!))
        XCTAssertFalse(DeepSeekAuth.isAllowedAuthorizeURL(
            URL(string: "https://platform.deepseek.com:8443/dsh/authorize")!))
    }

    func testCallbackServerReceivesMatchingState() async throws {
        let server = OAuthCallbackServer(state: "state-123")
        let port = try server.start()
        defer { server.stop() }

        async let received = server.waitForCode(timeout: 5)

        var request = URLRequest(url: URL(
            string: "http://127.0.0.1:\(port)/oauth/callback?code=code-abc&state=state-123")!)
        request.timeoutInterval = 5
        let responseTask = Task {
            try await URLSession.shared.data(for: request)
        }

        let code = try await received
        XCTAssertEqual(code, "code-abc")
        server.respond(redirectURL: nil)

        let (_, response) = try await responseTask.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
