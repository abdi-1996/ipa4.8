import Foundation
import Darwin
import Network

private struct RawHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

private enum RawHTTPClientError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Некорректный сетевой запрос."
        case .invalidResponse: return "Компьютер вернул некорректный HTTP-ответ."
        case .timedOut: return "Компьютер не ответил вовремя."
        }
    }
}

/// Minimal HTTP/1.1 client built on Network.framework.
/// Apple documents that App Transport Security doesn't apply to lower-level
/// networking interfaces such as Network.framework, so this transport works
/// for the private HTTP endpoint inside LAN/Tailscale without relying solely
/// on Info.plist ATS exceptions.
private enum RawHTTPClient {
    static func send(_ request: URLRequest) async throws -> RawHTTPResponse {
        guard let url = request.url,
              let host = url.host,
              let portNumber = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80),
              (1...65535).contains(portNumber),
              let port = NWEndpoint.Port(rawValue: UInt16(portNumber)) else {
            throw RawHTTPClientError.invalidRequest
        }

        let timeout = max(1.0, request.timeoutInterval)
        let payload = try serializedRequest(request, host: host, port: portNumber)

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "PCRemote.RawHTTP.\(UUID().uuidString)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
            let lock = NSLock()
            var finished = false
            var buffer = Data()
            var didSend = false

            func finish(_ result: Result<RawHTTPResponse, Error>) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(with: result)
            }

            func receiveNext() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { content, _, isComplete, error in
                    if let content, !content.isEmpty {
                        buffer.append(content)
                        do {
                            if let ready = try completeResponseIfAvailable(buffer) {
                                finish(.success(ready))
                                return
                            }
                        } catch {
                            finish(.failure(error))
                            return
                        }
                    }
                    if let error {
                        finish(.failure(error))
                        return
                    }
                    if isComplete {
                        do {
                            finish(.success(try parseResponse(buffer)))
                        } catch {
                            finish(.failure(error))
                        }
                        return
                    }
                    receiveNext()
                }
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard !didSend else { return }
                    didSend = true
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            finish(.failure(error))
                            return
                        }
                        receiveNext()
                    })
                case .failed(let error):
                    finish(.failure(error))
                case .cancelled:
                    break
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                finish(.failure(RawHTTPClientError.timedOut))
            }
            connection.start(queue: queue)
        }
    }

    private static func serializedRequest(_ request: URLRequest, host: String, port: Int) throws -> Data {
        guard let url = request.url else { throw RawHTTPClientError.invalidRequest }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? url.path
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            target += "?\(query)"
        }

        let method = (request.httpMethod ?? "GET").uppercased()
        let body = request.httpBody ?? Data()
        var headers = request.allHTTPHeaderFields ?? [:]

        func hasHeader(_ name: String) -> Bool {
            headers.keys.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        if !hasHeader("Host") {
            headers["Host"] = "\(host):\(port)"
        }
        headers["Connection"] = "close"
        headers["Accept-Encoding"] = "identity"
        if !body.isEmpty || ["POST", "PUT", "PATCH"].contains(method) {
            headers["Content-Length"] = String(body.count)
        }
        if !hasHeader("User-Agent") {
            headers["User-Agent"] = "PCRemote-iOS/4.8.0"
        }

        var head = "\(method) \(target) HTTP/1.1\r\n"
        for key in headers.keys.sorted() {
            if let value = headers[key] {
                head += "\(key): \(value)\r\n"
            }
        }
        head += "\r\n"

        guard var result = head.data(using: .utf8) else {
            throw RawHTTPClientError.invalidRequest
        }
        result.append(body)
        return result
    }

    private static func completeResponseIfAvailable(_ data: Data) throws -> RawHTTPResponse? {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw RawHTTPClientError.invalidResponse
        }
        var headers: [String: String] = [:]
        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = line.index(after: colon)
            headers[key] = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let bodyCount = data.distance(from: range.upperBound, to: data.endIndex)
        if let lengthText = headers["content-length"], let length = Int(lengthText), bodyCount >= length {
            return try parseResponse(data)
        }
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            let body = data.subdata(in: range.upperBound..<data.endIndex)
            if body.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil || body.starts(with: Data("0\r\n\r\n".utf8)) {
                return try parseResponse(data)
            }
        }
        return nil
    }

    private static func parseResponse(_ data: Data) throws -> RawHTTPResponse {
        let separator = Data([13, 10, 13, 10])
        guard let range = data.range(of: separator) else {
            throw RawHTTPClientError.invalidResponse
        }

        let headerData = data.subdata(in: data.startIndex..<range.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw RawHTTPClientError.invalidResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw RawHTTPClientError.invalidResponse }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else {
            throw RawHTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let valueStart = line.index(after: colon)
            let value = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let bodyStart = range.upperBound
        let rawBody = bodyStart <= data.endIndex ? data.subdata(in: bodyStart..<data.endIndex) : Data()
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            body = try decodeChunked(rawBody)
        } else if let lengthText = headers["content-length"], let length = Int(lengthText), length >= 0 {
            guard rawBody.count >= length else { throw RawHTTPClientError.invalidResponse }
            body = rawBody.prefix(length)
        } else {
            body = rawBody
        }

        return RawHTTPResponse(statusCode: statusCode, headers: headers, body: Data(body))
    }

    private static func decodeChunked(_ data: Data) throws -> Data {
        let crlf = Data([13, 10])
        var index = data.startIndex
        var output = Data()

        while index < data.endIndex {
            guard let lineRange = data.range(of: crlf, options: [], in: index..<data.endIndex),
                  let line = String(data: data.subdata(in: index..<lineRange.lowerBound), encoding: .utf8) else {
                throw RawHTTPClientError.invalidResponse
            }
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw RawHTTPClientError.invalidResponse
            }
            index = lineRange.upperBound
            if size == 0 { return output }
            guard data.distance(from: index, to: data.endIndex) >= size else {
                throw RawHTTPClientError.invalidResponse
            }
            let chunkEnd = data.index(index, offsetBy: size)
            output.append(data.subdata(in: index..<chunkEnd))
            index = chunkEnd
            guard data.distance(from: index, to: data.endIndex) >= 2 else {
                throw RawHTTPClientError.invalidResponse
            }
            let trailerEnd = data.index(index, offsetBy: 2)
            guard data.subdata(in: index..<trailerEnd) == crlf else {
                throw RawHTTPClientError.invalidResponse
            }
            index = trailerEnd
        }
        return output
    }
}

enum APIError: LocalizedError {
    case badURL
    case badResponse
    case badConnectionID
    case server(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Не удалось создать адрес подключения."
        case .badResponse: return "Некорректный ответ от компьютера."
        case .badConnectionID: return "Неверный ID устройства."
        case .server(let message): return message
        }
    }
}

private struct ConnectionIDPayload: Codable {
    let h: String
    let p: Int
    let t: String
    let m: String?
    let b: String?
    let th: String?
    let td: String?
    let zh: String?
}

enum ConnectionIDCodec {
    static func device(from rawValue: String) throws -> SavedDevice {
        let cleaned = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")

        guard cleaned.hasPrefix("PCR1-") else { throw APIError.badConnectionID }
        let encoded = String(cleaned.dropFirst(5))
        guard !encoded.isEmpty else { throw APIError.badConnectionID }

        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(ConnectionIDPayload.self, from: data),
              !payload.h.isEmpty,
              !payload.t.isEmpty,
              (1...65535).contains(payload.p) else {
            throw APIError.badConnectionID
        }

        return SavedDevice(
            name: "ПК",
            host: payload.h,
            port: payload.p,
            password: payload.t,
            connectionID: cleaned,
            macAddress: payload.m,
            broadcastAddress: payload.b,
            tailscaleHost: payload.th,
            tailscaleDNS: payload.td,
            zerotierHost: payload.zh
        )
    }
}

final class APIClient {
    let device: SavedDevice

    init(device: SavedDevice) {
        self.device = device
    }

    struct ConnectivityProbe: Decodable {
        let ok: Bool
        let computer: String
        let port: Int
        let transport: String
        let server_version: String?
        let password_set: Bool?

        var serverVersion: String { server_version ?? "?" }
        var passwordSet: Bool { password_set ?? false }
    }

    static func probeConnection(
        lanHost: String,
        tailscaleHost: String,
        zerotierHost: String,
        port: Int,
        routeMode: ConnectionRouteMode
    ) async throws -> (String, ConnectivityProbe) {
        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return trimmed.isEmpty ? nil : trimmed
        }

        let lan = clean(lanHost)
        let tail = clean(tailscaleHost)
        let zero = clean(zerotierHost)
        let ordered: [String?]
        switch routeMode {
        case .lan: ordered = [lan]
        case .zerotier: ordered = [zero]
        case .tailscale: ordered = [tail]
        case .automatic: ordered = [lan, zero, tail]
        }

        var hosts: [String] = []
        var seen = Set<String>()
        for candidate in ordered.compactMap({ $0 }) {
            let key = candidate.lowercased()
            if seen.insert(key).inserted { hosts.append(candidate) }
        }
        guard !hosts.isEmpty, (1...65535).contains(port) else {
            throw APIError.server("Укажите адрес компьютера для выбранного маршрута.")
        }

        var lastError: Error?
        for (index, host) in hosts.enumerated() {
            guard let url = URL(string: "http://\(host):\(port)/api/ping") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: index < hosts.count - 1 ? 2.5 : 7.0)
            req.httpMethod = "GET"
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            do {
                let response = try await RawHTTPClient.send(req)
                guard (200..<300).contains(response.statusCode) else {
                    throw APIError.server("Сервер ответил HTTP \(response.statusCode).")
                }
                let probe = try JSONDecoder().decode(ConnectivityProbe.self, from: response.body)
                guard probe.ok else { throw APIError.badResponse }
                return (host, probe)
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw APIError.server("Компьютер недоступен по выбранному маршруту.")
    }

    static func loginWithPassword(
        password: String,
        lanHost: String,
        tailscaleHost: String,
        zerotierHost: String,
        port: Int,
        routeMode: ConnectionRouteMode
    ) async throws -> (SavedDevice, StatusResponse) {
        func clean(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return trimmed.isEmpty ? nil : trimmed
        }

        let lan = clean(lanHost)
        let tail = clean(tailscaleHost)
        let zero = clean(zerotierHost)
        let ordered: [String?]
        switch routeMode {
        case .tailscale:
            ordered = [tail]
        case .zerotier:
            ordered = [zero]
        case .lan:
            ordered = [lan]
        case .automatic:
            ordered = [lan, zero, tail]
        }

        var hosts: [String] = []
        var seen = Set<String>()
        for candidate in ordered.compactMap({ $0 }) {
            if !seen.contains(candidate.lowercased()) {
                hosts.append(candidate)
                seen.insert(candidate.lowercased())
            }
        }
        guard !hosts.isEmpty, (1...65535).contains(port) else {
            throw APIError.server("Укажите адрес компьютера для выбранного маршрута.")
        }

        let body = try JSONSerialization.data(withJSONObject: ["password": password])
        var lastError: Error?
        for (index, host) in hosts.enumerated() {
            guard let url = URL(string: "http://\(host):\(port)/api/auth/login") else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: index < hosts.count - 1 ? 3.0 : 12.0)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            do {
                let response = try await RawHTTPClient.send(req)
                let data = response.body
                let decoded = try? JSONDecoder().decode(AuthLoginResponse.self, from: data)
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode == 401 { throw APIError.server(decoded?.error ?? "Неверный пароль.") }
                    if response.statusCode == 409 { throw APIError.server(decoded?.error ?? "Сначала задайте пароль на PC Remote Server.") }
                    throw APIError.server(decoded?.error ?? "Ошибка сервера: HTTP \(response.statusCode)")
                }
                guard let result = decoded, result.ok, let token = result.token, let status = result.status else {
                    throw APIError.badResponse
                }
                let device = SavedDevice(
                    name: status.computer,
                    host: lan ?? status.ip,
                    port: status.port,
                    password: token,
                    connectionID: nil,
                    macAddress: status.mac,
                    broadcastAddress: status.broadcast,
                    tailscaleHost: status.tailscaleIP ?? tail,
                    tailscaleDNS: status.tailscaleDNS,
                    zerotierHost: status.zerotierIP ?? zero
                )
                return (device, status)
            } catch let error as APIError {
                if case .server = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        if let lastError { throw lastError }
        throw APIError.badResponse
    }

    private var routeMode: ConnectionRouteMode {
        let raw = UserDefaults.standard.string(forKey: "connection_route_mode") ?? ConnectionRouteMode.automatic.rawValue
        return ConnectionRouteMode(rawValue: raw) ?? .automatic
    }

    private var candidateHosts: [String] {
        func clean(_ value: String?) -> String? {
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return trimmed.isEmpty ? nil : trimmed
        }

        let lan = clean(device.host)
        let tailIP = clean(device.tailscaleHost)
        let tailDNS = clean(device.tailscaleDNS)
        let zero = clean(device.zerotierHost)
        let ordered: [String?]
        switch routeMode {
        case .tailscale:
            ordered = [tailIP, tailDNS]
        case .zerotier:
            ordered = [zero]
        case .lan:
            ordered = [lan]
        case .automatic:
            // Prefer home LAN, then ZeroTier, then Tailscale for remote fallback.
            ordered = [lan, zero, tailIP, tailDNS]
        }

        var seen = Set<String>()
        return ordered.compactMap { value in
            guard let value, !seen.contains(value.lowercased()) else { return nil }
            seen.insert(value.lowercased())
            return value
        }
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        let host = candidateHosts.first ?? device.host
        guard !host.isEmpty,
              let base = URL(string: "http://\(host):\(device.port)"),
              let url = URL(string: path, relativeTo: base) else {
            throw APIError.badURL
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue("Bearer \(device.password)", forHTTPHeaderField: "Authorization")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func requestsForFallback(from req: URLRequest) -> [URLRequest] {
        guard let originalURL = req.url else { return [req] }
        var result: [URLRequest] = []
        let hosts = candidateHosts.isEmpty ? [device.host] : candidateHosts
        for (index, host) in hosts.enumerated() {
            guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else { continue }
            components.host = host
            components.port = device.port
            guard let url = components.url else { continue }
            var copy = req
            copy.url = url
            if routeMode == .automatic && hosts.count > 1 && index < hosts.count - 1 {
                copy.timeoutInterval = min(req.timeoutInterval, 3.0)
            }
            result.append(copy)
        }
        return result.isEmpty ? [req] : result
    }

    private func checkedData(for req: URLRequest, allowNotFound: Bool = false) async throws -> Data? {
        var lastNetworkError: Error?
        for candidate in requestsForFallback(from: req) {
            do {
                let response = try await RawHTTPClient.send(candidate)
                let data = response.body
                if allowNotFound && response.statusCode == 404 { return nil }
                guard (200..<300).contains(response.statusCode) else {
                    if response.statusCode == 401 { throw APIError.server("Сессия больше не подходит к этому серверу. Войдите снова.") }
                    if response.statusCode == 404 { throw APIError.server("Объект не найден.") }
                    if response.statusCode == 403 { throw APIError.server("Нет доступа.") }
                    if response.statusCode == 413 { throw APIError.server("Слишком большой запрос.") }
                    throw APIError.server("Ошибка сервера: HTTP \(response.statusCode)")
                }
                return data
            } catch let error as APIError {
                throw error
            } catch {
                lastNetworkError = error
            }
        }
        if let lastNetworkError { throw lastNetworkError }
        throw APIError.badResponse
    }

    private func decode<T: Decodable>(_ type: T.Type, from req: URLRequest) async throws -> T {
        guard let data = try await checkedData(for: req) else { throw APIError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func action(path: String, object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let response = try await decode(ActionResponse.self, from: request(path: path, method: "POST", body: data))
        if !response.ok {
            throw APIError.server(response.error ?? "Команда не выполнена.")
        }
    }

    func status() async throws -> StatusResponse {
        try await decode(StatusResponse.self, from: request(path: "/api/status"))
    }

    func desktopApps() async throws -> [RemoteApp] {
        try await decode([RemoteApp].self, from: request(path: "/api/apps/desktop"))
    }

    func allApps() async throws -> [RemoteApp] {
        try await decode([RemoteApp].self, from: request(path: "/api/apps/all"))
    }

    func recentApps() async throws -> [RemoteApp] {
        try await decode([RemoteApp].self, from: request(path: "/api/apps/recent"))
    }

    func apps() async throws -> [RemoteApp] {
        try await allApps()
    }

    func appIconData(app: RemoteApp) async throws -> Data? {
        var components = URLComponents()
        components.path = "/api/apps/icon"
        components.queryItems = [URLQueryItem(name: "id", value: app.id)]
        return try await checkedData(for: request(path: components.string ?? "/api/apps/icon"), allowNotFound: true)
    }

    func launch(app: RemoteApp) async throws {
        try await action(path: "/api/apps/launch", object: ["id": app.id])
    }

    func roots() async throws -> [FileItem] {
        try await decode([FileItem].self, from: request(path: "/api/fs/roots"))
    }

    func list(path: String) async throws -> [FileItem] {
        var components = URLComponents()
        components.path = "/api/fs/list"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try await decode([FileItem].self, from: request(path: components.string ?? "/api/fs/list"))
    }

    func downloadFile(item: FileItem) async throws -> URL {
        var components = URLComponents()
        components.path = "/api/fs/download"
        components.queryItems = [URLQueryItem(name: "path", value: item.path)]
        let req = try request(path: components.string ?? "/api/fs/download")

        var downloaded: RawHTTPResponse?
        var lastNetworkError: Error?
        for candidate in requestsForFallback(from: req) {
            do {
                downloaded = try await RawHTTPClient.send(candidate)
                break
            } catch {
                lastNetworkError = error
            }
        }
        guard let response = downloaded else {
            if let lastNetworkError { throw lastNetworkError }
            throw APIError.badResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw APIError.server("Сессия больше не подходит к этому серверу. Войдите снова.") }
            if response.statusCode == 404 { throw APIError.server("Файл не найден.") }
            if response.statusCode == 403 { throw APIError.server("Нет доступа к файлу.") }
            throw APIError.server("Ошибка сервера: HTTP \(response.statusCode)")
        }

        let fm = FileManager.default
        let temporaryURL = fm.temporaryDirectory.appendingPathComponent("PCRemoteDownload-\(UUID().uuidString)")
        try response.body.write(to: temporaryURL, options: .atomic)
        let previewRoot = fm.temporaryDirectory.appendingPathComponent("PCRemotePreview", isDirectory: true)
        try? fm.createDirectory(at: previewRoot, withIntermediateDirectories: true)
        let folder = previewRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(item.name.isEmpty ? "file" : item.name, isDirectory: false)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func uploadFile(localURL: URL, toFolder folderPath: String) async throws -> FileItem {
        let filename = localURL.lastPathComponent.isEmpty ? "upload.bin" : localURL.lastPathComponent
        let fileData = try Data(contentsOf: localURL, options: .mappedIfSafe)
        let boundary = "PCRemote-\(UUID().uuidString)"
        var body = Data()

        func append(_ string: String) {
            if let data = string.data(using: .utf8) { body.append(data) }
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"path\"\r\n\r\n")
        append(folderPath)
        append("\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename.replacingOccurrences(of: "\"", with: "_"))\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var req = try request(path: "/api/fs/upload", method: "POST")
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let data = try await checkedData(for: req) else { throw APIError.badResponse }
        let response = try JSONDecoder().decode(FileUploadResponse.self, from: data)
        guard response.ok, let item = response.item else {
            throw APIError.server(response.error ?? "Не удалось загрузить файл на ПК.")
        }
        return item
    }

    func openOnPC(path: String) async throws {
        try await action(path: "/api/fs/open", object: ["path": path])
    }

    func powerAction(_ actionName: String) async throws {
        try await action(path: "/api/power/action", object: ["action": actionName])
    }

    // MARK: - Remote screen

    func remoteInfo() async throws -> RemoteScreenInfo {
        try await decode(RemoteScreenInfo.self, from: request(path: "/api/remote/info"))
    }

    func remoteFrame(mode: RemoteQualityMode) async throws -> Data {
        var components = URLComponents()
        components.path = "/api/remote/frame"
        components.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        var req = try request(path: components.string ?? "/api/remote/frame")
        req.timeoutInterval = 6
        guard let data = try await checkedData(for: req) else { throw APIError.badResponse }
        return data
    }

    func remoteFocusInfo() async throws -> RemoteFocusInfo {
        try await decode(RemoteFocusInfo.self, from: request(path: "/api/remote/focus"))
    }

    func remoteTouch(kind: String, x1: Double, y1: Double, x2: Double? = nil, y2: Double? = nil, duration: Double = 0.22) async throws {
        var object: [String: Any] = [
            "kind": kind, "x1": x1, "y1": y1, "duration": duration
        ]
        if let x2 { object["x2"] = x2 }
        if let y2 { object["y2"] = y2 }
        try await action(path: "/api/remote/input/touch", object: object)
    }

    func remoteTap(x: Double, y: Double, rightClick: Bool = false) async throws {
        try await action(
            path: "/api/remote/input/tap",
            object: ["x": x, "y": y, "button": rightClick ? "right" : "left", "clicks": 1]
        )
    }

    func remoteScroll(dx: Int, dy: Int) async throws {
        try await action(path: "/api/remote/input/scroll", object: ["dx": dx, "dy": dy])
    }

    func remoteText(_ text: String) async throws {
        try await action(path: "/api/remote/input/text", object: ["text": text])
    }

    func remoteKey(_ key: String) async throws {
        try await action(path: "/api/remote/input/key", object: ["key": key])
    }

    func remoteHotkey(_ keys: [String]) async throws {
        try await action(path: "/api/remote/input/hotkey", object: ["keys": keys])
    }

    // MARK: - ComfyUI

    func comfyDashboard(workflowID: String? = nil) async throws -> ComfyDashboardResponse {
        var components = URLComponents()
        components.path = "/api/comfy/dashboard"
        if let workflowID, !workflowID.isEmpty {
            components.queryItems = [URLQueryItem(name: "workflow_id", value: workflowID)]
        }
        return try await decode(ComfyDashboardResponse.self, from: request(path: components.string ?? "/api/comfy/dashboard"))
    }

    func comfyGenerate(workflowID: String, parameters: ComfyParameters) async throws -> ComfyGenerateResponse {
        let payload = ComfyGenerateRequest(workflow_id: workflowID, parameters: parameters)
        let data = try JSONEncoder().encode(payload)
        let response = try await decode(ComfyGenerateResponse.self, from: request(path: "/api/comfy/generate", method: "POST", body: data))
        if !response.ok {
            throw APIError.server(response.error ?? "ComfyUI не принял workflow.")
        }
        return response
    }

    func comfyInterrupt() async throws {
        try await action(path: "/api/comfy/interrupt", object: [:])
    }

    func comfyClearQueue() async throws {
        try await action(path: "/api/comfy/queue/clear", object: [:])
    }

    func comfyImageData(_ image: ComfyImageItem) async throws -> Data {
        var components = URLComponents()
        components.path = "/api/comfy/image"
        components.queryItems = [
            URLQueryItem(name: "filename", value: image.filename),
            URLQueryItem(name: "subfolder", value: image.subfolder),
            URLQueryItem(name: "type", value: image.type),
        ]
        guard let data = try await checkedData(for: request(path: components.string ?? "/api/comfy/image")) else {
            throw APIError.badResponse
        }
        return data
    }

    func comfyOpenFullUIOnPC() async throws {
        try await action(path: "/api/comfy/open/ui", object: [:])
    }

    func comfyOpenImageOnPC(_ image: ComfyImageItem) async throws {
        try await action(path: "/api/comfy/image/open", object: [
            "filename": image.filename,
            "subfolder": image.subfolder,
            "type": image.type,
        ])
    }


    func comfyWorkflowDetails(workflowID: String) async throws -> ComfyWorkflowDetailsResponse {
        var components = URLComponents()
        components.path = "/api/comfy/workflow/details"
        components.queryItems = [URLQueryItem(name: "workflow_id", value: workflowID)]
        return try await decode(ComfyWorkflowDetailsResponse.self, from: request(path: components.string ?? "/api/comfy/workflow/details"))
    }

    func comfyUpdateNode(workflowID: String, node: ComfyNodeInfo) async throws {
        let inputMap = Dictionary(uniqueKeysWithValues: node.inputs.filter { !$0.isConnection }.map { ($0.name, $0.value) })
        try await action(path: "/api/comfy/workflow/node/update", object: [
            "workflow_id": workflowID,
            "node_id": node.id,
            "title": node.title,
            "color": node.color,
            "placement": node.placement,
            "width_mode": node.widthMode,
            "muted": node.muted,
            "position_x": node.position_x ?? node.positionX,
            "position_y": node.position_y ?? node.positionY,
            "node_width": node.node_width ?? node.nodeWidth,
            "node_height": node.node_height ?? node.nodeHeight,
            "inputs": inputMap,
        ])
    }

    func comfyNodeCatalog(query: String = "") async throws -> ComfyNodeCatalogResponse {
        var components = URLComponents()
        components.path = "/api/comfy/nodes/catalog"
        if !query.isEmpty { components.queryItems = [URLQueryItem(name: "q", value: query)] }
        return try await decode(ComfyNodeCatalogResponse.self, from: request(path: components.string ?? "/api/comfy/nodes/catalog"))
    }

    func comfyAddNode(workflowID: String, classType: String, x: Double, y: Double) async throws -> ComfyNodeInfo {
        let body = try JSONSerialization.data(withJSONObject: [
            "workflow_id": workflowID,
            "class_type": classType,
            "position_x": x,
            "position_y": y,
        ])
        struct Response: Codable { let ok: Bool; let node: ComfyNodeInfo?; let error: String? }
        let response = try await decode(Response.self, from: request(path: "/api/comfy/workflow/node/add", method: "POST", body: body))
        guard response.ok, let node = response.node else { throw APIError.server(response.error ?? "Не удалось добавить ноду.") }
        return node
    }

    func comfyDeleteNode(workflowID: String, nodeID: String) async throws {
        try await action(path: "/api/comfy/workflow/node/delete", object: ["workflow_id": workflowID, "node_id": nodeID])
    }

    func comfyConnectNodes(workflowID: String, fromNode: String, fromSlot: Int, toNode: String, toInput: String, toSlot: Int) async throws {
        try await action(path: "/api/comfy/workflow/connect", object: [
            "workflow_id": workflowID,
            "from_node": fromNode,
            "from_slot": fromSlot,
            "to_node": toNode,
            "to_input": toInput,
            "to_slot": toSlot,
        ])
    }

    func comfyDisconnectNodes(workflowID: String, toNode: String, toInput: String) async throws {
        try await action(path: "/api/comfy/workflow/disconnect", object: [
            "workflow_id": workflowID,
            "to_node": toNode,
            "to_input": toInput,
        ])
    }

    func comfySaveNodeOrder(workflowID: String, order: [String]) async throws {
        try await action(path: "/api/comfy/workflow/order", object: [
            "workflow_id": workflowID,
            "order": order,
        ])
    }

    func comfyImportWorkflowFromPC(path pcPath: String) async throws -> ComfyImportResponse {
        let body = try JSONSerialization.data(withJSONObject: ["path": pcPath])
        let response = try await decode(ComfyImportResponse.self, from: request(path: "/api/comfy/workflows/import", method: "POST", body: body))
        if !response.ok { throw APIError.server(response.error ?? "Не удалось импортировать workflow.") }
        return response
    }

    func comfyImportWorkflowFromIPhone(filename: String, data: Data) async throws -> ComfyImportResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "filename": filename,
            "content_base64": data.base64EncodedString(),
        ])
        let response = try await decode(ComfyImportResponse.self, from: request(path: "/api/comfy/workflows/import", method: "POST", body: body))
        if !response.ok { throw APIError.server(response.error ?? "Не удалось импортировать workflow.") }
        return response
    }


    // MARK: - CorelDRAW

    func corelStatus() async throws -> CorelStatusResponse {
        let response = try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/status"))
        if !response.ok, let error = response.error { throw APIError.server(error) }
        return response
    }

    func corelLaunch() async throws {
        try await action(path: "/api/corel/launch", object: [:])
    }

    func corelPreviewData() async throws -> Data {
        let path = "/api/corel/preview?t=\(Int(Date().timeIntervalSince1970 * 1000))"
        guard let data = try await checkedData(for: request(path: path)) else { throw APIError.badResponse }
        return data
    }

    func corelObjects() async throws -> [CorelShapeInfo] {
        try await decode([CorelShapeInfo].self, from: request(path: "/api/corel/objects"))
    }

    func corelNewDocument() async throws -> CorelStatusResponse {
        try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/new", method: "POST", body: Data("{}".utf8)))
    }

    func corelOpen(path pcPath: String) async throws -> CorelStatusResponse {
        let body = try JSONSerialization.data(withJSONObject: ["path": pcPath])
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/open", method: "POST", body: body))
    }

    func corelAction(_ name: String) async throws -> CorelStatusResponse {
        let body = try JSONSerialization.data(withJSONObject: ["action": name])
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/action", method: "POST", body: body))
    }

    func corelSelect(index: Int) async throws -> CorelStatusResponse {
        let body = try JSONSerialization.data(withJSONObject: ["index": index])
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/select", method: "POST", body: body))
    }

    func corelTransform(
        x: Double? = nil,
        y: Double? = nil,
        width: Double? = nil,
        height: Double? = nil,
        rotation: Double? = nil,
        keepRatio: Bool = true
    ) async throws -> CorelStatusResponse {
        var object: [String: Any] = ["keep_ratio": keepRatio]
        if let x { object["x"] = x }
        if let y { object["y"] = y }
        if let width { object["width"] = width }
        if let height { object["height"] = height }
        if let rotation { object["rotation"] = rotation }
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/transform", method: "POST", body: body))
    }

    func corelStyle(fill: String? = nil, outline: String? = nil, outlineWidth: Double? = nil) async throws -> CorelStatusResponse {
        var object: [String: Any] = [:]
        if let fill { object["fill"] = fill }
        if let outline { object["outline"] = outline }
        if let outlineWidth { object["outline_width"] = outlineWidth }
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/style", method: "POST", body: body))
    }

    func corelCreate(kind: String, text: String = "Текст") async throws -> CorelStatusResponse {
        let body = try JSONSerialization.data(withJSONObject: ["kind": kind, "text": text])
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/create", method: "POST", body: body))
    }

    func corelPage(action: String, index: Int? = nil) async throws -> CorelStatusResponse {
        var object: [String: Any] = ["action": action]
        if let index { object["index"] = index }
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await decode(CorelStatusResponse.self, from: request(path: "/api/corel/page", method: "POST", body: body))
    }
}


// MARK: - Wake-on-LAN

enum WakeOnLANError: LocalizedError {
    case missingData
    case invalidMAC
    case socketError

    var errorDescription: String? {
        switch self {
        case .missingData: return "В ID этого устройства нет данных Wake-on-LAN. Переподключите ПК новой версией сервера."
        case .invalidMAC: return "Некорректный MAC-адрес для Wake-on-LAN."
        case .socketError: return "Не удалось отправить Wake-on-LAN пакет."
        }
    }
}

enum WakeOnLAN {
    static func send(device: SavedDevice, port: UInt16 = 9) throws {
        guard let mac = device.macAddress, let broadcast = device.broadcastAddress else {
            throw WakeOnLANError.missingData
        }
        try send(mac: mac, broadcast: broadcast, port: port)
    }

    static func send(mac: String, broadcast: String, port: UInt16 = 9) throws {
        let cleaned = mac
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
        guard cleaned.count == 12 else { throw WakeOnLANError.invalidMAC }

        var macBytes: [UInt8] = []
        var index = cleaned.startIndex
        for _ in 0..<6 {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { throw WakeOnLANError.invalidMAC }
            macBytes.append(byte)
            index = next
        }
        let packet = Array(repeating: UInt8(0xFF), count: 6) + Array(repeating: macBytes, count: 16).flatMap { $0 }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw WakeOnLANError.socketError }
        defer { close(fd) }

        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw WakeOnLANError.socketError
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        let converted = broadcast.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        guard converted == 1 else { throw WakeOnLANError.socketError }

        let result: Int = packet.withUnsafeBytes { rawBuffer in
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    sendto(fd, rawBuffer.baseAddress, packet.count, 0, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard result == packet.count else { throw WakeOnLANError.socketError }
    }
}
