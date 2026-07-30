import CaptureCore
import Foundation
import TranscribeerCore

// MARK: - Apple SpeechAnalyzer (macOS 26+)

@MainActor
extension TranscriptionService {
    func transcribeSpeechAnalyzer(
        session: URL,
        config: AppConfig,
        timing: DualSourceTranscriber.TimingInfo
    ) async throws -> String {
        guard #available(macOS 26.0, *) else {
            throw SpeechAnalyzerError.unsupportedOS
        }
        disarmIdleTimer()

        progress = 0
        micProgress = 0
        sysProgress = 0
        liveSegments = []
        lastDetectedLanguage = nil

        let onMicProgress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.applyMicProgress(value) }
        }
        let onSysProgress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.applySysProgress(value) }
        }

        defer {
            progress = nil
            micProgress = nil
            sysProgress = nil
        }

        let output = try await SpeechAnalyzerTranscriber.transcribe(
            session: session,
            config: config,
            timing: timing,
            onMicProgress: onMicProgress,
            onSysProgress: onSysProgress
        )

        if config.language == "auto", let detected = output.detectedLanguage, !detected.isEmpty {
            lastDetectedLanguage = detected
        }

        liveSegments = output.segments.map(Self.toLiveSegment)
        return TranscriptFormatter.formatDual(output.segments)
    }

    /// Read `timing.json` if present. Returns nil-anchored timing when the
    /// file is missing; throws when the file exists but cannot be parsed so
    /// data corruption is surfaced rather than masked.
    func readTiming(from session: URL) throws -> DualSourceTranscriber.TimingInfo {
        let timingURL = session.appendingPathComponent("timing.json")
        guard FileManager.default.fileExists(atPath: timingURL.path) else {
            return .init(micStartEpoch: nil, sysStartEpoch: nil)
        }
        let metadata = try TimingMetadata.read(from: timingURL)
        return .init(
            micStartEpoch: metadata.micStartEpoch,
            sysStartEpoch: metadata.sysStartEpoch
        )
    }
}
