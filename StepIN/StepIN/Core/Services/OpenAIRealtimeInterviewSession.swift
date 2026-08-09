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
        case listening
        case speaking
        case thinking
        case paused
        case completed
        case error
    }

    let finalPhrase = "Thank you. That concludes our interview."

    private let configuration: InterviewConfiguration
    private let apiKey: String
    private let onStateChange: (RuntimeState) -> Void
    private let onInterviewerText: (String) -> Void
    private let onTranscriptEntry: (TranscriptEntry) -> Void
    private let onCompleted: (_ isPartial: Bool, _ completedQuestionCount: Int) -> Void
    private let onError: (RealtimeSessionError) -> Void
    private let primaryInterviewLanguage = "English"

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
    private let candidateTurnCompletionGrace: Duration = .seconds(2.0)
    private let semanticallyCompleteTurnDelay: Duration = .milliseconds(700)
    private let defaultTurnCompletionDelay: Duration = .milliseconds(1200)
    private var uploadedCandidateAudioDurationMs: Double = 0
    private var candidateResponseInFlight = false
    private var serverVADStoppedCurrentTurn = false
    private let minimumCommitAudioDurationMs: Double = 100

    init(
        configuration: InterviewConfiguration,
        apiKey: String,
        onStateChange: @escaping (RuntimeState) -> Void,
        onInterviewerText: @escaping (String) -> Void,
        onTranscriptEntry: @escaping (TranscriptEntry) -> Void,
        onCompleted: @escaping (_ isPartial: Bool, _ completedQuestionCount: Int) -> Void,
        onError: @escaping (RealtimeSessionError) -> Void
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.onStateChange = onStateChange
        self.onInterviewerText = onInterviewerText
        self.onTranscriptEntry = onTranscriptEntry
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

    func stop() {
        candidateCompletionTask?.cancel()
        candidateCompletionTask = nil
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
        let prompt = InterviewSystemPrompt.make(for: configuration, primaryInterviewLanguage: primaryInterviewLanguage)
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
                            "eagerness": "low",
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
        try await sendEvent(event)
    }

    private func requestOpeningTurn() async throws {
        beginAssistantAudioTurn()
        try await sendEvent([
            "type": "response.create",
            "response": [
                "instructions": "Begin the interview now. Use the required opening sentence, then ask the warm-up question exactly."
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
            if let transcript = object["transcript"] as? String {
                appendCandidateTranscript(transcript)
                if candidateCompletionTask != nil, !assistantAudioActive {
                    scheduleCandidateCompletion()
                }
            }
        case "response.created", "response.output_item.added", "response.content_part.added":
            beginAssistantAudioTurn()
            onStateChange(.speaking)
        case "response.output_audio.delta", "response.audio.delta":
            if let delta = object["delta"] as? String {
                beginAssistantAudioTurn()
                playBase64PCM(delta)
                onStateChange(.speaking)
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

        candidateResponseInFlight = true
        uploadedCandidateAudioDurationMs = 0
        serverVADStoppedCurrentTurn = false
        beginAssistantAudioTurn()
        do {
            try await sendEvent(["type": "response.create"])
            onStateChange(.thinking)
        } catch {
            reportError(RealtimeSessionError(message: error.localizedDescription, type: "response_create", code: nil, param: nil))
        }
    }

    private func beginAssistantAudioTurn() {
        cancelPendingCandidateCompletion()
        assistantAudioActive = true
        serverAudioDone = false
    }

    private func finishAssistantPlaybackIfReady() {
        guard assistantAudioActive, serverAudioDone, pendingPlaybackBuffers == 0 else { return }
        assistantAudioActive = false

        if shouldCompleteAfterAssistantPlayback {
            shouldCompleteAfterAssistantPlayback = false
            complete(isPartial: false)
        } else if !didComplete {
            onStateChange(.listening)
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

    // MARK: Transcript

    private func appendCandidateTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        candidateTextBuffer = trimmed
        onTranscriptEntry(TranscriptEntry(speaker: .candidate, text: trimmed))
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
        if text.localizedCaseInsensitiveContains("tell me about yourself") { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to add before we conclude") { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to add or ask before we conclude") { return false }
        if text.localizedCaseInsensitiveContains("anything you'd like to ask or add") { return false }
        if text.localizedCaseInsensitiveContains("before we wrap up") { return false }
        if text.localizedCaseInsensitiveContains("could you clarify") { return false }
        if text.localizedCaseInsensitiveContains("could you give me a specific example") { return false }
        if isLikelyFollowUpOrProbe(text) { return false }
        return countedQuestionCount < configuration.questionCount.rawValue
    }

    private func isLikelyFollowUpOrProbe(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let followUpPrefixes = [
            "what was your role",
            "what part of",
            "what did you own",
            "how did you approach that",
            "how did you measure",
            "what was the outcome",
            "what led you to",
            "why did you choose",
            "can you tell me more",
            "could you tell me more",
            "could you give me an example",
            "what do you mean by",
            "how so",
            "in what way",
            "what happened next"
        ]

        return followUpPrefixes.contains { normalized.hasPrefix($0) }
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
