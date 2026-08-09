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
    /// Set when the interview finishes (naturally or ended early).
    private(set) var didFinish = false
    private(set) var endedEarly = false

    var robotState: RobotState {
        switch phase {
        case .idle: .idle
        case .interviewerSpeaking: .speaking
        case .candidateListening: .listening
        case .processingAnswer: .thinking
        case .paused: .paused
        case .finished: .analyzing
        case .error: .idle
        }
    }

    var stateLabel: String {
        switch phase {
        case .interviewerSpeaking: "Speaking"
        case .candidateListening: "Listening"
        case .processingAnswer: "Thinking"
        case .paused: "Paused"
        case .error: "Connection Issue"
        default: ""
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
    private let onFinished: (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int) -> Void

    init(
        configuration: InterviewConfiguration,
        engine: MockInterviewEngine? = nil,
        onFinished: @escaping (_ transcript: [TranscriptEntry], _ isPartial: Bool, _ completedCount: Int) -> Void
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
        guard phase == .idle else { return }
        sessionErrorMessage = nil

        if let realtimeSession {
            phaseTask = Task { [weak self] in
                do {
                    try await realtimeSession.start()
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
        case .speaking:
            phase = .interviewerSpeaking
            showFinishAnswer = false
        case .listening:
            phase = .candidateListening
            showFinishAnswer = true
        case .paused:
            phase = .paused
            showFinishAnswer = false
        case .completed:
            phase = .finished
        case .error:
            phase = .error
            showFinishAnswer = false
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

    private func finishRealtime(isPartial: Bool, completedCount: Int) {
        guard !didFinish else { return }
        phaseTask?.cancel()
        phaseTask = nil
        didFinish = true
        endedEarly = isPartial
        sessionErrorMessage = nil
        realtimeCompletedQuestionCount = completedCount
        phase = .finished
        onFinished(transcript, isPartial, completedCount)
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
        onFinished(transcript, isPartial, completedCount)
    }
}
