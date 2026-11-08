import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import ShadeCore

final class ClaudeClientTests: XCTestCase {
    let request = MessagesRequest(model: "claude-opus-5-5", system: "spec", messages: [.user([ClaudeMessage.text("hi")])],
                                  effort: "high", fallbacks: "default")

    func client(_ transport: StubTransport, sleeps: SleepRecorder = SleepRecorder(), attempts: Int = 3) throws -> ClaudeClient {
        try ClaudeClient(apiKey: "sk-ant-test", transport: transport, retry: RetryPolicy(maxAttempts: attempts), sleep: sleeps.sleep)
    }

    func testSendsTheDocumentedRequestShape() async throws {
        let transport = StubTransport([.http(200, messagesBody(text: "ok"), [:])])
        _ = try await client(transport).send(request)
        let sent = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(sent.url, ClaudeClient.endpoint)
        XCTAssertEqual(sent.httpMethod, "POST")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-version"), ClaudeClient.apiVersion)
        XCTAssertEqual(sent.value(forHTTPHeaderField: "anthropic-beta"), ClaudeClient.fallbackBeta)
        XCTAssertNil(sent.url?.query, "nothing secret in the URL")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 16_000)
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        let system = try XCTUnwrap((body["system"] as? [[String: Any]])?.first)
        XCTAssertEqual((system["cache_control"] as? [String: Any])?["type"] as? String, "ephemeral")
        XCTAssertNil(body["temperature"], "sampling params are rejected by current models")
    }

    func testNoBetaHeaderWithoutFallbacks() async throws {
        let transport = StubTransport([.http(200, messagesBody(text: "ok"), [:])])
        var plain = request
        plain.fallbacks = nil
        _ = try await client(transport).send(plain)
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testThinkingBlocksAreReplayedUnchanged() async throws {
        let thinking = #"{"type":"thinking","thinking":"","signature":"sig-abc"}"#
        let transport = StubTransport([.http(200, messagesBody(text: "answer", extraBlocks: [thinking]), [:])])
        let response = try await client(transport).send(request)
        XCTAssertEqual(response.text, "answer")
        XCTAssertEqual(response.asAssistantMessage.content.count, 2)
        XCTAssertEqual(response.asAssistantMessage.content[0]["signature"]?.stringValue, "sig-abc")
    }

    func testRetriesRateLimitsHonouringRetryAfter() async throws {
        let sleeps = SleepRecorder()
        let transport = StubTransport([
            .http(429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#, ["retry-after": "7"]),
            .http(200, messagesBody(text: "ok"), [:])
        ])
        let response = try await client(transport, sleeps: sleeps).send(request)
        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(transport.callCount, 2)
        XCTAssertEqual(sleeps.delays.count, 1)
        XCTAssertGreaterThanOrEqual(sleeps.delays[0], 7)
    }

    func testGivesUpAfterMaxAttemptsWithTheLastError() async throws {
        let sleeps = SleepRecorder()
        let overloaded = StubTransport.Reply.http(529, #"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#, [:])
        let transport = StubTransport([overloaded, overloaded, overloaded, .http(200, messagesBody(text: "never"), [:])])
        let c = try client(transport, sleeps: sleeps)
        await assertShadeErrorAsync(.claudeOverloaded) { try await c.send(self.request) }
        XCTAssertEqual(transport.callCount, 3)
        XCTAssertEqual(sleeps.delays.count, 2)
    }

    func testClientErrorsAreNotRetried() async throws {
        for (status, code) in [(401, ShadeError.Code.claudeUnauthorized), (400, .claudeBadRequest), (403, .claudeForbidden), (413, .claudeRequestTooLarge)] {
            let transport = StubTransport([.http(status, #"{"type":"error","error":{"type":"x","message":"nope"}}"#, ["request-id": "req_1"])])
            let c = try client(transport)
            await assertShadeErrorAsync(code) { try await c.send(self.request) }
            XCTAssertEqual(transport.callCount, 1, "HTTP \(status) must not be retried")
        }
    }

    func testNetworkTimeoutsAreRetried() async throws {
        let transport = StubTransport([.failure(URLError(.timedOut)), .http(200, messagesBody(text: "ok"), [:])])
        let response = try await client(transport).send(request)
        XCTAssertEqual(response.text, "ok")
        XCTAssertEqual(transport.callCount, 2)
    }

    func testOfflineFailsWithANetworkError() async throws {
        let transport = StubTransport(Array(repeating: .failure(URLError(.notConnectedToInternet)), count: 3))
        let c = try client(transport)
        await assertShadeErrorAsync(.networkUnavailable) { try await c.send(self.request) }
    }

    func testRefusalsSurfaceTheExplanation() async throws {
        let body = #"{"id":"m","content":[],"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"Not allowed."}}"#
        let c = try client(StubTransport([.http(200, body, [:])]))
        do {
            _ = try await c.send(request)
            XCTFail("expected refusal")
        } catch let error as ShadeError {
            XCTAssertEqual(error.code, .claudeRefused)
            XCTAssertTrue(error.message.contains("Not allowed."))
        }
    }

    func testUnreadableResponseBody() async throws {
        let c = try client(StubTransport([.http(200, "<html>proxy error</html>", [:])]))
        await assertShadeErrorAsync(.claudeBadResponse) { try await c.send(self.request) }
    }

    func testAPIKeyValidation() {
        XCTAssertShadeError(.claudeMissingKey) { try ClaudeClient.validatedKey("   ") }
        XCTAssertShadeError(.claudeInvalidKey) { try ClaudeClient.validatedKey("sk-ant\r\nX-Evil: 1") }
        XCTAssertShadeError(.claudeInvalidKey) { try ClaudeClient.validatedKey("sk ant") }
        XCTAssertEqual(try ClaudeClient.validatedKey("  sk-ant-abc123\n"), "sk-ant-abc123")
    }
}

final class RetryPolicyTests: XCTestCase {
    func testBackoffGrowsAndIsCapped() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 10)
        XCTAssertEqual(policy.delay(afterAttempt: 1, retryAfter: nil, random: { _ in 1 }), 1)
        XCTAssertEqual(policy.delay(afterAttempt: 3, retryAfter: nil, random: { _ in 1 }), 4)
        XCTAssertEqual(policy.delay(afterAttempt: 9, retryAfter: nil, random: { _ in 1 }), 10)
        XCTAssertEqual(policy.delay(afterAttempt: 2, retryAfter: nil, random: { _ in 0 }), 0.1, "never a zero-delay hot loop")
    }

    func testRetryAfterWinsButIsCapped() {
        let policy = RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 30)
        XCTAssertEqual(policy.delay(afterAttempt: 1, retryAfter: 12, random: { _ in 0.5 }), 12)
        XCTAssertEqual(policy.delay(afterAttempt: 1, retryAfter: 3600, random: { _ in 0.5 }), 30)
    }

    func testRetryableStatuses() {
        XCTAssertTrue([408, 429, 500, 502, 503, 504, 529].allSatisfy(RetryPolicy.isRetryable))
        XCTAssertFalse([400, 401, 403, 404, 413, 422].contains(where: RetryPolicy.isRetryable))
    }
}
