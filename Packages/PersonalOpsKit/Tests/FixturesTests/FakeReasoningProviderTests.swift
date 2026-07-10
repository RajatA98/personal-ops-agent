import XCTest
import Core
import Reasoning
@testable import Fixtures

final class FakeReasoningProviderTests: XCTestCase {

    func test_returnsScriptedResponseDeterministically() async throws {
        let provider = FakeReasoningProvider(scriptedText: "canned narrative")
        let req = ReasoningRequest(purpose: .morningBriefing,
                                   messages: [ReasoningMessage(role: .user, content: "brief me")])
        let a = try await provider.complete(req)
        let b = try await provider.complete(req)
        XCTAssertEqual(a.text, "canned narrative")
        XCTAssertEqual(a.text, b.text) // deterministic
    }

    func test_recordsCallsForAssertion() async throws {
        let provider = FakeReasoningProvider(scriptedText: "ok")
        _ = try await provider.complete(
            ReasoningRequest(purpose: .qanda, messages: []))
        XCTAssertEqual(provider.recordedRequests.count, 1)
        XCTAssertEqual(provider.recordedRequests.first?.purpose, .qanda)
    }

    func test_conformsToReasoningProvider() {
        let _: any ReasoningProvider = FakeReasoningProvider(scriptedText: "x")
    }
}
