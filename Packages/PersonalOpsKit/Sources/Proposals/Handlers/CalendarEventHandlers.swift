import Foundation
import Core
import Data
import Integrations

/// Creates one agent-owned calendar event via Phase 2's **idempotent** write path. The
/// caller-provided `idempotencyKey` (seeded from a stable `GoalTask.appID`) means approving
/// the same proposal twice — or a re-derived duplicate — yields exactly one event. Writes go
/// only to the agent calendar (Safety Rule #2); the DTO is stamped with the resolved agent
/// calendar ID and `isAgentOwned = true`.
public struct CreateAgentCalendarEventHandler: ProposalHandler {
    public let handledType: ProposalType = .createAgentCalendarEvent
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(CreateAgentCalendarEventPayload.self,
                                                      from: proposal.payload)
        guard let calendar = context.calendar else { throw ProposalError.integrationUnavailable }

        let calendarID = try await calendar.ensureAgentCalendar()
        let dto = CalendarEventDTO(
            id: payload.idempotencyKey,      // deterministic ID → idempotent create
            calendarID: calendarID,
            title: payload.title,
            start: payload.start,
            end: payload.end,
            isAgentOwned: true)

        let created = try await calendar.createEvent(dto, idempotencyKey: payload.idempotencyKey)
        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Scheduled \"\(payload.title)\" on the agent calendar",
                                createdEventID: created.id)
    }
}

/// Updates one existing agent-owned event. The underlying client rejects any write whose
/// `calendarID` is not the agent calendar (Safety Rule #2) — the handler never targets a real
/// calendar.
public struct UpdateAgentCalendarEventHandler: ProposalHandler {
    public let handledType: ProposalType = .updateAgentCalendarEvent
    public init() {}

    public func execute(_ proposal: Proposal, grant: ApprovalGrant,
                        context: HandlerContext) async throws -> ExecutionReceipt {
        let payload = try ProposalPayloadCoder.decode(UpdateAgentCalendarEventPayload.self,
                                                      from: proposal.payload)
        guard let calendar = context.calendar else { throw ProposalError.integrationUnavailable }

        let dto = CalendarEventDTO(
            id: payload.eventID,
            calendarID: payload.calendarID,
            title: payload.title,
            start: payload.start,
            end: payload.end,
            isAgentOwned: true)

        let updated = try await calendar.updateEvent(dto)
        return ExecutionReceipt(proposalAppID: proposal.appID, type: handledType,
                                summary: "Updated \"\(payload.title)\"",
                                createdEventID: updated.id)
    }
}
