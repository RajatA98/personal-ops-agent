import XCTest
@testable import Reasoning

final class PromptLibraryTests: XCTestCase {

    func test_allPromptsLoadWithVersionHeaderStripped() {
        for prompt in PromptLibrary.Prompt.allCases {
            let loaded = PromptLibrary.load(prompt)
            XCTAssertFalse(loaded.body.isEmpty, "\(prompt.rawValue) body empty")
            XCTAssertFalse(loaded.body.hasPrefix("PROMPT_VERSION"), "version header not stripped")
            XCTAssertEqual(loaded.version, prompt.rawValue)
        }
    }

    func test_sharedPreamble_statesProposeDontActAndHonesty() {
        let body = PromptLibrary.load(.sharedPreamble).body.lowercased()
        XCTAssertTrue(body.contains("propose"))
        XCTAssertTrue(body.contains("i don't know"))
    }

    func test_deterministicFlowPrompts_containGroundingRule() {
        for flow in [PromptLibrary.Prompt.morningBriefing, .weeklyReview] {
            let body = PromptLibrary.load(flow).body.lowercased()
            XCTAssertTrue(body.contains("grounding"), "\(flow.rawValue) missing grounding rule")
            XCTAssertTrue(body.contains("only") && body.contains("provided"),
                          "\(flow.rawValue) grounding rule weak")
        }
    }

    func test_parse_handlesMissingHeaderGracefully() {
        let loaded = PromptLibrary.parse("just body text", fallbackVersion: "x")
        XCTAssertEqual(loaded.version, "x")
        XCTAssertEqual(loaded.body, "just body text")
    }
}
