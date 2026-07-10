import Foundation
import Core

/// # AudioPlayer — the raw-bytes playback boundary
///
/// Abstracts "play these audio bytes to completion / stop immediately" so the ElevenLabs TTS
/// (which returns encoded audio over REST) is testable with a fake audio layer and its
/// interruption behavior can be asserted without real hardware. The real implementation
/// (`SystemAudioPlayer`) wraps `AVAudioPlayer`; tests inject a fake.
public protocol AudioPlayer: Sendable {
    /// Play `audio` (encoded, e.g. MP3) and return when it finishes — or return early if
    /// `stop()` is called. Throws `AppError.voice(.ttsFailed)` if the bytes can't be played.
    func play(_ audio: Data) async throws
    /// Halt playback immediately; any in-flight `play(_:)` returns.
    func stop() async
}

#if canImport(AVFoundation)
import AVFoundation

/// Real playback over `AVAudioPlayer`. Guarded so the type exists everywhere AVFoundation ships;
/// tests never instantiate it (they use a fake). Real audio output is device-verified.
public final class SystemAudioPlayer: NSObject, AudioPlayer, AVAudioPlayerDelegate, @unchecked Sendable {

    private let lock = NSLock()
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Error>?

    public override init() { super.init() }

    public func play(_ audio: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            do {
                let player = try AVAudioPlayer(data: audio)
                player.delegate = self
                self.player = player
                self.continuation = cont
                lock.unlock()
                if !player.play() {
                    finish(.failure(AppError.voice(.ttsFailed)))
                }
            } catch {
                lock.unlock()
                cont.resume(throwing: AppError.voice(.ttsFailed))
            }
        }
    }

    public func stop() async {
        lock.withLock {
            player?.stop()
            player = nil
        }
        finish(.success(()))
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finish(flag ? .success(()) : .failure(AppError.voice(.ttsFailed)))
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        switch result {
        case .success: cont?.resume()
        case .failure(let error): cont?.resume(throwing: error)
        }
    }
}
#else
public final class SystemAudioPlayer: AudioPlayer, @unchecked Sendable {
    public init() {}
    public func play(_ audio: Data) async throws { throw AppError.voice(.ttsFailed) }
    public func stop() async {}
}
#endif
