import Foundation
import WhisperKit

// MARK: - Single-file WhisperKit transcription

@MainActor
extension TranscriptionService {
    /// Transcribe an audio file to timestamped segments.
    ///
    /// The underlying WhisperKit call runs on a detached, user-initiated task
    /// so the main actor is free to service UI events throughout. Progress
    /// updates are throttled to ~10 Hz to avoid hammering SwiftUI's tracking.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file (WAV, M4A, etc.).
    ///   - language: Language code (e.g. "en") or "auto" for detection.
    /// - Returns: Array of timestamped transcript segments.
    func transcribe(
        audioURL: URL,
        language: String = "auto"
    ) async throws -> [TranscriptSegment] {
        disarmIdleTimer()

        if whisperKit == nil || modelState != .loaded {
            try await loadModel()
        }

        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        progress = 0
        liveSegments = []

        // When language is known, skip Whisper's temperature-fallback cascade
        // (up to 5 retries per chunk at increasing temperatures). The fallback
        // is designed for mixed-language or noisy audio — with an explicit
        // language it's pure overhead and can 5x the wall time.
        //
        // `skipSpecialTokens: true` is important: WhisperKit defaults to
        // `false`, which leaks `<|startoftranscript|>`, `<|he|>`, `<|0.00|>`,
        // `<|endoftext|>` tokens into `segment.text`. With VAD chunking those
        // accumulate per chunk and make the transcript unreadable.
        let explicitLanguage = language != "auto"
        let options = DecodingOptions(
            verbose: false,
            language: explicitLanguage ? language : nil,
            temperatureFallbackCount: explicitLanguage ? 0 : 5,
            detectLanguage: !explicitLanguage,
            skipSpecialTokens: true,
            chunkingStrategy: .vad
        )

        // Throttled, main-actor-safe progress sink. The KVO callback can fire
        // dozens of times per second; we only forward noticeable changes.
        let progressSink = ProgressSink { [weak self] value in
            Task { @MainActor in
                self?.progress = value
            }
        }

        let observation = kit.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { reported, _ in
            progressSink.submit(reported.fractionCompleted)
        }

        // Stream discovered segments to the UI. WhisperKit invokes this from
        // a background queue, so hop to the main actor before mutating state.
        // Segments may arrive slightly out of order with VAD chunking — the
        // view sorts by `start` before rendering.
        kit.segmentDiscoveryCallback = { [weak self] segments in
            let mapped = segments.map { seg in
                TranscriptSegment(
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: seg.text.trimmingCharacters(in: .whitespaces)
                )
            }
            Task { @MainActor in
                self?.liveSegments.append(contentsOf: mapped)
            }
        }

        defer {
            observation.invalidate()
            kit.segmentDiscoveryCallback = nil
            progress = nil
            activeTask = nil
        }

        let audioPath = audioURL.path
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let results = try await kit.transcribe(
                audioPath: audioPath,
                decodeOptions: options
            )
            return results.flatMap(\.segments).map { segment in
                TranscriptSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespaces)
                )
            }
        }
        activeTask = task

        let segments = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        armIdleTimer(minutes: 10) // default; no config available in this path
        return segments
    }
}
