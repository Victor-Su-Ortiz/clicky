//
//  TogetherParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  Transcription provider backed by NVIDIA Parakeet served on Together AI.
//  Primary path: push-to-talk audio streams live over the Cloudflare
//  Worker's /stt-stream websocket relay (Together's realtime endpoint), so
//  the final transcript lands ~250ms after key release. Fallback path: the
//  same audio is always buffered locally as 16kHz mono PCM16, and if the
//  websocket fails at any point — including the realtime endpoint dropping
//  Parakeet support, which is undocumented — the session uploads the WAV to
//  the Worker's /stt route instead (~550ms warm). The Worker holds the
//  Together API key on both paths, so no key ships in the app.
//

import AVFoundation
import Foundation

struct TogetherParakeetTranscriptionProviderError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class TogetherParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Together Parakeet"
    let requiresSpeechRecognitionPermission = false

    /// One URLSession shared across all dictation sessions, so connection
    /// and TLS reuse make every upload after the first one fast — measured
    /// cold handshakes cost 0.5–1.5s extra per transcription. Mirrors the
    /// AssemblyAI provider's shared-session pattern (and per-session
    /// sessions corrupted its connection pool; see that file's notes).
    fileprivate static let sharedURLSession: URLSession = {
        // No waitsForConnectivity, and both timeouts sit well under the 20s
        // final-transcript fallback: a connectivity blip must fail FAST
        // through onError (which tells the user to try again) rather than
        // stall until the fallback silently discards the utterance.
        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.timeoutIntervalForRequest = 12
        urlSessionConfiguration.timeoutIntervalForResource = 16
        urlSessionConfiguration.waitsForConnectivity = false
        return URLSession(configuration: urlSessionConfiguration)
    }()

    /// The Worker holds the Together API key, so there is nothing to
    /// configure app-side. A missing TOGETHER_API_KEY secret on the Worker
    /// surfaces as a clear runtime error from the /stt route.
    var isConfigured: Bool {
        true
    }

    var unavailableExplanation: String? {
        nil
    }

    /// URLSession for the streaming websocket — separate from the upload
    /// session because that one's 16s resource timeout would kill a
    /// websocket mid-dictation on a long push-to-talk hold.
    fileprivate static let sharedWebsocketURLSession: URLSession = {
        let urlSessionConfiguration = URLSessionConfiguration.default
        urlSessionConfiguration.waitsForConnectivity = false
        return URLSession(configuration: urlSessionConfiguration)
    }()

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // Parakeet has no contextual-prompt parameter, so keyterms are unused.
        // Try the low-latency websocket first; if the relay or Together's
        // realtime endpoint is unavailable, fall back to the upload session
        // so dictation always works.
        let streamingSession = TogetherParakeetStreamingTranscriptionSession(
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )
        do {
            try await streamingSession.connect()
            return streamingSession
        } catch {
            print("⚠️ Parakeet websocket unavailable (\(error.localizedDescription)) — using upload fallback")
            streamingSession.cancel()
            return TogetherParakeetTranscriptionSession(
                onTranscriptUpdate: onTranscriptUpdate,
                onFinalTranscriptReady: onFinalTranscriptReady,
                onError: onError
            )
        }
    }
}

private final class TogetherParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// For an upload-based provider this is a hard deadline on the ENTIRE
    /// upload + inference roundtrip (nothing exists before key release), not
    /// a safety net like it is for streaming providers — so it is generous.
    /// The URLSession timeouts below are shorter, so a network failure
    /// always surfaces as a spoken error before this fallback can silently
    /// drop the utterance.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 20.0

    private static let targetSampleRate = 16_000

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.parakeet.transcription")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    /// Shared across sessions for connection reuse — never invalidated.
    private let urlSession = TogetherParakeetTranscriptionProvider.sharedURLSession

    private var bufferedPCM16AudioData = Data()
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var transcriptionUploadTask: Task<Void, Never>?

    init(
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            let bufferedPCM16AudioData = self.bufferedPCM16AudioData
            self.transcriptionUploadTask = Task { [weak self] in
                await self?.transcribeBufferedAudio(bufferedPCM16AudioData)
            }
        }
    }

    func cancel() {
        // [weak self] is load-bearing: cancel() is also called from deinit,
        // and a strong capture there would outlive deallocation — the block
        // would later write into freed memory (use-after-free). With weak,
        // the deinit-time block resolves nil and no-ops.
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.bufferedPCM16AudioData.removeAll(keepingCapacity: false)
        }

        // Cancelling the Task cancels the in-flight URLSession request via
        // cooperative cancellation. The URLSession itself is shared across
        // sessions and must never be invalidated here.
        transcriptionUploadTask?.cancel()
    }

    private func transcribeBufferedAudio(_ bufferedPCM16AudioData: Data) async {
        guard !Task.isCancelled else { return }

        let trimmedAudioDataIsEmpty = stateQueue.sync {
            isCancelled || bufferedPCM16AudioData.isEmpty
        }

        if trimmedAudioDataIsEmpty {
            deliverFinalTranscript("")
            return
        }

        let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
            fromPCM16MonoAudio: bufferedPCM16AudioData,
            sampleRate: Self.targetSampleRate
        )

        do {
            let transcriptText = try await requestTranscription(for: wavAudioData)
            guard !stateQueue.sync(execute: { isCancelled }) else { return }

            if !transcriptText.isEmpty {
                onTranscriptUpdate(transcriptText)
            }

            deliverFinalTranscript(transcriptText)
        } catch {
            guard !stateQueue.sync(execute: { isCancelled }) else { return }
            print("[Parakeet Transcription] ❌ Upload failed (audio size: \(wavAudioData.count) bytes): \(error.localizedDescription)")
            onError(error)
        }
    }

    private func requestTranscription(for wavAudioData: Data) async throws -> String {
        try await TogetherParakeetUploadSupport.requestTranscription(
            wavAudioData: wavAudioData,
            urlSession: urlSession
        )
    }

    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true
        onFinalTranscriptReady(transcriptText)
    }

    deinit {
        cancel()
    }
}

// MARK: - Shared Upload Request

/// The WAV→transcript request against the Worker's /stt route, shared by
/// the upload session (primary path) and the streaming session (fallback).
enum TogetherParakeetUploadSupport {
    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    static let transcriptionURL = URL(string: "\(CompanionManager.workerBaseURL)/stt")!

    static func requestTranscription(wavAudioData: Data, urlSession: URLSession) async throws -> String {
        // The Worker owns the model and request shape — the app sends only
        // the raw WAV, mirroring how /tts receives only the text.
        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.httpBody = wavAudioData

        let (responseData, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TogetherParakeetTranscriptionProviderError(
                message: "Parakeet transcription returned an invalid response."
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseText = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw TogetherParakeetTranscriptionProviderError(
                message: "Parakeet transcription failed: \(responseText)"
            )
        }

        if let transcriptionResponse = try? JSONDecoder().decode(
            TranscriptionResponse.self,
            from: responseData
        ) {
            return transcriptionResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        throw TogetherParakeetTranscriptionProviderError(
            message: "Parakeet transcription returned an unexpected response format."
        )
    }
}

// MARK: - Streaming Session (websocket relay)

/// Streams push-to-talk audio over the Worker's /stt-stream websocket relay
/// to Together's realtime Parakeet endpoint. Protocol: PCM16 chunks go out
/// as base64 `input_audio_buffer.append` events while the user talks; on key
/// release a `commit` is sent and the server's VAD-segmented
/// `transcription.completed` events are joined into the final transcript.
/// Every audio buffer is ALSO kept locally: any websocket failure — connect,
/// mid-stream, or a finalization that never arrives — reroutes the whole
/// utterance through the upload fallback, so the undocumented realtime
/// capability is never a single point of failure.
final class TogetherParakeetStreamingTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// Generous hard deadline (see the upload session's note); internal
    /// finalization deadlines below are much shorter, so the upload fallback
    /// always resolves or errors well before this fires.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 20.0

    /// The Worker's relay route with the scheme switched to websocket form.
    /// Handles both https→wss (production) and http→ws (local wrangler dev).
    private static let defaultWebsocketURL: URL = {
        let websocketBaseURL = CompanionManager.workerBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
        return URL(string: websocketBaseURL + "/stt-stream")!
    }()
    private static let targetSampleRate = 16_000
    /// How long connect() waits for the relay's session.created handshake.
    private static let connectTimeoutSeconds: TimeInterval = 2.5
    /// Post-commit wait for the final segment's completion when a segment is
    /// clearly still in flight (deltas seen, no completion yet).
    private static let inFlightFinalizationDeadlineSeconds: TimeInterval = 3.5
    /// Post-commit grace when nothing appears in flight — catches a trailing
    /// completion for the last instants of audio without adding real latency.
    private static let quietFinalizationDeadlineSeconds: TimeInterval = 0.6

    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let stateQueue = DispatchQueue(label: "com.learningbuddy.parakeet.streaming")
    private let audioPCM16Converter = BuddyPCM16AudioConverter(
        targetSampleRate: Double(targetSampleRate)
    )
    private let webSocketTask: URLSessionWebSocketTask

    // All mutable state below is owned by stateQueue.
    private var fallbackPCM16AudioData = Data()
    private var completedSegmentTranscripts: [String] = []
    /// Cumulative transcript of the segment currently being spoken (the
    /// realtime endpoint re-sends the whole evolving segment in each delta).
    private var inProgressSegmentTranscript = ""
    /// True when audio has been appended after the last completed segment —
    /// the reliable "something is still in flight" signal. Deltas lag the
    /// audio, so a short trailing phrase can be in flight before its first
    /// delta arrives; relying on deltas alone would clip it.
    private var hasAppendedAudioSinceLastCompletedSegment = false
    private var hasRequestedFinalTranscript = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var isWebsocketBroken = false
    private var pendingConnectContinuation: CheckedContinuation<Void, Error>?
    private var finalizationDeadlineWorkItem: DispatchWorkItem?
    private var receiveLoopTask: Task<Void, Never>?
    private var fallbackUploadTask: Task<Void, Never>?

    init(
        websocketURL: URL = TogetherParakeetStreamingTranscriptionSession.defaultWebsocketURL,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
        self.webSocketTask = TogetherParakeetTranscriptionProvider.sharedWebsocketURLSession
            .webSocketTask(with: websocketURL)
    }

    /// Opens the websocket and waits for the relay's session.created
    /// handshake. Throws on failure or timeout so the provider can hand the
    /// dictation to the upload session instead.
    func connect() async throws {
        webSocketTask.resume()
        startReceiveLoop()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stateQueue.async {
                guard !self.isWebsocketBroken else {
                    continuation.resume(throwing: TogetherParakeetTranscriptionProviderError(
                        message: "Parakeet websocket failed before the handshake."
                    ))
                    return
                }
                self.pendingConnectContinuation = continuation
            }
            stateQueue.asyncAfter(deadline: .now() + Self.connectTimeoutSeconds) { [weak self] in
                guard let self, let pendingContinuation = self.pendingConnectContinuation else { return }
                self.pendingConnectContinuation = nil
                self.isWebsocketBroken = true
                pendingContinuation.resume(throwing: TogetherParakeetTranscriptionProviderError(
                    message: "Parakeet websocket handshake timed out."
                ))
            }
        }
    }

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }

        stateQueue.async { [weak self] in
            guard let self, !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            // Always buffer for the upload fallback, even while streaming.
            self.fallbackPCM16AudioData.append(audioPCM16Data)
            self.hasAppendedAudioSinceLastCompletedSegment = true

            guard !self.isWebsocketBroken else { return }
            let appendEventJSON = #"{"type":"input_audio_buffer.append","audio":"\#(audioPCM16Data.base64EncodedString())"}"#
            self.sendWebsocketMessage(appendEventJSON)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async { [weak self] in
            guard let self, !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true

            guard !self.isWebsocketBroken else {
                self.startUploadFallback()
                return
            }

            self.sendWebsocketMessage(#"{"type":"input_audio_buffer.commit"}"#)

            // Audio appended since the last completed segment means the tail
            // of speech is still being transcribed (even if its first delta
            // hasn't arrived yet) — give it the full deadline. Otherwise only
            // a short grace period, in case the last instants of audio
            // produce one more completion after the commit.
            let isFinalSegmentStillInFlight = !self.inProgressSegmentTranscript.isEmpty
                || self.hasAppendedAudioSinceLastCompletedSegment
            let finalizationDeadline = isFinalSegmentStillInFlight
                ? Self.inFlightFinalizationDeadlineSeconds
                : Self.quietFinalizationDeadlineSeconds
            let deadlineWorkItem = DispatchWorkItem { [weak self] in
                self?.finalizeWithBestEffort()
            }
            self.finalizationDeadlineWorkItem = deadlineWorkItem
            self.stateQueue.asyncAfter(deadline: .now() + finalizationDeadline, execute: deadlineWorkItem)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.fallbackPCM16AudioData.removeAll(keepingCapacity: false)
            self.finalizationDeadlineWorkItem?.cancel()
            self.pendingConnectContinuation?.resume(throwing: CancellationError())
            self.pendingConnectContinuation = nil
        }

        receiveLoopTask?.cancel()
        fallbackUploadTask?.cancel()
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Websocket plumbing (all callbacks hop to stateQueue)

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let webSocketTask = self?.webSocketTask else { return }
                do {
                    let message = try await webSocketTask.receive()
                    self?.handleWebsocketMessage(message)
                } catch {
                    self?.markWebsocketBroken(reason: error.localizedDescription)
                    return
                }
            }
        }
    }

    private func sendWebsocketMessage(_ messageJSON: String) {
        webSocketTask.send(.string(messageJSON)) { [weak self] sendError in
            if let sendError {
                self?.markWebsocketBroken(reason: sendError.localizedDescription)
            }
        }
    }

    private func handleWebsocketMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let messageText) = message,
              let messageJSON = try? JSONSerialization.jsonObject(with: Data(messageText.utf8)) as? [String: Any],
              let eventType = messageJSON["type"] as? String else {
            return
        }

        stateQueue.async { [weak self] in
            guard let self, !self.isCancelled else { return }

            if eventType == "session.created" {
                self.pendingConnectContinuation?.resume()
                self.pendingConnectContinuation = nil
                return
            }

            if eventType.contains("transcription.delta"),
               let deltaTranscript = messageJSON["delta"] as? String {
                self.inProgressSegmentTranscript = deltaTranscript
                return
            }

            if eventType.contains("transcription.completed") {
                let segmentTranscript = (messageJSON["transcript"] as? String)
                    ?? ((messageJSON["item"] as? [String: Any])?["transcript"] as? String)
                    ?? self.inProgressSegmentTranscript
                if !segmentTranscript.isEmpty {
                    self.completedSegmentTranscripts.append(segmentTranscript)
                }
                self.inProgressSegmentTranscript = ""
                self.hasAppendedAudioSinceLastCompletedSegment = false
                self.onTranscriptUpdate(self.completedSegmentTranscripts.joined(separator: " "))

                // The completion that arrives after the commit is the final
                // segment — deliver without waiting for the deadline.
                if self.hasRequestedFinalTranscript {
                    self.finalizationDeadlineWorkItem?.cancel()
                    self.deliverFinalTranscriptOnStateQueue()
                }
                return
            }

            if eventType == "error" {
                print("[Parakeet Streaming] ⚠️ server error event: \(messageText.prefix(200))")
                self.markWebsocketBrokenOnStateQueue(reason: "server error event")
            }
        }
    }

    private func markWebsocketBroken(reason: String) {
        stateQueue.async { [weak self] in
            self?.markWebsocketBrokenOnStateQueue(reason: reason)
        }
    }

    private func markWebsocketBrokenOnStateQueue(reason: String) {
        // The socket closing after delivery (we close it ourselves) or after
        // cancel is expected, not a breakage.
        guard !isWebsocketBroken, !hasDeliveredFinalTranscript, !isCancelled else { return }
        isWebsocketBroken = true
        print("[Parakeet Streaming] ⚠️ websocket broke (\(reason)) — upload fallback armed")

        pendingConnectContinuation?.resume(throwing: TogetherParakeetTranscriptionProviderError(
            message: "Parakeet websocket failed: \(reason)"
        ))
        pendingConnectContinuation = nil

        // If the user already released the key, the websocket can no longer
        // produce the final transcript — reroute through the upload now.
        if hasRequestedFinalTranscript && !hasDeliveredFinalTranscript {
            finalizationDeadlineWorkItem?.cancel()
            startUploadFallback()
        }
    }

    // MARK: - Finalization (on stateQueue)

    private func finalizeWithBestEffort() {
        guard !hasDeliveredFinalTranscript, !isCancelled else { return }
        let hasAnyWebsocketText = !completedSegmentTranscripts.isEmpty || !inProgressSegmentTranscript.isEmpty
        if hasAnyWebsocketText && !hasAppendedAudioSinceLastCompletedSegment {
            deliverFinalTranscriptOnStateQueue()
        } else {
            // Either the websocket produced nothing at all, or the deadline
            // expired with the tail of speech still untranscribed —
            // delivering partial text would silently clip the user's last
            // words, so the upload (which has the complete buffered audio)
            // decides instead.
            startUploadFallback()
        }
    }

    private func deliverFinalTranscriptOnStateQueue() {
        guard !hasDeliveredFinalTranscript else { return }
        hasDeliveredFinalTranscript = true

        var transcriptParts = completedSegmentTranscripts
        if !inProgressSegmentTranscript.isEmpty {
            transcriptParts.append(inProgressSegmentTranscript)
        }
        let finalTranscript = transcriptParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        onFinalTranscriptReady(finalTranscript)
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }

    private func startUploadFallback() {
        guard !hasDeliveredFinalTranscript, fallbackUploadTask == nil else { return }
        let bufferedAudioData = fallbackPCM16AudioData

        guard !bufferedAudioData.isEmpty else {
            hasDeliveredFinalTranscript = true
            onFinalTranscriptReady("")
            return
        }

        fallbackUploadTask = Task { [weak self] in
            let wavAudioData = BuddyWAVFileBuilder.buildWAVData(
                fromPCM16MonoAudio: bufferedAudioData,
                sampleRate: TogetherParakeetStreamingTranscriptionSession.targetSampleRate
            )
            do {
                let transcriptText = try await TogetherParakeetUploadSupport.requestTranscription(
                    wavAudioData: wavAudioData,
                    urlSession: TogetherParakeetTranscriptionProvider.sharedURLSession
                )
                self?.stateQueue.async { [weak self] in
                    guard let self, !self.isCancelled, !self.hasDeliveredFinalTranscript else { return }
                    self.hasDeliveredFinalTranscript = true
                    if !transcriptText.isEmpty {
                        self.onTranscriptUpdate(transcriptText)
                    }
                    self.onFinalTranscriptReady(transcriptText)
                }
            } catch {
                self?.stateQueue.async { [weak self] in
                    guard let self, !self.isCancelled, !self.hasDeliveredFinalTranscript else { return }
                    print("[Parakeet Streaming] ❌ upload fallback failed: \(error.localizedDescription)")
                    self.onError(error)
                }
            }
        }
    }

    deinit {
        // Direct, non-self-capturing cleanup only — enqueuing a strong-self
        // block from deinit would outlive deallocation (use-after-free).
        receiveLoopTask?.cancel()
        fallbackUploadTask?.cancel()
        webSocketTask.cancel(with: .normalClosure, reason: nil)
    }
}
