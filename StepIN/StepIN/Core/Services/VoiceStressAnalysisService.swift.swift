import Foundation
import Combine
import AVFoundation
import SoundAnalysis
import CoreML

final class VoiceStressAnalysisService: NSObject, ObservableObject {

    @Published private(set) var detectedEmotion: String = "Listening..."
    @Published private(set) var confidence: Double = 0.0

    var onResult: ((_ emotion: String, _ confidence: Double) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let analysisQueue = DispatchQueue(label: "StepIN.VoiceStressAnalysisService.analysis")
    private let resultLock = NSLock()
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var isAnalyzing = false
    private var resultSamples: [String: [Double]] = [:]

    func startListening() {
        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            try startAnalyzingExistingStream(format: format)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(
                onBus: 0,
                bufferSize: 8192,
                format: format
            ) { [weak self] buffer, time in
                self?.analyze(buffer, atAudioFramePosition: time.sampleTime)
            }

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("VoiceStressAnalysisService error:", error)
        }
    }

    func stopListening() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        stopAnalyzing()
    }

    func startAnalyzingExistingStream(format: AVAudioFormat) throws {
        stopAnalyzing()

        let model = try MySoundClassifier_1(configuration: MLModelConfiguration())
        let request = try SNClassifySoundRequest(mlModel: model.model)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        try analyzer.add(request, withObserver: self)

        resetResultSamples()
        analysisQueue.sync {
            streamAnalyzer = analyzer
            isAnalyzing = true
        }
        print("Voice stress analysis started")
    }

    func analyze(_ buffer: AVAudioPCMBuffer, atAudioFramePosition position: AVAudioFramePosition) {
        analysisQueue.async { [weak self] in
            guard let self, self.isAnalyzing, let streamAnalyzer = self.streamAnalyzer else { return }
            streamAnalyzer.analyze(buffer, atAudioFramePosition: position)
        }
    }

    func stopAnalyzing() {
        var didStop = false
        analysisQueue.sync {
            didStop = isAnalyzing || streamAnalyzer != nil
            isAnalyzing = false
            streamAnalyzer = nil
        }

        if didStop {
            publishFinalResultIfAvailable()
            print("Voice stress analysis stopped")
        }
    }

    private func recordResult(emotion: String, confidence: Double) {
        resultLock.lock()
        resultSamples[emotion, default: []].append(confidence)
        resultLock.unlock()
    }

    private func resetResultSamples() {
        resultLock.lock()
        resultSamples.removeAll()
        resultLock.unlock()
    }

    private func finalResult() -> (emotion: String, confidence: Double)? {
        resultLock.lock()
        let samples = resultSamples
        resultSamples.removeAll()
        resultLock.unlock()

        return samples
            .map { emotion, confidences in
                let average = confidences.reduce(0, +) / Double(confidences.count)
                return (emotion: emotion, confidence: average)
            }
            .max { first, second in
                first.confidence < second.confidence
            }
    }

    private func publishFinalResultIfAvailable() {
        guard let result = finalResult() else { return }

        let deliver = {
            self.detectedEmotion = result.emotion
            self.confidence = result.confidence
            self.onResult?(result.emotion, result.confidence)
        }
        if Thread.isMainThread {
            deliver()
        } else {
            DispatchQueue.main.async(execute: deliver)
        }

        print("🎤 Final Voice Analysis: \(result.emotion) - \(Int(result.confidence * 100))%")
    }

    private static func displayName(for identifier: String) -> String {
        let normalized = identifier.lowercased()
        if normalized.contains("calm") { return "Calm" }
        if normalized.contains("neutral") { return "Neutral" }
        if normalized.contains("fear") || normalized.contains("fearful") { return "Fearful" }
        return identifier.capitalized
    }
}

extension VoiceStressAnalysisService: SNResultsObserving {

    func request(
        _ request: SNRequest,
        didProduce result: SNResult
    ) {

        guard let classificationResult =
                result as? SNClassificationResult,
              let bestResult =
                classificationResult.classifications.first
        else {
            return
        }

        let emotion = Self.displayName(for: bestResult.identifier)
        let confidence = bestResult.confidence
        recordResult(emotion: emotion, confidence: confidence)

        DispatchQueue.main.async {
            self.detectedEmotion = emotion
            self.confidence = confidence
        }
    }

    func request(
        _ request: SNRequest,
        didFailWithError error: Error
    ) {
        print(" Sound analysis failed:", error)
    }

    func requestDidComplete(_ request: SNRequest) {
        print(" Sound analysis completed")
    }
}
//  VoiceStressAnalysisService.swift.swift
//  StepIN
//
//  Created by LARA on 28/02/1448 AH.
//
