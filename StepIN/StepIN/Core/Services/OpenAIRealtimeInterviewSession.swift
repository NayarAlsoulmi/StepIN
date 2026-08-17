//
//  OpenAIRealtimeInterviewSession.swift
//  StepIN
//
//  Minimal Realtime voice runtime. It preserves the existing StepIN UI state
//  machine while streaming microphone audio to OpenAI and playing returned audio.
//

import AVFoundation
import Foundation

@MainActor
final class OpenAIRealtimeInterviewSession {
    enum RuntimeState: Equatable {
        case preparing
        case ready
        case introductionSpeaking
        case openingBeat
        case listening
        case speaking
        case thinking
        case paused
        case completed
        case error
    }

    fileprivate enum InterviewLanguage: String, Equatable {
        case english = "English"
        case arabic = "Arabic"
    }

    private enum AssistantTurnPurpose: Equatable {
        case introduction
        case interview
        case closing
    }

    private enum CandidateTurnState: Equatable {
        case idle
        case speaking
        case pendingCompletion
        case committing
        case committed
    }

    private enum RealtimeConnectionState: String {
        case disconnected
        case connecting
        case socketConnected
        case sessionConfiguring
        case ready
        case failed
    }

    let finalPhrase = "Thank you. That concludes our interview."
    private var introductionText: String {
        let firstName = configuration.candidateFirstName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstName.isEmpty {
            return "Hello, \(firstName). I'm your AI Interviewer, and I'll be conducting your interview today."
        }

        return "Hello, I'm your AI Interviewer, and I'll be conducting your interview today."
    }

    private let configuration: InterviewConfiguration
    private let apiKey: String
    private let onStateChange: (RuntimeState) -> Void
    private let onInterviewerText: (String) -> Void
    private let onTranscriptEntry: (TranscriptEntry) -> Void
    private let onVoiceAnalysisResult: (_ turnID: UUID, _ emotion: String, _ confidence: Double) -> Void
    private let onCompleted: (_ isPartial: Bool, _ completedQuestionCount: Int) -> Void
    private let onError: (RealtimeSessionError) -> Void
    /// Called once per logical candidate turn (at response.create) with the accumulated
    /// transcript, and again if a late transcription.completed arrives afterwards.
    /// The ViewModel creates or updates a single entry per turnID.
    private let onCandidateTranscript: (_ turnID: UUID, _ text: String) -> Void
    private var primaryInterviewLanguage: InterviewLanguage = .english

    // Lazily constructed so the callback closure can capture self safely after
    // all stored properties are initialized (standard Swift two-phase init).
    private lazy var localAnalyzer: LocalVoiceAnalyzer = LocalVoiceAnalyzer(
        onSpeechResumed: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelPendingCandidateCompletion()
            }
        }
    )

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var audioEngine = AVAudioEngine()
    private var playbackEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let voiceStressAnalysisService = VoiceStressAnalysisService()
    private var microphoneInputFormat: AVAudioFormat?
    private var isConnected = false
    private var isPaused = false
    private var didComplete = false
    private var didReportError = false
    private var assistantTextBuffer = ""
    private var lastAssistantTranscript = ""
    private var bufferedAssistantAudioDeltas: [String] = []
    private var assistantQuestionAudioReleaseApproved = false
    private var audioGateStartedAt: Date?
    private var candidateTextBuffer = ""
    private var countedQuestionCount = 0
    private var assistantAudioActive = false
    private var serverAudioDone = true
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration = 0
    private var shouldCompleteAfterAssistantPlayback = false
    private var candidateCompletionTask: Task<Void, Never>?
    private var openingQuestionTask: Task<Void, Never>?
    private let openingQuestionBeat: Duration = .milliseconds(550)
    private var uploadedCandidateAudioDurationMs: Double = 0
    private var candidateResponseInFlight = false
    private var serverVADStoppedCurrentTurn = false
    private let minimumCommitAudioDurationMs: Double = 100
    private var hasDeliveredIntroduction = false
    private var currentAssistantTurnPurpose: AssistantTurnPurpose = .interview
    private var candidateTurnState: CandidateTurnState = .idle
    private var assistantTurnPending = false
    private var assistantResponseCreated = false
    private var serverResponseActive = false
    private var activeResponseID: String?
    private var obsoleteResponseIDs: Set<String> = []
    private var validatedResponseIDs: Set<String> = []
    private var regenerationTriggeredResponseIDs: Set<String> = []
    private var currentLocalResponseKey = UUID().uuidString
    private var assistantAudioStartedAt: Date?
    private var pendingCompletionStartedAt: Date?
    private var lastSpeechStoppedAt: Date?
    private var responseCommitStartedAt: Date?
    private var shouldCompleteCurrentAssistantTurn = false
    private var connectionState: RealtimeConnectionState = .disconnected
    private var didStartIntroductionAudio = false
    private let conversationController: InterviewConversationController
    private var pendingAssistantTurnCountsTowardTotal = false
    private var currentStartupPhase: RealtimeStartupPhase = .notStarted
    private var startupT0: Date?
    private var didLogIntroAudioStart = false
    private var didLogFirstQuestionAudioStart = false
    private var languageViolationRecoveryNeeded = false
    private var languageRegenerationAttemptedForCurrentResponse = false
    private var activeAssistantBaseInstructions: String?
    private var didPrepareRealtimeInfrastructure = false
    private var didBeginInterview = false
    private var didEmitClosingTranscript = false

    // MARK: — Candidate turn / transcript identity

    /// Local UUID for the current logical candidate answer turn.
    /// Created at speech_started, cleared only once assistant audio actually begins.
    /// A resumed turn (candidate pauses then continues) reuses the same UUID.
    private var activeCandidateTurnID: UUID?
    /// Maps API item_id strings → local candidate turn UUIDs.
    /// Kept across turns so late transcription.completed events (arriving after
    /// response.create) can still be matched to the correct transcript entry.
    private var itemIDToCandidateTurnID: [String: UUID] = [:]
    /// Accumulated authoritative transcript texts per turn, one element per
    /// audio item committed by the server VAD (in arrival order).
    private var candidateTranscriptAccumulator: [UUID: [String]] = [:]
    /// Turn UUIDs for which onCandidateTranscript has been called at least once.
    /// Routes subsequent transcription.completed events to the update path.
    private var emittedCandidateTurnIDs: Set<UUID> = []
    private var candidateTurnItemIDs: [UUID: [String]] = [:]
    private var candidateTranscriptTextByItemID: [String: String] = [:]
    private var pendingTranscriptionItemIDs: Set<String> = []
    private var pendingTranscriptionWaitStartedAt: Date?
    private var currentVoiceAnalysisTurnID: UUID?
    private var voiceResultTurnIDForNextResult: UUID?

    init(
        configuration: InterviewConfiguration,
        apiKey: String,
        onStateChange: @escaping (RuntimeState) -> Void,
        onInterviewerText: @escaping (String) -> Void,
        onTranscriptEntry: @escaping (TranscriptEntry) -> Void,
        onVoiceAnalysisResult: @escaping (_ turnID: UUID, _ emotion: String, _ confidence: Double) -> Void = { _, _, _ in },
        onCandidateTranscript: @escaping (_ turnID: UUID, _ text: String) -> Void,
        onCompleted: @escaping (_ isPartial: Bool, _ completedQuestionCount: Int) -> Void,
        onError: @escaping (RealtimeSessionError) -> Void
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.onStateChange = onStateChange
        self.onInterviewerText = onInterviewerText
        self.onTranscriptEntry = onTranscriptEntry
        self.onVoiceAnalysisResult = onVoiceAnalysisResult
        self.onCandidateTranscript = onCandidateTranscript
        self.onCompleted = onCompleted
        self.onError = onError
        self.conversationController = InterviewConversationController(configuration: configuration)
        self.voiceStressAnalysisService.onResult = { [weak self] emotion, confidence in
            self?.handleVoiceAnalysisResult(emotion: emotion, confidence: confidence)
        }
    }

    func start() async throws {
        try await prepare()
        try await beginInterview()
    }

    func prepare() async throws {
        guard !didPrepareRealtimeInfrastructure else {
            onStateChange(.ready)
            return
        }

        do {
            startupT0 = .now
            logInterviewStartup("T2 realtime preparation starts")
            onStateChange(.preparing)
            setStartupPhase(.audioSetup)
            try configureAudioSession()
            configurePlayback()
            setStartupPhase(.connect)
            try connectWebSocket()
            setStartupPhase(.sessionUpdate)
            setConnectionState(.sessionConfiguring)
            try await sendSessionUpdate()
            setStartupPhase(.completed)
            setConnectionState(.ready)
            didPrepareRealtimeInfrastructure = true
            logInterviewStartup("T5 realtime READY")
            onStateChange(.ready)
        } catch let error as RealtimeStartupFailure {
            throw RealtimeSessionError(
                message: error.localizedDescription,
                type: "startup",
                code: nil,
                param: nil,
                diagnostics: error.diagnostics
            )
        } catch let error as RealtimeSessionError {
            throw error
        } catch {
            let diagnostics = startupDiagnostics(for: error, phase: currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeSessionError(
                message: error.localizedDescription,
                type: "startup",
                code: nil,
                param: nil,
                diagnostics: diagnostics
            )
        }
    }

    func beginInterview() async throws {
        guard didPrepareRealtimeInfrastructure else {
            try await prepare()
            try await beginInterview()
            return
        }
        guard !didBeginInterview else { return }
        didBeginInterview = true

        do {
            setStartupPhase(.audioSetup)
            try startMicrophoneCapture()
            setStartupPhase(.responseCreate)
            try await requestOpeningTurn()
            logStartupFlag("responseCreateSent", true)
            logInterviewStartup("T8 opening response.create sent")
        } catch let error as RealtimeStartupFailure {
            throw RealtimeSessionError(
                message: error.localizedDescription,
                type: "startup",
                code: nil,
                param: nil,
                diagnostics: error.diagnostics
            )
        } catch let error as RealtimeSessionError {
            throw error
        } catch {
            let diagnostics = startupDiagnostics(for: error, phase: currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeSessionError(
                message: error.localizedDescription,
                type: "startup",
                code: nil,
                param: nil,
                diagnostics: diagnostics
            )
        }
    }

    func pause() {
        isPaused = true
        stopVoiceAnalysis()
        audioEngine.pause()
        playerNode.pause()
        onStateChange(.paused)
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        try? audioEngine.start()
        playerNode.play()
        // Reset silence tracking so that user-initiated pause time is not
        // counted as a candidate delivery pause in the voice metrics.
        Task { await localAnalyzer.resetSilenceTracking() }
        onStateChange(.listening)
    }

    func finishCurrentAnswer() {
        candidateCompletionTask?.cancel()
        candidateCompletionTask = nil
        stopVoiceAnalysis()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.serverVADStoppedCurrentTurn || self.shouldCommitCandidateAudioManually else {
                self.uploadedCandidateAudioDurationMs = 0
                self.onStateChange(.listening)
                return
            }

            await self.requestAssistantResponseForCompletedCandidateTurn(commitIfNeeded: self.shouldCommitCandidateAudioManually)
        }
    }

    func endEarly() {
        complete(isPartial: countedQuestionCount < configuration.questionCount.rawValue)
    }

    func collectDeliveryMetrics(transcript: [TranscriptEntry]) async -> VoiceDeliveryMetrics {
        let fillerCount = VoiceDeliveryMetrics.countFillerWords(in: transcript)
        return await localAnalyzer.generateMetrics(fillerWordCount: fillerCount)
    }

    func stop() {
        candidateCompletionTask?.cancel()
        candidateCompletionTask = nil
        openingQuestionTask?.cancel()
        openingQuestionTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        stopVoiceAnalysis()
        audioEngine.stop()
        microphoneInputFormat = nil
        playbackGeneration += 1
        pendingPlaybackBuffers = 0
        assistantAudioActive = false
        serverAudioDone = true
        shouldCompleteAfterAssistantPlayback = false
        uploadedCandidateAudioDurationMs = 0
        candidateResponseInFlight = false
        serverVADStoppedCurrentTurn = false
        candidateTurnState = .idle
        assistantTurnPending = false
        assistantResponseCreated = false
        serverResponseActive = false
        activeResponseID = nil
        obsoleteResponseIDs = []
        validatedResponseIDs = []
        regenerationTriggeredResponseIDs = []
        currentLocalResponseKey = UUID().uuidString
        assistantAudioStartedAt = nil
        pendingCompletionStartedAt = nil
        lastSpeechStoppedAt = nil
        responseCommitStartedAt = nil
        shouldCompleteCurrentAssistantTurn = false
        activeCandidateTurnID = nil
        itemIDToCandidateTurnID = [:]
        candidateTranscriptAccumulator = [:]
        emittedCandidateTurnIDs = []
        candidateTurnItemIDs = [:]
        candidateTranscriptTextByItemID = [:]
        pendingTranscriptionItemIDs = []
        pendingTranscriptionWaitStartedAt = nil
        currentVoiceAnalysisTurnID = nil
        voiceResultTurnIDForNextResult = nil
        hasDeliveredIntroduction = false
        currentAssistantTurnPurpose = .interview
        didStartIntroductionAudio = false
        pendingAssistantTurnCountsTowardTotal = false
        languageViolationRecoveryNeeded = false
        languageRegenerationAttemptedForCurrentResponse = false
        didEmitClosingTranscript = false
        activeAssistantBaseInstructions = nil
        bufferedAssistantAudioDeltas = []
        assistantQuestionAudioReleaseApproved = false
        didPrepareRealtimeInfrastructure = false
        didBeginInterview = false
        startupT0 = nil
        didLogIntroAudioStart = false
        didLogFirstQuestionAudioStart = false
        logSocketSnapshot(prefix: "preStop")
        playerNode.stop()
        playbackEngine.stop()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        setConnectionState(.disconnected)
    }

    // MARK: Connection

    private func connectWebSocket() throws {
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime") else {
            throw RealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = URLSession.shared.webSocketTask(with: request)
        webSocketTask = task
        setConnectionState(.connecting)
        task.resume()
        isConnected = true
        setConnectionState(.socketConnected)
        logInterviewStartup("T3 socket connected")
        logStartupFlag("socketOpened", true)
        logSocketSnapshot(prefix: "afterConnect")
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    private func sendSessionUpdate() async throws {
        let prompt = InterviewSystemPrompt.make(for: configuration, primaryInterviewLanguage: primaryInterviewLanguage.rawValue)
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "model": "gpt-realtime",
                "instructions": prompt,
                "output_modalities": ["audio"],
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "turn_detection": [
                            "type": "semantic_vad",
                            "eagerness": "medium",
                            "create_response": false,
                            "interrupt_response": false
                        ],
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe"
                        ]
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": "alloy"
                    ]
                ]
            ]
        ]
        try await sendEvent(event, startupPhase: .sessionUpdate)
        logStartupFlag("sessionUpdateSent", true)
        logInterviewStartup("T4 session.update sent")
    }

    private func requestOpeningTurn() async throws {
        prepareAssistantTurn(purpose: .introduction, willCompleteInterview: false)
        didStartIntroductionAudio = false
        try await sendResponseCreate(
            instructions: "Speak exactly this English introduction and do not ask any interview question: \"\(introductionText)\"",
            startupPhase: .responseCreate
        )
    }

    private func sendResponseCreate(instructions: String, startupPhase: RealtimeStartupPhase? = nil) async throws {
        activeAssistantBaseInstructions = instructions
        languageRegenerationAttemptedForCurrentResponse = false
        bufferedAssistantAudioDeltas = []
        assistantQuestionAudioReleaseApproved = false
        activeResponseID = nil
        serverResponseActive = false
        currentLocalResponseKey = UUID().uuidString
        try await sendEvent([
            "type": "response.create",
            "response": [
                "instructions": responseInstructions(for: instructions)
            ]
        ], startupPhase: startupPhase)
    }

    private func resendCurrentResponseWithStrongerLanguageLock() async {
        guard let instructions = activeAssistantBaseInstructions,
              !languageRegenerationAttemptedForCurrentResponse,
              candidateResponseInFlight,
              !assistantAudioActive else {
            languageViolationRecoveryNeeded = true
            return
        }

        languageRegenerationAttemptedForCurrentResponse = true
        languageViolationRecoveryNeeded = true
        await regenerateAssistantResponse(
            instructions: responseInstructions(for: instructions, forceRecovery: true),
            reason: "language_regeneration"
        )
    }

    private func responseInstructions(for instructions: String, forceRecovery: Bool = false) -> String {
        let languageLock = "LANGUAGE LOCK: Output only in \(primaryInterviewLanguage.rawValue). Do not mirror or switch languages because the candidate used, mentioned, or was transcribed as another language. Swift supports only English and Arabic and has selected \(primaryInterviewLanguage.rawValue) for this response."
        let inCharacterGuard = "IN-CHARACTER SPOKEN OUTPUT ONLY: Speak directly to the candidate as the interviewer. Output only a natural interview question, a brief acknowledgement, a clarification question, a professional transition, or the final closing. Never mention the user, the assistant, the interviewer, prompt instructions, strategy, planning, analysis, whether you need more information, or what you will ask later. If more information is needed, ask the candidate directly."
        let recovery = (languageViolationRecoveryNeeded || forceRecovery)
            ? "Previous assistant output violated the language lock. Correct now: respond only in \(primaryInterviewLanguage.rawValue), with no unsupported third language."
            : nil
        languageViolationRecoveryNeeded = false
        return [languageLock, inCharacterGuard, recovery, instructions].compactMap { $0 }.joined(separator: "\n")
    }

    private func sendEvent(_ event: [String: Any], startupPhase: RealtimeStartupPhase? = nil) async throws {
        if let startupPhase {
            setStartupPhase(startupPhase)
        }
        guard let webSocketTask else {
            let diagnostics = startupDiagnostics(for: RealtimeError.notConnected, phase: startupPhase ?? currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeStartupFailure(diagnostics: diagnostics)
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: event)
        } catch {
            let diagnostics = startupDiagnostics(for: error, phase: startupPhase ?? currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeStartupFailure(diagnostics: diagnostics)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            let diagnostics = startupDiagnostics(for: RealtimeError.encodingFailed, phase: startupPhase ?? currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeStartupFailure(diagnostics: diagnostics)
        }

        do {
            try await webSocketTask.send(.string(text))
        } catch {
            let diagnostics = startupDiagnostics(for: error, phase: startupPhase ?? currentStartupPhase)
            logStartupDiagnostics(diagnostics)
            throw RealtimeStartupFailure(diagnostics: diagnostics)
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled, isConnected {
            do {
                guard let message = try await webSocketTask?.receive() else { return }
                switch message {
                case .string(let text):
                    handleEventText(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleEventText(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                guard !didComplete else { return }
                let diagnostics = startupDiagnostics(for: error, phase: currentStartupPhase)
                logStartupDiagnostics(diagnostics)
                reportError(RealtimeSessionError(
                    message: error.localizedDescription,
                    type: "websocket_receive",
                    code: nil,
                    param: nil,
                    diagnostics: diagnostics
                ))
                return
            }
        }
    }

    private func handleEventText(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }

        if isObsoleteResponseEvent(object) {
            logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
            return
        }

        switch type {
        case "input_audio_buffer.speech_started":
            handleCandidateSpeechStarted(itemID: object["item_id"] as? String)
        case "input_audio_buffer.speech_stopped":
            handleCandidateSpeechStopped(itemID: object["item_id"] as? String)
        case "conversation.item.input_audio_transcription.completed":
            updateCandidateTranscript(
                itemID: object["item_id"] as? String ?? "",
                text: object["transcript"] as? String ?? ""
            )
        case "response.created":
            let responseID = responseID(from: object)
            activeResponseID = responseID
            if let responseID {
                obsoleteResponseIDs.remove(responseID)
            }
            serverResponseActive = true
            assistantResponseCreated = true
            assistantTurnPending = true
            logTurnOwnership(
                speechStopped: false,
                evaluation: nil,
                responseCreateSent: candidateResponseInFlight,
                responseCreated: assistantResponseCreated,
                assistantAudioActuallyStarted: false,
                speechResumed: false,
                responseCancelled: false,
                candidateStateBefore: candidateTurnState,
                candidateStateAfter: candidateTurnState,
                candidateAudioSuppressed: false
            )
        case "response.output_item.added", "response.content_part.added":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            assistantResponseCreated = true
            assistantTurnPending = true
        case "response.output_audio.delta", "response.audio.delta":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            if let delta = object["delta"] as? String {
                handleAssistantAudioDelta(delta)
            }
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            if let delta = object["delta"] as? String {
                assistantTextBuffer += delta
                if shouldGateCurrentInterviewQuestion {
                    tryEarlyAudioRelease()
                } else {
                    onInterviewerText(assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        case "response.output_audio.done", "response.audio.done":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            serverAudioDone = true
            logAssistantPlayback(audioDeltaReceived: false, bufferScheduled: false, bufferPlayed: false)
            finishAssistantPlaybackIfReady()
        case "response.output_audio_transcript.done", "response.audio_transcript.done", "response.output_text.done":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            if let transcript = object["transcript"] as? String ?? object["text"] as? String {
                assistantTextBuffer = transcript
            }
            flushAssistantTranscriptIfNeeded()
        case "response.done", "response.cancelled", "response.failed":
            guard responseBelongsToActiveTurn(object) else {
                logIgnoredObsoleteResponseEvent(type: type, responseID: responseID(from: object))
                return
            }
            if responseID(from: object) == activeResponseID || responseID(from: object) == nil {
                serverResponseActive = false
            }
            let completedText = assistantTextBuffer.isEmpty ? lastAssistantTranscript : assistantTextBuffer
            flushAssistantTranscriptIfNeeded()
            // Primary gate: shouldCompleteCurrentAssistantTurn is set to true whenever
            // prepareAssistantTurn(willCompleteInterview: true) was called (i.e. for .finalClose actions).
            // This fires regardless of what text the model actually speaks, so model drift cannot prevent
            // completion. The finalPhrase check is a belt-and-suspenders fallback for edge cases
            // (e.g. a future code path that uses finalPhrase without setting willCompleteInterview).
            shouldCompleteAfterAssistantPlayback = shouldCompleteCurrentAssistantTurn || completedText.contains(finalPhrase)
            shouldCompleteCurrentAssistantTurn = false
            serverAudioDone = true
            candidateResponseInFlight = false
            if assistantAudioActive {
                finishAssistantPlaybackIfReady()
            } else if assistantTurnPending {
                finishPendingAssistantResponseWithoutAudio()
            }
        case "error":
            let error = RealtimeSessionError(openAIEvent: object)
            logOpenAIErrorEvent(object)
            if error.isEmptyAudioCommit {
                recoverFromEmptyAudioCommit()
            } else if error.isResponseCancelNotActive {
                handleRecoverableResponseCancelNotActive()
            } else {
                reportError(error)
            }
        default:
            break
        }
    }

    private func responseID(from object: [String: Any]) -> String? {
        if let responseID = object["response_id"] as? String {
            return responseID
        }
        if let response = object["response"] as? [String: Any],
           let responseID = response["id"] as? String {
            return responseID
        }
        return nil
    }

    private func responseBelongsToActiveTurn(_ object: [String: Any]) -> Bool {
        guard let eventResponseID = responseID(from: object) else {
            return true
        }
        if obsoleteResponseIDs.contains(eventResponseID) {
            return false
        }
        guard let activeResponseID else {
            return true
        }
        return eventResponseID == activeResponseID
    }

    private func isObsoleteResponseEvent(_ object: [String: Any]) -> Bool {
        guard let responseID = responseID(from: object) else { return false }
        return obsoleteResponseIDs.contains(responseID)
    }

    private func currentValidationResponseKey() -> String {
        activeResponseID ?? currentLocalResponseKey
    }

    private func markActiveResponseObsolete() {
        if let activeResponseID {
            obsoleteResponseIDs.insert(activeResponseID)
        }
    }

    private func cancelActiveAssistantResponseIfNeeded() async {
        guard serverResponseActive else {
            logResponseCancellation(skipped: true, reason: "server_response_not_active")
            return
        }
        let cancellingResponseID = activeResponseID
        do {
            try await sendEvent(["type": "response.cancel"])
            serverResponseActive = false
            logResponseCancellation(skipped: false, reason: "cancel_sent")
        } catch {
            let message = error.localizedDescription
            // NOTE: sendEvent() only throws for local failures (no WebSocket task, JSON encode error).
            // It does NOT throw based on server-side rejection, so this branch is effectively unreachable
            // for "response_cancel_not_active". Server-side cancellation errors arrive asynchronously via
            // the WebSocket "error" event and are handled by handleRecoverableResponseCancelNotActive().
            // This catch block is kept as a belt-and-suspenders fallback only.
            if message.contains("response_cancel_not_active") || message.contains("no active response") {
                serverResponseActive = false
                logResponseCancellation(skipped: true, reason: "response_cancel_not_active")
                return
            }
            #if DEBUG
            print("[Realtime] responseCancelFailed responseID=\(cancellingResponseID ?? "unknown") error=\(message)")
            #endif
        }
    }

    private func regenerateAssistantResponse(instructions: String, reason: String) async {
        markActiveResponseObsolete()
        discardInvalidAssistantOutput()
        await cancelActiveAssistantResponseIfNeeded()
        do {
            try await sendResponseCreate(instructions: instructions)
        } catch {
            reportError(RealtimeSessionError(message: error.localizedDescription, type: reason, code: nil, param: nil))
        }
    }

    private func discardInvalidAssistantOutput() {
        discardBufferedAssistantAudio()
        assistantTextBuffer = ""
        lastAssistantTranscript = ""
    }

    private func handleRecoverableResponseCancelNotActive() {
        serverResponseActive = false
        #if DEBUG
        print("[Realtime] Ignoring recoverable response_cancel_not_active")
        #endif
    }

    private func logResponseCancellation(skipped: Bool, reason: String) {
        #if DEBUG
        print("[RealtimeResponseLifecycle] cancelSkipped=\(skipped) reason=\(reason) activeResponseID=\(activeResponseID ?? "none") serverResponseActive=\(serverResponseActive)")
        #endif
    }

    private func logIgnoredObsoleteResponseEvent(type: String, responseID: String?) {
        #if DEBUG
        print("[RealtimeResponseLifecycle] ignoredObsoleteEvent type=\(type) responseID=\(responseID ?? "none") activeResponseID=\(activeResponseID ?? "none")")
        #endif
    }

    private func handleCandidateSpeechStarted(itemID: String?) {
        let stateBefore = candidateTurnState
        let responseCreateSentBefore = candidateResponseInFlight
        let responseCreatedBefore = assistantResponseCreated
        // Never reclaim a closing-purpose response: cancelling it would clear
        // shouldCompleteCurrentAssistantTurn and leave the interview stuck open,
        // causing the model to deliver a second goodbye on the next candidate turn.
        let canReclaimResponse = assistantTurnPending && candidateResponseInFlight && !isAssistantPlaybackAudiblyActive && currentAssistantTurnPurpose != .closing
        cancelPendingCandidateCompletion()
        beginCandidateTurn(itemID: itemID)

        if canReclaimResponse {
            cancelRecoverableAssistantResponse()
            candidateResponseInFlight = false
            assistantResponseCreated = false
            assistantTurnPending = false
            shouldCompleteCurrentAssistantTurn = false
            pendingAssistantTurnCountsTowardTotal = false
            assistantTextBuffer = ""
            bufferedAssistantAudioDeltas = []
            assistantQuestionAudioReleaseApproved = false
            candidateTurnState = .speaking
        }

        let suppressed = shouldSuppressCandidateInput
        logTurnOwnership(
            speechStopped: false,
            evaluation: nil,
            responseCreateSent: responseCreateSentBefore,
            responseCreated: responseCreatedBefore,
            assistantAudioActuallyStarted: assistantAudioActive,
            speechResumed: true,
            responseCancelled: canReclaimResponse,
            candidateStateBefore: stateBefore,
            candidateStateAfter: candidateTurnState,
            candidateAudioSuppressed: suppressed
        )

        if !suppressed {
            candidateResponseInFlight = false
            serverVADStoppedCurrentTurn = false
            startVoiceAnalysisIfNeeded()
            onStateChange(.listening)
        }
    }

    private func handleCandidateSpeechStopped(itemID: String?) {
        let stateBefore = candidateTurnState
        let suppressed = shouldSuppressCandidateInput
        if let itemID, !itemID.isEmpty, let turnID = activeCandidateTurnID {
            itemIDToCandidateTurnID[itemID] = turnID
            recordCandidateItemID(itemID, for: turnID)
        }
        logTranscriptPipeline(
            "speechStopped",
            itemID: itemID,
            mappedTurnID: activeCandidateTurnID,
            textLength: nil,
            accumulatedTextLength: candidateTextBuffer.count,
            responseCreate: candidateResponseInFlight,
            turnClosed: false
        )
        logTurnOwnership(
            speechStopped: true,
            evaluation: nil,
            responseCreateSent: candidateResponseInFlight,
            responseCreated: assistantResponseCreated,
            assistantAudioActuallyStarted: assistantAudioActive,
            speechResumed: false,
            responseCancelled: false,
            candidateStateBefore: stateBefore,
            candidateStateAfter: candidateTurnState,
            candidateAudioSuppressed: suppressed
        )
        if !suppressed {
            serverVADStoppedCurrentTurn = true
            lastSpeechStoppedAt = Date()
            stopVoiceAnalysis()
            scheduleCandidateCompletion()
            onStateChange(.listening)
        }
    }

    private func cancelRecoverableAssistantResponse() {
        guard serverResponseActive else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cancelActiveAssistantResponseIfNeeded()
        }
    }

    private func finishPendingAssistantResponseWithoutAudio() {
        assistantTurnPending = false
        assistantResponseCreated = false
        candidateTurnState = .idle
        pendingAssistantTurnCountsTowardTotal = false
        assistantTextBuffer = ""
        bufferedAssistantAudioDeltas = []
        assistantQuestionAudioReleaseApproved = false
        // Check the completion flag BEFORE clearing it — this was set when the
        // closing action sent response.create with willCompleteInterview=true.
        // Clearing it unconditionally caused the interview to stay open (returning
        // to .listening) even after the model's goodbye, producing a second close cycle.
        if shouldCompleteAfterAssistantPlayback {
            shouldCompleteAfterAssistantPlayback = false
            complete(isPartial: false)
        } else if !didComplete {
            onStateChange(.listening)
        }
    }

    // MARK: Audio

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(24_000)
        try session.setActive(true)
    }

    private func configurePlayback() {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: format)

        do {
            try playbackEngine.start()
            playerNode.play()
        } catch {
            playbackEngine.stop()
        }
    }

    private func startMicrophoneCapture() throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // SwiftUI Preview has no real audio hardware; inputNode returns sampleRate=0 /
        // channelCount=0. Passing that to installTap raises a fatal CoreAudio assertion.
        // Skip capture entirely — preview never sends audio to OpenAI anyway.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        microphoneInputFormat = inputFormat
        let voiceAnalyzer = voiceStressAnalysisService
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self, voiceAnalyzer] buffer, time in
            voiceAnalyzer.analyze(buffer, atAudioFramePosition: time.sampleTime)
            guard let self else { return }
            let pcmData = Self.convertToPCM16Data(buffer: buffer)
            guard !pcmData.isEmpty else { return }
            let base64 = pcmData.base64EncodedString()
            let durationMs = Self.pcm16DurationMilliseconds(pcmData)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let suppressed = self.isPaused || !self.isConnected || self.shouldSuppressCandidateInput
                self.logAudioPipeline(
                    micBufferCaptured: true,
                    micBufferSuppressed: suppressed,
                    micBufferUploaded: !suppressed
                )
                guard !suppressed else { return }
                // Fan-out: dispatch PCM to the local analyzer concurrently with the
                // OpenAI send so ingest latency does not add to network latency.
                // The analyzer's serial actor executor preserves buffer order.
                Task { await self.localAnalyzer.ingest(pcmData: pcmData) }
                try? await self.sendEvent(["type": "input_audio_buffer.append", "audio": base64])
                self.uploadedCandidateAudioDurationMs += durationMs
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func startVoiceAnalysisIfNeeded() {
        guard let microphoneInputFormat, let turnID = activeCandidateTurnID else { return }

        do {
            currentVoiceAnalysisTurnID = turnID
            voiceResultTurnIDForNextResult = nil
            logVoiceCoreML(
                turnID: turnID,
                analysisStarted: true,
                analysisStopped: false,
                classification: nil,
                confidence: nil,
                resultStored: false,
                transcriptExists: emittedCandidateTurnIDs.contains(turnID),
                resultAttached: false
            )
            try voiceStressAnalysisService.startAnalyzingExistingStream(format: microphoneInputFormat)
        } catch {
            print("VoiceStressAnalysisService error:", error)
        }
    }

    private func stopVoiceAnalysis() {
        voiceResultTurnIDForNextResult = currentVoiceAnalysisTurnID
        if let turnID = currentVoiceAnalysisTurnID {
            logVoiceCoreML(
                turnID: turnID,
                analysisStarted: false,
                analysisStopped: true,
                classification: nil,
                confidence: nil,
                resultStored: false,
                transcriptExists: emittedCandidateTurnIDs.contains(turnID),
                resultAttached: false
            )
        }
        voiceStressAnalysisService.stopAnalyzing()
    }

    private func handleVoiceAnalysisResult(emotion: String, confidence: Double) {
        guard let turnID = voiceResultTurnIDForNextResult ?? currentVoiceAnalysisTurnID ?? activeCandidateTurnID else {
            #if DEBUG
            print("[VoiceCoreML] turnID=nil analysisStarted=false analysisStopped=true classification=\(emotion) confidence=\(String(format: "%.2f", confidence)) resultStored=false transcriptExists=false resultAttached=false")
            #endif
            return
        }

        onVoiceAnalysisResult(turnID, emotion, confidence)
        logVoiceCoreML(
            turnID: turnID,
            analysisStarted: false,
            analysisStopped: false,
            classification: emotion,
            confidence: confidence,
            resultStored: true,
            transcriptExists: emittedCandidateTurnIDs.contains(turnID),
            resultAttached: emittedCandidateTurnIDs.contains(turnID)
        )
        if voiceResultTurnIDForNextResult == turnID {
            voiceResultTurnIDForNextResult = nil
        }
    }

    private func playBase64PCM(_ base64: String) {
        guard let data = Data(base64Encoded: base64), !data.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)) else {
            return
        }

        buffer.frameLength = buffer.frameCapacity
        data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: Int16.self).baseAddress,
                  let destination = buffer.int16ChannelData?[0] else { return }
            destination.update(from: source, count: Int(buffer.frameLength))
        }

        if !playbackEngine.isRunning { try? playbackEngine.start() }
        if !playerNode.isPlaying { playerNode.play() }

        let generation = playbackGeneration
        pendingPlaybackBuffers += 1
        logAssistantPlayback(audioDeltaReceived: false, bufferScheduled: true, bufferPlayed: false)
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                self.logAssistantPlayback(audioDeltaReceived: false, bufferScheduled: false, bufferPlayed: true)
                self.finishAssistantPlaybackIfReady()
            }
        }
    }

    private func scheduleCandidateCompletion() {
        candidateCompletionTask?.cancel()
        candidateTurnState = .pendingCompletion
        pendingCompletionStartedAt = Date()
        let delay = firstTurnCompletionEvaluationDelay()
        candidateCompletionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.evaluatePendingCandidateCompletion()
            } catch {
                return
            }
        }
    }

    private func cancelPendingCandidateCompletion() {
        let hadPendingCompletion = candidateCompletionTask != nil || candidateTurnState == .pendingCompletion
        candidateCompletionTask?.cancel()
        candidateCompletionTask = nil
        pendingCompletionStartedAt = nil
        if candidateTurnState == .pendingCompletion {
            candidateTurnState = .speaking
        }
        #if DEBUG
        if hadPendingCompletion {
            print("[CandidateTurn] speechStopped=false semanticContinuation=nil prosodyEnding=nil completionCandidate=false speechResumed=true handoffCancelled=true finalized=false responseCommitted=\(candidateTurnState == .committed) assistantAudioStarted=\(assistantAudioStartedAt != nil)")
        }
        #endif
    }

    private var shouldCommitCandidateAudioManually: Bool {
        !serverVADStoppedCurrentTurn && uploadedCandidateAudioDurationMs >= minimumCommitAudioDurationMs
    }

    private var shouldSuppressCandidateInput: Bool {
        isAssistantPlaybackAudiblyActive
    }

    private var isAssistantPlaybackAudiblyActive: Bool {
        assistantAudioActive && pendingPlaybackBuffers > 0
    }

    private func firstTurnCompletionEvaluationDelay() -> Duration {
        .milliseconds(150)
    }

    private func evaluatePendingCandidateCompletion() async {
        guard candidateTurnState == .pendingCompletion, !didComplete, !didReportError else { return }

        if shouldWaitForActiveTurnTranscription() {
            logTranscriptPipeline(
                "waitingForTranscription",
                itemID: pendingTranscriptionItemIDs.first,
                mappedTurnID: activeCandidateTurnID,
                textLength: nil,
                accumulatedTextLength: candidateTextBuffer.count,
                responseCreate: false,
                turnClosed: false
            )
            candidateCompletionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    await self?.evaluatePendingCandidateCompletion()
                } catch {
                    return
                }
            }
            return
        }

        let transcript = candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        let silenceMs = max(
            lastSpeechStoppedAt.map { Date().timeIntervalSince($0) * 1_000 } ?? 0,
            await localAnalyzer.turnSnapshot().confirmedSilenceMs
        )
        let voiceSnapshot = await localAnalyzer.turnSnapshot()
        let evaluation = TurnCompletionEvaluator.evaluate(
            transcript: transcript,
            serverVADStopped: serverVADStoppedCurrentTurn,
            silenceMs: silenceMs,
            voiceSnapshot: voiceSnapshot
        )

        logTurnCompletion(evaluation: evaluation, silenceMs: silenceMs, voiceSnapshot: voiceSnapshot)
        logTurnOwnership(
            speechStopped: true,
            evaluation: evaluation.decision.rawValue,
            responseCreateSent: candidateResponseInFlight,
            responseCreated: assistantResponseCreated,
            assistantAudioActuallyStarted: assistantAudioActive,
            speechResumed: false,
            responseCancelled: false,
            candidateStateBefore: candidateTurnState,
            candidateStateAfter: candidateTurnState,
            candidateAudioSuppressed: false
        )

        switch evaluation.decision {
        case .waiting, .likelyFinished:
            let delay: Duration = evaluation.decision == .waiting ? .milliseconds(180) : .milliseconds(100)
            candidateCompletionTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                    await self?.evaluatePendingCandidateCompletion()
                } catch {
                    return
                }
            }
        case .finished:
            await requestAssistantResponseForCompletedCandidateTurn(commitIfNeeded: false)
        }
    }

    private func requestAssistantResponseForCompletedCandidateTurn(commitIfNeeded: Bool) async {
        guard !shouldSuppressCandidateInput, !didComplete, !didReportError, !candidateResponseInFlight else { return }
        candidateCompletionTask = nil
        pendingCompletionStartedAt = nil
        candidateTurnState = .committing
        responseCommitStartedAt = Date()
        stopVoiceAnalysis()

        if commitIfNeeded {
            guard uploadedCandidateAudioDurationMs >= minimumCommitAudioDurationMs else {
                uploadedCandidateAudioDurationMs = 0
                onStateChange(.listening)
                return
            }

            do {
                try await sendEvent(["type": "input_audio_buffer.commit"])
            } catch {
                reportError(RealtimeSessionError(message: error.localizedDescription, type: "input_audio_buffer.commit", code: nil, param: nil))
                return
            }
        }

        candidateResponseInFlight = true
        do {
            let textToEmit: String
            let activeTurnID = activeCandidateTurnID
            if let turnID = activeTurnID {
                let accumulated = accumulatedCandidateTranscript(for: turnID)
                textToEmit = accumulated.isEmpty
                    ? candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    : accumulated
            } else {
                textToEmit = candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            let languageRequest = Self.requestedInterviewLanguage(in: textToEmit, currentLanguage: primaryInterviewLanguage)
            if let requestedLanguage = languageRequest {
                let previousLanguage = primaryInterviewLanguage
                let capturedInstructions = activeAssistantBaseInstructions
                primaryInterviewLanguage = requestedLanguage
                do {
                    try await sendLanguageInstructionUpdate()
                } catch {
                    candidateResponseInFlight = false
                    reportError(RealtimeSessionError(message: error.localizedDescription, type: "session_language_update", code: nil, param: nil))
                    return
                }
                consumeLanguageControlTurn(turnID: activeTurnID)
                logLanguageControlDecision(
                    candidateText: textToEmit,
                    requestedLanguage: requestedLanguage,
                    previousLanguage: previousLanguage,
                    newLanguage: primaryInterviewLanguage,
                    sessionUpdateSent: true,
                    responseCreateSent: true,
                    normalInterviewActionSkipped: true,
                    returnedToListening: false
                )
                await resumeInterviewAfterLanguageSwitch(previousQuestionInstructions: capturedInstructions)
                return
            }

            // Emit exactly one candidate transcript entry for this logical turn.
            // Joins all transcription.completed texts received since speech_started.
            // Marks the turn as emitted so any late-arriving transcription.completed
            // event will update the existing entry rather than append a new one.
            if let turnID = activeCandidateTurnID {
                emittedCandidateTurnIDs.insert(turnID)
                if !textToEmit.isEmpty {
                    onCandidateTranscript(turnID, textToEmit)
                }
                logTranscriptPipeline(
                    "responseCreate",
                    itemID: nil,
                    mappedTurnID: turnID,
                    textLength: textToEmit.count,
                    accumulatedTextLength: textToEmit.count,
                    responseCreate: true,
                    turnClosed: false
                )
            } else {
                logTranscriptPipeline(
                    "responseCreate",
                    itemID: nil,
                    mappedTurnID: nil,
                    textLength: textToEmit.count,
                    accumulatedTextLength: textToEmit.count,
                    responseCreate: true,
                    turnClosed: false
                )
            }

            logLanguageControlNoRequest(candidateText: textToEmit, activeLanguage: primaryInterviewLanguage)

            let action = conversationController.nextAction(
                after: textToEmit,
                countedQuestionCount: countedQuestionCount
            )
            let finalSpeechSnapshot = await localAnalyzer.turnSnapshot()
            guard !finalSpeechSnapshot.isSpeaking, !shouldSuppressCandidateInput else {
                candidateResponseInFlight = false
                candidateTurnState = .speaking
                logCandidateTurnHandoffCancelled(reason: "speech_active_before_response_create")
                onStateChange(.listening)
                return
            }

            pendingAssistantTurnCountsTowardTotal = action.countsTowardTotal
            candidateTurnState = .committed
            prepareAssistantTurn(purpose: action.isFinalClose ? .closing : .interview, willCompleteInterview: action.isFinalClose)
            try await sendResponseCreate(
                instructions: conversationController.instructions(
                    for: action,
                    language: primaryInterviewLanguage.rawValue
                )
            )
            uploadedCandidateAudioDurationMs = 0
            serverVADStoppedCurrentTurn = false
            logHandoffLatency(responseCommitted: true)
            onStateChange(.thinking)
        } catch {
            candidateTurnState = .idle
            assistantTurnPending = false
            reportError(RealtimeSessionError(message: error.localizedDescription, type: "response_create", code: nil, param: nil))
        }
    }

    private func sendLanguageInstructionUpdate() async throws {
        try await sendInProgressSessionUpdate()
    }

    /// Called immediately after a language-switch request is processed. Sends a
    /// response.create asking the model to briefly acknowledge the switch and
    /// re-ask the same question in the new language (or open with the first question
    /// if no prior question context exists). The turn is marked non-counted so it
    /// does not consume a question slot.
    private func resumeInterviewAfterLanguageSwitch(previousQuestionInstructions: String?) async {
        let lang = primaryInterviewLanguage.rawValue
        let instructions: String
        if let prev = previousQuestionInstructions {
            instructions = """
            LANGUAGE LOCK: Output only in \(lang).
            The candidate just asked to switch to \(lang). Acknowledge in 1-2 words only (e.g., "\(lang == "Arabic" ? "بالتأكيد" : "Of course")"), then immediately re-ask the same interview question, naturally phrased in \(lang). Do not translate word-for-word — rephrase naturally in \(lang). Do not advance to a new topic; this is the same question repeated in the new language.
            Question context (internal orchestration — never read this aloud): \(prev)
            """
        } else {
            instructions = """
            LANGUAGE LOCK: Output only in \(lang).
            The candidate asked to conduct the interview in \(lang). Acknowledge in 1-2 words, then ask the first interview question in \(lang).
            """
        }
        pendingAssistantTurnCountsTowardTotal = false
        prepareAssistantTurn(purpose: .interview, willCompleteInterview: false)
        do {
            try await sendResponseCreate(instructions: instructions)
            onStateChange(.thinking)
        } catch {
            candidateTurnState = .idle
            assistantTurnPending = false
            reportError(RealtimeSessionError(message: error.localizedDescription, type: "language_switch_resume", code: nil, param: nil))
        }
    }

    private func consumeLanguageControlTurn(turnID: UUID?) {
        if let turnID {
            let itemIDs = candidateTurnItemIDs[turnID] ?? []
            for itemID in itemIDs {
                itemIDToCandidateTurnID.removeValue(forKey: itemID)
                candidateTranscriptTextByItemID.removeValue(forKey: itemID)
                pendingTranscriptionItemIDs.remove(itemID)
            }
            candidateTurnItemIDs.removeValue(forKey: turnID)
            candidateTranscriptAccumulator.removeValue(forKey: turnID)
        }
        activeCandidateTurnID = nil
        candidateTextBuffer = ""
        pendingTranscriptionWaitStartedAt = nil
        uploadedCandidateAudioDurationMs = 0
        serverVADStoppedCurrentTurn = false
        candidateResponseInFlight = false
        candidateTurnState = .idle
    }

    private func sendInProgressSessionUpdate() async throws {
        let prompt = InterviewSystemPrompt.make(
            for: configuration,
            primaryInterviewLanguage: primaryInterviewLanguage.rawValue,
            includeOpeningInstructions: false
        )
        // Transcription language is intentionally left unspecified so candidate
        // input can be understood in English, Arabic, or mixed speech while
        // primaryInterviewLanguage remains the sole output-language state.
        try await sendEvent([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": prompt
            ]
        ])
    }

    private func prepareAssistantTurn(purpose: AssistantTurnPurpose, willCompleteInterview: Bool) {
        cancelPendingCandidateCompletion()
        currentAssistantTurnPurpose = purpose
        didEmitClosingTranscript = false
        assistantTurnPending = true
        assistantResponseCreated = false
        shouldCompleteCurrentAssistantTurn = willCompleteInterview
        serverAudioDone = false
        bufferedAssistantAudioDeltas = []
        assistantQuestionAudioReleaseApproved = false
        audioGateStartedAt = nil
    }

    private var shouldGateCurrentInterviewQuestion: Bool {
        pendingAssistantTurnCountsTowardTotal
            && currentAssistantTurnPurpose == .interview
            && !assistantQuestionAudioReleaseApproved
    }

    private func handleAssistantAudioDelta(_ delta: String) {
        logAssistantPlayback(audioDeltaReceived: true, bufferScheduled: false, bufferPlayed: false)
        if shouldGateCurrentInterviewQuestion {
            if audioGateStartedAt == nil {
                audioGateStartedAt = Date()
            }
            bufferedAssistantAudioDeltas.append(delta)
            return
        }

        playAssistantAudioDelta(delta)
    }

    private func releaseBufferedAssistantAudioIfNeeded() {
        assistantQuestionAudioReleaseApproved = true
        let buffered = bufferedAssistantAudioDeltas
        bufferedAssistantAudioDeltas = []
        #if DEBUG
        if let start = audioGateStartedAt {
            let heldMs = Int(Date().timeIntervalSince(start) * 1_000)
            print("[AudioGate] questionAudioHeldForMs=\(heldMs) bufferedDeltaCount=\(buffered.count) — silence candidate heard before question started playing")
        }
        #endif
        audioGateStartedAt = nil
        for delta in buffered {
            playAssistantAudioDelta(delta)
        }
    }

    private func discardBufferedAssistantAudio() {
        bufferedAssistantAudioDeltas = []
        assistantQuestionAudioReleaseApproved = false
        audioGateStartedAt = nil
    }

    /// Runs a cheap partial check on the transcript accumulated so far. If the anchor
    /// mention and dimension keywords are already present, releases the audio buffer
    /// immediately rather than waiting for the full transcript to arrive and be validated.
    /// Full validation still runs at transcript.done — see flushAssistantTranscriptIfNeeded().
    private func tryEarlyAudioRelease() {
        let partial = assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        // Need at least ~8 words so anchor and dimension checks have meaningful signal.
        guard partial.split(separator: " ").count >= 8 else { return }
        guard conversationController.earlyValidateGeneratedQuestion(partial: partial) else { return }
        #if DEBUG
        print("[AudioGate] earlyRelease partialWords=\(partial.split(separator: " ").count) bufferedDeltaCount=\(bufferedAssistantAudioDeltas.count)")
        #endif
        releaseBufferedAssistantAudioIfNeeded()
        onInterviewerText(partial)
    }

    private func playAssistantAudioDelta(_ delta: String) {
        let audioAlreadyDone = serverAudioDone
        beginAssistantAudioTurn(purpose: currentAssistantTurnPurpose)
        if audioAlreadyDone {
            serverAudioDone = true
        }
        logAssistantAudioStartedIfNeeded()
        logStartupAudioMilestoneIfNeeded()
        playBase64PCM(delta)
        if currentAssistantTurnPurpose == .introduction {
            if !didStartIntroductionAudio {
                didStartIntroductionAudio = true
                onStateChange(.introductionSpeaking)
            }
        } else {
            onStateChange(.speaking)
        }
    }

    private func beginAssistantAudioTurn(purpose: AssistantTurnPurpose) {
        let stateBefore = candidateTurnState
        currentAssistantTurnPurpose = purpose
        assistantTurnPending = false
        assistantResponseCreated = true
        assistantAudioActive = true
        serverAudioDone = false
        if candidateTurnState == .committed {
            let closedTurnID = activeCandidateTurnID
            activeCandidateTurnID = nil
            pendingTranscriptionWaitStartedAt = nil
            Task { await localAnalyzer.markTurnComplete() }
            logTranscriptPipeline(
                "turnClosed",
                itemID: nil,
                mappedTurnID: closedTurnID,
                textLength: nil,
                accumulatedTextLength: candidateTextBuffer.count,
                responseCreate: candidateResponseInFlight,
                turnClosed: true
            )
        }
        logTurnOwnership(
            speechStopped: false,
            evaluation: nil,
            responseCreateSent: candidateResponseInFlight,
            responseCreated: assistantResponseCreated,
            assistantAudioActuallyStarted: true,
            speechResumed: false,
            responseCancelled: false,
            candidateStateBefore: stateBefore,
            candidateStateAfter: candidateTurnState,
            candidateAudioSuppressed: true
        )
    }

    private func finishAssistantPlaybackIfReady() {
        guard assistantAudioActive, serverAudioDone, pendingPlaybackBuffers == 0 else { return }
        let completedPurpose = currentAssistantTurnPurpose
        assistantAudioActive = false
        assistantTurnPending = false
        assistantAudioStartedAt = nil
        candidateTurnState = .idle
        logAssistantPlayback(audioDeltaReceived: false, bufferScheduled: false, bufferPlayed: false)

        if completedPurpose == .introduction, !hasDeliveredIntroduction {
            hasDeliveredIntroduction = true
            didStartIntroductionAudio = false
            onStateChange(.openingBeat)
            scheduleFirstQuestionAfterIntroduction()
        } else if shouldCompleteAfterAssistantPlayback {
            shouldCompleteAfterAssistantPlayback = false
            complete(isPartial: false)
        } else if !didComplete {
            onStateChange(.listening)
        }
    }

    private func scheduleFirstQuestionAfterIntroduction() {
        openingQuestionTask?.cancel()
        openingQuestionTask = Task { [weak self] in
            do {
                guard let self else { return }
                try await Task.sleep(for: self.openingQuestionBeat)
                try Task.checkCancellation()
                await self.requestFirstCountedQuestion()
            } catch {
                return
            }
        }
    }

    private func requestFirstCountedQuestion() async {
        guard hasDeliveredIntroduction, !didComplete, !didReportError else { return }
        do {
            logInterviewStartup("T10 first counted question requested")
            try await sendInProgressSessionUpdate()
            let action = conversationController.openingAction()
            pendingAssistantTurnCountsTowardTotal = action.countsTowardTotal
            prepareAssistantTurn(purpose: .interview, willCompleteInterview: false)
            try await sendResponseCreate(
                instructions: conversationController.instructions(
                    for: action,
                    language: primaryInterviewLanguage.rawValue
                )
            )
            onStateChange(.thinking)
        } catch {
            reportError(RealtimeSessionError(message: error.localizedDescription, type: "opening_question_create", code: nil, param: nil))
        }
    }

    private static func convertToPCM16Data(buffer: AVAudioPCMBuffer) -> Data {
        guard let channelData = buffer.floatChannelData else { return Data() }
        let frames = Int(buffer.frameLength)
        var data = Data(capacity: frames * MemoryLayout<Int16>.size)
        let source = channelData[0]
        for index in 0..<frames {
            let sample = max(-1.0, min(1.0, source[index]))
            var intSample = Int16(sample * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func pcm16DurationMilliseconds(_ data: Data) -> Double {
        let sampleCount = Double(data.count / MemoryLayout<Int16>.size)
        return sampleCount / 24_000 * 1_000
    }

    fileprivate static func requestedInterviewLanguage(
        in text: String,
        currentLanguage: InterviewLanguage = .english
    ) -> InterviewLanguage? {
        switch LanguageSwitchDetector.detect(in: text, currentLanguage: currentLanguage) {
        case .switchToArabic:  return .arabic
        case .switchToEnglish: return .english
        case .none:            return nil
        }
    }

    // MARK: Candidate turn / transcript lifecycle

    /// Called when speech_started fires. Creates a new logical turn UUID when no
    /// turn is active; otherwise records the new item_id under the existing turn
    /// (candidate resumed after a mid-answer thinking pause, still same turn).
    private func beginCandidateTurn(itemID: String?) {
        if activeCandidateTurnID == nil {
            candidateTextBuffer = ""
            activeCandidateTurnID = UUID()
            pendingTranscriptionWaitStartedAt = nil
        }
        if let itemID, !itemID.isEmpty {
            let turnID = activeCandidateTurnID!
            itemIDToCandidateTurnID[itemID] = turnID
            recordCandidateItemID(itemID, for: turnID)
        }
        logTranscriptPipeline(
            "speechStarted",
            itemID: itemID,
            mappedTurnID: activeCandidateTurnID,
            textLength: nil,
            accumulatedTextLength: candidateTextBuffer.count,
            responseCreate: candidateResponseInFlight,
            turnClosed: false
        )
    }

    private func recordCandidateItemID(_ itemID: String, for turnID: UUID) {
        var itemIDs = candidateTurnItemIDs[turnID] ?? []
        if !itemIDs.contains(itemID) {
            itemIDs.append(itemID)
            candidateTurnItemIDs[turnID] = itemIDs
        }
        if candidateTranscriptTextByItemID[itemID] == nil {
            pendingTranscriptionItemIDs.insert(itemID)
        }
    }

    private func accumulatedCandidateTranscript(for turnID: UUID) -> String {
        let orderedItemText = (candidateTurnItemIDs[turnID] ?? [])
            .compactMap { candidateTranscriptTextByItemID[$0] }
        let fallbackText = candidateTranscriptAccumulator[turnID] ?? []
        return (orderedItemText + fallbackText)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldWaitForActiveTurnTranscription() -> Bool {
        guard let turnID = activeCandidateTurnID else { return false }
        let activeItemIDs = candidateTurnItemIDs[turnID] ?? []
        guard activeItemIDs.contains(where: { pendingTranscriptionItemIDs.contains($0) }) else {
            pendingTranscriptionWaitStartedAt = nil
            return false
        }

        let startedAt = pendingTranscriptionWaitStartedAt ?? Date()
        pendingTranscriptionWaitStartedAt = startedAt
        return Date().timeIntervalSince(startedAt) < 1.5
    }

    /// Called when conversation.item.input_audio_transcription.completed fires.
    ///
    /// Accumulates text across all audio items belonging to the same logical turn
    /// (each item_id maps to a turn UUID set in beginCandidateTurn). Updates
    /// candidateTextBuffer so the semantic-completeness heuristic reflects the
    /// current turn's content.
    ///
    /// If the turn was already emitted (response.create already dispatched), calls
    /// onCandidateTranscript again so the ViewModel can update the existing bubble
    /// in place — no new entry is created, no matter how late the event arrives.
    private func updateCandidateTranscript(itemID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Resolve which logical turn this audio item belongs to.
        // Falls back to activeCandidateTurnID for API edge cases where
        // speech_started did not carry an item_id.
        let turnID: UUID
        if let mapped = itemIDToCandidateTurnID[itemID] {
            turnID = mapped
        } else if let active = activeCandidateTurnID {
            turnID = active
            if !itemID.isEmpty { itemIDToCandidateTurnID[itemID] = turnID }
        } else {
            // No active turn and no mapping — transcription arrived for a turn
            // whose item_ids were not recorded. Discard safely.
            return
        }

        if !itemID.isEmpty {
            recordCandidateItemID(itemID, for: turnID)
            candidateTranscriptTextByItemID[itemID] = trimmed
            pendingTranscriptionItemIDs.remove(itemID)
            candidateTextBuffer = accumulatedCandidateTranscript(for: turnID)
        } else {
            var parts = candidateTranscriptAccumulator[turnID] ?? []
            if parts.last != trimmed {
                parts.append(trimmed)
            }
            candidateTranscriptAccumulator[turnID] = parts
            candidateTextBuffer = parts.joined(separator: " ")
        }
        pendingTranscriptionWaitStartedAt = nil

        logTranscriptPipeline(
            "transcriptionCompleted",
            itemID: itemID,
            mappedTurnID: turnID,
            textLength: trimmed.count,
            accumulatedTextLength: candidateTextBuffer.count,
            responseCreate: candidateResponseInFlight,
            turnClosed: activeCandidateTurnID == nil
        )

        // If response.create was already dispatched for this turn, forward the
        // now-complete text so the ViewModel updates the existing entry in place.
        if emittedCandidateTurnIDs.contains(turnID) {
            onCandidateTranscript(turnID, candidateTextBuffer)
        }
        if candidateTurnState == .pendingCompletion {
            candidateCompletionTask?.cancel()
            candidateCompletionTask = Task { [weak self] in
                await self?.evaluatePendingCandidateCompletion()
            }
        }
    }

    private func flushAssistantTranscriptIfNeeded() {
        let trimmed = assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if assistantOutputViolatesLanguageLock(trimmed) {
            logAssistantLanguageViolation(textLength: trimmed.count)
            // If the candidate just gave a turn, the model likely self-switched because it
            // detected a language request that Swift's keyword matching missed. Accept the
            // switch and sync Swift's state rather than fighting the model back to the old language.
            let candidateJustSpoke = !candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if candidateJustSpoke {
                let newLanguage: InterviewLanguage = (primaryInterviewLanguage == .english) ? .arabic : .english
                primaryInterviewLanguage = newLanguage
                languageViolationRecoveryNeeded = false
                Task { @MainActor [weak self] in
                    try? await self?.sendInProgressSessionUpdate()
                }
                // Fall through: emit the transcript normally in the new language
            } else {
                if !assistantAudioActive, candidateResponseInFlight {
                    Task { @MainActor [weak self] in
                        await self?.resendCurrentResponseWithStrongerLanguageLock()
                    }
                    return
                }
                languageViolationRecoveryNeeded = true
            }
        }
        if pendingAssistantTurnCountsTowardTotal {
            let validationKey = currentValidationResponseKey()
            if validatedResponseIDs.contains(validationKey) || regenerationTriggeredResponseIDs.contains(validationKey) {
                return
            }
            // If audio was already released by the early partial check, regenerating would
            // create overlapping audio streams (old audio still playing + new response starting).
            // Accept the question unconditionally and log any full-validation discrepancy for monitoring.
            if assistantQuestionAudioReleaseApproved {
                #if DEBUG
                print("[AudioGate] fullValidationSkipped — audio already released, accepting to avoid overlap")
                #endif
                validatedResponseIDs.insert(validationKey)
                // Fall through to transcript emit below.
            } else {
                let decision = conversationController.validateGeneratedQuestion(
                    counted: true,
                    text: trimmed,
                    language: primaryInterviewLanguage.rawValue
                )
                switch decision {
                case .accepted:
                    validatedResponseIDs.insert(validationKey)
                    releaseBufferedAssistantAudioIfNeeded()
                case .retry(let instructions):
                    regenerationTriggeredResponseIDs.insert(validationKey)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.regenerateAssistantResponse(instructions: instructions, reason: "question_regeneration")
                    }
                    return
                case .fallback(let fallback):
                    regenerationTriggeredResponseIDs.insert(validationKey)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.regenerateAssistantResponse(
                            instructions: """
                            LANGUAGE LOCK: Output only in \(self.primaryInterviewLanguage.rawValue).
                            Say exactly this interview question and nothing else: "\(fallback)"
                            """,
                            reason: "question_fallback"
                        )
                    }
                    return
                }
            }
        }
        if currentAssistantTurnPurpose == .closing {
            guard !didEmitClosingTranscript else { return }
            didEmitClosingTranscript = true
        }
        lastAssistantTranscript = trimmed
        onInterviewerText(trimmed)
        onTranscriptEntry(TranscriptEntry(speaker: .interviewer, text: trimmed))
        if shouldCountAssistantTurn(trimmed) {
            countedQuestionCount = min(countedQuestionCount + 1, configuration.questionCount.rawValue)
        }
        conversationController.markAssistantTurnCompleted(
            counted: pendingAssistantTurnCountsTowardTotal,
            text: trimmed
        )
        pendingAssistantTurnCountsTowardTotal = false
        assistantTextBuffer = ""
    }

    private func shouldCountAssistantTurn(_ text: String) -> Bool {
        pendingAssistantTurnCountsTowardTotal && countedQuestionCount < configuration.questionCount.rawValue
    }

    private func reportError(_ error: RealtimeSessionError) {
        guard !didComplete, !didReportError else { return }
        didReportError = true
        if let diagnostics = error.diagnostics {
            logStartupDiagnostics(diagnostics)
        } else {
            logSocketSnapshot(prefix: "preErrorStop")
        }
        setConnectionState(.failed)
        stop()
        onStateChange(.error)
        onError(error)
    }

    private func recoverFromEmptyAudioCommit() {
        cancelPendingCandidateCompletion()
        uploadedCandidateAudioDurationMs = 0
        candidateResponseInFlight = false
        assistantAudioActive = false
        serverAudioDone = true
        shouldCompleteAfterAssistantPlayback = false
        onStateChange(.listening)
    }

    private func complete(isPartial: Bool) {
        guard !didComplete else { return }
        didComplete = true
        stop()
        onStateChange(.completed)
        onCompleted(isPartial, countedQuestionCount)
    }

    private func setStartupPhase(_ phase: RealtimeStartupPhase) {
        currentStartupPhase = phase
        #if DEBUG
        print("[RealtimeStartup] phase=\(phase.rawValue)")
        #endif
    }

    private func setConnectionState(_ state: RealtimeConnectionState) {
        connectionState = state
        #if DEBUG
        print("[RealtimeStartup] connectionState=\(state.rawValue)")
        #endif
    }

    private func logTurnCompletion(
        evaluation: TurnCompletionEvaluator.Evaluation,
        silenceMs: Double,
        voiceSnapshot: LocalVoiceAnalyzer.TurnSnapshot
    ) {
        #if DEBUG
        let latencyMs = pendingCompletionStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) } ?? 0
        print("[TurnCompletion] vadState=\(serverVADStoppedCurrentTurn ? "speech_stopped" : "active") silence=\(Int(silenceMs))ms semanticState=\(evaluation.semanticState.rawValue) explicitEnd=\(evaluation.explicitEnd) audioEndCue=\(voiceSnapshot.audioEndCue) confidence=\(String(format: "%.2f", evaluation.confidence)) decision=\(evaluation.decision.rawValue) speechResumed=false responseCommitted=\(candidateTurnState == .committed) assistantAudioStarted=\(assistantAudioStartedAt != nil) totalHandoffLatency=\(latencyMs)ms")
        print("[CandidateTurn] speechStopped=\(serverVADStoppedCurrentTurn) semanticContinuation=\(evaluation.semanticState == .continuing) prosodyEnding=\(voiceSnapshot.audioEndCue) completionCandidate=\(evaluation.decision != .waiting) speechResumed=false handoffCancelled=false finalized=\(evaluation.decision == .finished)")
        #endif
    }

    private func logCandidateTurnHandoffCancelled(reason: String) {
        #if DEBUG
        print("[CandidateTurn] speechStopped=\(serverVADStoppedCurrentTurn) semanticContinuation=nil prosodyEnding=nil completionCandidate=true speechResumed=true handoffCancelled=true finalized=false reason=\(reason)")
        #endif
    }

    private func logTurnOwnership(
        speechStopped: Bool,
        evaluation: String?,
        responseCreateSent: Bool,
        responseCreated: Bool,
        assistantAudioActuallyStarted: Bool,
        speechResumed: Bool,
        responseCancelled: Bool,
        candidateStateBefore: CandidateTurnState,
        candidateStateAfter: CandidateTurnState,
        candidateAudioSuppressed: Bool
    ) {
        #if DEBUG
        print("[TurnOwnership] speechStopped=\(speechStopped) evaluation=\(evaluation ?? "nil") responseCreateSent=\(responseCreateSent) responseCreated=\(responseCreated) assistantAudioActuallyStarted=\(assistantAudioActuallyStarted) speechResumed=\(speechResumed) responseCancelled=\(responseCancelled) candidateStateBefore=\(candidateStateBefore) candidateStateAfter=\(candidateStateAfter) candidateAudioSuppressed=\(candidateAudioSuppressed)")
        #endif
    }

    private func logAudioPipeline(
        micBufferCaptured: Bool,
        micBufferSuppressed: Bool,
        micBufferUploaded: Bool
    ) {
        #if DEBUG
        print("[AudioPipeline] timestamp=\(Date().timeIntervalSince1970) candidateState=\(candidateTurnState) assistantAudioActive=\(assistantAudioActive) assistantTurnPending=\(assistantTurnPending) candidateResponseInFlight=\(candidateResponseInFlight) pendingPlaybackBuffers=\(pendingPlaybackBuffers) serverAudioDone=\(serverAudioDone) micBufferCaptured=\(micBufferCaptured) micBufferSuppressed=\(micBufferSuppressed) micBufferUploaded=\(micBufferUploaded)")
        #endif
    }

    private func logTranscriptPipeline(
        _ event: String,
        itemID: String?,
        mappedTurnID: UUID?,
        textLength: Int?,
        accumulatedTextLength: Int,
        responseCreate: Bool,
        turnClosed: Bool
    ) {
        #if DEBUG
        print("[TranscriptPipeline] event=\(event) itemID=\(itemID ?? "nil") mappedTurnID=\(mappedTurnID?.uuidString ?? "nil") textLength=\(textLength.map(String.init) ?? "nil") accumulatedTextLength=\(accumulatedTextLength) responseCreate=\(responseCreate) turnClosed=\(turnClosed)")
        #endif
    }

    private func logAssistantPlayback(
        audioDeltaReceived: Bool,
        bufferScheduled: Bool,
        bufferPlayed: Bool
    ) {
        #if DEBUG
        print("[AssistantPlayback] audioDeltaReceived=\(audioDeltaReceived) bufferScheduled=\(bufferScheduled) pendingBuffers=\(pendingPlaybackBuffers) bufferPlayed=\(bufferPlayed) serverAudioDone=\(serverAudioDone) assistantAudioActive=\(assistantAudioActive)")
        #endif
    }

    private func logVoiceCoreML(
        turnID: UUID,
        analysisStarted: Bool,
        analysisStopped: Bool,
        classification: String?,
        confidence: Double?,
        resultStored: Bool,
        transcriptExists: Bool,
        resultAttached: Bool
    ) {
        #if DEBUG
        let confidenceText = confidence.map { String(format: "%.2f", $0) } ?? "nil"
        print("[VoiceCoreML] turnID=\(turnID.uuidString) analysisStarted=\(analysisStarted) analysisStopped=\(analysisStopped) classification=\(classification ?? "nil") confidence=\(confidenceText) resultStored=\(resultStored) transcriptExists=\(transcriptExists) resultAttached=\(resultAttached)")
        #endif
    }

    private func assistantOutputViolatesLanguageLock(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 24 else { return false }

        switch primaryInterviewLanguage {
        case .english:
            return containsSignificantArabicScript(trimmed) || isClearlyUnsupportedLatinLanguage(trimmed)
        case .arabic:
            return isClearlyNonArabicDialogue(trimmed)
        }
    }

    private func containsSignificantArabicScript(_ text: String) -> Bool {
        let arabicScalars = text.unicodeScalars.filter { (0x0600...0x06FF).contains(Int($0.value)) }.count
        return arabicScalars >= 4
    }

    private func isClearlyUnsupportedLatinLanguage(_ text: String) -> Bool {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let words = folded.split { !$0.isLetter }.map(String.init)
        guard words.count >= 8 else { return false }

        let englishFunctionWords = Set(["the", "and", "that", "you", "your", "this", "with", "what", "how", "why", "tell", "about", "interview", "question", "experience", "project", "role"])
        let englishCount = words.filter { englishFunctionWords.contains($0) }.count
        let unsupportedMarkers = [
            "voce", "obrigado", "obrigada", "pergunta", "resposta", "entrevista",
            "trabalho", "experiencia", "vamos", "pode", "falar", "conte", "sobre",
            "continuar", "candidato", "empresa"
        ]
        let markerCount = unsupportedMarkers.filter { marker in
            words.contains(marker) || folded.contains(" \(marker) ")
        }.count

        return markerCount >= 3 && englishCount <= 2
    }

    private func isClearlyNonArabicDialogue(_ text: String) -> Bool {
        let arabicScalars = text.unicodeScalars.filter { (0x0600...0x06FF).contains(Int($0.value)) }.count
        let latinWords = text.split { !$0.isLetter }.filter { token in
            token.unicodeScalars.contains { (0x0041...0x007A).contains(Int($0.value)) }
        }
        return arabicScalars < 4 && latinWords.count >= 8
    }

    private func logAssistantLanguageViolation(textLength: Int) {
        #if DEBUG
        print("[Language] current=\(primaryInterviewLanguage.rawValue) assistantOutputViolation=true textLength=\(textLength) assistantAudioActive=\(assistantAudioActive) candidateResponseInFlight=\(candidateResponseInFlight) recovery=\(!assistantAudioActive && candidateResponseInFlight ? "regenerate" : "next_response")")
        #endif
    }

    private func logLanguageControlDecision(
        candidateText: String,
        requestedLanguage: InterviewLanguage,
        previousLanguage: InterviewLanguage,
        newLanguage: InterviewLanguage,
        sessionUpdateSent: Bool,
        responseCreateSent: Bool,
        normalInterviewActionSkipped: Bool,
        returnedToListening: Bool
    ) {
        #if DEBUG
        print("[LanguageControl] candidateText=\"\(candidateText)\" detectedRequest=\(requestedLanguage.rawValue) previousLanguage=\(previousLanguage.rawValue) newLanguage=\(newLanguage.rawValue) sessionUpdateSent=\(sessionUpdateSent) responseCreateSent=\(responseCreateSent) normalInterviewActionSkipped=\(normalInterviewActionSkipped) returnedToListening=\(returnedToListening)")
        #endif
    }

    private func logLanguageControlNoRequest(candidateText: String, activeLanguage: InterviewLanguage) {
        #if DEBUG
        print("[LanguageControl] candidateText=\"\(candidateText)\" detectedRequest=nil activeLanguage=\(activeLanguage.rawValue)")
        #endif
    }

    private func logAssistantAudioStartedIfNeeded() {
        #if DEBUG
        guard assistantAudioStartedAt == nil else { return }
        assistantAudioStartedAt = Date()
        logHandoffLatency(responseCommitted: candidateTurnState == .committed)
        print("[TurnCompletion] assistantAudioStarted=true")
        #else
        if assistantAudioStartedAt == nil {
            assistantAudioStartedAt = Date()
        }
        #endif
    }

    private func logHandoffLatency(responseCommitted: Bool) {
        #if DEBUG
        guard let responseCommitStartedAt else { return }
        let latencyMs = Int(Date().timeIntervalSince(responseCommitStartedAt) * 1_000)
        print("[TurnCompletion] responseCommitted=\(responseCommitted) assistantAudioStarted=\(assistantAudioStartedAt != nil) totalHandoffLatency=\(latencyMs)ms")
        #endif
    }

    private func logStartupAudioMilestoneIfNeeded() {
        if currentAssistantTurnPurpose == .introduction, !didLogIntroAudioStart {
            didLogIntroAudioStart = true
            logInterviewStartup("T9 introduction audio starts")
        } else if currentAssistantTurnPurpose == .interview, hasDeliveredIntroduction, !didLogFirstQuestionAudioStart {
            didLogFirstQuestionAudioStart = true
            logInterviewStartup("T11 first question audio starts")
        }
    }

    private func logInterviewStartup(_ label: String) {
        #if DEBUG
        let delta = startupT0.map { String(format: "%.3fs", Date.now.timeIntervalSince($0)) } ?? "n/a"
        print("[InterviewStartup] \(label) delta=\(delta)")
        #endif
    }

    private func startupDiagnostics(for error: Error, phase: RealtimeStartupPhase) -> RealtimeStartupDiagnostics {
        let nsError = error as NSError
        let closeCode = webSocketTask?.closeCode.rawValue
        let closeReason = webSocketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        let httpStatus = (webSocketTask?.response as? HTTPURLResponse)?.statusCode
        return RealtimeStartupDiagnostics(
            phase: phase.rawValue,
            underlyingDomain: nsError.domain,
            underlyingCode: nsError.code,
            localizedDescription: nsError.localizedDescription,
            closeCode: closeCode,
            closeReason: closeReason,
            httpStatus: httpStatus,
            openAIErrorType: nil,
            openAIErrorCode: nil,
            openAIErrorMessage: nil,
            openAIErrorParam: nil
        )
    }

    private func logSocketSnapshot(prefix: String) {
        #if DEBUG
        let closeCode = webSocketTask?.closeCode.rawValue
        let closeReason = webSocketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        let httpStatus = (webSocketTask?.response as? HTTPURLResponse)?.statusCode
        print("[RealtimeStartup] \(prefix).closeCode=\(closeCode.map(String.init) ?? "nil")")
        print("[RealtimeStartup] \(prefix).closeReason=\(closeReason ?? "nil")")
        print("[RealtimeStartup] \(prefix).httpStatus=\(httpStatus.map(String.init) ?? "nil")")
        #endif
    }

    private func logStartupFlag(_ name: String, _ value: Bool) {
        #if DEBUG
        print("[RealtimeStartup] \(name)=\(value)")
        #endif
    }

    private func logStartupDiagnostics(_ diagnostics: RealtimeStartupDiagnostics) {
        #if DEBUG
        print("[RealtimeStartup] phase=\(diagnostics.phase)")
        print("[RealtimeStartup] underlyingDomain=\(diagnostics.underlyingDomain ?? "nil")")
        print("[RealtimeStartup] underlyingCode=\(diagnostics.underlyingCode.map(String.init) ?? "nil")")
        print("[RealtimeStartup] localizedDescription=\(diagnostics.localizedDescription ?? "nil")")
        print("[RealtimeStartup] closeCode=\(diagnostics.closeCode.map(String.init) ?? "nil")")
        print("[RealtimeStartup] closeReason=\(diagnostics.closeReason ?? "nil")")
        print("[RealtimeStartup] httpStatus=\(diagnostics.httpStatus.map(String.init) ?? "nil")")
        print("[RealtimeStartup] openAIErrorType=\(diagnostics.openAIErrorType ?? "nil")")
        print("[RealtimeStartup] openAIErrorCode=\(diagnostics.openAIErrorCode ?? "nil")")
        print("[RealtimeStartup] openAIErrorMessage=\(diagnostics.openAIErrorMessage ?? "nil")")
        print("[RealtimeStartup] openAIErrorParam=\(diagnostics.openAIErrorParam ?? "nil")")
        #endif
    }

    private func logOpenAIErrorEvent(_ object: [String: Any]) {
        #if DEBUG
        let error = object["error"] as? [String: Any]
        let diagnostics = RealtimeStartupDiagnostics(
            phase: currentStartupPhase.rawValue,
            underlyingDomain: nil,
            underlyingCode: nil,
            localizedDescription: nil,
            closeCode: webSocketTask?.closeCode.rawValue,
            closeReason: webSocketTask?.closeReason.flatMap { String(data: $0, encoding: .utf8) },
            httpStatus: (webSocketTask?.response as? HTTPURLResponse)?.statusCode,
            openAIErrorType: error?["type"] as? String,
            openAIErrorCode: error?["code"] as? String,
            openAIErrorMessage: error?["message"] as? String,
            openAIErrorParam: error?["param"] as? String
        )
        logStartupDiagnostics(diagnostics)
        #endif
    }

    // MARK: - Language Switch Intent Detection
    fileprivate struct LanguageSwitchDetector {
    enum Intent {
        case switchToArabic
        case switchToEnglish
        case none
    }

    // MARK: - Public API

    static func detect(in rawText: String, currentLanguage: InterviewLanguage) -> Intent {
        let normalized = normalize(rawText)
        guard !normalized.isEmpty else { return .none }

        let hasArabic = containsLanguageTarget(.arabic, in: normalized)
        let hasEnglish = containsLanguageTarget(.english, in: normalized)

        // Both language words present → bilingual interview content, not a switch command.
        if hasArabic && hasEnglish { return .none }
        guard hasArabic || hasEnglish else { return .none }

        let target: InterviewLanguage = hasArabic ? .arabic : .english
        // Already in the requested language — idempotent; caller can decide.
        if target == currentLanguage { return .none }

        // Negation in the opening tokens cancels the request.
        if isNegated(normalized) { return .none }

        // Require evidence of communicative / change intent. Without this guard, any
        // interview answer that mentions a language (e.g., "صممت واجهة للمستخدم العربي")
        // would incorrectly trigger a switch.
        let hasIntent = containsIntentSignal(normalized)
        let wordCount = normalized.split(separator: " ").filter { !$0.isEmpty }.count
        let isBareCommand = wordCount == 1                                         // "عربي", "arabic"
        let isPolitePhrasing = wordCount <= 4 && containsPolitenessMarker(normalized) // "arabic please"

        guard hasIntent || isBareCommand || isPolitePhrasing else { return .none }

        return hasArabic ? .switchToArabic : .switchToEnglish
    }

    // MARK: - Normalization

    static func normalize(_ text: String) -> String {
        var s = text

        // Hamza / alef variants → bare alef; alef maqsura → ya
        for (src, dst) in [("أ", "ا"), ("إ", "ا"), ("آ", "ا"), ("ى", "ي")] {
            s = s.replacingOccurrences(of: src, with: dst)
        }

        // Remove tatweel (kashida)
        s = s.replacingOccurrences(of: "\u{0640}", with: "")

        // Remove Arabic diacritics: harakat (064B–065F) and honorific marks (0610–061A)
        s = String(s.unicodeScalars.filter {
            let v = $0.value
            return !((v >= 0x064B && v <= 0x065F) || (v >= 0x0610 && v <= 0x061A))
        })

        // Strip punctuation and apostrophes that affect token boundaries
        for ch in ["'", "\u{2019}", "\"", "؟", "،", "?", ",", ".", "!", "؛", ";"] {
            s = s.replacingOccurrences(of: ch, with: "")
        }

        // Lowercase and collapse whitespace
        return s.lowercased().split { $0.isWhitespace }.joined(separator: " ")
    }

    // MARK: - Language Target Detection

    // Every recognized form of "Arabic" after normalization, with common preposition prefixes.
    static let arabicTargets: [String] = [
        "عربي", "عربيه", "عربية", "عربيا",           // bare
        "العربي", "العربيه", "العربية",               // ال definite
        "بالعربي", "بالعربيه", "بالعربية",            // بال "in the"
        "للعربي", "للعربيه", "للعربية",               // لل "for/to the"
        "لعربي", "لعربية",                            // ل "to"
        "arabic",
    ]

    // Every recognized form of "English" after normalization (إ → ا).
    static let englishTargets: [String] = [
        "انجليزي", "انجليزيه", "انجليزية", "انجليزيا",
        "الانجليزي", "الانجليزيه", "الانجليزية",
        "بالانجليزي", "بالانجليزيه", "بالانجليزية",
        "للانجليزي", "للانجليزيه", "للانجليزية",
        "لانجليزي", "لانجليزية",
        "english",
    ]

    static func containsLanguageTarget(_ language: InterviewLanguage, in normalized: String) -> Bool {
        let markers = language == .arabic ? arabicTargets : englishTargets
        return markers.contains { containsWholeWord(normalized, phrase: $0) }
    }

    // MARK: - Intent Signal Detection

    // Desire / want — covers Gulf, Levantine, Egyptian, Yemeni, MSA
    private static let desireVerbs: [String] = [
        "ابغي",          // أبغى  — Saudi/Gulf
        "ابي",           // أبي   — Gulf
        "ودي", "نودي",
        "نبي", "نبغي",
        "بدي", "بدنا",   // Levantine
        "عايز", "عايزه", "عايزة",  // Egyptian
        "اشتي", "نشتي",  // Yemeni/Omani
        "اريد", "نريد",  // MSA
        "اود", "نود",
        "افضل", "نفضل",
        "ارتاح",
        "احب", "نحب",
    ]

    // Change / switch verbs
    private static let changeVerbs: [String] = [
        "حول", "غير", "بدل", "انتقل", "اجعل", "خلي", "سوي",
    ]

    // Let's / permission markers
    private static let permissionVerbs: [String] = [
        "خلنا", "خلينا",
        "دعنا", "لنواصل", "لنكمل", "لنتكلم", "لنتحدث",
        "ممكن", "ينفع", "فينا", "عادي", "تقدر",
        "يمكن", "يمكننا",
    ]

    // Communication verbs (imperative or 1st/2nd person) + question-repeat words
    private static let communicationVerbs: [String] = [
        "تكلم", "نتكلم", "اتكلم",
        "تحدث", "التحدث", "نتحدث", "يتحدث",
        "كلمني", "كلمنا",
        "احكي", "نحكي", "تحكي",    // Levantine
        "احچي", "نحچي", "تحچي",   // Iraqi
        "نكمل", "كمل", "اكمل", "واصل", "نواصل",
        "اتحدث",  // MSA "I speak" (أتحدث → اتحدث after normalization)
        "اسالني", "قول", "اعد", "كرر",
    ]

    // English intent signals
    private static let englishIntentWords: [String] = [
        "switch", "change",
        "speak", "talk", "continue",
        "prefer", "repeat",
        "please", "can", "could",
        "lets",    // "let's" with apostrophe removed by normalize()
        "shall", "want", "rather",
    ]

    static func containsIntentSignal(_ normalized: String) -> Bool {
        let all = desireVerbs + changeVerbs + permissionVerbs + communicationVerbs + englishIntentWords
        return all.contains { containsWholeWord(normalized, phrase: $0) }
    }

    // MARK: - Negation Guard

    private static let negationTokens: Set<String> = [
        "ما", "لا", "مو", "مب", "مش", "لن", "لم",          // Arabic
        "no", "not", "dont", "cant", "wont", "never",        // English (apostrophes stripped)
    ]

    // Checks whether the first three tokens contain a negation particle.
    // Using a small window avoids blocking "لا بأس نكمل بالعربي" only if the
    // fixed phrase appears at position 0; that edge case falls through to the
    // model, which handles it correctly via the system prompt.
    static func isNegated(_ normalized: String) -> Bool {
        normalized.split(separator: " ").prefix(3).map(String.init).contains {
            negationTokens.contains($0)
        }
    }

    // MARK: - Politeness / Emphasis Markers

    // Used only for the 2-4 word short command path (no intent verb required).
    private static let politenessSubstrings: [String] = [
        "please",
        "فضلك",   // من فضلك
        "سمحت",   // لو سمحت
        "تكرمت",
        "عفوا",
        // "لو" intentionally excluded: it means "if" in Arabic and causes false positives;
        // "لو سمحت" is covered by matching "سمحت" as a substring.
    ]

    static func containsPolitenessMarker(_ normalized: String) -> Bool {
        politenessSubstrings.contains { normalized.contains($0) }
    }

    // MARK: - Whole-word Boundary Matching

    static func containsWholeWord(_ text: String, phrase: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: phrase, range: searchStart..<text.endIndex) {
            let leading = range.lowerBound == text.startIndex
                || !isTokenChar(text[text.index(before: range.lowerBound)])
            let trailing = range.upperBound == text.endIndex
                || !isTokenChar(text[range.upperBound])
            if leading, trailing { return true }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isTokenChar(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
    }
    } // end LanguageSwitchDetector
}

enum TurnCompletionEvaluator {
    enum Decision: String, Sendable {
        case waiting = "WAITING"
        case likelyFinished = "LIKELY_FINISHED"
        case finished = "FINISHED"
    }

    enum SemanticState: String, Sendable {
        case noTranscript = "NO_TRANSCRIPT"
        case continuing = "CONTINUING"
        case possiblyComplete = "POSSIBLY_COMPLETE"
        case complete = "COMPLETE"
        case explicitEnd = "EXPLICIT_END"
    }

    struct Evaluation: Sendable {
        let decision: Decision
        let semanticState: SemanticState
        let explicitEnd: Bool
        let confidence: Double
    }

    static func evaluate(
        transcript: String,
        serverVADStopped: Bool,
        silenceMs: Double,
        voiceSnapshot: LocalVoiceAnalyzer.TurnSnapshot
    ) -> Evaluation {
        let semanticState = semanticState(for: transcript)
        let explicitEnd = semanticState == .explicitEnd
        let strongAudioEndCue = voiceSnapshot.audioEndCue
        let sustainedSilenceCue = silenceMs >= 900
        let audioEndCue = strongAudioEndCue || sustainedSilenceCue

        if voiceSnapshot.isSpeaking {
            return Evaluation(decision: .waiting, semanticState: semanticState, explicitEnd: explicitEnd, confidence: 0.20)
        }

        if explicitEnd, serverVADStopped, silenceMs >= 200 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: true, confidence: 0.98)
        }

        if semanticState == .continuing {
            if silenceMs >= 6_500 {
                return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.70)
            }
            return Evaluation(decision: .waiting, semanticState: semanticState, explicitEnd: false, confidence: 0.25)
        }

        if semanticState == .noTranscript {
            if serverVADStopped, silenceMs >= 2_500, audioEndCue {
                return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.62)
            }
            return Evaluation(decision: .waiting, semanticState: semanticState, explicitEnd: false, confidence: 0.20)
        }

        if serverVADStopped, semanticState == .complete, strongAudioEndCue, silenceMs >= 900 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.88)
        }

        if serverVADStopped, semanticState == .complete, audioEndCue, silenceMs >= 1_200 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.80)
        }

        if serverVADStopped, semanticState == .possiblyComplete, strongAudioEndCue, silenceMs >= 1_300 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.78)
        }

        if serverVADStopped, semanticState == .possiblyComplete, audioEndCue, silenceMs >= 2_200 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.78)
        }

        if serverVADStopped, audioEndCue, silenceMs >= 1_500 {
            return Evaluation(decision: .likelyFinished, semanticState: semanticState, explicitEnd: false, confidence: 0.66)
        }

        if silenceMs >= 7_000 {
            return Evaluation(decision: .finished, semanticState: semanticState, explicitEnd: false, confidence: 0.64)
        }

        return Evaluation(decision: .waiting, semanticState: semanticState, explicitEnd: false, confidence: 0.40)
    }

    private static func semanticState(for text: String) -> SemanticState {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noTranscript }

        let lowercased = trimmed.lowercased()
        let phraseComparable = lowercased.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        if explicitCompletionPhrases.contains(where: { lowercased.hasSuffix($0) || lowercased == $0 }) {
            return .explicitEnd
        }
        if explicitCompletionPhrases.contains(where: { phraseComparable.hasSuffix($0) || phraseComparable == $0 }) {
            return .explicitEnd
        }

        let finalClause = finalClause(in: phraseComparable)
        if continuationPhrases.contains(where: { lowercased.hasSuffix($0) || finalClause.hasSuffix($0) }) {
            return .continuing
        }
        if continuationStarters.contains(where: { finalClause == $0 || (finalClause.hasPrefix("\($0) ") && finalClause.split(separator: " ").count <= 6) }) {
            return .continuing
        }
        if incompleteClauseEndings.contains(where: { finalClause.hasSuffix($0) }) {
            return .continuing
        }

        let incompleteEndings = [
            "and", "or", "but", "because", "so", "then", "when", "while",
            "where", "which", "that", "to", "for", "with", "about", "from",
            "was", "were", "is"
        ]
        if incompleteEndings.contains(where: { lowercased.hasSuffix(" \($0)") || lowercased == $0 }) {
            return .continuing
        }

        let words = lowercased.split { !$0.isLetter && !$0.isNumber }
        if hasTerminalClosure(in: finalClause) {
            return .complete
        }

        return words.count >= 8 ? .possiblyComplete : .continuing
    }

    private static func finalClause(in text: String) -> String {
        let separators = CharacterSet(charactersIn: ".!?;")
        let sentenceTail = text.components(separatedBy: separators).last ?? text
        let softSeparators = [", and ", ", but ", " and then ", " but then ", " after that "]
        var clause = sentenceTail
        for separator in softSeparators {
            if let range = clause.range(of: separator, options: .backwards) {
                clause = String(clause[range.upperBound...])
            }
        }
        return clause.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hasTerminalClosure(in finalClause: String) -> Bool {
        guard !finalClause.isEmpty else { return false }
        let terminalEndings = [
            "solved it", "resolved it", "finished it", "completed it",
            "that was the result", "that was the impact", "that was the main challenge",
            "that is the result", "that is the impact", "that is what i learned",
            "we solved it", "we resolved it", "we completed it",
            "i solved it", "i resolved it", "i completed it",
            "the issue was solved", "the problem was solved"
        ]
        if terminalEndings.contains(where: { finalClause.hasSuffix($0) || finalClause.contains($0) }) {
            return true
        }

        let trailingOutcomeWords = ["result", "impact", "outcome", "solution"]
        if trailingOutcomeWords.contains(where: { finalClause.hasSuffix(" \($0)") }) {
            return true
        }

        return false
    }

    private static let explicitCompletionPhrases = [
        "that's all", "thats all", "that's it", "thats it", "i'm done", "im done",
        "i think that's everything", "i think thats everything", "that's my answer",
        "thats my answer", "that's everything", "thats everything",
        "هذا كل شيء", "هذا كل شي", "خلصت", "انتهيت", "هذه إجابتي", "هذي اجابتي"
    ]

    private static let continuationPhrases = [
        "the reason was because", "and then", "what i did next was",
        "the main thing i wanted to", "for example", "so what happened was",
        "what happened was", "i was going to say", "because when", "another thing",
        "the reason was", "the reason is", "one challenge was", "another thing was",
        "the main challenge was", "the biggest challenge was", "the biggest issue was",
        "i decided to", "we decided to", "we needed to", "i wanted to", "which meant", "in order to",
        "بعدها", "مثلا", "السبب كان", "الشيء الأساسي"
    ]

    private static let continuationStarters = [
        "and", "but", "because", "so", "then", "for example"
    ]

    private static let incompleteClauseEndings = [
        "was because", "is because", "what happened was", "the reason was",
        "the reason is", "one challenge was", "another thing was",
        "the main challenge was", "the biggest challenge was", "the biggest issue was",
        "i decided to", "we decided to", "we needed to", "i wanted to", "which meant", "in order to"
    ]
}

private enum RealtimeStartupPhase: String, Sendable {
    case notStarted = "notStarted"
    case audioSetup = "audio setup"
    case connect = "connect"
    case sessionUpdate = "session.update"
    case responseCreate = "response.create"
    case completed = "completed"
}

struct RealtimeStartupDiagnostics: Equatable, Sendable {
    let phase: String
    let underlyingDomain: String?
    let underlyingCode: Int?
    let localizedDescription: String?
    let closeCode: Int?
    let closeReason: String?
    let httpStatus: Int?
    let openAIErrorType: String?
    let openAIErrorCode: String?
    let openAIErrorMessage: String?
    let openAIErrorParam: String?
}

private struct RealtimeStartupFailure: Error, LocalizedError {
    let diagnostics: RealtimeStartupDiagnostics

    var errorDescription: String? {
        diagnostics.localizedDescription ?? "Realtime startup failed during \(diagnostics.phase)."
    }
}

struct RealtimeSessionError: Error, Equatable, Sendable {
    let message: String
    let type: String?
    let code: String?
    let param: String?
    let diagnostics: RealtimeStartupDiagnostics?

    init(
        message: String,
        type: String?,
        code: String?,
        param: String?,
        diagnostics: RealtimeStartupDiagnostics? = nil
    ) {
        self.message = message
        self.type = type
        self.code = code
        self.param = param
        self.diagnostics = diagnostics
    }

    init(openAIEvent: [String: Any]) {
        let error = openAIEvent["error"] as? [String: Any]
        self.message = error?["message"] as? String ?? "The realtime interview session reported an error."
        self.type = error?["type"] as? String
        self.code = error?["code"] as? String
        self.param = error?["param"] as? String
        self.diagnostics = RealtimeStartupDiagnostics(
            phase: "openAI.error",
            underlyingDomain: nil,
            underlyingCode: nil,
            localizedDescription: self.message,
            closeCode: nil,
            closeReason: nil,
            httpStatus: nil,
            openAIErrorType: self.type,
            openAIErrorCode: self.code,
            openAIErrorMessage: self.message,
            openAIErrorParam: self.param
        )
    }

    var displayMessage: String {
        var parts = [message]
        if let code, !code.isEmpty {
            parts.append("Code: \(code)")
        }
        if let type, !type.isEmpty {
            parts.append("Type: \(type)")
        }
        return parts.joined(separator: " ")
    }

    var isEmptyAudioCommit: Bool {
        code == "input_audio_buffer_commit_empty"
    }

    var isResponseCancelNotActive: Bool {
        code == "response_cancel_not_active"
            || message.localizedCaseInsensitiveContains("no active response")
    }
}

private enum RealtimeError: Error, LocalizedError {
    case invalidURL
    case notConnected
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The interview service URL could not be constructed. Please check your network settings and try again."
        case .notConnected:
            return "The connection to the interview service was not open when a message needed to be sent. This may be a transient network issue — please try starting the interview again."
        case .encodingFailed:
            return "A message to the interview service could not be encoded. Please try again."
        }
    }
}
