import CaptureCore
import Foundation
import TranscribeerCore

// MARK: - Cloud (OpenAI / Gemini)

@MainActor
extension TranscriptionService {
    /// Cloud-backend equivalent of the local dual-source path. Calls the API
    /// once per present audio source, applies wall-clock offsets, tags mic
    /// segments as `selfLabel` and sys segments as `otherLabel`, then
    /// interleaves by start time.
    func transcribeCloud(
        session: URL,
        config: AppConfig,
        timing: DualSourceTranscriber.TimingInfo,
        backend: TranscriptionBackend
    ) async throws -> String {
        disarmIdleTimer()

        let micURL = SourceAudioFiles.preferredURL(in: session, source: .mic)
        let sysURL = SourceAudioFiles.preferredURL(in: session, source: .sys)
        let mixedURL = session.appendingPathComponent("audio.m4a")
        let hasMic = micURL != nil
        let hasSys = sysURL != nil
        let hasMixed = FileManager.default.fileExists(atPath: mixedURL.path)

        let model = backend == .openai
            ? config.openaiTranscriptionModel
            : config.geminiTranscriptionModel

        progress = 0
        micProgress = hasMic ? 0 : nil
        sysProgress = hasSys ? 0 : nil
        micSnapshot = nil
        sysSnapshot = nil
        cloudBackendName = backend.displayName
        liveSegments = []

        let onMicProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void = { snap in
            Task { @MainActor in self.applyMicSnapshot(snap) }
        }
        let onSysProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void = { snap in
            Task { @MainActor in self.applySysSnapshot(snap) }
        }
        let dualCfg = CloudTranscriptionCoordinator.DualConfig(
            backend: backend,
            micURL: micURL,
            sysURL: sysURL,
            timing: timing,
            model: model,
            language: config.language,
            selfLabel: config.audio.selfLabel,
            otherLabel: config.audio.otherLabel,
            onMicProgress: onMicProgress,
            onSysProgress: onSysProgress
        )
        let task = Task.detached(priority: .userInitiated) { () -> [LabeledSegment] in
            try Task.checkCancellation()
            if hasMic || hasSys {
                return try await CloudTranscriptionCoordinator.runDual(dualCfg)
            }
            guard hasMixed else { return [] }
            return try await CloudTranscriptionCoordinator.runMixed(
                backend: backend,
                audioURL: mixedURL,
                model: model,
                language: config.language,
                onProgress: onMicProgress
            )
        }
        cloudTask = task

        defer {
            progress = nil
            micProgress = nil
            sysProgress = nil
            micSnapshot = nil
            sysSnapshot = nil
            cloudBackendName = nil
            cloudTask = nil
        }

        let appSegments = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }

        liveSegments = appSegments.map(Self.toLiveSegment)
        armIdleTimer(minutes: config.idleUnloadMinutes)
        return TranscriptFormatter.formatDual(appSegments)
    }
}
