import Foundation

/// One WebSocket session with Muse Voice Transcribe (wss://api.meta.ai/v1/asr/realtime).
final class RealtimeSession: NSObject, URLSessionWebSocketDelegate {
    let id = UUID()
    let keywords: [String]
    private let apiKey: String
    private let url: URL
    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask!
    private(set) var isReady = false
    private(set) var isClosed = false
    private var buffered: [Data] = []
    private let maxBufferedChunks = 30   // ~2.4 s of audio while the handshake completes
    private var audioMsSent: Double = 0
    private var sendTimes: [(ms: Double, at: Date)] = []
    let openedAt = Date()
    var onEvent: ((TranscriptEvent, RealtimeSession) -> Void)?
    private let queue: DispatchQueue

    init(url: URL, apiKey: String, keywords: [String], queue: DispatchQueue) {
        self.url = url; self.apiKey = apiKey; self.keywords = keywords; self.queue = queue
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        task = urlSession.webSocketTask(with: url)
    }

    func open() {
        task.resume()
        receiveLoop()
        let handshake: JSON = .object([
            "authorization": .object(["accessToken": .string("Bearer \(apiKey)")]),
            "audioEncoding": "PCM_24KHZ",
            "model": "muse-voice-transcribe-1.0",
            "mode": "ENDPOINTING",
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false,
            "keywords": .array(keywords.map { .string($0) }),
            "languageBias": ["English"],
        ])
        guard let text = try? String(data: handshake.data(), encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] err in
            if let err, let self { self.fail("handshake send: \(err.localizedDescription)") }
        }
    }

    func send(_ pcm: Data) {
        guard !isClosed else { return }
        if !isReady {
            if buffered.count < maxBufferedChunks { buffered.append(pcm) }
            return
        }
        rawSend(pcm)
    }

    private func rawSend(_ pcm: Data) {
        let ms = Double(pcm.count) / 2.0 / AudioCapture.sampleRate * 1000
        audioMsSent += ms
        sendTimes.append((audioMsSent, Date()))
        if sendTimes.count > 400 { sendTimes.removeFirst(sendTimes.count - 400) }
        task.send(.data(pcm)) { [weak self] err in
            if let err, let self, !self.isClosed { self.fail("audio send: \(err.localizedDescription)") }
        }
    }

    /// Wall-clock time at which the audio frame containing `audioMs` was sent.
    func sentTime(forAudioMs ms: Double) -> Date? {
        sendTimes.first(where: { $0.ms >= ms })?.at ?? sendTimes.last?.at
    }

    func endStream() {
        guard !isClosed else { return }
        task.send(.string("{\"type\":\"endStream\"}")) { _ in }
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close() }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }

    private func fail(_ message: String) {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            task.cancel(with: .abnormalClosure, reason: nil)
            onEvent?(.disconnected(code: -1, reason: message), self)
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    if !self.isClosed {
                        let code = self.task.closeCode.rawValue
                        let reason = self.task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? error.localizedDescription
                        self.isClosed = true
                        self.onEvent?(.disconnected(code: code, reason: reason), self)
                    }
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receiveLoop()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = try? JSON.parse(text) else { return }
        guard let type = json["type"]?.stringValue else {
            if let sid = json["sessionId"]?.stringValue {
                isReady = true
                let pending = buffered; buffered.removeAll()
                pending.forEach { rawSend($0) }
                onEvent?(.connected(sessionId: sid), self)
            }
            return
        }
        switch type {
        case "speechStart":
            onEvent?(.speechStart(turnId: json["turnId"]?.intValue ?? 0), self)
        case "transcript":
            let t = json["transcript"]?.stringValue ?? ""
            if json["final"]?.boolValue == true {
                onEvent?(.final(text: t, turnId: json["turnId"]?.intValue ?? -1, asrLatencyMs: nil), self)
            } else {
                onEvent?(.partial(text: t), self)
            }
        case "speechEnd":
            let ms = json["audioProcessedMs"]?.doubleValue ?? audioMsSent
            lastSpeechEndSentAt = sentTime(forAudioMs: ms)
            onEvent?(.speechEnd(turnId: json["turnId"]?.intValue ?? 0), self)
        case "speechComplete":
            let t = json["transcript"]?.stringValue ?? ""
            let latency = lastSpeechEndSentAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            onEvent?(.final(text: t, turnId: json["turnId"]?.intValue ?? 0, asrLatencyMs: latency), self)
        case "error":
            let msg = json["message"]?.stringValue ?? "unknown error"
            onEvent?(.error(msg), self)
        default:
            break
        }
    }
    private var lastSpeechEndSentAt: Date?

    // URLSessionWebSocketDelegate
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            onEvent?(.disconnected(code: closeCode.rawValue, reason: reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""), self)
        }
    }
}

/// Keeps one realtime session alive: reconnects on errors, rotates before the 60-minute cap,
/// and hot-swaps sessions when the vocabulary hints change (new session first, then the old one is closed).
public final class RealtimeTranscriber {
    public var keywordsProvider: () -> [String] = { [] }
    /// Delivered on the main queue.
    public var onEvent: ((TranscriptEvent) -> Void)?
    public var apiKey: String?
    public private(set) var isConnected = false

    private let url = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    private let queue = DispatchQueue(label: "ai.sirena.transcriber")
    private var active: RealtimeSession?
    private var pending: RealtimeSession?
    private var stopped = true
    private var reconnectAttempt = 0
    private var speaking = false
    private var lastSpeechActivity = Date.distantPast
    private var consecutiveHandshakeFailures = 0
    private let rotateAfter: TimeInterval = 50 * 60
    private var emittedFinals: [UUID: Set<Int>] = [:]

    public init(apiKey: String?) { self.apiKey = apiKey }

    /// True when the realtime endpoint keeps rejecting us (e.g. not enabled for this key).
    public var realtimeLooksUnavailable: Bool { consecutiveHandshakeFailures >= 3 }

    public func start() {
        queue.async { [self] in
            stopped = false
            reconnectAttempt = 0
            openSession(replacing: false)
        }
    }

    public func stop() {
        queue.async { [self] in
            stopped = true
            isConnected = false
            active?.endStream(); active = nil
            pending?.close(); pending = nil
        }
    }

    public func send(_ pcm: Data) {
        queue.async { [self] in
            guard !stopped else { return }
            active?.send(pcm)
            // Keep the pending session warm too, so no audio is lost at the swap.
            pending?.send(pcm)
        }
    }

    /// Opens a new session with the current keywords if they changed and nobody is speaking.
    public func refreshKeywords(force: Bool = false) {
        queue.async { [self] in
            guard !stopped, pending == nil, let active else { return }
            let kw = keywordsProvider()
            guard force || kw != active.keywords else { return }
            guard !speaking, Date().timeIntervalSince(lastSpeechActivity) > 1.0 else { return }
            Log.speech.info("rotating ASR session for new keywords (\(kw.count, privacy: .public))")
            openSession(replacing: true)
        }
    }

    private func openSession(replacing: Bool) {
        guard let key = apiKey, !key.isEmpty else {
            emit(.error("No API key"))
            return
        }
        let session = RealtimeSession(url: url, apiKey: key, keywords: keywordsProvider(), queue: queue)
        session.onEvent = { [weak self] event, s in self?.handle(event, from: s) }
        if replacing { pending = session } else { active = session }
        session.open()
        // Handshake watchdog
        queue.asyncAfter(deadline: .now() + 12) { [weak self, weak session] in
            guard let self, let session, !session.isReady, !session.isClosed else { return }
            session.close()
            self.handle(.disconnected(code: -2, reason: "handshake timeout"), from: session)
        }
    }

    private func handle(_ event: TranscriptEvent, from session: RealtimeSession) {
        switch event {
        case .connected:
            consecutiveHandshakeFailures = 0
            reconnectAttempt = 0
            if session === pending {
                let old = active
                active = session; pending = nil
                old?.endStream()
                emittedFinals[old?.id ?? UUID()] = nil
            }
            isConnected = true
            emit(event)
            scheduleRotation(for: session)
        case .speechStart:
            if session === active { speaking = true; lastSpeechActivity = Date(); emit(event) }
        case .partial:
            lastSpeechActivity = Date()
            emit(event)
        case .speechEnd:
            lastSpeechActivity = Date()
            emit(event)
        case .final(_, let turnId, _):
            speaking = false
            lastSpeechActivity = Date()
            var set = emittedFinals[session.id] ?? []
            if turnId >= 0, set.contains(turnId) { return }
            set.insert(turnId); emittedFinals[session.id] = set
            emit(event)
        case .error(let msg):
            Log.speech.error("asr error: \(msg, privacy: .public)")
            emit(event)
        case .disconnected(let code, let reason):
            if session === pending {
                pending = nil
                Log.speech.error("pending ASR session failed (\(code)): \(reason, privacy: .public)")
                return
            }
            guard session === active else { return }
            active = nil
            isConnected = false
            emittedFinals[session.id] = nil
            if !session.isReady { consecutiveHandshakeFailures += 1 }
            guard !stopped else { return }
            emit(.disconnected(code: code, reason: reason))
            scheduleReconnect()
        case .reconnecting, .fallbackActive:
            break
        }
    }

    private func scheduleRotation(for session: RealtimeSession) {
        queue.asyncAfter(deadline: .now() + rotateAfter) { [weak self, weak session] in
            guard let self, let session, session === self.active, !self.stopped else { return }
            Log.speech.info("rotating ASR session before the 60-minute cap")
            self.openSession(replacing: true)
        }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(10.0, 0.5 * pow(2.0, Double(reconnectAttempt - 1)))
        emit(.reconnecting(attempt: reconnectAttempt))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.active == nil else { return }
            self.openSession(replacing: false)
        }
    }

    private func emit(_ event: TranscriptEvent) {
        DispatchQueue.main.async { [onEvent] in onEvent?(event) }
    }
}
