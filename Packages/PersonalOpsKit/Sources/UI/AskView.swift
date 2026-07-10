import SwiftUI
import SwiftData
import Core
import Integrations
import Agent

/// # Ask tab — free-form Q&A over memory (Phase 5)
///
/// A simple chat surface over the bounded tool-calling loop (`QAOrchestrator`). The user types a
/// question; the agent searches memory/goals/calendar/etc. via read tools and answers, and any
/// state-changing request becomes a pending Proposal in the Ops Inbox — never a direct action.
/// Phase 6 wraps this exact seam in voice (STT in, TTS out).
///
/// Degrades honestly: with no `GEMINI_API_KEY` configured, the agent is unavailable and the view
/// says so plainly instead of failing.
public struct AskView: View {
    private let agent: AgentEnvironment
    private let integrations: IntegrationsEnvironment

    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthKitSource) private var healthSource

    @State private var input: String = ""
    @State private var turns: [AskTurn] = []
    @State private var isThinking = false

    public init(agent: AgentEnvironment, integrations: IntegrationsEnvironment) {
        self.agent = agent
        self.integrations = integrations
    }

    public var body: some View {
        VStack(spacing: 0) {
            if agent.isAvailable {
                transcript
                composer
            } else {
                unavailable
            }
        }
        .navigationTitle("Ask")
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if turns.isEmpty {
                    Text("Ask about your goals, schedule, or anything in your memory. I can only propose changes — you approve them in the Ops Inbox.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                ForEach(turns) { turn in
                    AskBubble(turn: turn)
                }
                if isThinking {
                    Label("Thinking…", systemImage: "ellipsis.bubble")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isThinking)
        }
        .padding()
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label("Assistant unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text("Add your Gemini API key to Secrets/Config.local (GEMINI_API_KEY) to enable Ask.")
        }
    }

    private func send() {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isThinking else { return }
        guard let orchestrator = agent.qaOrchestrator(
            context: modelContext,
            calendar: integrations.calendar,
            gmail: integrations.gmail,
            health: healthSource) else { return }

        input = ""
        turns.append(AskTurn(role: .user, text: question))
        isThinking = true

        Task {
            let answer: String
            do {
                let result = try await orchestrator.answer(question: question)
                answer = result.answer.isEmpty ? "I don't have an answer for that." : result.answer
            } catch {
                answer = "The assistant is temporarily unavailable. Please try again."
            }
            turns.append(AskTurn(role: .assistant, text: answer))
            isThinking = false
        }
    }
}

struct AskTurn: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

private struct AskBubble: View {
    let turn: AskTurn

    var body: some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 40) }
            Text(turn.text)
                .padding(10)
                .background(turn.role == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
