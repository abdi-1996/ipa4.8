import SwiftUI
import UIKit

@MainActor
final class CorelDrawModel: ObservableObject {
    let device: SavedDevice
    let app: RemoteApp
    let client: APIClient

    @Published var status: CorelStatusResponse?
    @Published var objects: [CorelShapeInfo] = []
    @Published var preview: UIImage?
    @Published var busy = false
    @Published var errorMessage = ""

    init(device: SavedDevice, app: RemoteApp) {
        self.device = device
        self.app = app
        self.client = APIClient(device: device)
    }

    func bootstrap() async {
        busy = true
        errorMessage = ""
        do {
            try? await client.corelLaunch()
            await refresh(includePreview: true)
        }
        busy = false
    }

    func refresh(includePreview: Bool = true) async {
        do {
            let value = try await client.corelStatus()
            status = value
            if value.documentOpen {
                async let objectTask = client.corelObjects()
                if includePreview {
                    async let previewTask = client.corelPreviewData()
                    let (objectResult, previewData) = try await (objectTask, previewTask)
                    objects = objectResult
                    if let image = UIImage(data: previewData) { preview = image }
                } else {
                    objects = try await objectTask
                }
            } else {
                objects = []
                preview = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func perform(_ action: String) async {
        await mutate { [self] in
            status = try await client.corelAction(action)
        }
    }

    func create(_ kind: String, text: String = "Текст") async {
        await mutate { [self] in
            status = try await client.corelCreate(kind: kind, text: text)
        }
    }

    func select(_ object: CorelShapeInfo) async {
        UISelectionFeedbackGenerator().selectionChanged()
        await mutate { [self] in
            status = try await client.corelSelect(index: object.index)
        }
    }

    func transform(x: Double?, y: Double?, width: Double?, height: Double?, rotation: Double?, keepRatio: Bool) async {
        await mutate { [self] in
            status = try await client.corelTransform(
                x: x, y: y, width: width, height: height, rotation: rotation, keepRatio: keepRatio
            )
        }
    }

    func style(fill: String?, outline: String?, outlineWidth: Double?) async {
        await mutate { [self] in
            status = try await client.corelStyle(fill: fill, outline: outline, outlineWidth: outlineWidth)
        }
    }

    func page(_ action: String, index: Int? = nil) async {
        await mutate { [self] in
            status = try await client.corelPage(action: action, index: index)
        }
    }

    func newDocument() async {
        await mutate { [self] in
            status = try await client.corelNewDocument()
        }
    }

    func open(path: String) async {
        await mutate { [self] in
            status = try await client.corelOpen(path: path)
        }
    }

    private func mutate(_ operation: @escaping () async throws -> Void) async {
        busy = true
        errorMessage = ""
        do {
            try await operation()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            await refresh(includePreview: true)
        } catch {
            errorMessage = error.localizedDescription
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        busy = false
    }
}

struct CorelDrawView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CorelDrawModel

    @State private var showObjects = false
    @State private var showTransform = false
    @State private var showStyle = false
    @State private var showPages = false
    @State private var showTextCreator = false
    @State private var showOpenPicker = false
    @State private var previewScale: CGFloat = 1
    @State private var previewOffset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero

    init(device: SavedDevice, app: RemoteApp) {
        _model = StateObject(wrappedValue: CorelDrawModel(device: device, app: app))
    }

    var body: some View {
        ZStack {
            CorelBackground().ignoresSafeArea()

            VStack(spacing: 12) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                if !model.errorMessage.isEmpty {
                    Text(model.errorMessage)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                }

                if model.status?.documentOpen == true {
                    documentCanvas
                    selectionStrip
                    toolDock
                } else {
                    emptyDocument
                }
            }
            .padding(.bottom, 8)

            if model.busy {
                ProgressView()
                    .tint(.white)
                    .padding(16)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .preferredColorScheme(.dark)
        .task { await model.bootstrap() }
        .sheet(isPresented: $showObjects) {
            CorelObjectsSheet(model: model)
        }
        .sheet(isPresented: $showTransform) {
            CorelTransformSheet(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showStyle) {
            CorelStyleSheet(model: model)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showPages) {
            CorelPagesSheet(model: model)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showTextCreator) {
            CorelTextCreator(model: model)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showOpenPicker) {
            CorelDocumentPicker(client: model.client) { path in
                showOpenPicker = false
                Task { await model.open(path: path) }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                CorelCircleButton(systemName: "chevron.left")
            }

            VStack(spacing: 2) {
                Text(model.status?.documentName ?? "CorelDRAW")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                HStack(spacing: 5) {
                    Circle().fill(model.status?.running == true ? Color.green : Color.orange).frame(width: 7, height: 7)
                    Text(headerSubtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await model.perform("save") }
            } label: {
                CorelCircleButton(systemName: "square.and.arrow.down.fill")
            }
            .disabled(model.status?.documentOpen != true)

            Menu {
                Button("Новый документ", systemImage: "doc.badge.plus") { Task { await model.newDocument() } }
                Button("Открыть с ПК", systemImage: "folder") { showOpenPicker = true }
                Divider()
                Button("Обновить", systemImage: "arrow.clockwise") { Task { await model.refresh(includePreview: true) } }
                Button("Показать CorelDRAW на ПК", systemImage: "display") { Task { try? await model.client.corelLaunch() } }
            } label: {
                CorelCircleButton(systemName: "ellipsis")
            }
        }
    }

    private var headerSubtitle: String {
        guard let status = model.status else { return "Подключение…" }
        if !status.documentOpen { return "Готов к работе" }
        let dirty = status.dirty ? " • изменён" : ""
        return "Стр. \(max(1, status.pageIndex))/\(max(1, status.pageCount))\(dirty)"
    }

    private var documentCanvas: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )

                if let image = model.preview {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(previewScale)
                        .offset(previewOffset)
                        .gesture(
                            SimultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in previewScale = min(6, max(0.65, lastScale * value)) }
                                    .onEnded { _ in lastScale = previewScale },
                                DragGesture(minimumDistance: 2)
                                    .onChanged { value in
                                        previewOffset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                    .onEnded { _ in lastOffset = previewOffset }
                            )
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                previewScale = 1
                                lastScale = 1
                                previewOffset = .zero
                                lastOffset = .zero
                            }
                        }
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Готовим предпросмотр…").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                VStack {
                    HStack {
                        Text("\(model.objects.count) объектов")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                previewScale = 1
                                lastScale = 1
                                previewOffset = .zero
                                lastOffset = .zero
                            }
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.bold())
                                .padding(9)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    Spacer()
                }
                .padding(14)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .frame(maxHeight: .infinity)
        .padding(.horizontal, 14)
    }

    private var selectionStrip: some View {
        HStack(spacing: 10) {
            if let selection = model.status?.selection {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(String(format: "%.1f × %.1f   •   %.0f°", selection.width, selection.height, selection.rotation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showTransform = true } label: { Image(systemName: "slider.horizontal.3") }
                Button { showStyle = true } label: { Image(systemName: "paintpalette.fill") }
            } else {
                Image(systemName: "cursorarrow.rays")
                Text("Выберите объект для быстрых настроек")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showObjects = true } label: { Image(systemName: "square.stack.3d.up") }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .frame(height: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 14)
    }

    private var toolDock: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                CorelToolButton(system: "cursorarrow", title: "Объекты") { showObjects = true }
                CorelToolButton(system: "rectangle", title: "Прямоуг.") { Task { await model.create("rectangle") } }
                CorelToolButton(system: "circle", title: "Эллипс") { Task { await model.create("ellipse") } }
                CorelToolButton(system: "textformat", title: "Текст") { showTextCreator = true }
                CorelToolButton(system: "line.diagonal", title: "Линия") { Task { await model.create("line") } }
                CorelToolButton(system: "paintpalette", title: "Цвет") { showStyle = true }
                CorelToolButton(system: "move.3d", title: "Размер") { showTransform = true }
                CorelToolButton(system: "doc.on.doc", title: "Копия") { Task { await model.perform("duplicate") } }
                CorelToolButton(system: "square.3.layers.3d", title: "Группа") { Task { await model.perform("group") } }
                CorelToolButton(system: "square.2.layers.3d", title: "Разгруп.") { Task { await model.perform("ungroup") } }
                CorelToolButton(system: "square.3.layers.3d.top.filled", title: "Вперёд") { Task { await model.perform("front") } }
                CorelToolButton(system: "square.3.layers.3d.down.left", title: "Назад") { Task { await model.perform("back") } }
                CorelToolButton(system: "doc.on.doc.fill", title: "Страницы") { showPages = true }
                CorelToolButton(system: "arrow.uturn.backward", title: "Undo") { Task { await model.perform("undo") } }
                CorelToolButton(system: "arrow.uturn.forward", title: "Redo") { Task { await model.perform("redo") } }
                CorelToolButton(system: "trash", title: "Удалить", destructive: true) { Task { await model.perform("delete") } }
            }
            .padding(.horizontal, 14)
        }
        .padding(.bottom, 2)
    }

    private var emptyDocument: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "scribble.variable")
                .font(.system(size: 62, weight: .semibold))
                .foregroundStyle(.linearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
            Text("CorelDRAW")
                .font(.largeTitle.bold())
            Text("Создайте новый документ или откройте CDR с компьютера. CorelDRAW запустится на ПК, а управление останется здесь.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            HStack(spacing: 12) {
                Button { Task { await model.newDocument() } } label: {
                    Label("Новый", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CorelPrimaryButtonStyle())

                Button { showOpenPicker = true } label: {
                    Label("Открыть", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(CorelSecondaryButtonStyle())
            }
            .padding(.horizontal, 22)
            Spacer()
        }
    }
}

private struct CorelBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.015, green: 0.025, blue: 0.045), Color(red: 0.02, green: 0.12, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle().fill(Color.green.opacity(0.14)).frame(width: 360).blur(radius: 90).offset(x: 180, y: -260)
            Circle().fill(Color.cyan.opacity(0.10)).frame(width: 300).blur(radius: 100).offset(x: -180, y: 260)
        }
    }
}

private struct CorelCircleButton: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.12)))
    }
}

private struct CorelToolButton: View {
    let system: String
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(destructive ? Color.red : Color.white)
            .frame(width: 68, height: 58)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
    }
}

private struct CorelObjectsSheet: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [CorelShapeInfo] {
        search.isEmpty ? model.objects : model.objects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { object in
                Button {
                    Task {
                        await model.select(object)
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: object.type))
                            .foregroundStyle(.green)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(object.name).lineLimit(1)
                            Text(String(format: "%.1f × %.1f", object.width, object.height))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.status?.selection?.index == object.index {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Объекты")
            .searchable(text: $search, prompt: "Поиск объекта")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Все") { Task { await model.perform("select_all") } }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
    }

    private func icon(for type: Int) -> String {
        switch type {
        case 1: return "rectangle"
        case 2: return "textformat"
        case 3: return "circle"
        default: return "scribble"
        }
    }
}

private struct CorelTransformSheet: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss
    @State private var x = ""
    @State private var y = ""
    @State private var width = ""
    @State private var height = ""
    @State private var rotation = ""
    @State private var keepRatio = true

    var body: some View {
        NavigationStack {
            Form {
                if let selection = model.status?.selection {
                    Section("Положение") {
                        numericRow("X", text: $x)
                        numericRow("Y", text: $y)
                    }
                    Section("Размер") {
                        Toggle("Сохранять пропорции", isOn: $keepRatio)
                        numericRow("Ширина", text: $width)
                        numericRow("Высота", text: $height)
                    }
                    Section("Поворот") {
                        numericRow("Угол", text: $rotation)
                    }
                    Section {
                        Button("Применить") {
                            Task {
                                await model.transform(
                                    x: Double(x), y: Double(y), width: Double(width), height: Double(height), rotation: Double(rotation), keepRatio: keepRatio
                                )
                                dismiss()
                            }
                        }
                    }
                    .onAppear {
                        x = format(selection.x); y = format(selection.y)
                        width = format(selection.width); height = format(selection.height)
                        rotation = format(selection.rotation)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "cursorarrow")
                            .font(.system(size: 34, weight: .semibold))
                        Text("Объект не выбран")
                            .font(.headline)
                        Text("Выберите объект на вкладке «Объекты». ")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            }
            .navigationTitle("Размер и положение")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func numericRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 130)
        }
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}

private struct CorelStyleSheet: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss
    @State private var fill = "#22C55E"
    @State private var outline = "#FFFFFF"
    @State private var outlineWidth = 0.2

    private let colors = ["#FFFFFF", "#111827", "#EF4444", "#F59E0B", "#22C55E", "#06B6D4", "#3B82F6", "#8B5CF6", "#EC4899"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Заливка") {
                    colorStrip(selected: $fill)
                    TextField("#RRGGBB", text: $fill).textInputAutocapitalization(.characters)
                }
                Section("Контур") {
                    colorStrip(selected: $outline)
                    TextField("#RRGGBB", text: $outline).textInputAutocapitalization(.characters)
                    HStack {
                        Text("Толщина")
                        Slider(value: $outlineWidth, in: 0...5, step: 0.05)
                        Text(String(format: "%.2f", outlineWidth)).monospacedDigit().frame(width: 44)
                    }
                }
                Section {
                    Button("Применить") {
                        Task {
                            await model.style(fill: fill, outline: outline, outlineWidth: outlineWidth)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Цвет и контур")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }

    private func colorStrip(selected: Binding<String>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(colors, id: \.self) { hex in
                    Button {
                        selected.wrappedValue = hex
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 34, height: 34)
                            .overlay(Circle().stroke(Color.white, lineWidth: selected.wrappedValue == hex ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct CorelPagesSheet: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Text("Страница \(model.status?.pageIndex ?? 0) из \(model.status?.pageCount ?? 0)")
                    .font(.title2.bold())
                HStack(spacing: 16) {
                    Button { Task { await model.page("previous") } } label: { Label("Назад", systemImage: "chevron.left") }
                    Button { Task { await model.page("add") } } label: { Label("Добавить", systemImage: "plus") }
                    Button { Task { await model.page("next") } } label: { Label("Дальше", systemImage: "chevron.right") }
                }
                .buttonStyle(.borderedProminent)

                if let count = model.status?.pageCount, count > 0 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(1...count, id: \.self) { page in
                                if page == model.status?.pageIndex {
                                    Button("\(page)") { Task { await model.page("set", index: page) } }
                                        .buttonStyle(.borderedProminent)
                                } else {
                                    Button("\(page)") { Task { await model.page("set", index: page) } }
                                        .buttonStyle(.bordered)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle("Страницы")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
}

private struct CorelTextCreator: View {
    @ObservedObject var model: CorelDrawModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextEditor(text: $text)
                    .font(.title3)
                    .padding(10)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .frame(minHeight: 150)
                Button {
                    Task {
                        await model.create("text", text: text.isEmpty ? "Текст" : text)
                        dismiss()
                    }
                } label: {
                    Label("Добавить текст", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Новый текст")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Отмена") { dismiss() } } }
        }
    }
}

private struct CorelDocumentPicker: View {
    let client: APIClient
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var roots: [FileItem] = []
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List {
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                ForEach(roots) { item in
                    NavigationLink(value: item) { ExplorerRow(item: item) }
                }
            }
            .navigationTitle("Открыть в CorelDRAW")
            .navigationDestination(for: FileItem.self) { item in
                CorelFolderPicker(client: client, folder: item, onSelect: onSelect)
            }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
            .task {
                do { roots = try await client.roots() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct CorelFolderPicker: View {
    let client: APIClient
    let folder: FileItem
    let onSelect: (String) -> Void
    @State private var items: [FileItem] = []
    @State private var error = ""
    @State private var search = ""

    private let extensions = Set(["cdr", "cdt", "cmx", "svg", "pdf", "ai", "eps"])

    private var filtered: [FileItem] {
        items.filter { item in
            if item.isFolder { return search.isEmpty || item.name.localizedCaseInsensitiveContains(search) }
            let ext = (item.name as NSString).pathExtension.lowercased()
            return extensions.contains(ext) && (search.isEmpty || item.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            ForEach(filtered) { item in
                if item.isFolder {
                    NavigationLink(value: item) { ExplorerRow(item: item) }
                } else {
                    Button { onSelect(item.path) } label: { ExplorerRow(item: item) }
                        .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "CDR, SVG, PDF…")
        .navigationDestination(for: FileItem.self) { item in
            CorelFolderPicker(client: client, folder: item, onSelect: onSelect)
        }
        .task {
            do { items = try await client.list(path: folder.path) }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct CorelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(.black)
            .background(Color.green.opacity(configuration.isPressed ? 0.65 : 0.95), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct CorelSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
}

private extension Color {
    init(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let int = UInt64(value, radix: 16) ?? 0
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
