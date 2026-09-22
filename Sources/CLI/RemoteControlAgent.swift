import Foundation
import FlyingFox
import FlyingSocks

/// Remote-control agent (PRD §6.10): runs `hark` as a long-lived control plane
/// instead of capturing on launch. Serves a small HTTP/1.1 + JSON API over TCP
/// — flat verbs `GET /status`, `POST /start|/pause|/resume|/stop` — driving a
/// single active recording. The API is control + status only: it never serves
/// transcript/audio content (artifacts land under the working directory).
///
/// Bound to loopback by default; binding to a non-loopback interface requires a
/// bearer token (`$HARK_REMOTE_TOKEN`). Launch-time capture flags become the
/// per-session defaults, overridable by each `POST /start` body.
final class RemoteControlAgent: @unchecked Sendable {
    private let defaults: UncheckedSendableBox<Hark>
    private let rawAddress: String
    private let sessions = RemoteSessionManager()
    private let captureQueue = DispatchQueue(label: "hark.remote.capture")
    private var token: String?
    /// The parsed bound address (`host:port`) reported by `GET /status`; set in
    /// `run()` once the raw `[host:]port` value is parsed (a bare
    /// `--remote-control` arrives here as just the resolved port).
    private var displayAddress: String

    init(defaults: Hark, address: String) {
        self.defaults = UncheckedSendableBox(value: defaults)
        self.rawAddress = address
        self.displayAddress = address
    }

    /// Parses the address, enforces the token policy, starts the server, and
    /// blocks until SIGINT/SIGTERM (or a fatal server error). Throws
    /// `HarkError` for the CLI to map to an exit code.
    func run() throws {
        let address = try RemoteAddress.parse(rawAddress)
        displayAddress = address.display
        token = Self.configuredToken()
        if !address.isLoopback && token == nil {
            throw HarkError.usage("""
                binding to \(address.display) exposes the control API beyond this machine; \
                set $HARK_REMOTE_TOKEN first, or bind to loopback (e.g. \(address.port)).
                """)
        }

        let server = HTTPServer(address: try address.socketAddress())

        Log.notice(
            "hark remote-control agent on http://\(address.display) "
                + (token == nil ? "(loopback, no auth)" : "(bearer-token auth)"))

        let finished = DispatchSemaphore(value: 0)
        let serverError = LockBox<Error>()
        let shuttingDown = LockBox<Bool>()

        let watcher = SignalWatcher()
        watcher.watch([SIGINT, SIGTERM]) { [sessions] in
            Log.notice("shutting down remote-control agent…")
            shuttingDown.set(true)
            sessions.stopActive()
            if sessions.isFinishing() {
                // Visible in the service log: the process exits regardless (the
                // stuck thread goes with it), but say so rather than look clean.
                Log.notice("a previous capture was still finishing; exiting anyway")
            }
            Task { await server.stop(timeout: 1) }
        }

        let task = Task {
            do {
                await registerRoutes(on: server)
                try await server.run()
            } catch {
                serverError.set(error)
            }
            finished.signal()
        }
        finished.wait()
        watcher.cancel()
        task.cancel()

        // `server.stop()` tears the listener down, which surfaces as a thrown
        // error from `server.run()` (e.g. kqueue EBADF). After a shutdown
        // request that's the *expected* path — a clean stop, exit 0 — so only
        // report errors that arrive without one (a genuine startup failure).
        if let error = serverError.get(), shuttingDown.get() != true {
            throw HarkError.ioError(
                "remote-control server could not start on \(address.display): \(error) "
                    + "(is the port already in use?)")
        }
    }

    // MARK: Routes

    private func registerRoutes(on server: HTTPServer) async {
        await server.appendRoute("GET /status") { [self] request in
            handle(request) { try statusResponse() }
        }
        await server.appendRoute("POST /start") { [self] request in
            await handleAsync(request) { try await startResponse(request) }
        }
        await server.appendRoute("POST /pause") { [self] request in
            handle(request) { actionResponse(try sessions.pause()) }
        }
        await server.appendRoute("POST /resume") { [self] request in
            handle(request) { actionResponse(try sessions.resume()) }
        }
        await server.appendRoute("POST /mute") { [self] request in
            handle(request) { actionResponse(try sessions.mute()) }
        }
        await server.appendRoute("POST /unmute") { [self] request in
            handle(request) { actionResponse(try sessions.unmute()) }
        }
        await server.appendRoute("POST /stop") { [self] request in
            handle(request) { actionResponse(try sessions.stop()) }
        }
    }

    /// Auth + error mapping for synchronous handlers.
    private func handle(_ request: HTTPRequest, _ body: () throws -> HTTPResponse) -> HTTPResponse {
        guard authorized(request) else { return Self.error("unauthorized", .unauthorized) }
        do { return try body() } catch { return Self.mapError(error) }
    }

    /// Auth + error mapping for async handlers (those that read the body).
    private func handleAsync(
        _ request: HTTPRequest, _ body: () async throws -> HTTPResponse
    ) async -> HTTPResponse {
        guard authorized(request) else { return Self.error("unauthorized", .unauthorized) }
        do { return try await body() } catch { return Self.mapError(error) }
    }

    // MARK: Handlers

    private func startResponse(_ request: HTTPRequest) async throws -> HTTPResponse {
        let data = try await request.bodyData
        let req: StartRequest
        if data.isEmpty {
            req = StartRequest()
        } else {
            do {
                req = try JSONDecoder().decode(StartRequest.self, from: data)
            } catch {
                throw HarkError.usage("invalid JSON body: \(error)")
            }
        }
        // Resolve existing-output collisions up front (default `unique`) so the
        // response and `GET /status` report the paths actually being written.
        let command = try req.makeCommand(defaults: defaults.value).reservingOutputs()
        let control = CaptureControl()
        let id = UUID().uuidString
        // begin throws .busy (→409) if a recording is already active, or
        // .noMicrophone (→422) if `muted` is requested for a mic-less capture.
        let snap = try sessions.begin(
            id: id, control: control, hasMic: command.capturesMicrophone,
            muted: req.muted ?? false, audio: command.audio, transcript: command.transcript)

        // Run the capture off the server's executor; report the terminal state.
        let box = UncheckedSendableBox(value: command)
        let outcome = StartOutcome()
        captureQueue.async { [sessions] in
            let cmd = box.value
            do {
                try cmd.executeLive(control: control)
                sessions.finish(id: id, error: nil)
                outcome.ended(with: nil)
            } catch {
                Log.verbose("remote session \(id) ended with error: \(error)")
                sessions.finish(id: id, error: Self.message(for: error))
                outcome.ended(with: error)
            }
            control.markRunEnded()
        }
        // Opening the sources, and loading a recognizer model that may be cold,
        // all happen inside executeLive. Answering before that meant answering
        // "recording" while nothing was being captured, and everything said in
        // the meantime was gone. Wait for the capture to exist, and hand back the
        // run's own error instead of a 201 when it fails on the way up.
        let capturing = control.waitUntilCapturing(timeout: Self.startWait)
        if !capturing, let error = outcome.error {
            throw error
        }
        return Self.json(StartedResponse(snapshot: snap, capturing: capturing), .created)
    }

    /// How long `POST /start` waits for the capture to be running before it
    /// answers anyway with `capturing: false`. A first-ever model download can
    /// outlast any sensible wait, and the client can watch `GET /status` for it.
    static let startWait: TimeInterval = 60

    private func statusResponse() throws -> HTTPResponse {
        Self.json(
            StatusResponse(version: harkVersion, address: displayAddress, session: sessions.current()),
            .ok)
    }

    private func actionResponse(_ snap: RemoteSessionManager.Snapshot) -> HTTPResponse {
        Self.json(ActionResponse(snapshot: snap), .ok)
    }

    // MARK: Auth

    private func authorized(_ request: HTTPRequest) -> Bool {
        guard let token else { return true }  // loopback, no token configured
        return request.headers[.authorization] == "Bearer \(token)"
    }

    private static func configuredToken() -> String? {
        ProcessInfo.processInfo.environment["HARK_REMOTE_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: Response building

    private static func json<T: Encodable>(_ value: T, _ status: HTTPStatusCode) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: status, headers: [.contentType: "application/json"], body: data)
    }

    private static func error(_ message: String, _ status: HTTPStatusCode) -> HTTPResponse {
        json(ErrorResponse(error: message), status)
    }

    /// Maps an internal error to an HTTP response (exit-code semantics → status).
    private static func mapError(_ error: Error) -> HTTPResponse {
        switch error {
        case AgentError.busy:
            return self.error("a recording is already active", .conflict)
        case AgentError.finishing:
            // The previous capture's worker never returned (see the stop-timeout
            // watchdog). Captures run on one serial queue, so accepting this
            // start would return 201 for a session that never records.
            return self.error(
                "the previous capture is still finishing and no new recording can start; "
                    + "check GET /status and restart the agent if it stays wedged",
                .conflict)
        case AgentError.noActiveSession:
            return self.error("no active recording", .notFound)
        case AgentError.noMicrophone:
            return self.error("no microphone in this capture", .unprocessableContent)
        case let harkError as HarkError:
            return self.error(harkError.message, httpStatus(for: harkError.code))
        case let transcription as TranscriptionError:
            return self.error(transcription.description, .unprocessableContent)
        default:
            return self.error("\(error)", .internalServerError)
        }
    }

    /// Maps Hark's exit-code semantics to an HTTP status (PRD §6.10).
    static func httpStatus(for code: HarkExitCode) -> HTTPStatusCode {
        switch code {
        case .usage: return .badRequest
        case .noInput: return .notFound
        case .noPermission: return .forbidden
        case .unavailable: return .unprocessableContent
        // An output file already exists and the session's policy refused it.
        case .cantCreate: return .conflict
        default: return .internalServerError
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case let harkError as HarkError: return harkError.message
        case let transcription as TranscriptionError: return transcription.description
        default: return "\(error)"
        }
    }
}

// MARK: - Address parsing

/// A parsed `[host:]port` bind address for the agent. Loopback by default.
struct RemoteAddress {
    let host: String?  // nil = loopback
    let port: UInt16

    var isLoopback: Bool {
        switch host {
        case nil, "", "localhost", "127.0.0.1", "::1": return true
        default: return false
        }
    }

    var display: String { "\(host ?? "127.0.0.1"):\(port)" }

    /// Parses `[host:]port` (e.g. `8473`, `:8473`, `127.0.0.1:8473`, `0.0.0.0:8473`).
    static func parse(_ raw: String) throws -> RemoteAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw HarkError.usage("--remote-control needs a port (e.g. 8473 or 0.0.0.0:8473).")
        }
        let host: String?
        let portText: String
        if let colon = trimmed.lastIndex(of: ":") {
            let h = String(trimmed[..<colon])
            host = h.isEmpty ? nil : h
            portText = String(trimmed[trimmed.index(after: colon)...])
        } else {
            host = nil
            portText = trimmed
        }
        guard let port = UInt16(portText), port > 0 else {
            throw HarkError.usage("--remote-control port must be 1–65535 (got '\(portText)').")
        }
        return RemoteAddress(host: host, port: port)
    }

    /// The IPv4 socket address to bind. Loopback → 127.0.0.1; `0.0.0.0` → all
    /// interfaces; otherwise a specific IPv4 address. IPv6 is not supported.
    func socketAddress() throws -> sockaddr_in {
        if isLoopback {
            return try .inet(ip4: "127.0.0.1", port: port)
        }
        if host == "0.0.0.0" {
            return .inet(port: port)
        }
        do {
            return try .inet(ip4: host!, port: port)
        } catch {
            throw HarkError.usage("--remote-control host must be an IPv4 address (got '\(host!)').")
        }
    }
}

// MARK: - JSON response shapes (control + status only; no artifact content)

private struct ErrorResponse: Encodable {
    let error: String
}

private struct StartedResponse: Encodable {
    let id: String
    let state: String
    let muted: Bool
    let audio: String?
    let transcript: String?
    /// Whether the capture was already running when this answer was sent. False
    /// only when the wait ran out, never because the start failed: that is an
    /// error response instead.
    let capturing: Bool

    init(snapshot: RemoteSessionManager.Snapshot, capturing: Bool) {
        id = snapshot.id
        state = snapshot.state.rawValue
        muted = snapshot.muted
        audio = snapshot.audio
        transcript = snapshot.transcript
        self.capturing = capturing
    }
}

/// How a capture run ended, for the `/start` handler waiting on the way up.
/// Thread-safe: written on the capture queue, read on the server's.
private final class StartOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?

    func ended(with error: Error?) {
        lock.lock(); failure = error; lock.unlock()
    }

    var error: Error? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }
}

private struct ActionResponse: Encodable {
    let id: String
    let state: String
    let muted: Bool

    init(snapshot: RemoteSessionManager.Snapshot) {
        id = snapshot.id
        state = snapshot.state.rawValue
        muted = snapshot.muted
    }
}

/// The `GET /status` body. Internal, unlike its `private` siblings above, only
/// so a test can construct one and check the encoded shape: `@testable import`
/// does not lift `private`, so there is no other way to pin the wire format.
struct StatusResponse: Encodable {
    struct Agent: Encodable {
        let version: String
        let address: String
    }
    struct Session: Encodable {
        let id: String
        let state: String
        let muted: Bool
        let elapsed: Double
        let audio: String?
        let transcript: String?
        let error: String?
        /// The open transcript line, present only while a `--live-streaming`
        /// capture is recording. Optional, so with streaming off the key is
        /// absent and the payload is byte-identical to before.
        let partial: PartialLine?
        /// Whether the capture is open. `state` says `recording` from the moment a
        /// start is accepted, which is before the sources are started; this says
        /// whether what is said now will be recorded.
        let capturing: Bool
        let callAudio: CallAudio?
    }
    /// Whether the call's audio (the system tap) is still being heard.
    struct CallAudio: Encodable {
        let state: String
        let silentFor: Double
        let restarts: Int
    }
    let agent: Agent
    let session: Session?

    init(version: String, address: String, session: RemoteSessionManager.Snapshot?) {
        agent = Agent(version: version, address: address)
        self.session = session.map {
            Session(
                id: $0.id, state: $0.state.rawValue, muted: $0.muted,
                elapsed: Date().timeIntervalSince($0.startedAt),
                audio: $0.audio, transcript: $0.transcript, error: $0.error,
                partial: $0.partial, capturing: $0.capturing,
                callAudio: $0.callAudio.map {
                    CallAudio(
                        state: $0.state.rawValue,
                        silentFor: ($0.silentFor * 10).rounded() / 10,
                        restarts: $0.restarts)
                })
        }
    }
}
