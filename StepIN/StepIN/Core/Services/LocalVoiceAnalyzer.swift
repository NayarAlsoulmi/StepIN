//
//  LocalVoiceAnalyzer.swift
//  StepIN
//
//  On-device deterministic vocal-delivery analyzer.
//
//  Receives PCM16 candidate audio buffers fanned out from the existing
//  AVAudioEngine input tap. Maintains a speech/silence state machine to
//  accumulate pause metrics, energy statistics, and a fast speech-resumption
//  signal for the turn-completion guard.
//
//  All metric work happens on this actor's serial executor, safely off both
//  the real-time audio callback thread and the MainActor.
//

import Foundation

actor LocalVoiceAnalyzer {

    // MARK: — Configuration

    /// Normalized RMS (0–1, PCM16 scale) above which a buffer is classified as speech.
    /// Tuned for close-mic voice in a quiet environment; adjust if needed.
    private let speechRMSThreshold: Float = 0.015

    /// Consecutive above-threshold buffers required to confirm speech resumption.
    /// At ~100 ms per buffer, 3 buffers ≈ 300 ms — fast enough for the turn guard
    /// while rejecting brief ambient spikes.
    private let speechConfirmationCount: Int = 3

    /// Consecutive below-threshold buffers required to confirm silence onset.
    /// At ~100 ms per buffer, 8 buffers ≈ 800 ms — conservative enough to avoid
    /// counting thinking micro-pauses as silence transitions.
    private let silenceConfirmationCount: Int = 8

    /// Minimum silence duration (measured between confirmed speech transitions)
    /// before a gap is recorded as a meaningful pause in delivery metrics.
    private let meaningfulPauseDurationMs: Double = 1_500

    /// Approximate duration of each PCM buffer in milliseconds.
    /// Derived from 2400 frames at the requested 24 kHz session rate.
    private let bufferDurationMs: Double = 100

    // MARK: — Callback

    /// Invoked when confirmed speech resumption is detected during a pending
    /// completion window. The session calls cancelPendingCandidateCompletion()
    /// from within this @Sendable closure — dispatched to @MainActor.
    private let onSpeechResumed: @Sendable () -> Void

    // MARK: — Speech / silence state machine

    private var isSpeaking = false
    private var consecutiveAboveThreshold = 0
    private var consecutiveBelowThreshold = 0

    // MARK: — Pause tracking

    /// Buffer index at which the current silence interval began (back-dated
    /// to the first below-threshold buffer to compensate for confirmation delay).
    private var silenceStartBufferIndex: Int? = nil
    private var pauseCount = 0
    private var totalPauseDurationMs = 0.0
    private var longestPauseDurationMs = 0.0

    // MARK: — Energy statistics

    private var speakingBufferCount = 0
    private var silenceBufferCount = 0
    private var rmsSum = 0.0
    private var rmsSumSquared = 0.0
    private var rmsObservationCount = 0

    // MARK: — Turn accounting

    private var totalCandidateBufferCount = 0
    private var completedTurnCount = 0

    // MARK: — Init

    init(onSpeechResumed: @escaping @Sendable () -> Void) {
        self.onSpeechResumed = onSpeechResumed
    }

    // MARK: — PCM ingestion

    /// Accepts one candidate-active PCM16 buffer (little-endian Int16, mono).
    /// Called once per ~100 ms audio callback, off the real-time thread.
    func ingest(pcmData: Data) {
        let rms = computeRMS(pcmData)
        totalCandidateBufferCount += 1

        let aboveThreshold = rms >= speechRMSThreshold

        if aboveThreshold {
            consecutiveAboveThreshold += 1
            consecutiveBelowThreshold = 0
        } else {
            consecutiveBelowThreshold += 1
            consecutiveAboveThreshold = 0
        }

        // Silence onset: back-date silence start to when the below-threshold
        // run first began, compensating for the confirmation-count delay.
        if isSpeaking && consecutiveBelowThreshold >= silenceConfirmationCount {
            isSpeaking = false
            let backDatedStart = totalCandidateBufferCount - silenceConfirmationCount
            silenceStartBufferIndex = backDatedStart
        }

        // Speech resumption: back-date resume point and close any open pause.
        // Also fires the turn-completion guard callback.
        if !isSpeaking && consecutiveAboveThreshold >= speechConfirmationCount {
            let backDatedResume = totalCandidateBufferCount - speechConfirmationCount
            closePauseIfOpen(resumeBufferIndex: backDatedResume)
            isSpeaking = true
            onSpeechResumed()
        }

        // Frame accounting (energy only over confirmed-speaking buffers).
        if isSpeaking {
            speakingBufferCount += 1
            rmsSum += Double(rms)
            rmsSumSquared += Double(rms) * Double(rms)
            rmsObservationCount += 1
        } else {
            silenceBufferCount += 1
        }
    }

    // MARK: — Turn boundary

    /// Called by the session when a candidate turn is definitively over
    /// (just before response.create is dispatched). Closes any open pause
    /// at the current buffer position and increments the turn counter.
    func markTurnComplete() {
        closePauseIfOpen(resumeBufferIndex: nil)
        completedTurnCount += 1
    }

    /// Clears active silence tracking when the interview is paused/resumed,
    /// so that user-initiated pause time is not counted as a candidate pause.
    func resetSilenceTracking() {
        silenceStartBufferIndex = nil
        consecutiveAboveThreshold = 0
        consecutiveBelowThreshold = 0
        isSpeaking = false
    }

    // MARK: — Metrics export

    /// Produces the final delivery metrics summary. Call once after the session ends.
    /// fillerWordCount must be pre-computed by the caller from the candidate transcript
    /// (text analysis is kept on the @MainActor session to avoid isolation issues here).
    func generateMetrics(fillerWordCount: Int) -> VoiceDeliveryMetrics {
        guard totalCandidateBufferCount > 0 else {
            return VoiceDeliveryMetrics(
                totalSpeakingSeconds: 0, totalSilenceSeconds: 0,
                pauseCount: 0, averagePauseDurationMs: 0, longestPauseDurationMs: 0,
                speakingRatio: 0, rmsEnergyMean: 0, rmsEnergyVariability: 0,
                answeredTurnCount: 0, fillerWordCount: 0
            )
        }

        let totalSpeaking = Double(speakingBufferCount) * bufferDurationMs / 1_000
        let totalSilence = Double(silenceBufferCount) * bufferDurationMs / 1_000
        let ratio = Double(speakingBufferCount) / Double(totalCandidateBufferCount)
        let avgPause = pauseCount > 0 ? totalPauseDurationMs / Double(pauseCount) : 0

        let energyMean: Double
        let energyVariability: Double
        if rmsObservationCount > 0 {
            energyMean = rmsSum / Double(rmsObservationCount)
            let variance = (rmsSumSquared / Double(rmsObservationCount)) - (energyMean * energyMean)
            energyVariability = energyMean > 0 ? sqrt(max(0, variance)) / energyMean : 0
        } else {
            energyMean = 0
            energyVariability = 0
        }

        return VoiceDeliveryMetrics(
            totalSpeakingSeconds: totalSpeaking,
            totalSilenceSeconds: totalSilence,
            pauseCount: pauseCount,
            averagePauseDurationMs: avgPause,
            longestPauseDurationMs: longestPauseDurationMs,
            speakingRatio: ratio,
            rmsEnergyMean: energyMean,
            rmsEnergyVariability: energyVariability,
            answeredTurnCount: completedTurnCount,
            fillerWordCount: fillerWordCount
        )
    }

    // MARK: — Helpers

    /// Closes an open silence interval and records it if it meets the meaningful-pause threshold.
    /// resumeBufferIndex nil means the turn ended naturally (use current position).
    private func closePauseIfOpen(resumeBufferIndex: Int?) {
        guard let startIndex = silenceStartBufferIndex else { return }
        let endIndex = resumeBufferIndex ?? totalCandidateBufferCount
        let durationMs = Double(max(0, endIndex - startIndex)) * bufferDurationMs
        if durationMs >= meaningfulPauseDurationMs {
            pauseCount += 1
            totalPauseDurationMs += durationMs
            longestPauseDurationMs = max(longestPauseDurationMs, durationMs)
        }
        silenceStartBufferIndex = nil
    }

    /// Computes normalized RMS for a little-endian PCM16 buffer.
    private func computeRMS(_ data: Data) -> Float {
        let sampleCount = data.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }
        var sumSquares: Float = 0
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<min(samples.count, sampleCount) {
                let normalized = Float(samples[i]) / Float(Int16.max)
                sumSquares += normalized * normalized
            }
        }
        return sqrt(sumSquares / Float(sampleCount))
    }
}
