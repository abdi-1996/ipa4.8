import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ColorizeBrandLogo: View {
    var compact = false

    var body: some View {
        HStack(spacing: 3) {
            ZStack {
                Text("C")
                    .font(.system(size: compact ? 30 : 34, weight: .black, design: .rounded))
                    .foregroundStyle(.red)
                    .offset(x: 3, y: 1)
                Text("C")
                    .font(.system(size: compact ? 30 : 34, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            Text("OLOR")
                .font(.system(size: compact ? 22 : 26, weight: .black, design: .rounded))
                .foregroundStyle(.red)
            Text("I")
                .font(.system(size: compact ? 22 : 26, weight: .black, design: .rounded))
                .foregroundStyle(.white)
            Text("ZE")
                .font(.system(size: compact ? 22 : 26, weight: .black, design: .rounded))
                .foregroundStyle(.red)
        }
        .overlay(alignment: .bottomTrailing) {
            Text("ЖАРНАМА АГЕНТТІГІ")
                .font(.system(size: compact ? 6 : 7, weight: .semibold))
                .foregroundStyle(.secondary)
                .offset(y: compact ? 7 : 8)
        }
        .fixedSize()
    }
}

struct RemoteMedia: Codable, Identifiable, Hashable {
    let id: Int64
    let name: String
    let mime: String
    let size: Int64
    let date: Int64
    let kind: String
}

struct MediaEnvelope: Codable {
    let items: [RemoteMedia]
    let offset: Int
    let count: Int
}

@MainActor
final class GalleryStore: ObservableObject {
    @Published var items: [RemoteMedia] = []
    @Published var status = "Не подключено"
    @Published var loading = false
    @Published var shareURL: URL?
    @Published var alertMessage: String?

    @AppStorage("gallery.host") var host = ""
    @AppStorage("gallery.token") var token = ""

    func endpoint(_ path: String, extra: [URLQueryItem] = []) -> URL? {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { return nil }
        if !base.hasPrefix("http://") && !base.hasPrefix("https://") { base = "http://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        guard var c = URLComponents(string: base + path) else { return nil }
        c.queryItems = [URLQueryItem(name: "token", value: token)] + extra
        return c.url
    }

    func connect() async {
        guard let url = endpoint("/api/status") else {
            status = "Введите адрес Android"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.userAuthenticationRequired)
            }
            status = "Подключено"
            await reload()
        } catch {
            status = "Ошибка подключения"
            alertMessage = "Проверьте адрес, код подключения и что ColorizeFinance запущен на Android."
        }
    }

    func reload() async {
        guard let url = endpoint("/api/media", extra: [
            URLQueryItem(name: "limit", value: "300"),
            URLQueryItem(name: "offset", value: "0")
        ]) else { return }
        loading = true
        defer { loading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            items = try JSONDecoder().decode(MediaEnvelope.self, from: data).items
            status = "Подключено · \(items.count) файлов"
        } catch {
            alertMessage = "Не удалось загрузить галерею: \(error.localizedDescription)"
        }
    }

    func thumbnailURL(_ item: RemoteMedia) -> URL? {
        endpoint("/api/thumb", extra: [URLQueryItem(name: "id", value: String(item.id))])
    }

    func download(_ item: RemoteMedia) async {
        guard let url = endpoint("/api/file", extra: [URLQueryItem(name: "id", value: String(item.id))]) else { return }
        loading = true
        defer { loading = false }
        do {
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let safe = item.name.replacingOccurrences(of: "/", with: "_")
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "ColorizeMedia" : safe)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            shareURL = dest
        } catch {
            alertMessage = "Не удалось скачать файл: \(error.localizedDescription)"
        }
    }

    func requestDelete(_ item: RemoteMedia) async {
        guard let url = endpoint("/api/delete-request", extra: [URLQueryItem(name: "id", value: String(item.id))]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 202 else {
                throw URLError(.badServerResponse)
            }
            alertMessage = "Запрос отправлен. Подтвердите удаление на Android."
        } catch {
            alertMessage = "Не удалось отправить запрос удаления."
        }
    }

    func upload(data: Data, filename: String, mime: String) async {
        guard let url = endpoint("/api/upload", extra: [
            URLQueryItem(name: "name", value: filename),
            URLQueryItem(name: "mime", value: mime)
        ]) else { return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                throw URLError(.badServerResponse)
            }
            await reload()
        } catch {
            alertMessage = "Не удалось отправить файл на Android."
        }
    }
}

@main
struct ColorizeGalleryControlApp: App {
    var body: some Scene {
        WindowGroup { GalleryRootView() }
    }
}

struct GalleryRootView: View {
    @StateObject private var store = GalleryStore()
    @State private var selectedPicker: PhotosPickerItem?
    @State private var selectedItem: RemoteMedia?
    @State private var showSettings = false

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 3)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

                if store.items.isEmpty && !store.loading {
                    ContentUnavailableView(
                        "Галерея Android",
                        systemImage: "photo.on.rectangle.angled",
                        description: Text(store.host.isEmpty ? "Сначала подключите свой Android." : "Нажмите обновить или проверьте подключение.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(store.items) { item in
                                Button {
                                    selectedItem = item
                                } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        AsyncImage(url: store.thumbnailURL(item)) { phase in
                                            switch phase {
                                            case .success(let image):
                                                image.resizable().scaledToFill()
                                            default:
                                                Rectangle().fill(.gray.opacity(0.15))
                                                    .overlay(Image(systemName: item.kind == "video" ? "video.fill" : "photo"))
                                            }
                                        }
                                        .frame(height: 115)
                                        .clipped()

                                        if item.kind == "video" {
                                            Image(systemName: "play.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.white)
                                                .shadow(radius: 2)
                                                .padding(6)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(3)
                    }
                    .refreshable { await store.reload() }
                }

                if store.loading {
                    ProgressView()
                        .padding(18)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ColorizeBrandLogo(compact: true)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    PhotosPicker(selection: $selectedPicker, matching: .any(of: [.images, .videos])) {
                        Image(systemName: "plus")
                    }
                    Button { Task { await store.reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Circle()
                        .fill(store.status.hasPrefix("Подключено") ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(store.status).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
            .sheet(isPresented: $showSettings) {
                ConnectionView(store: store)
            }
            .sheet(item: $selectedItem) { item in
                MediaDetailView(store: store, item: item)
            }
            .sheet(isPresented: Binding(
                get: { store.shareURL != nil },
                set: { if !$0 { store.shareURL = nil } }
            )) {
                if let url = store.shareURL {
                    ShareSheet(items: [url])
                }
            }
            .alert("ColorizeFinance", isPresented: Binding(
                get: { store.alertMessage != nil },
                set: { if !$0 { store.alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.alertMessage ?? "")
            }
            .onChange(of: selectedPicker) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { return }
                        let type = item.supportedContentTypes.first
                        let mime = type?.preferredMIMEType ?? "application/octet-stream"
                        let ext = type?.preferredFilenameExtension ?? (mime.hasPrefix("video/") ? "mov" : "jpg")
                        let name = "iphone_\(Int(Date().timeIntervalSince1970)).\(ext)"
                        await store.upload(data: data, filename: name, mime: mime)
                    } catch {
                        store.alertMessage = "Не удалось прочитать выбранный файл."
                    }
                    selectedPicker = nil
                }
            }
            .task {
                if !store.host.isEmpty && !store.token.isEmpty {
                    await store.connect()
                } else {
                    showSettings = true
                }
            }
        }
        .tint(.red)
    }
}

struct ConnectionView: View {
    @ObservedObject var store: GalleryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Android") {
                    TextField("Адрес, например 100.64.1.2:8787", text: store.$host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Код подключения", text: store.$token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Button("Подключиться") {
                        Task {
                            await store.connect()
                            if store.status.hasPrefix("Подключено") { dismiss() }
                        }
                    }
                    .disabled(store.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                              store.token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Section {
                    Text("Адрес и код показываются в ColorizeFinance на вашем Android после входа и выдачи системного разрешения на фото и видео.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Подключение")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

struct MediaDetailView: View {
    @ObservedObject var store: GalleryStore
    let item: RemoteMedia
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                AsyncImage(url: store.thumbnailURL(item)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit()
                    default:
                        RoundedRectangle(cornerRadius: 22)
                            .fill(.gray.opacity(0.15))
                            .overlay(Image(systemName: item.kind == "video" ? "video.fill" : "photo").font(.largeTitle))
                    }
                }
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 22))

                VStack(spacing: 5) {
                    Text(item.name).font(.headline).lineLimit(2)
                    Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task {
                        await store.download(item)
                        dismiss()
                    }
                } label: {
                    Label("Скачать / поделиться", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    Task {
                        await store.requestDelete(item)
                        dismiss()
                    }
                } label: {
                    Label("Запросить удаление", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("Удаление окончательно выполняется только после подтверждения на вашем Android.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .navigationTitle(item.kind == "video" ? "Видео" : "Фото")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
