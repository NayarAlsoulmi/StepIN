//
//  VoiceDeliveryMetrics.swift
//  StepIN
//
//  Deterministic vocal-delivery measurements collected from the candidate's
//  PCM audio stream during an interview. These are observable signals only —
//  no psychological state is inferred.
//

import Foundation

struct VoiceDeliveryMetrics: Sendable {
    let totalSpeakingSeconds: Double
    let totalSilenceSeconds: Double
    /// Distinct meaningful pauses (each ≥ meaningfulPauseDurationMs).
    let pauseCount: Int
    let averagePauseDurationMs: Double
    let longestPauseDurationMs: Double
    /// Fraction of candidate-active time spent speaking (0–1).
    let speakingRatio: Double
    /// Mean RMS energy across confirmed-speaking frames (0–1, normalized PCM16).
    let rmsEnergyMean: Double
    /// Standard deviation of per-buffer RMS, as a fraction of mean (0–1).
    let rmsEnergyVariability: Double
    /// Completed candidate answer turns measured.
    let answeredTurnCount: Int
    /// Estimated filler-word occurrences counted from transcript text.
    let fillerWordCount: Int

    // Minimum evidence thresholds before delivery data is used in analysis.
    // Requires at least two completed turns and 20 seconds of actual speech.
    var hasEnoughEvidence: Bool {
        answeredTurnCount >= 2 && totalSpeakingSeconds >= 20.0
    }

    static let empty = VoiceDeliveryMetrics(
        totalSpeakingSeconds: 0,
        totalSilenceSeconds: 0,
        pauseCount: 0,
        averagePauseDurationMs: 0,
        longestPauseDurationMs: 0,
        speakingRatio: 0,
        rmsEnergyMean: 0,
        rmsEnergyVariability: 0,
        answeredTurnCount: 0,
        fillerWordCount: 0
    )

    // Counts common disfluency markers from candidate transcript text.
    // Works on both English and Arabic input; does not require audio.
    static func countFillerWords(in transcript: [TranscriptEntry]) -> Int {
        let candidateText = transcript
            .filter { $0.speaker == .candidate }
            .map { $0.text.lowercased() }
            .joined(separator: " ")
        guard !candidateText.isEmpty else { return 0 }

        // English disfluency markers
        let englishFillers = [
            "um ", "uh ", "uhh ", "umm ", " hmm ", "you know", " basically ",
            "i mean", "kind of", "sort of", "like, ", ", like ", " right, "
        ]
        // Arabic disfluency markers (native script and common romanizations)
        let arabicFillers = [
            "يعني", "اه ", "اهه ", "هيك ", " بس ", "ايش ", "مثلاً"
        ]

        var count = 0
        for pattern in englishFillers + arabicFillers {
            var range = candidateText.startIndex..<candidateText.endIndex
            while let found = candidateText.range(of: pattern, range: range) {
                count += 1
                range = found.upperBound..<candidateText.endIndex
            }
        }
        return count
    }
}
