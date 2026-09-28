import SwiftUI
import SwiftData
import Security

// Account + Firebase sync support for Colorize Finance 3.2.0.
// Configuration is restored from the previous Colorize Finance install when possible.
// If it is missing, the app tries to read the public Firebase web configuration
// from the Colorize Finance hosting page; a manual setup screen is the fallback.

struct BackendConfiguration: Codable, Equatable {
    var projectID: String
    var apiKey: String

    var project: String { projectID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var key: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !project.isEmpty && !key.isEmpty }
}

enum BackendConfigurationStore {
    private static let storageKey = "colorize.finance.firebase.configuration"

    static func stored() -> BackendConfiguration? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(BackendConfiguration.self, from: data),
              value.isValid else { return nil }
        return value
    }

    static func save(_ value: BackendConfiguration) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func resolveFromHosting() async -> BackendConfiguration? {
        if let cached = stored() { return cached }
        guard let url = URL(string: "https://colorize-17e61.web.app/") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            func capture(_ patterns: [String]) -> String? {
                for pattern in patterns {
                    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
                    let range = NSRange(html.startIndex..<html.endIndex, in: html)
                    if let match = regex.firstMatch(in: html, range: range),
                       match.numberOfRanges > 1,
                       let valueRange = Range(match.range(at: 1), in: html) {
                        return String(html[valueRange])
                    }
                }
                return nil
            }

            let key = capture([
                #"apiKey\s*[:=]\s*["']([^"']+)["']"#,
                #"api_key\s*[:=]\s*["']([^"']+)["']"#
            ])
            let project = capture([
                #"projectId\s*[:=]\s*["']([^"']+)["']"#,
                #"projectID\s*[:=]\s*["']([^"']+)["']"#
            ]) ?? "colorize-17e61"

            guard let key, !key.isEmpty else { return nil }
            let config = BackendConfiguration(projectID: project, apiKey: key)
            save(config)
            return config
        } catch {
            return nil
        }
    }
}

struct AuthSession: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let userID: String
    let email: String
    var needsRefresh: Bool { expiresAt.timeIntervalSinceNow < 120 }
}

struct KeychainStore {
    let service: String

    func set(_ data: Data, account: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(insert as CFDictionary, nil)
        guard result == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(result)) }
    }

    func data(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private struct FirebaseSignBody: Encodable {
    let email: String
    let password: String
    let returnSecureToken = true
}

private struct FirebaseAuthReply: Decodable {
    let idToken: String
    let email: String?
    let refreshToken: String
    let expiresIn: String
    let localId: String
}

private struct FirebaseRefreshReply: Decodable {
    let expires_in: String
    let refresh_token: String
    let id_token: String
    let user_id: String
}

private struct FirebaseLookupBody: Encodable { let idToken: String }
private struct FirebaseLookupReply: Decodable { let users: [FirebaseLookupUser]? }
private struct FirebaseLookupUser: Decodable { let emailVerified: Bool? }

private struct FirebaseOOBBody: Encodable {
    let requestType: String
    let email: String?
    let idToken: String?
}
private struct FirebaseOOBReply: Decodable { let email: String? }

private struct FirebaseErrorEnvelope: Decodable {
    let error: FirebaseErrorMessage
}
private struct FirebaseErrorMessage: Decodable {
    let message: String
}

@MainActor
final class AuthController: ObservableObject {
    @Published private(set) var configuration: BackendConfiguration?
    @Published private(set) var session: AuthSession?
    @Published private(set) var isBusy = false
    @Published private(set) var isBootstrapping = true
    @Published var message: String?

    private let keychain = KeychainStore(service: "kz.colorize.finance.auth.firebase")
    private let sessionAccount = "shared-account-session"

    init() {
        configuration = BackendConfigurationStore.stored()
        if let data = keychain.data(account: sessionAccount),
           let saved = try? JSONDecoder().decode(AuthSession.self, from: data) {
            session = saved
        }
    }

    var isConfigured: Bool { configuration?.isValid == true }
    var isAuthenticated: Bool { session != nil }

    func bootstrap() async {
        defer { isBootstrapping = false }
        if configuration == nil {
            configuration = await BackendConfigurationStore.resolveFromHosting()
        }
    }

    func saveConfiguration(projectID: String, apiKey: String) {
        let value = BackendConfiguration(projectID: projectID, apiKey: apiKey)
        guard value.isValid else {
            message = "Введите Firebase Project ID и Web API Key."
            return
        }
        BackendConfigurationStore.save(value)
        configuration = value
        message = nil
    }

    func signIn(email: String, password: String) async {
        guard let config = configuration else {
            message = "Firebase не настроен."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let reply: FirebaseAuthReply = try await identityRequest(
                config: config,
                endpoint: "accounts:signInWithPassword",
                body: FirebaseSignBody(email: email, password: password)
            )
            let verified = try await emailVerified(config: config, idToken: reply.idToken)
            guard verified else {
                try? await sendVerification(config: config, idToken: reply.idToken)
                throw NSError(domain: "Auth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Подтвердите email по письму Firebase, затем войдите снова."])
            }
            let newSession = AuthSession(
                accessToken: reply.idToken,
                refreshToken: reply.refreshToken,
                expiresAt: Date().addingTimeInterval(TimeInterval(Int(reply.expiresIn) ?? 3600)),
                userID: reply.localId,
                email: reply.email ?? email
            )
            try saveSession(newSession)
            session = newSession
            message = nil
        } catch {
            message = friendly(error)
        }
    }

    func signUp(email: String, password: String) async {
        guard let config = configuration else {
            message = "Firebase не настроен."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let reply: FirebaseAuthReply = try await identityRequest(
                config: config,
                endpoint: "accounts:signUp",
                body: FirebaseSignBody(email: email, password: password)
            )
            try await sendVerification(config: config, idToken: reply.idToken)
            session = nil
            keychain.delete(account: sessionAccount)
            message = "Аккаунт создан. Подтвердите email по письму Firebase и затем войдите."
        } catch {
            message = friendly(error)
        }
    }

    func resetPassword(email: String) async {
        guard let config = configuration else {
            message = "Firebase не настроен."
            return
        }
        guard !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "Введите email."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let _: FirebaseOOBReply = try await identityRequest(
                config: config,
                endpoint: "accounts:sendOobCode",
                body: FirebaseOOBBody(requestType: "PASSWORD_RESET", email: email, idToken: nil)
            )
            message = "Письмо для восстановления пароля отправлено."
        } catch {
            message = friendly(error)
        }
    }

    func validSession() async throws -> AuthSession {
        guard let current = session else {
            throw NSError(domain: "Auth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Нужно войти в аккаунт."])
        }
        guard current.needsRefresh else { return current }
        guard let config = configuration else {
            throw NSError(domain: "Auth", code: 3, userInfo: [NSLocalizedDescriptionKey: "Firebase не настроен."])
        }

        guard var components = URLComponents(string: "https://securetoken.googleapis.com/v1/token") else {
            throw NSError(domain: "Auth", code: 4)
        }
        components.queryItems = [URLQueryItem(name: "key", value: config.key)]
        guard let url = components.url else { throw NSError(domain: "Auth", code: 5) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = current.refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? current.refreshToken
        request.httpBody = "grant_type=refresh_token&refresh_token=\(encoded)".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let reply = try JSONDecoder().decode(FirebaseRefreshReply.self, from: data)
        let refreshed = AuthSession(
            accessToken: reply.id_token,
            refreshToken: reply.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(Int(reply.expires_in) ?? 3600)),
            userID: reply.user_id,
            email: current.email
        )
        try saveSession(refreshed)
        session = refreshed
        return refreshed
    }

    func signOut() {
        session = nil
        message = nil
        keychain.delete(account: sessionAccount)
    }

    private func saveSession(_ value: AuthSession) throws {
        try keychain.set(try JSONEncoder().encode(value), account: sessionAccount)
    }

    private func emailVerified(config: BackendConfiguration, idToken: String) async throws -> Bool {
        let reply: FirebaseLookupReply = try await identityRequest(
            config: config,
            endpoint: "accounts:lookup",
            body: FirebaseLookupBody(idToken: idToken)
        )
        return reply.users?.first?.emailVerified ?? false
    }

    private func sendVerification(config: BackendConfiguration, idToken: String) async throws {
        let _: FirebaseOOBReply = try await identityRequest(
            config: config,
            endpoint: "accounts:sendOobCode",
            body: FirebaseOOBBody(requestType: "VERIFY_EMAIL", email: nil, idToken: idToken)
        )
    }

    private func identityRequest<Response: Decodable, Body: Encodable>(
        config: BackendConfiguration,
        endpoint: String,
        body: Body
    ) async throws -> Response {
        guard var components = URLComponents(string: "https://identitytoolkit.googleapis.com/v1/\(endpoint)") else {
            throw NSError(domain: "Auth", code: 6)
        }
        components.queryItems = [URLQueryItem(name: "key", value: config.key)]
        guard let url = components.url else { throw NSError(domain: "Auth", code: 7) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "Firebase", code: -1, userInfo: [NSLocalizedDescriptionKey: "Нет ответа Firebase."])
        }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(FirebaseErrorEnvelope.self, from: data) {
                throw NSError(domain: "Firebase", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: envelope.error.message])
            }
            throw NSError(domain: "Firebase", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Firebase HTTP \(http.statusCode)"])
        }
    }

    private func friendly(_ error: Error) -> String {
        let raw = error.localizedDescription
        if raw.contains("EMAIL_NOT_FOUND") { return "Аккаунт с этой почтой не найден." }
        if raw.contains("INVALID_PASSWORD") || raw.contains("INVALID_LOGIN_CREDENTIALS") { return "Неверная почта или пароль." }
        if raw.contains("EMAIL_EXISTS") { return "Аккаунт с этой почтой уже существует." }
        if raw.contains("WEAK_PASSWORD") { return "Пароль должен содержать минимум 6 символов." }
        if raw.contains("TOO_MANY_ATTEMPTS") { return "Слишком много попыток. Попробуйте позже." }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct AccountRootView: View {
    @EnvironmentObject private var auth: AuthController
    @EnvironmentObject private var sync: CloudSyncCoordinator

    var body: some View {
        Group {
            if auth.isBootstrapping {
                ZStack {
                    AppBackground()
                    ProgressView("Подключение Colorize Finance…")
                }
            } else if !auth.isConfigured {
                FirebaseSetupView()
            } else if !auth.isAuthenticated {
                LoginView()
            } else {
                AdaptiveRootView()
                    .task(id: auth.session?.accessToken) {
                        await sync.syncNow(auth: auth)
                        while !Task.isCancelled && auth.isAuthenticated {
                            try? await Task.sleep(for: .seconds(15))
                            await sync.syncNow(auth: auth)
                        }
                    }
            }
        }
        .task { await auth.bootstrap() }
        .animation(.easeInOut(duration: 0.2), value: auth.isAuthenticated)
    }
}

struct LoginView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var createMode = false

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && (!createMode || password == confirm)
    }

    var body: some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 30)
                    GlassCard {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("Colorize Finance").font(.system(size: 30, weight: .bold, design: .rounded))
                                    Text(createMode ? "Создание общего аккаунта" : "Вход в аккаунт").foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("C").font(.title.bold()).foregroundStyle(.white)
                                    .frame(width: 54, height: 54).background(CF.red, in: Circle())
                            }

                            TextField("Email", text: $email)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)

                            SecureField("Пароль", text: $password)
                                .textContentType(createMode ? .newPassword : .password)
                                .textFieldStyle(.roundedBorder)

                            if createMode {
                                SecureField("Повторите пароль", text: $confirm)
                                    .textContentType(.newPassword)
                                    .textFieldStyle(.roundedBorder)
                            }

                            if let message = auth.message {
                                Text(message)
                                    .font(.footnote)
                                    .foregroundStyle(message.contains("создан") || message.contains("отправлено") ? Color.secondary : Color.red)
                            }

                            Button {
                                Task {
                                    if createMode {
                                        await auth.signUp(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                                    } else {
                                        await auth.signIn(email: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
                                    }
                                }
                            } label: {
                                if auth.isBusy {
                                    ProgressView().tint(.white).frame(maxWidth: .infinity)
                                } else {
                                    Text(createMode ? "Зарегистрироваться" : "Войти").frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(CF.red)
                            .controlSize(.large)
                            .disabled(!canSubmit || auth.isBusy)

                            if !createMode {
                                Button("Забыли пароль?") {
                                    Task { await auth.resetPassword(email: email.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                }
                                .frame(maxWidth: .infinity)
                            }

                            Button(createMode ? "У меня уже есть аккаунт" : "Создать аккаунт") {
                                withAnimation { createMode.toggle(); confirm = ""; auth.message = nil }
                            }
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)
                    Spacer(minLength: 30)
                }
            }
        }
        .tint(CF.red)
    }
}

struct FirebaseSetupView: View {
    @EnvironmentObject private var auth: AuthController
    @State private var projectID = "colorize-17e61"
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Не удалось автоматически восстановить настройки Firebase. Это окно обычно появляется только после чистой установки.")
                        .foregroundStyle(.secondary)
                }
                Section("Firebase") {
                    TextField("Project ID", text: $projectID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Web API Key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Подключить") { auth.saveConfiguration(projectID: projectID, apiKey: apiKey) }
                        .disabled(projectID.isEmpty || apiKey.isEmpty)
                }
            }
            .navigationTitle("Подключение аккаунта")
        }
    }
}

// MARK: - Cloud snapshot

private protocol CloudRecord: Codable, Identifiable where ID == UUID {
    var id: UUID { get }
    var modifiedAt: Date { get }
}

private struct CloudMaterial: CloudRecord {
    let id: UUID
    var name: String
    var category: String
    var unitRaw: String
    var purchasePrice: Double
    var defaultWastePercent: Double
    var stockQuantity: Double
    var createdAt: Date
    var modifiedAt: Date
}

private struct CloudClient: CloudRecord {
    let id: UUID
    var name: String
    var phone: String
    var company: String
    var notes: String
    var createdAt: Date
    var modifiedAt: Date
}

private struct CloudExpense: CloudRecord {
    let id: UUID
    var title: String
    var category: String
    var amount: Double
    var date: Date
    var notes: String
    var modifiedAt: Date
}

private struct CloudOrder: CloudRecord {
    let id: UUID
    var number: Int
    var title: String
    var clientName: String
    var productTypeRaw: String
    var statusRaw: String
    var widthMeters: Double
    var heightMeters: Double
    var salePrice: Double
    var depositAmount: Double
    var desiredMarginPercent: Double
    var createdAt: Date
    var dueDate: Date?
    var notes: String
    var modifiedAt: Date
}

private struct CloudCostLine: CloudRecord {
    let id: UUID
    var orderID: UUID?
    var title: String
    var categoryRaw: String
    var quantity: Double
    var unitRaw: String
    var unitCost: Double
    var wastePercent: Double
    var createdAt: Date
    var modifiedAt: Date
}

private struct CloudTombstone: Codable, Hashable {
    let kind: String
    let id: UUID
    let deletedAt: Date
}

private struct CloudSnapshot: Codable {
    var schemaVersion: Int = 1
    var generatedAt: Date = .now
    var materials: [CloudMaterial] = []
    var clients: [CloudClient] = []
    var expenses: [CloudExpense] = []
    var orders: [CloudOrder] = []
    var costLines: [CloudCostLine] = []
    var tombstones: [CloudTombstone] = []

    func semanticData() throws -> Data {
        var copy = self
        copy.generatedAt = Date(timeIntervalSince1970: 0)
        return try CloudCodec.encoder.encode(copy)
    }
}

private enum CloudCodec {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

private final class SyncMetadata {
    private let defaults = UserDefaults.standard
    private let prefix: String

    init(userID: String) {
        prefix = "colorize.finance.sync.\(userID)"
    }

    func modifiedAt(kind: String, id: UUID, fingerprint: String, fallback: Date) -> Date {
        let fKey = "\(prefix).fingerprint.\(kind).\(id.uuidString)"
        let dKey = "\(prefix).modifiedAt.\(kind).\(id.uuidString)"
        let previous = defaults.string(forKey: fKey)
        if previous == fingerprint, let date = defaults.object(forKey: dKey) as? Date {
            return date
        }
        let date = previous == nil ? fallback : .now
        defaults.set(fingerprint, forKey: fKey)
        defaults.set(date, forKey: dKey)
        return date
    }

    func adopt(kind: String, id: UUID, fingerprint: String, modifiedAt: Date) {
        defaults.set(fingerprint, forKey: "\(prefix).fingerprint.\(kind).\(id.uuidString)")
        defaults.set(modifiedAt, forKey: "\(prefix).modifiedAt.\(kind).\(id.uuidString)")
    }

    func tombstones(kind: String, current: Set<UUID>) -> [CloudTombstone] {
        let key = "\(prefix).known.\(kind)"
        let known = Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:)))
        return known.subtracting(current).map { CloudTombstone(kind: kind, id: $0, deletedAt: .now) }
    }

    func remember(kind: String, ids: Set<UUID>) {
        defaults.set(ids.map(\.uuidString).sorted(), forKey: "\(prefix).known.\(kind)")
    }
}

private func stableFingerprint(_ values: [String]) -> String {
    Data(values.joined(separator: "\u{001F}").utf8).base64EncodedString()
}

private func dateToken(_ date: Date?) -> String {
    guard let date else { return "" }
    return String(format: "%.6f", date.timeIntervalSince1970)
}

private func materialFingerprint(_ value: Material) -> String {
    stableFingerprint([value.name, value.category, value.unitRaw, String(value.purchasePrice), String(value.defaultWastePercent), String(value.stockQuantity), dateToken(value.createdAt)])
}
private func materialFingerprint(_ value: CloudMaterial) -> String {
    stableFingerprint([value.name, value.category, value.unitRaw, String(value.purchasePrice), String(value.defaultWastePercent), String(value.stockQuantity), dateToken(value.createdAt)])
}
private func clientFingerprint(_ value: Client) -> String {
    stableFingerprint([value.name, value.phone, value.company, value.notes, dateToken(value.createdAt)])
}
private func clientFingerprint(_ value: CloudClient) -> String {
    stableFingerprint([value.name, value.phone, value.company, value.notes, dateToken(value.createdAt)])
}
private func expenseFingerprint(_ value: CompanyExpense) -> String {
    stableFingerprint([value.title, value.category, String(value.amount), dateToken(value.date), value.notes])
}
private func expenseFingerprint(_ value: CloudExpense) -> String {
    stableFingerprint([value.title, value.category, String(value.amount), dateToken(value.date), value.notes])
}
private func orderFingerprint(_ value: AdOrder) -> String {
    stableFingerprint([String(value.number), value.title, value.clientName, value.productTypeRaw, value.statusRaw, String(value.widthMeters), String(value.heightMeters), String(value.salePrice), String(value.depositAmount), String(value.desiredMarginPercent), dateToken(value.createdAt), dateToken(value.dueDate), value.notes])
}
private func orderFingerprint(_ value: CloudOrder) -> String {
    stableFingerprint([String(value.number), value.title, value.clientName, value.productTypeRaw, value.statusRaw, String(value.widthMeters), String(value.heightMeters), String(value.salePrice), String(value.depositAmount), String(value.desiredMarginPercent), dateToken(value.createdAt), dateToken(value.dueDate), value.notes])
}
private func lineFingerprint(_ value: CostLine) -> String {
    stableFingerprint([value.order?.id.uuidString ?? "", value.title, value.categoryRaw, String(value.quantity), value.unitRaw, String(value.unitCost), String(value.wastePercent), dateToken(value.createdAt)])
}
private func lineFingerprint(_ value: CloudCostLine) -> String {
    stableFingerprint([value.orderID?.uuidString ?? "", value.title, value.categoryRaw, String(value.quantity), value.unitRaw, String(value.unitCost), String(value.wastePercent), dateToken(value.createdAt)])
}

private func mergeTombstones(_ a: [CloudTombstone], _ b: [CloudTombstone]) -> [CloudTombstone] {
    var map: [String: CloudTombstone] = [:]
    for item in a + b {
        let key = "\(item.kind):\(item.id.uuidString)"
        if let current = map[key], current.deletedAt >= item.deletedAt { continue }
        map[key] = item
    }
    return Array(map.values)
}

private func mergeRecords<T: CloudRecord>(_ a: [T], _ b: [T], kind: String, tombstones: [String: Date]) -> [T] {
    var map: [UUID: T] = [:]
    for item in a + b {
        if let current = map[item.id], current.modifiedAt >= item.modifiedAt { continue }
        map[item.id] = item
    }
    return map.values.filter { item in
        guard let deleted = tombstones["\(kind):\(item.id.uuidString)"] else { return true }
        return item.modifiedAt > deleted
    }.sorted { $0.id.uuidString < $1.id.uuidString }
}

private func mergeSnapshots(_ local: CloudSnapshot, _ remote: CloudSnapshot) -> CloudSnapshot {
    let tombstones = mergeTombstones(local.tombstones, remote.tombstones)
    let deletionMap = Dictionary(uniqueKeysWithValues: tombstones.map { ("\($0.kind):\($0.id.uuidString)", $0.deletedAt) })
    return CloudSnapshot(
        schemaVersion: max(local.schemaVersion, remote.schemaVersion),
        generatedAt: max(local.generatedAt, remote.generatedAt),
        materials: mergeRecords(local.materials, remote.materials, kind: "material", tombstones: deletionMap),
        clients: mergeRecords(local.clients, remote.clients, kind: "client", tombstones: deletionMap),
        expenses: mergeRecords(local.expenses, remote.expenses, kind: "expense", tombstones: deletionMap),
        orders: mergeRecords(local.orders, remote.orders, kind: "order", tombstones: deletionMap),
        costLines: mergeRecords(local.costLines, remote.costLines, kind: "costLine", tombstones: deletionMap),
        tombstones: tombstones
    )
}

@MainActor
final class CloudSyncCoordinator: ObservableObject {
    enum State: Equatable {
        case idle
        case syncing
        case success(Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastSync: Date?
    private let container: ModelContainer
    private var running = false

    init(container: ModelContainer) {
        self.container = container
    }

    func syncNow(auth: AuthController) async {
        guard !running, let config = auth.configuration else { return }
        running = true
        state = .syncing
        defer { running = false }

        do {
            let session = try await auth.validSession()
            let meta = SyncMetadata(userID: session.userID)
            let context = ModelContext(container)
            let local = try makeLocalSnapshot(context: context, meta: meta)
            let remoteRow = try await readRemote(config: config, userID: session.userID, token: session.accessToken)
            var merged = remoteRow.map { mergeSnapshots(local, $0.snapshot) } ?? local

            try apply(merged, context: context, meta: meta)

            let remoteSemantic = try remoteRow?.snapshot.semanticData()
            let mergedSemantic = try merged.semanticData()
            if remoteSemantic != mergedSemantic {
                merged.generatedAt = .now
                try await writeRemote(
                    config: config,
                    userID: session.userID,
                    token: session.accessToken,
                    snapshot: merged,
                    revision: (remoteRow?.revision ?? 0) + 1
                )
            }

            remember(merged, meta: meta)
            let now = Date()
            lastSync = now
            state = .success(now)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func makeLocalSnapshot(context: ModelContext, meta: SyncMetadata) throws -> CloudSnapshot {
        let materials = try context.fetch(FetchDescriptor<Material>())
        let clients = try context.fetch(FetchDescriptor<Client>())
        let expenses = try context.fetch(FetchDescriptor<CompanyExpense>())
        let orders = try context.fetch(FetchDescriptor<AdOrder>())
        let lines = try context.fetch(FetchDescriptor<CostLine>())

        var tombstones: [CloudTombstone] = []
        tombstones += meta.tombstones(kind: "material", current: Set(materials.map(\.id)))
        tombstones += meta.tombstones(kind: "client", current: Set(clients.map(\.id)))
        tombstones += meta.tombstones(kind: "expense", current: Set(expenses.map(\.id)))
        tombstones += meta.tombstones(kind: "order", current: Set(orders.map(\.id)))
        tombstones += meta.tombstones(kind: "costLine", current: Set(lines.map(\.id)))

        return CloudSnapshot(
            generatedAt: .now,
            materials: materials.map {
                CloudMaterial(id: $0.id, name: $0.name, category: $0.category, unitRaw: $0.unitRaw, purchasePrice: $0.purchasePrice, defaultWastePercent: $0.defaultWastePercent, stockQuantity: $0.stockQuantity, createdAt: $0.createdAt, modifiedAt: meta.modifiedAt(kind: "material", id: $0.id, fingerprint: materialFingerprint($0), fallback: $0.updatedAt))
            },
            clients: clients.map {
                CloudClient(id: $0.id, name: $0.name, phone: $0.phone, company: $0.company, notes: $0.notes, createdAt: $0.createdAt, modifiedAt: meta.modifiedAt(kind: "client", id: $0.id, fingerprint: clientFingerprint($0), fallback: $0.createdAt))
            },
            expenses: expenses.map {
                CloudExpense(id: $0.id, title: $0.title, category: $0.category, amount: $0.amount, date: $0.date, notes: $0.notes, modifiedAt: meta.modifiedAt(kind: "expense", id: $0.id, fingerprint: expenseFingerprint($0), fallback: $0.date))
            },
            orders: orders.map {
                CloudOrder(id: $0.id, number: $0.number, title: $0.title, clientName: $0.clientName, productTypeRaw: $0.productTypeRaw, statusRaw: $0.statusRaw, widthMeters: $0.widthMeters, heightMeters: $0.heightMeters, salePrice: $0.salePrice, depositAmount: $0.depositAmount, desiredMarginPercent: $0.desiredMarginPercent, createdAt: $0.createdAt, dueDate: $0.dueDate, notes: $0.notes, modifiedAt: meta.modifiedAt(kind: "order", id: $0.id, fingerprint: orderFingerprint($0), fallback: $0.createdAt))
            },
            costLines: lines.map {
                CloudCostLine(id: $0.id, orderID: $0.order?.id, title: $0.title, categoryRaw: $0.categoryRaw, quantity: $0.quantity, unitRaw: $0.unitRaw, unitCost: $0.unitCost, wastePercent: $0.wastePercent, createdAt: $0.createdAt, modifiedAt: meta.modifiedAt(kind: "costLine", id: $0.id, fingerprint: lineFingerprint($0), fallback: $0.createdAt))
            },
            tombstones: tombstones
        )
    }

    private func apply(_ snapshot: CloudSnapshot, context: ModelContext, meta: SyncMetadata) throws {
        var materials = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Material>()).map { ($0.id, $0) })
        var clients = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<Client>()).map { ($0.id, $0) })
        var expenses = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CompanyExpense>()).map { ($0.id, $0) })
        var orders = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<AdOrder>()).map { ($0.id, $0) })
        var lines = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<CostLine>()).map { ($0.id, $0) })

        let materialIDs = Set(snapshot.materials.map(\.id))
        let clientIDs = Set(snapshot.clients.map(\.id))
        let expenseIDs = Set(snapshot.expenses.map(\.id))
        let orderIDs = Set(snapshot.orders.map(\.id))
        let lineIDs = Set(snapshot.costLines.map(\.id))

        for id in lines.keys.filter({ !lineIDs.contains($0) }) { if let value = lines.removeValue(forKey: id) { context.delete(value) } }
        for id in orders.keys.filter({ !orderIDs.contains($0) }) { if let value = orders.removeValue(forKey: id) { context.delete(value) } }
        for id in materials.keys.filter({ !materialIDs.contains($0) }) { if let value = materials.removeValue(forKey: id) { context.delete(value) } }
        for id in clients.keys.filter({ !clientIDs.contains($0) }) { if let value = clients.removeValue(forKey: id) { context.delete(value) } }
        for id in expenses.keys.filter({ !expenseIDs.contains($0) }) { if let value = expenses.removeValue(forKey: id) { context.delete(value) } }

        for dto in snapshot.materials {
            let value = materials[dto.id] ?? Material(name: dto.name, category: dto.category, unit: MaterialUnit(rawValue: dto.unitRaw) ?? .piece, purchasePrice: dto.purchasePrice, defaultWastePercent: dto.defaultWastePercent, stockQuantity: dto.stockQuantity)
            if materials[dto.id] == nil { value.id = dto.id; context.insert(value); materials[dto.id] = value }
            value.name = dto.name
            value.category = dto.category
            value.unitRaw = dto.unitRaw
            value.purchasePrice = dto.purchasePrice
            value.defaultWastePercent = dto.defaultWastePercent
            value.stockQuantity = dto.stockQuantity
            value.createdAt = dto.createdAt
            value.updatedAt = dto.modifiedAt
            meta.adopt(kind: "material", id: dto.id, fingerprint: materialFingerprint(dto), modifiedAt: dto.modifiedAt)
        }

        for dto in snapshot.clients {
            let value = clients[dto.id] ?? Client(name: dto.name, phone: dto.phone, company: dto.company, notes: dto.notes)
            if clients[dto.id] == nil { value.id = dto.id; context.insert(value); clients[dto.id] = value }
            value.name = dto.name
            value.phone = dto.phone
            value.company = dto.company
            value.notes = dto.notes
            value.createdAt = dto.createdAt
            meta.adopt(kind: "client", id: dto.id, fingerprint: clientFingerprint(dto), modifiedAt: dto.modifiedAt)
        }

        for dto in snapshot.expenses {
            let value = expenses[dto.id] ?? CompanyExpense(title: dto.title, category: dto.category, amount: dto.amount, date: dto.date, notes: dto.notes)
            if expenses[dto.id] == nil { value.id = dto.id; context.insert(value); expenses[dto.id] = value }
            value.title = dto.title
            value.category = dto.category
            value.amount = dto.amount
            value.date = dto.date
            value.notes = dto.notes
            meta.adopt(kind: "expense", id: dto.id, fingerprint: expenseFingerprint(dto), modifiedAt: dto.modifiedAt)
        }

        for dto in snapshot.orders {
            let value = orders[dto.id] ?? AdOrder(number: dto.number, title: dto.title)
            if orders[dto.id] == nil { value.id = dto.id; context.insert(value); orders[dto.id] = value }
            value.number = dto.number
            value.title = dto.title
            value.clientName = dto.clientName
            value.productTypeRaw = dto.productTypeRaw
            value.statusRaw = dto.statusRaw
            value.widthMeters = dto.widthMeters
            value.heightMeters = dto.heightMeters
            value.salePrice = dto.salePrice
            value.depositAmount = dto.depositAmount
            value.desiredMarginPercent = dto.desiredMarginPercent
            value.createdAt = dto.createdAt
            value.dueDate = dto.dueDate
            value.notes = dto.notes
            meta.adopt(kind: "order", id: dto.id, fingerprint: orderFingerprint(dto), modifiedAt: dto.modifiedAt)
        }

        for dto in snapshot.costLines {
            let value = lines[dto.id] ?? CostLine(title: dto.title, category: CostCategory(rawValue: dto.categoryRaw) ?? .other, quantity: dto.quantity, unit: MaterialUnit(rawValue: dto.unitRaw) ?? .piece, unitCost: dto.unitCost, wastePercent: dto.wastePercent)
            if lines[dto.id] == nil { value.id = dto.id; context.insert(value); lines[dto.id] = value }
            value.title = dto.title
            value.categoryRaw = dto.categoryRaw
            value.quantity = dto.quantity
            value.unitRaw = dto.unitRaw
            value.unitCost = dto.unitCost
            value.wastePercent = dto.wastePercent
            value.createdAt = dto.createdAt
            value.order = dto.orderID.flatMap { orders[$0] }
            meta.adopt(kind: "costLine", id: dto.id, fingerprint: lineFingerprint(dto), modifiedAt: dto.modifiedAt)
        }

        try context.save()
    }

    private func remember(_ snapshot: CloudSnapshot, meta: SyncMetadata) {
        meta.remember(kind: "material", ids: Set(snapshot.materials.map(\.id)))
        meta.remember(kind: "client", ids: Set(snapshot.clients.map(\.id)))
        meta.remember(kind: "expense", ids: Set(snapshot.expenses.map(\.id)))
        meta.remember(kind: "order", ids: Set(snapshot.orders.map(\.id)))
        meta.remember(kind: "costLine", ids: Set(snapshot.costLines.map(\.id)))
    }

    private struct RemoteRow {
        let snapshot: CloudSnapshot
        let revision: Int
    }

    private struct FirestoreDocument: Decodable {
        let fields: [String: FirestoreReadField]?
    }
    private struct FirestoreReadField: Decodable {
        let stringValue: String?
        let integerValue: String?
        let timestampValue: String?
    }
    private struct FirestoreWriteDocument: Encodable {
        let fields: [String: FirestoreWriteField]
    }
    private struct FirestoreWriteField: Encodable {
        let stringValue: String?
        let integerValue: String?
        let timestampValue: String?
        enum CodingKeys: String, CodingKey { case stringValue, integerValue, timestampValue }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if let stringValue { try c.encode(stringValue, forKey: .stringValue) }
            if let integerValue { try c.encode(integerValue, forKey: .integerValue) }
            if let timestampValue { try c.encode(timestampValue, forKey: .timestampValue) }
        }
    }
    private struct FirestoreErrorEnvelope: Decodable { let error: FirestoreErrorMessage }
    private struct FirestoreErrorMessage: Decodable { let message: String }

    private func documentURL(config: BackendConfiguration, userID: String) throws -> URL {
        let project = config.project.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.project
        let user = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userID
        guard let url = URL(string: "https://firestore.googleapis.com/v1/projects/\(project)/databases/(default)/documents/companies/\(user)/sync/state") else {
            throw NSError(domain: "Sync", code: 1)
        }
        return url
    }

    private func readRemote(config: BackendConfiguration, userID: String, token: String) async throws -> RemoteRow? {
        var request = URLRequest(url: try documentURL(config: config, userID: userID))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NSError(domain: "Sync", code: 2) }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            if let envelope = try? JSONDecoder().decode(FirestoreErrorEnvelope.self, from: data) {
                throw NSError(domain: "Sync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: envelope.error.message])
            }
            throw NSError(domain: "Sync", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Firestore HTTP \(http.statusCode)"])
        }

        let document = try JSONDecoder().decode(FirestoreDocument.self, from: data)
        guard let payload = document.fields?["payload"]?.stringValue,
              let payloadData = payload.data(using: .utf8) else { return nil }

        // Recovery behavior: a legacy/broken web snapshot must not block the app.
        guard let snapshot = try? CloudCodec.decoder.decode(CloudSnapshot.self, from: payloadData) else {
            return nil
        }
        let revision = Int(document.fields?["revision"]?.integerValue ?? "0") ?? 0
        return RemoteRow(snapshot: snapshot, revision: revision)
    }

    private func writeRemote(config: BackendConfiguration, userID: String, token: String, snapshot: CloudSnapshot, revision: Int) async throws {
        guard let payload = String(data: try CloudCodec.encoder.encode(snapshot), encoding: .utf8) else { return }
        let document = FirestoreWriteDocument(fields: [
            "payload": FirestoreWriteField(stringValue: payload, integerValue: nil, timestampValue: nil),
            "revision": FirestoreWriteField(stringValue: nil, integerValue: String(revision), timestampValue: nil),
            "updatedAt": FirestoreWriteField(stringValue: nil, integerValue: nil, timestampValue: ISO8601DateFormatter().string(from: .now))
        ])
        var request = URLRequest(url: try documentURL(config: config, userID: userID))
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(document)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "Ошибка синхронизации"
            throw NSError(domain: "Sync", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: text])
        }
    }
}
