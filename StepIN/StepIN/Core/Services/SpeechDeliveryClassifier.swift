//
//  SpeechDeliveryClassifier.swift
//  StepIN
//
//  Integration boundary for a future on-device Core ML vocal delivery classifier.
//
//  No model exists yet. This type returns nil for all queries so the absence
//  of a model produces no fabricated output. When a validated .mlpackage is
//  available, implement classify() per the steps described below.
//
//  IMPORTANT: Classification labels describe observable delivery patterns, not
//  psychological or emotional state. Labels such as "stressed", "anxious", or
//  "confident" are not used because they cannot be responsibly inferred from
//  audio alone without a demographically validated, peer-reviewed model.
//
//  Model integration prerequisites (from architecture diagnosis):
//  - At least 100 labeled interview audio clips across Arabic and English speakers
//  - Both genders, varied accents, ≥ 2 independent annotators, κ ≥ 0.6 agreement
//  - Separate validation sets for Arabic and English
//  - Train / validation / test split of 70 / 15 / 15
//  - Measured accuracy and confusion matrix before shipping
//

import Foundation

actor SpeechDeliveryClassifier {

    // MARK: — Delivery classification labels

    /// Observable delivery patterns that a trained model would classify.
    /// These describe what is heard, not what is felt internally.
    enum Classification: String, Sendable {
        case fluent       // smooth, continuous delivery with natural pacing
        case hesitant     // frequent stops, filled pauses, or restarts
        case fragmented   // broken-up pacing with inconsistent segment lengths
    }

    /// A single-window prediction with its associated confidence.
    struct Prediction: Sendable {
        let classification: Classification
        let confidence: Float  // 0–1
    }

    // MARK: — Thresholds (configurable when a model is available)

    /// Minimum prediction confidence to trust a result in user feedback.
    /// Below this threshold, the result is discarded rather than shown.
    static let confidenceThreshold: Float = 0.70

    /// Minimum number of audio windows required before producing an aggregate
    /// prediction for a single candidate answer. Prevents premature classification
    /// from very short clips.
    static let minimumWindowsRequired: Int = 5

    // MARK: — Classification (not yet implemented)

    /// Accepts a short window of candidate PCM audio and returns a delivery
    /// prediction. Currently returns nil — no model is loaded.
    ///
    /// Future implementation steps:
    ///  1. At init, load a validated .mlpackage via `try MLModel(contentsOf:)`.
    ///  2. In classify(), extract audio features from the PCM window:
    ///     - Use Accelerate / vDSP to compute a log-mel spectrogram or MFCCs
    ///       at the resolution expected by the model.
    ///  3. Wrap features in an MLMultiArray and call `model.prediction(from:)`.
    ///  4. Map the output class label to Classification.
    ///  5. Return a Prediction only when confidence >= confidenceThreshold.
    ///  6. Never run this on the real-time audio thread.
    ///     Call it once per completed candidate turn, not per 100 ms buffer.
    ///  7. Aggregate predictions across multiple windows before producing a
    ///     turn-level classification used in analysis.
    ///
    /// - Parameters:
    ///   - pcmWindow: A short segment of PCM16 candidate audio (e.g., 3–10 s).
    ///   - sampleRate: The actual sample rate of the data (typically 24 000 Hz).
    /// - Returns: A prediction, or nil when no model is available or confidence
    ///   is below the threshold.
    func classify(pcmWindow: Data, sampleRate: Int) async -> Prediction? {
        // No model available. Return nil — no fabricated output.
        return nil
    }
}
