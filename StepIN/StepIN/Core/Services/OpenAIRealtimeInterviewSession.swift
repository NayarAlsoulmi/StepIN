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
        case introductionSpeaking
        case openingBeat
        case listening
        case speaking
        case thinking
        case paused
        case completed
        case error
    }

    private enum InterviewLanguage: String, Equatable {
        case english = "English"
        case arabic = "Arabic"

        /// ISO 639-1 code passed to the transcription model to pin language detection.
        /// Prevents per-utterance auto-detection from misclassifying short English
        /// words as another language (e.g. "Zero" → "Yero" via Turkish phoneme match).
        var transcriptionLanguageCode: String {
            switch self {
            case .english: return "en"
            case .arabic: return "ar"
            }
        }
    }

    private enum AssistantTurnPurpose: Equatable {
        case introduction
        case interview
        case closing
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
    private var isConnected = false
    private var isPaused = false
    private var didComplete = false
    private var didReportError = false
    private var assistantTextBuffer = ""
    private var lastAssistantTranscript = ""
    private var candidateTextBuffer = ""
    private var countedQuestionCount = 0
    private var assistantAudioActive = false
    private var serverAudioDone = true
    private var pendingPlaybackBuffers = 0
    private var playbackGeneration = 0
    private var shouldCompleteAfterAssistantPlayback = false
    private var candidateCompletionTask: Task<Void, Never>?
    private var openingQuestionTask: Task<Void, Never>?
    private let candidateTurnCompletionGrace: Duration = .seconds(2.0)
    private let semanticallyCompleteTurnDelay: Duration = .milliseconds(500)
    private let defaultTurnCompletionDelay: Duration = .milliseconds(800)
    private let openingQuestionBeat: Duration = .milliseconds(550)
    private var uploadedCandidateAudioDurationMs: Double = 0
    private var candidateResponseInFlight = false
    private var serverVADStoppedCurrentTurn = false
    private let minimumCommitAudioDurationMs: Double = 100
    private var hasDeliveredIntroduction = false
    private var currentAssistantTurnPurpose: AssistantTurnPurpose = .interview
    private var didStartIntroductionAudio = false

    // MARK: — Candidate turn / transcript identity

    /// Local UUID for the current logical candidate answer turn.
    /// Created at speech_started, cleared when response.create is dispatched.
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

    init(
        configuration: InterviewConfiguration,
        apiKey: String,
        onStateChange: @escaping (RuntimeState) -> Void,
        onInterviewerText: @escaping (String) -> Void,
        onTranscriptEntry: @escaping (TranscriptEntry) -> Void,
        onCandidateTranscript: @escaping (_ turnID: UUID, _ text: String) -> Void,
        onCompleted: @escaping (_ isPartial: Bool, _ completedQuestionCount: Int) -> Void,
        onError: @escaping (RealtimeSessionError) -> Void
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.onStateChange = onStateChange
        self.onInterviewerText = onInterviewerText
        self.onTranscriptEntry = onTranscriptEntry
        self.onCandidateTranscript = onCandidateTranscript
        self.onCompleted = onCompleted
        self.onError = onError
    }

    func start() async throws {
        onStateChange(.preparing)
        try configureAudioSession()
        configurePlayback()
        try connectWebSocket()
        try await sendSessionUpdate()
        try startMicrophoneCapture()
        try await requestOpeningTurn()
        onStateChange(.speaking)
    }

    func pause() {
        isPaused = true
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
        audioEngine.stop()
        playbackGeneration += 1
        pendingPlaybackBuffers = 0
        assistantAudioActive = false
        serverAudioDone = true
        shouldCompleteAfterAssistantPlayback = false
        uploadedCandidateAudioDurationMs = 0
        candidateResponseInFlight = false
        serverVADStoppedCurrentTurn = false
        activeCandidateTurnID = nil
        itemIDToCandidateTurnID = [:]
        candidateTranscriptAccumulator = [:]
        emittedCandidateTurnIDs = []
        hasDeliveredIntroduction = false
        currentAssistantTurnPurpose = .interview
        didStartIntroductionAudio = false
        playerNode.stop()
        playbackEngine.stop()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
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
        task.resume()
        isConnected = true
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
                            "model": "gpt-4o-mini-transcribe",
                            "language": primaryInterviewLanguage.transcriptionLanguageCode
                        ]
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24000],
                        "voice": "alloy"
                    ]
                ]
            ]
        ]
        try await sendEvent(event)
    }

    private func requestOpeningTurn() async throws {
        beginAssistantAudioTurn(purpose: .introduction)
        didStartIntroductionAudio = false
        try await sendEvent([
            "type": "response.create",
            "response": [
                "instructions": "Speak exactly this English introduction and do not ask any interview question: \"\(introductionText)\""
            ]
        ])
    }

    private func sendEvent(_ event: [String: Any]) async throws {
        guard let webSocketTask else { throw RealtimeError.notConnected }
        let data = try JSONSerialization.data(withJSONObject: event)
        guard let text = String(data: data, encoding: .utf8) else { throw RealtimeError.encodingFailed }
        try await webSocketTask.send(.string(text))
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
                reportError(RealtimeSessionError(message: error.localizedDescription, type: "websocket_receive", code: nil, param: nil))
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

        switch type {
        case "input_audio_buffer.speech_started":
            cancelPendingCandidateCompletion()
            beginCandidateTurn(itemID: object["item_id"] as? String)
            if !assistantAudioActive {
                candidateResponseInFlight = false
                serverVADStoppedCurrentTurn = false
                onStateChange(.listening)
            }
        case "input_audio_buffer.speech_stopped":
            if !assistantAudioActive {
                serverVADStoppedCurrentTurn = true
                scheduleCandidateCompletion()
                onStateChange(.listening)
            }
        case "conversation.item.input_audio_transcription.completed":
            updateCandidateTranscript(
                itemID: object["item_id"] as? String ?? "",
                text: object["transcript"] as? String ?? ""
            )
        case "response.created", "response.output_item.added", "response.content_part.added":
            beginAssistantAudioTurn(purpose: currentAssistantTurnPurpose)
            if currentAssistantTurnPurpose != .introduction {
                onStateChange(.speaking)
            }
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = object["delta"] as? String {
                beginAssistantAudioTurn(purpose: currentAssistantTurnPurpose)
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
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            if let delta = object["delta"] as? String {
                assistantTextBuffer += delta
                onInterviewerText(assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "response.output_audio.done", "response.audio.done":
            serverAudioDone = true
            finishAssistantPlaybackIfReady()
        case "response.output_audio_transcript.done", "response.audio_transcript.done", "response.output_text.done":
            if let transcript = object["transcript"] as? String ?? object["text"] as? String {
                assistantTextBuffer = transcript
            }
            flushAssistantTranscriptIfNeeded()
        case "response.done":
            let completedText = assistantTextBuffer.isEmpty ? lastAssistantTranscript : assistantTextBuffer
            flushAssistantTranscriptIfNeeded()
            shouldCompleteAfterAssistantPlayback = completedText.contains(finalPhrase)
            serverAudioDone = true
            candidateResponseInFlight = false
            finishAssistantPlaybackIfReady()
        case "error":
            let error = RealtimeSessionError(openAIEvent: object)
            if error.isEmptyAudioCommit {
                recoverFromEmptyAudioCommit()
            } else {
                reportError(error)
            }
        default:
            break
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
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let pcmData = Self.convertToPCM16Data(buffer: buffer)
            guard !pcmData.isEmpty else { return }
            let base64 = pcmData.base64EncodedString()
            let durationMs = Self.pcm16DurationMilliseconds(pcmData)
            Task { @MainActor [weak self] in
                guard let self, !self.isPaused, self.isConnected, !self.assistantAudioActive else { return }
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
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playbackGeneration == generation else { return }
                self.pendingPlaybackBuffers = max(0, self.pendingPlaybackBuffers - 1)
                self.finishAssistantPlaybackIfReady()
            }
        }
    }

    private func scheduleCandidateCompletion() {
        candidateCompletionTask?.cancel()
        let delay = candidateTurnCompletionDelay()
        candidateCompletionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                await self?.requestAssistantResponseForCompletedCandidateTurn(commitIfNeeded: false)
            } catch {
                return
            }
        }
    }

    private func cancelPendingCandidateCompletion() {
        candidateCompletionTask?.cancel()
        candidateCompletionTask = nil
    }

    private var shouldCommitCandidateAudioManually: Bool {
        !serverVADStoppedCurrentTurn && uploadedCandidateAudioDurationMs >= minimumCommitAudioDurationMs
    }

    private func candidateTurnCompletionDelay() -> Duration {
        let trimmed = candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultTurnCompletionDelay }
        return Self.appearsSemanticallyIncomplete(trimmed) ? candidateTurnCompletionGrace : semanticallyCompleteTurnDelay
    }

    private func requestAssistantResponseForCompletedCandidateTurn(commitIfNeeded: Bool) async {
        guard !assistantAudioActive, !didComplete, !didReportError, !candidateResponseInFlight else { return }
        candidateCompletionTask = nil

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

        if let requestedLanguage = Self.requestedInterviewLanguage(in: candidateTextBuffer),
           requestedLanguage != primaryInterviewLanguage {
            primaryInterviewLanguage = requestedLanguage
            do {
                try await sendLanguageInstructionUpdate()
            } catch {
                reportError(RealtimeSessionError(message: error.localizedDescription, type: "session_language_update", code: nil, param: nil))
                return
            }
        }

        candidateResponseInFlight = true
        uploadedCandidateAudioDurationMs = 0
        serverVADStoppedCurrentTurn = false
        beginAssistantAudioTurn(purpose: .interview)
        do {
            // Emit exactly one candidate transcript entry for this logical turn.
            // Joins all transcription.completed texts received since speech_started.
            // Marks the turn as emitted so any late-arriving transcription.completed
            // event will update the existing entry rather than append a new one.
            if let turnID = activeCandidateTurnID {
                let parts = candidateTranscriptAccumulator[turnID] ?? []
                let accumulated = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let textToEmit = accumulated.isEmpty
                    ? candidateTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    : accumulated
                emittedCandidateTurnIDs.insert(turnID)
                if !textToEmit.isEmpty {
                    onCandidateTranscript(turnID, textToEmit)
                }
                activeCandidateTurnID = nil
            }
            // Notify the analyzer that this candidate turn is complete before
            // sending response.create, so the turn boundary is captured accurately.
            await localAnalyzer.markTurnComplete()
            try await sendEvent(["type": "response.create"])
            onStateChange(.thinking)
        } catch {
            reportError(RealtimeSessionError(message: error.localizedDescription, type: "response_create", code: nil, param: nil))
        }
    }

    private func sendLanguageInstructionUpdate() async throws {
        try await sendInProgressSessionUpdate()
    }

    private func sendInProgressSessionUpdate() async throws {
        let prompt = InterviewSystemPrompt.make(
            for: configuration,
            primaryInterviewLanguage: primaryInterviewLanguage.rawValue,
            includeOpeningInstructions: false
        )
        // Include the transcription language so a mid-session language switch
        // (e.g. candidate requests Arabic) also pins the transcription model
        // to the new language rather than reverting to auto-detection.
        try await sendEvent([
            "type": "session.update",
            "session": [
                "type": "realtime",
                "instructions": prompt,
                "audio": [
                    "input": [
                        "transcription": [
                            "model": "gpt-4o-mini-transcribe",
                            "language": primaryInterviewLanguage.transcriptionLanguageCode
                        ]
                    ]
                ]
            ]
        ])
    }

    private func beginAssistantAudioTurn(purpose: AssistantTurnPurpose) {
        cancelPendingCandidateCompletion()
        currentAssistantTurnPurpose = purpose
        assistantAudioActive = true
        serverAudioDone = false
    }

    private func finishAssistantPlaybackIfReady() {
        guard assistantAudioActive, serverAudioDone, pendingPlaybackBuffers == 0 else { return }
        let completedPurpose = currentAssistantTurnPurpose
        assistantAudioActive = false

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
            try await sendInProgressSessionUpdate()
            beginAssistantAudioTurn(purpose: .interview)
            let hasCVContext = configuration.resolvedCVText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let firstQuestionInstruction = hasCVContext
                ? "Ask the first real counted interview question now in English. Do not greet again, do not mention question numbers, and do not ask any separate starter question. When the candidate's CV contains a project, experience, or skill directly relevant to this role, opening with a question grounded in that specific detail is strongly preferred over a generic opener — but do not announce that you read their CV."
                : "Ask the first real counted interview question now in English. Do not greet again, do not mention question numbers, and do not ask any separate starter question."
            try await sendEvent([
                "type": "response.create",
                "response": [
                    "instructions": firstQuestionInstruction
                ]
            ])
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

    private static func requestedInterviewLanguage(in text: String) -> InterviewLanguage? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        if requestsArabicInterviewLanguage(normalized) {
            return .arabic
        }

        if requestsEnglishInterviewLanguage(normalized) {
            return .english
        }

        return nil
    }

    private static func requestsArabicInterviewLanguage(_ text: String) -> Bool {
        let mentionsArabic = text.contains("arabic")
            || text.contains("عربي")
            || text.contains("العربي")
            || text.contains("بالعربي")
            || text.contains("العربية")
        guard mentionsArabic else { return false }

        let englishIntent = [
            "can we continue",
            "could we continue",
            "let's continue",
            "lets continue",
            "switch to",
            "change to",
            "can you speak",
            "could you speak",
            "speak arabic",
            "talk in",
            "continue in"
        ]

        let arabicIntent = [
            "ممكن نكمل",
            "نقدر نكمل",
            "خلنا نكمل",
            "نكمل بالعربي",
            "تكلم عربي",
            "تكلمي عربي",
            "تكلم بالعربي",
            "تكلمي بالعربي",
            "حول للعربي",
            "نحول للعربي",
            "غير للعربي"
        ]

        return englishIntent.contains { text.contains($0) } || arabicIntent.contains { text.contains($0) }
    }

    private static func requestsEnglishInterviewLanguage(_ text: String) -> Bool {
        let mentionsEnglish = text.contains("english")
            || text.contains("إنجليزي")
            || text.contains("انجليزي")
            || text.contains("بالإنجليزي")
            || text.contains("بالانجليزي")
        guard mentionsEnglish else { return false }

        let englishIntent = [
            "can we continue",
            "could we continue",
            "let's continue",
            "lets continue",
            "switch to",
            "change to",
            "can you speak",
            "could you speak",
            "speak english",
            "talk in",
            "continue in"
        ]

        let arabicIntent = [
            "ممكن نكمل",
            "نقدر نكمل",
            "خلنا نكمل",
            "نكمل بالإنجليزي",
            "نكمل بالانجليزي",
            "تكلم إنجليزي",
            "تكلم انجليزي",
            "تكلمي إنجليزي",
            "تكلمي انجليزي",
            "حول للإنجليزي",
            "حول للانجليزي",
            "نحول للإنجليزي",
            "نحول للانجليزي",
            "غير للإنجليزي",
            "غير للانجليزي"
        ]

        return englishIntent.contains { text.contains($0) } || arabicIntent.contains { text.contains($0) }
    }

    private static func appearsSemanticallyIncomplete(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowercased = trimmed.lowercased()
        let incompleteEndings = [
            "and", "or", "but", "because", "so", "then", "when", "while",
            "where", "which", "that", "to", "for", "with", "about", "from"
        ]

        if incompleteEndings.contains(where: { lowercased.hasSuffix(" \($0)") || lowercased == $0 }) {
            return true
        }

        let incompletePhrases = [
            "the main thing i learned",
            "the biggest challenge was",
            "one example would be",
            "what i mean is",
            "because when",
            "i was going to say",
            "for example"
        ]

        if incompletePhrases.contains(where: { lowercased.hasSuffix($0) }) {
            return true
        }

        return false
    }

    // MARK: Candidate turn / transcript lifecycle

    /// Called when speech_started fires. Creates a new logical turn UUID when no
    /// turn is active; otherwise records the new item_id under the existing turn
    /// (candidate resumed after a mid-answer thinking pause, still same turn).
    private func beginCandidateTurn(itemID: String?) {
        if activeCandidateTurnID == nil {
            candidateTextBuffer = ""
            activeCandidateTurnID = UUID()
        }
        if let itemID, !itemID.isEmpty {
            itemIDToCandidateTurnID[itemID] = activeCandidateTurnID!
        }
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

        // Accumulate (each item's text is the authoritative final for that item).
        var parts = candidateTranscriptAccumulator[turnID] ?? []
        parts.append(trimmed)
        candidateTranscriptAccumulator[turnID] = parts
        candidateTextBuffer = parts.joined(separator: " ")

        // If response.create was already dispatched for this turn, forward the
        // now-complete text so the ViewModel updates the existing entry in place.
        if emittedCandidateTurnIDs.contains(turnID) {
            onCandidateTranscript(turnID, candidateTextBuffer)
        }
    }

    private func flushAssistantTranscriptIfNeeded() {
        let trimmed = assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastAssistantTranscript = trimmed
        onInterviewerText(trimmed)
        onTranscriptEntry(TranscriptEntry(speaker: .interviewer, text: trimmed))
        if shouldCountAssistantTurn(trimmed) {
            countedQuestionCount = min(countedQuestionCount + 1, configuration.questionCount.rawValue)
        }
        assistantTextBuffer = ""
    }

    private func shouldCountAssistantTurn(_ text: String) -> Bool {
        guard text.contains("?") else { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to add before we conclude") { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to add or ask before we conclude") { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to ask or add") { return false }
        if text.localizedCaseInsensitiveContains("before we wrap up") { return false }
        if text.localizedCaseInsensitiveContains("take your time") { return false }
        if text.localizedCaseInsensitiveContains("could you repeat") { return false }
        if text.localizedCaseInsensitiveContains("would you like me to repeat") { return false }
        if text.localizedCaseInsensitiveContains("let me rephrase") { return false }
        if text.localizedCaseInsensitiveContains("sorry, could you repeat") { return false }
        if text.localizedCaseInsensitiveContains("i didn't quite catch") { return false }
        if text.localizedCaseInsensitiveContains("could you clarify") { return false }
        if text.localizedCaseInsensitiveContains("could you give me a specific example") { return false }
        return countedQuestionCount < configuration.questionCount.rawValue
    }

    private func reportError(_ error: RealtimeSessionError) {
        guard !didComplete, !didReportError else { return }
        didReportError = true
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
}

struct RealtimeSessionError: Error, Equatable, Sendable {
    let message: String
    let type: String?
    let code: String?
    let param: String?

    init(message: String, type: String?, code: String?, param: String?) {
        self.message = message
        self.type = type
        self.code = code
        self.param = param
    }

    init(openAIEvent: [String: Any]) {
        let error = openAIEvent["error"] as? [String: Any]
        self.message = error?["message"] as? String ?? "The realtime interview session reported an error."
        self.type = error?["type"] as? String
        self.code = error?["code"] as? String
        self.param = error?["param"] as? String
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
}

private enum RealtimeError: Error {
    case invalidURL
    case notConnected
    case encodingFailed
}
