import SwiftUI
import SwiftData
import Core
import Integrations
import Agent
import Voice

/// # Ask tab — free-form Q&A over memory (Phase 5), now with voice (Phase 6)
///
/// A chat surface over the bounded tool-calling loop (`QAOrchestrator`). Type a question, or tap
/// the mic to **speak** it: the same loop answers and (Phase 6) speaks the answer back through
/// the interruptible TTS router. A low-confidence transcript must be confirmed before it reaches
/// the model; playback can be interrupted at any time. Any state-changing request becomes a
/// pending Proposal in the Ops Inbox — never a direct action.
///
/// Degrades honestly: with no `GEMINI_API_KEY` the agent is unavailable and the view says so.
public struct AskView: View {
    private let agent: AgentEnvironment
    private let integrations: IntegrationsEnvironment
    private let voice: VoiceEnvironment?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.healthKitSource) private var healthSource

    @State private var input: String = ""
    @State private var turns: [AskTurn] = []
    @State private var isThinking = false
    @State private var voiceController: VoiceConversationController?

    public init(agent: AgentEnvironment,
                integrations: IntegrationsEnvironment,
                voice: VoiceEnvironment? = nil) {
        self.agent = agent
        self.integrations = integrations
        self.voice = voice
    }

    public var body: some View {
        VStack(spacing: 0) {
            if agent.isAvailable {
                transcript
                if let voiceController { VoiceStatusBar(controller: voiceController) }
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
                    Text("Ask about your goals, schedule, or anything in your memory — by typing or tapping the mic. I can only propose changes — you approve them in the Ops Inbox.")
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
            if voice != nil {
                Button(action: startVoiceTurn) {
                    Image(systemName: "mic.circle.fill").font(.title2)
                }
                .disabled(isThinking || voiceBusy)
                .accessibilityLabel("Ask by voice")
            }
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

    private var voiceBusy: Bool {
        guard let voiceController else { return false }
        return voiceController.state != .idle
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

    /// Build (once) a voice controller over a fresh orchestrator and run one push-to-talk turn.
    private func startVoiceTurn() {
        guard let voice,
              let orchestrator = agent.qaOrchestrator(
                context: modelContext,
                calendar: integrations.calendar,
                gmail: integrations.gmail,
                health: healthSource) else { return }
        let controller = voiceController ?? voice.conversationController(orchestrator: orchestrator)
        voiceController = controller
        let before = controller.turns.count
        Task {
            await controller.takeTurn()
            // Mirror any newly-spoken turns into the text transcript for a unified history.
            let new = controller.turns.dropFirst(before)
            for t in new {
                turns.append(AskTurn(role: t.role == .user ? .user : .assistant, text: t.text))
            }
        }
    }
}

/// A compact status/control strip for an in-progress voice turn: shows the current phase, a
/// confirm/discard prompt for low-confidence transcripts, and an interrupt button during
/// playback.
private struct VoiceStatusBar: View {
    let controller: VoiceConversationController

    var body: some View {
        Group {
            switch controller.state {
            case .idle:
                EmptyView()
            case .listening:
                statusRow("Listening…", systemImage: "waveform")
            case .transcribing:
                statusRow("Transcribing…", systemImage: "text.bubble")
            case let .confirming(transcript):
                VStack(alignment: .leading, spacing: 6) {
                    Text("I heard: “\(transcript.text)”").font(.callout)
                    Text("That wasn't very clear — send it anyway?")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Send") { Task { await controller.confirm() } }
                            .buttonStyle(.borderedProminent)
                        Button("Discard", role: .cancel) { controller.reject() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .thinking:
                statusRow(controller.progressCue ?? "Thinking…", systemImage: "ellipsis.bubble")
            case .speaking:
                HStack {
                    Label("Speaking…", systemImage: "speaker.wave.2")
                    Spacer()
                    Button("Stop") { Task { await controller.interrupt() } }
                        .buttonStyle(.bordered)
                }
            case let .error(message):
                statusRow(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func statusRow(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
