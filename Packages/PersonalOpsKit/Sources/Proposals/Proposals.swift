import Foundation
import Core

/// # Proposals module (the "propose, don't auto-act" execution layer)
///
/// Phase 4A fills this in: the typed Proposal state machine, per-type execution handlers,
/// confirmation copy, and the Ops Inbox. Phase 5's tool registry and Phase 3A's schedule
/// previews all map to the same contract (AGENT_DESIGN §3).
///
/// The closed proposal vocabulary (`ProposalType`, `ProposalStatus`) lives in `Core`
/// (`Core/Vocabulary.swift`) so the persistence layer's `Proposal` model can store it
/// without a dependency cycle — Phase 1 relocated it there from this file (a move, not a
/// redefinition). Reference those types via `import Core`.
public enum ProposalsModule {}
