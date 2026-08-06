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
    }

    // MARK: Observable state

    private(set) var phase: Phase = .idle
    private(set) var currentQuestionText: String = ""
    private(set) var showFinishAnswer = false
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
        }
    }

    var stateLabel: String {
        switch phase {
        case .interviewerSpeaking: "Speaking"
        case .candidateListening: "Listening"
        case .processingAnswer: "Thinking"
        case .paused: "Paused"
        default: ""
        }
    }

    var completedQuestionCount: Int { engine.askedQuestionCount }

    // MARK: Private

    private let engine: MockInterviewEngine
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
    }

    // MARK: Lifecycle

    func start() {
        guard phase == .idle else { return }
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
        guard phase != .paused, phase != .finished else { return }
        resumePhase = (phase == .processingAnswer) ? .processingAnswer : phase
        phaseTask?.cancel()
        phaseTask = nil
        showFinishAnswer = false
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
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

    /// User confirmed early end.
    func endInterview() {
        finish(early: true)
    }

    /// Fallback button pressed while listening.
    func finishAnswerPressed() {
        guard phase == .candidateListening else { return }
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

    private func finish(early: Bool) {
        guard !didFinish else { return }
        phaseTask?.cancel()
        phaseTask = nil
        didFinish = true
        endedEarly = early
        phase = .finished

        // Partial when ended before all selected questions were completed.
        let isPartial = early && engine.askedQuestionCount < configuration.questionCount.rawValue
        onFinished(transcript, isPartial, engine.askedQuestionCount)
    }
}
