import AppKit
import Darwin
import Foundation

// MARK: - Errors

enum AuthError: LocalizedError, Equatable {
    case socket
    case browser
    case invalidURL
    case timeout
    case cancelled
    case exchange

    var errorDescription: String? {
        switch self {
        case .socket:
            return "Could not start a local sign-in listener."
        case .browser:
            return "Could not open the browser."
        case .invalidURL:
            return "DeepSeek returned an invalid sign-in URL."
        case .timeout:
            return "Sign-in timed out. Try again."
        case .cancelled:
            return "Sign-in was cancelled."
        case .exchange:
            return "DeepSeek rejected the sign-in exchange."
        }
    }
}

struct AuthResult: Sendable {
    let token: String
    let user: AuthUser?
}

// MARK: - Loopback HTTP callback

/// A one-shot HTTP server bound to 127.0.0.1. It holds the browser request open until
/// the token exchange completes, then redirects the browser to DeepSeek's completion page.
final class OAuthCallbackServer: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "com.deepseekusage.tracker.oauth")
    private let acceptQueue = DispatchQueue(label: "com.deepseekusage.tracker.oauth.accept")
    private let lock = NSLock()

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var continuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var stopped = false

    private(set) var port: UInt16 = 0

    init(state: String) {
        self.state = state
    }

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AuthError.socket }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(fd)
            throw AuthError.socket
        }
        address.sin_port = 0

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw AuthError.socket
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        port = UInt16(bigEndian: address.sin_port)
        lock.lock()
        listenFD = fd
        lock.unlock()
        acceptQueue.async { [self] in self.acceptLoop() }
        return port
    }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        let code: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let pending = self.pendingResult {
                    self.pendingResult = nil
                    continuation.resume(with: pending)
                    return
                }
                self.continuation = continuation
                let work = DispatchWorkItem { [self] in
                    guard !self.isStopped else { return }
                    self.finish(.failure(AuthError.timeout))
                    self.stop()
                }
                self.timeoutWorkItem = work
                self.queue.asyncAfter(deadline: .now() + max(1, timeout), execute: work)
            }
        }
        return code
    }

    /// Sends a redirect to DeepSeek's completion page, or a neutral success page.
    func respond(redirectURL: URL?) {
        queue.async { [self] in
            self.timeoutWorkItem?.cancel()
            let fd = self.takeClientFD()
            guard fd >= 0 else {
                self.stop()
                return
            }
            if let redirectURL, DeepSeekAuth.isAllowedCompletionURL(redirectURL) {
                let response = "HTTP/1.1 302 Found\r\n"
                    + "Location: \(redirectURL.absoluteString)\r\n"
                    + "Cache-Control: no-store\r\n"
                    + "Content-Length: 0\r\n"
                    + "Connection: close\r\n\r\n"
                self.sendAll(fd, Data(response.utf8))
            } else {
                self.sendHTML(fd, Self.successHTML)
            }
            close(fd)
            self.closeListener()
            self.markStopped()
        }
    }

    func fail() {
        queue.async { [self] in
            self.timeoutWorkItem?.cancel()
            let fd = self.takeClientFD()
            if fd >= 0 {
                self.sendHTML(fd, Self.failureHTML)
                close(fd)
            }
            self.closeListener()
            self.markStopped()
        }
    }

    func stop() {
        let wasStopped: Bool
        lock.lock()
        wasStopped = stopped
        stopped = true
        let listener = listenFD
        let client = clientFD
        listenFD = -1
        clientFD = -1
        lock.unlock()

        timeoutWorkItem?.cancel()
        if listener >= 0 { close(listener) }
        if client >= 0 { close(client) }

        if !wasStopped {
            queue.async { [self] in
                self.finish(.failure(AuthError.cancelled))
            }
        }
    }

    // MARK: Socket loop

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped {
            lock.lock()
            let listener = listenFD
            lock.unlock()
            guard listener >= 0 else { break }

            var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 250)
            if ready <= 0 { continue }

            let client = accept(listener, nil, nil)
            guard client >= 0 else { break }

            let accepted = handle(client: client)
            if accepted { break }
        }
    }

    private func handle(client: Int32) -> Bool {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 16_384 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }

        guard let request = String(data: data, encoding: .utf8),
              let line = request.components(separatedBy: "\r\n").first
        else {
            close(client)
            return false
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])")
        else {
            sendHTML(client, Self.badRequestHTML)
            close(client)
            return false
        }

        guard components.path == "/oauth/callback" else {
            let response = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            sendAll(client, Data(response.utf8))
            close(client)
            return false
        }

        let query = components.queryItems ?? []
        let codes = query.filter { $0.name == "code" }.compactMap(\.value)
        let states = query.filter { $0.name == "state" }.compactMap(\.value)
        guard codes.count == 1, states.count == 1, states[0] == state, !codes[0].isEmpty else {
            sendHTML(client, Self.badRequestHTML)
            close(client)
            return false
        }

        lock.lock()
        clientFD = client
        lock.unlock()

        // We have the only callback we need; stop accepting, but keep this client
        // connected until the exchange finishes so the browser can be redirected.
        closeListener()
        queue.async { [self] in
            self.finish(.success(codes[0]))
        }
        return true
    }

    // MARK: State

    private func finish(_ result: Result<String, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else {
            pendingResult = result
        }
    }

    private func takeClientFD() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let fd = clientFD
        clientFD = -1
        return fd
    }

    private func closeListener() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    private func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    // MARK: HTTP helpers

    private func sendHTML(_ fd: Int32, _ html: String) {
        let body = Data(html.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Cache-Control: no-store\r\n"
        response += "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var data = Data(response.utf8)
        data.append(body)
        sendAll(fd, data)
    }

    private func sendAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let sent = send(fd, base.advanced(by: offset), data.count - offset, 0)
                guard sent > 0 else { break }
                offset += sent
            }
        }
    }

    // MARK: Pages

    private static let successHTML = """
    <!doctype html>
    <html><meta charset="utf-8"><title>Signed in</title>
    <style>
    body { font: 15px -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1115; color: #f5f5f7;
           display: grid; place-items: center; height: 100vh; margin: 0; }
    .card { text-align: center; padding: 32px 40px; border: 1px solid #2c2f36; border-radius: 16px; background: #171a21; }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { color: #a1a1aa; margin: 0; }
    </style>
    <div class="card"><h1>Signed in</h1><p>You can close this tab and return to DeepSeek Usage.</p></div>
    </html>
    """

    private static let failureHTML = """
    <!doctype html>
    <html><meta charset="utf-8"><title>Sign-in failed</title>
    <style>
    body { font: 15px -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1115; color: #f5f5f7;
           display: grid; place-items: center; height: 100vh; margin: 0; }
    .card { text-align: center; padding: 32px 40px; border: 1px solid #2c2f36; border-radius: 16px; background: #171a21; }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { color: #a1a1aa; margin: 0; }
    </style>
    <div class="card"><h1>Sign-in failed</h1><p>Return to the app and try again.</p></div>
    </html>
    """

    private static let badRequestHTML = """
    <!doctype html>
    <html><meta charset="utf-8"><title>Invalid sign-in callback</title>
    <style>
    body { font: 15px -apple-system, BlinkMacSystemFont, sans-serif; background: #0f1115; color: #f5f5f7;
           display: grid; place-items: center; height: 100vh; margin: 0; }
    .card { text-align: center; padding: 32px 40px; border: 1px solid #2c2f36; border-radius: 16px; background: #171a21; }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { color: #a1a1aa; margin: 0; }
    </style>
    <div class="card"><h1>Invalid callback</h1><p>Return to the app and start sign-in again.</p></div>
    </html>
    """
}

// MARK: - Orchestration

@MainActor
final class DeepSeekAuth {
    private let api: DeepSeekAPI
    private var activeServer: OAuthCallbackServer?

    init(api: DeepSeekAPI = .shared) {
        self.api = api
    }

    func signIn() async throws -> AuthResult {
        let verifier = PKCE.verifier()
        let challenge = PKCE.challenge(for: verifier)
        let state = PKCE.state()
        let server = OAuthCallbackServer(state: state)
        activeServer = server
        var handedOff = false
        defer {
            activeServer = nil
            // `respond`/`fail` own the browser connection and close it themselves.
            if !handedOff { server.stop() }
        }

        let port = try server.start()
        let redirectURI = "http://127.0.0.1:\(port)/oauth/callback"
        let initialization = try await api.authInit(
            challenge: challenge,
            state: state,
            redirectURI: redirectURI)

        guard let authorizeURL = URL(string: initialization.authorizeUrl),
              Self.isAllowedAuthorizeURL(authorizeURL)
        else {
            throw AuthError.invalidURL
        }
        guard NSWorkspace.shared.open(authorizeURL) else {
            throw AuthError.browser
        }

        let code: String
        do {
            code = try await server.waitForCode(timeout: TimeInterval(initialization.expiresIn))
        } catch {
            await api.authCancel(authorizeID: initialization.authorizeId, verifier: verifier)
            throw error
        }

        try Task.checkCancellation()
        let device = DeepSeekAPI.deviceInfo()
        let exchange: AuthExchangeResponse
        do {
            exchange = try await api.authExchange(
                code: code,
                verifier: verifier,
                redirectURI: redirectURI,
                deviceID: device.id,
                deviceModel: device.model,
                osVersion: device.osVersion)
        } catch {
            handedOff = true
            server.fail()
            await api.authCancel(authorizeID: initialization.authorizeId, verifier: verifier)
            throw error
        }

        handedOff = true
        let completionURL = URL(string: exchange.authorizedUrl)
        server.respond(redirectURL: completionURL)
        return AuthResult(token: exchange.token, user: exchange.user)
    }

    func cancel() {
        activeServer?.stop()
    }

    nonisolated static func isAllowedAuthorizeURL(_ url: URL) -> Bool {
        isPlatformURL(url, path: "/dsh/authorize")
    }

    nonisolated static func isAllowedCompletionURL(_ url: URL) -> Bool {
        isPlatformURL(url, path: "/dsh/authorized")
    }

    nonisolated private static func isPlatformURL(_ url: URL, path: String) -> Bool {
        guard url.scheme == "https",
              url.host == "platform.deepseek.com",
              url.path == path,
              url.user == nil,
              url.password == nil,
              url.fragment == nil
        else {
            return false
        }
        if let port = url.port, port != 443 { return false }
        return true
    }
}
