import XCTest
@testable import Core

final class ModelCallAuditTests: XCTestCase {

    func test_recordCarriesRequiredAuditFields() {
        let ts = Date(timeIntervalSince1970: 42)
        let audit = ModelCallAudit(
            timestamp: ts,
            purpose: .morningBriefing,
            inputCategories: [.calendar, .goals],
            provider: "gemini-flash",
            includedRawExternalContent: false,
            toolCallsRequested: [],
            roundCount: 1
        )
        XCTAssertEqual(audit.timestamp, ts)
        XCTAssertEqual(audit.purpose, .morningBriefing)
        XCTAssertEqual(audit.inputCategories, [.calendar, .goals])
        XCTAssertEqual(audit.provider, "gemini-flash")
        XCTAssertFalse(audit.includedRawExternalContent)
    }

    func test_isCodable_andEncodesNoTokenField() throws {
        let audit = ModelCallAudit(
            timestamp: Date(timeIntervalSince1970: 0),
            purpose: .qanda,
            inputCategories: [.memory],
            provider: "gemini-flash",
            includedRawExternalContent: true,
            toolCallsRequested: ["search_memory"],
            roundCount: 3
        )
        let data = try JSONEncoder().encode(audit)
        let json = String(decoding: data, as: UTF8.self).lowercased()
        // Schema must never carry token/header/prompt payload fields.
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("authorization"))
        XCTAssertFalse(json.contains("header"))
        let decoded = try JSONDecoder().decode(ModelCallAudit.self, from: data)
        XCTAssertEqual(decoded, audit)
    }
}
