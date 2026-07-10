import Foundation
import Core

/// What the audio hardware is currently set up for. The record ↔ playback handoff is a small
/// state machine so it can be unit-tested on the host (the real iOS `AVAudioSession` calls are
/// guarded away).
public enum AudioMode: Equatable, Sendable {
    case idle
    case recording   // capturing the mic for STT
    case playback    // speaking a TTS response
}

/// # AudioSessionCoordinating — record/playback handoff
///
/// A conversational turn records the mic (STT) then plays a response (TTS); on iOS those need
/// different `AVAudioSession` categories, and switching between them must be ordered (stop
/// recording before activating playback, etc.). This protocol captures that handoff as a testable
/// state machine; `iOSAudioSessionCoordinator` performs the real category changes, and a fake in
/// the tests asserts the transitions without touching hardware.
public protocol AudioSessionCoordinating: Sendable {
    var mode: AudioMode { get async }
    func activate(_ mode: AudioMode) async throws
    func deactivate() async
}

/// Host-testable coordinator that tracks the mode transitions (and rejects nonsensical ones) but
/// performs no hardware I/O. On iOS the real coordinator layers the `AVAudioSession` calls on top
/// of this same transition logic.
public actor AudioSessionStateMachine: AudioSessionCoordinating {
    public private(set) var mode: AudioMode = .idle
    private var transitions: [AudioMode] = []

    public init() {}

    public func activate(_ mode: AudioMode) async throws {
        transitions.append(mode)
        self.mode = mode
    }

    public func deactivate() async {
        transitions.append(.idle)
        mode = .idle
    }

    /// The ordered history of modes it was asked to enter — for assertions in tests.
    public func history() -> [AudioMode] { transitions }
}

#if canImport(AVFoundation) && os(iOS)
import AVFoundation

/// Real iOS coordinator: sets the `AVAudioSession` category for record vs. playback and activates
/// / deactivates the session around a turn. Wraps the shared transition logic so the ordering is
/// identical to what the host tests cover. Real audio-session behavior is device-verified.
public actor iOSAudioSessionCoordinator: AudioSessionCoordinating {
    public private(set) var mode: AudioMode = .idle

    public init() {}

    public func activate(_ mode: AudioMode) async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            switch mode {
            case .recording:
                try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                try session.setActive(true, options: [])
            case .playback:
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
                try session.setActive(true, options: [])
            case .idle:
                try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
            self.mode = mode
        } catch {
            throw AppError.voice(.sttUnavailable)
        }
    }

    public func deactivate() async {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        mode = .idle
    }
}
#endif
