//
//  InterviewSessionViewModel.swift
//  StepIN
//
//  Controls the live interview state machine. One phase at a time; the
//  robot state is derived, never set directly by the view. In mock mode
//  candidate turns are simulated so the full flow runs offline.
//

import Foundation
import Observation

@MainActor
@Observable
final class InterviewSessionViewModel {

    // MARK: Phases

    enum Phase: Equatable {
        case idle
        case ready
        case interviewerSpeaking
        case candidateListening
        case processingAnswer
        case paused
        case finished
        case error
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var currentQuestionText: String = ""
    private(set) var showFinishAnswer = false
    private(set) var sessionErrorMessage: String?
    private(set) var transcript: [TranscriptEntry] = []
    private(set) var robertOneShot: RobertAnimationState?
    private(set) var latestVoiceClassification: String?
    private(set) var latestVoiceConfidence: Double = 0
    /// Set when the interview finishes (naturally or ended early).
    private(set) var didFinish = false
    private(set) var endedEarly = false

    var robotState: RobotState {
        switch phase {
        case .idle, .ready: .idle
        case .interviewerSpeaking: .speaking
        case .candidateListening: .listening
        case .processingAnswer: .thinking
        case .paused: .paused
        case .finished: .analyzing
        case .error: .idle
        }
    }

    /// UI-facing state label. Wrapped in `String(localized:)` so the
    /// String Catalog can translate labels returned from this computed property.
    var stateLabel: String {
        switch phase {
        case .interviewerSpeaking:
            String(localized: "Speaking", comment: "Interview state label shown while the AI interviewer is talking")
        case .candidateListening:
            String(localized: "Listening", comment: "Interview state label shown while the candidate is answering")
        case .processingAnswer:
            String(localized: "Thinking", comment: "Interview state label shown while the AI is processing the answer")
        case .paused:
            String(localized: "Paused", comment: "Interview state label shown while the interview is paused")
        case .error:
            String(localized: "Connection Issue", comment: "Interview state label shown when the realtime session errors")
        default:
            ""
        }
    }

    var completedQuestionCount: Int { realtimeCompletedQuestionCount ?? engine.askedQuestionCount }

    // MARK: Private

    private let engine: MockInterviewEngine
    private var realtimeSession: OpenAIRealtimeInterviewSession?
    private var realtimeCompletedQuestionCount: Int?
    private let configuration: InterviewConfiguration
    private var phaseTask: Task<Void, Never>?
    /// The phase to re-enter after a pause.
    private var resumePhase: Phase = .interviewerSpeaking
    private var currentQuestion: InterviewQuestion?
    /// Called exactly once when the session ends.
    private let onFinished: (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int, _ metrics: VoiceDeliveryMetrics) -> Void
    /// Maps candidate turn UUID → index in `transcript` where that turn's entry lives.
    /// Allows late authoritative transcripts to update the existing entry in place.
    private var candidateTurnTranscriptIndex: [UUID: Int] = [:]
    /// Voice results are owned by candidate turn UUID so async Core ML callbacks
    /// cannot attach to the wrong answer when transcript timing varies.
    private var voiceResultByTurnID: [UUID: VoicePerformanceResult] = [:]
    private var didRequestPrepare = false
    private var didRequestBeginInterview = false

    init(
        configuration: InterviewConfiguration,
        engine: MockInterviewEngine? = nil,
        onFinished: @escaping (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int, _ metrics: VoiceDeliveryMetrics) -> Void
    ) {
        self.configuration = configuration
        self.engine = engine ?? MockInterviewEngine()
        self.onFinished = onFinished

        if engine == nil, let apiKey = OpenAIConfiguration.apiKey {
            self.realtimeSession = makeRealtimeSession(apiKey: apiKey)
        }
    }

    private func makeRealtimeSession(apiKey: String) -> OpenAIRealtimeInterviewSession {
        OpenAIRealtimeInterviewSession(
            configuration: configuration,
            apiKey: apiKey,
            onStateChange: { [weak self] state in self?.applyRealtimeState(state) },
            onInterviewerText: { [weak self] text in self?.currentQuestionText = text },
            onTranscriptEntry: { [weak self] entry in self?.appendRealtimeTranscript(entry) },
            onVoiceAnalysisResult: { [weak self] turnID, emotion, confidence in
                self?.updateVoiceAnalysis(turnID: turnID, emotion: emotion, confidence: confidence)
            },
            onCandidateTranscript: { [weak self] turnID, text in self?.handleCandidateTranscript(turnID: turnID, text: text) },
            onCompleted: { [weak self] isPartial, completedCount in
                self?.finishRealtime(isPartial: isPartial, completedCount: completedCount)
            },
            onError: { [weak self] error in
                self?.handleRealtimeError(error)
            }
        )
    }

    // MARK: Lifecycle

    func start() {
        prepare()
        beginInterview()
    }

    func prepare() {
        guard !didRequestPrepare else { return }
        guard phase == .idle else { return }
        didRequestPrepare = true
        sessionErrorMessage = nil
        latestVoiceClassification = nil
        latestVoiceConfidence = 0

        if let realtimeSession {
            phaseTask = Task { [weak self] in
                do {
                    try await realtimeSession.prepare()
                } catch let error as RealtimeSessionError {
                    self?.handleRealtimeError(error)
                } catch {
                    self?.handleRealtimeError(RealtimeSessionError(message: error.localizedDescription, type: "startup", code: nil, param: nil))
                }
            }
            return
        }

        phase = .ready
    }

    func beginInterview() {
        guard !didRequestBeginInterview else { return }
        didRequestBeginInterview = true

        if let realtimeSession {
            phaseTask = Task { [weak self] in
                do {
                    try await realtimeSession.beginInterview()
                } catch let error as RealtimeSessionError {
                    self?.handleRealtimeError(error)
                } catch {
                    self?.handleRealtimeError(RealtimeSessionError(message: error.localizedDescription, type: "startup", code: nil, param: nil))
                }
            }
            return
        }

        phaseTask = Task { [weak self] in
            guard let self else { return }
            do {
                let question = try await engine.start(configuration: configuration)
                await present(question: question)
            } catch {
                finish(early: true)
            }
        }
    }

    /// Pause: stop all activity, keep context. Resume continues the same
    /// logical point — completed questions are never repeated.
    func pause() {
        guard phase != .paused, phase != .finished, phase != .error else { return }
        if let realtimeSession {
            realtimeSession.pause()
            showFinishAnswer = false
            return
        }

        resumePhase = (phase == .processingAnswer) ? .processingAnswer : phase
        phaseTask?.cancel()
        phaseTask = nil
        showFinishAnswer = false
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        if let realtimeSession {
            realtimeSession.resume()
            return
        }

        switch resumePhase {
        case .interviewerSpeaking:
            // Re-speak the current question from the beginning.
            if let currentQuestion {
                phaseTask = Task { [weak self] in await self?.present(question: currentQuestion, appendToTranscript: false) }
            }
        case .candidateListening:
            phaseTask = Task { [weak self] in await self?.listen() }
        case .processingAnswer:
            phaseTask = Task { [weak self] in await self?.processAnswer() }
        default:
            phase = .idle
            start()
        }
    }

    func retryAfterRealtimeError() {
        guard phase == .error else { return }
        realtimeSession?.stop()
        guard let apiKey = OpenAIConfiguration.apiKey else { return }
        realtimeSession = makeRealtimeSession(apiKey: apiKey)
        didRequestPrepare = false
        didRequestBeginInterview = false
        phase = .idle
        start()
    }

    /// User confirmed early end.
    func endInterview() {
        if let realtimeSession {
            realtimeSession.endEarly()
            return
        }
        finish(early: true)
    }

    /// Fallback button pressed while listening.
    func finishAnswerPressed() {
        guard phase == .candidateListening else { return }
        if let realtimeSession {
            realtimeSession.finishCurrentAnswer()
            return
        }
        phaseTask?.cancel()
        phaseTask = Task { [weak self] in await self?.captureAnswerAndProcess() }
    }

    func robertOneShotCompleted() {
        robertOneShot = nil
    }

    // MARK: State machine

    /// Interviewer speaks the question, then listening begins.
    private func present(question: InterviewQuestion, appendToTranscript: Bool = true) async {
        currentQuestion = question
        currentQuestionText = question.text
        if appendToTranscript {
            transcript.append(TranscriptEntry(speaker: .interviewer, text: question.text))
        }
        phase = .interviewerSpeaking
        showFinishAnswer = false

        // Simulated speech duration proportional to question length.
        let words = Double(question.text.split(separator: " ").count)
        let duration = min(max(words * 0.32, 2.0), 6.0)
        guard (try? await Task.sleep(for: .seconds(duration))) != nil else { return }

        await listen()
    }

    /// Candidate turn. Finish Answer stays hidden initially and fades in
    /// later as a fallback; in mock mode the answer auto-completes.
    private func listen() async {
        phase = .candidateListening
        showFinishAnswer = false

        // Fallback button appears only after an appropriate period.
        guard (try? await Task.sleep(for: .seconds(2.5))) != nil else { return }
        showFinishAnswer = true

        // Mock turn detection: the simulated candidate finishes on their own.
        guard (try? await Task.sleep(for: .seconds(Double.random(in: 3.0...4.5)))) != nil else { return }
        await captureAnswerAndProcess()
    }

    private func captureAnswerAndProcess() async {
        guard phase == .candidateListening else { return }
        showFinishAnswer = false
        transcript.append(TranscriptEntry(speaker: .candidate, text: engine.simulatedAnswer()))
        await processAnswer()
    }

    private func processAnswer() async {
        phase = .processingAnswer
        guard (try? await Task.sleep(for: .seconds(1.1))) != nil else { return }

        do {
            if let next = try await engine.submitAnswer(transcript.last?.text ?? "") {
                await present(question: next)
            } else {
                // Interview complete: speak the exact final phrase, then finish.
                currentQuestionText = engine.finalPhrase
                transcript.append(TranscriptEntry(speaker: .interviewer, text: engine.finalPhrase))
                phase = .interviewerSpeaking
                try? await Task.sleep(for: .seconds(2.2))
                finish(early: false)
            }
        } catch {
            finish(early: true)
        }
    }

    private func applyRealtimeState(_ state: OpenAIRealtimeInterviewSession.RuntimeState) {
        switch state {
        case .preparing, .thinking:
            phase = .processingAnswer
            robertOneShot = nil
        case .ready:
            phase = .ready
            showFinishAnswer = false
            robertOneShot = nil
        case .introductionSpeaking:
            phase = .interviewerSpeaking
            showFinishAnswer = false
            robertOneShot = .wave
        case .openingBeat:
            phase = .idle
            showFinishAnswer = false
            robertOneShot = nil
        case .speaking:
            phase = .interviewerSpeaking
            showFinishAnswer = false
            robertOneShot = nil
        case .listening:
            phase = .candidateListening
            showFinishAnswer = true
            robertOneShot = nil
        case .paused:
            phase = .paused
            showFinishAnswer = false
            robertOneShot = nil
        case .completed:
            phase = .finished
            robertOneShot = nil
        case .error:
            phase = .error
            showFinishAnswer = false
            robertOneShot = nil
        }
    }

    private func handleRealtimeError(_ error: RealtimeSessionError) {
        guard !didFinish else { return }
        phaseTask?.cancel()
        phaseTask = nil
        sessionErrorMessage = error.displayMessage
        showFinishAnswer = false
        phase = .error
    }

    private func appendRealtimeTranscript(_ entry: TranscriptEntry) {
        guard transcript.last?.speaker != entry.speaker || transcript.last?.text != entry.text else { return }
        transcript.append(entry)
    }

    private func updateVoiceAnalysis(turnID: UUID, emotion: String, confidence: Double) {
        latestVoiceClassification = emotion
        latestVoiceConfidence = confidence
        let incoming = VoicePerformanceResult(label: emotion, confidence: confidence)
        if let existing = voiceResultByTurnID[turnID], existing.confidence > incoming.confidence {
            logVoiceCoreML(
                turnID: turnID,
                classification: existing.label,
                confidence: existing.confidence,
                resultStored: true,
                transcriptExists: candidateTurnTranscriptIndex[turnID] != nil,
                resultAttached: candidateTurnTranscriptIndex[turnID] != nil
            )
            return
        }

        voiceResultByTurnID[turnID] = incoming
        var resultAttached = false
        if let existingIndex = candidateTurnTranscriptIndex[turnID] {
            let existing = transcript[existingIndex]
            transcript[existingIndex] = TranscriptEntry(speaker: .candidate, text: existing.text, voiceResult: incoming)
            resultAttached = true
        }
        logVoiceCoreML(
            turnID: turnID,
            classification: emotion,
            confidence: confidence,
            resultStored: true,
            transcriptExists: candidateTurnTranscriptIndex[turnID] != nil,
            resultAttached: resultAttached
        )
    }

    /// Creates or updates the candidate TranscriptEntry for a logical turn.
    ///
    /// Called by the session at response.create with the text accumulated so far,
    /// and optionally again when a late transcription.completed arrives with the
    /// authoritative final text. The second call updates the existing entry in
    /// place rather than appending a new bubble — one turn, one entry, always.
    private func handleCandidateTranscript(turnID: UUID, text: String) {
        guard !text.isEmpty else { return }
        if let existingIndex = candidateTurnTranscriptIndex[turnID] {
            // Late transcription.completed updating text — preserve the voice result already attached.
            let existing = transcript[existingIndex]
            let voiceResult = voiceResultByTurnID[turnID] ?? existing.voiceResult
            transcript[existingIndex] = TranscriptEntry(speaker: .candidate, text: text, voiceResult: voiceResult)
            logVoiceCoreML(
                turnID: turnID,
                classification: voiceResult?.label,
                confidence: voiceResult?.confidence,
                resultStored: voiceResultByTurnID[turnID] != nil,
                transcriptExists: true,
                resultAttached: voiceResult != nil
            )
        } else {
            let voiceResult = voiceResultByTurnID[turnID]
            candidateTurnTranscriptIndex[turnID] = transcript.count
            transcript.append(TranscriptEntry(speaker: .candidate, text: text, voiceResult: voiceResult))
            logVoiceCoreML(
                turnID: turnID,
                classification: voiceResult?.label,
                confidence: voiceResult?.confidence,
                resultStored: voiceResultByTurnID[turnID] != nil,
                transcriptExists: true,
                resultAttached: voiceResult != nil
            )
        }
    }

    private func logVoiceCoreML(
        turnID: UUID,
        classification: String?,
        confidence: Double?,
        resultStored: Bool,
        transcriptExists: Bool,
        resultAttached: Bool
    ) {
        #if DEBUG
        let confidenceText = confidence.map { String(format: "%.2f", $0) } ?? "nil"
        print("[VoiceCoreML] turnID=\(turnID.uuidString) analysisStarted=false analysisStopped=false classification=\(classification ?? "nil") confidence=\(confidenceText) resultStored=\(resultStored) transcriptExists=\(transcriptExists) resultAttached=\(resultAttached)")
        #endif
    }

    private func logAnalysisVoiceEvidenceSummary(transcript: [TranscriptEntry]) {
        #if DEBUG
        let candidateEntries = transcript.filter { $0.speaker == .candidate }
        let voiceEntries = candidateEntries.compactMap(\.voiceResult)
        let voiceEvidence = voiceEntries
            .map { "\($0.label):\(String(format: "%.2f", $0.confidence))" }
            .joined(separator: ", ")
        print("[StepIN.AnalysisVoiceEvidence] candidateTurns=\(candidateEntries.count) candidateTurnsWithVoiceEvidence=\(voiceEntries.count) voiceEvidence=[\(voiceEvidence)]")
        #endif
    }

    private func finishRealtime(isPartial: Bool, completedCount: Int) {
        guard !didFinish else { return }
        phaseTask?.cancel()
        phaseTask = nil
        didFinish = true
        endedEarly = isPartial
        sessionErrorMessage = nil
        realtimeCompletedQuestionCount = completedCount
        phase = .finished
        // Collect delivery metrics asynchronously before forwarding to the flow.
        // Phase transitions are already applied above so the UI updates immediately.
        let capturedTranscript = transcript
        let capturedSession = realtimeSession
        logAnalysisVoiceEvidenceSummary(transcript: capturedTranscript)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let metrics = await capturedSession?.collectDeliveryMetrics(transcript: capturedTranscript) ?? .empty
            self.onFinished(capturedTranscript, isPartial, completedCount, metrics)
        }
    }

    private func finish(early: Bool) {
        guard !didFinish else { return }
        phaseTask?.cancel()
        phaseTask = nil
        realtimeSession?.stop()
        didFinish = true
        endedEarly = early
        sessionErrorMessage = nil
        phase = .finished

        // Partial when ended before all selected questions were completed.
        let completedCount = realtimeCompletedQuestionCount ?? engine.askedQuestionCount
        let isPartial = early && completedCount < configuration.questionCount.rawValue
        logAnalysisVoiceEvidenceSummary(transcript: transcript)
        onFinished(transcript, isPartial, completedCount, .empty)
    }
}
