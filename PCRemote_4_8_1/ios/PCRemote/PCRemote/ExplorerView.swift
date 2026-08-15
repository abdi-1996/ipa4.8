import SwiftUI
import QuickLook
import UIKit
import UniformTypeIdentifiers

struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ExplorerRootsView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var roots: [FileItem] = []
    @State private var errorMessage = ""

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    var body: some View {
        NavigationStack {
            List {
                if !errorMessage.isEmpty {
                    Text(errorMessage).foregroundStyle(.red)
                }

                Section {
                    Text("Откройте папку, затем нажмите +, чтобы загрузить файл с iPhone на ПК. Файлы с ПК можно сохранить в «Файлы» или отправить через меню «Поделиться».")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(roots) { item in
                    NavigationLink(value: item) {
                        ExplorerRow(item: item)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DesktopBackgroundView().ignoresSafeArea())
            .navigationTitle("Проводник")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .navigationDestination(for: FileItem.self) { item in
                FolderView(folder: item).environmentObject(settings)
            }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    @MainActor
    private func load() async {
        errorMessage = ""
        guard let client else { return }
        do { roots = try await client.roots() }
        catch { errorMessage = error.localizedDescription }
    }
}

struct FolderView: View {
    @EnvironmentObject var settings: ConnectionSettings
    let folder: FileItem

    @State private var items: [FileItem] = []
    @State private var search = ""
    @State private var errorMessage = ""
    @State private var downloadingPath: String?
    @State private var uploadingNames: [String] = []
    @State private var previewFile: PreviewFile?
    @State private var shareFile: PreviewFile?
    @State private var exportFile: PreviewFile?
    @State private var showImporter = false

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    private var filtered: [FileItem] {
        guard !search.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if !errorMessage.isEmpty {
                Text(errorMessage).foregroundStyle(.red)
            }

            if !uploadingNames.isEmpty {
                Section("Передача на ПК") {
                    ForEach(uploadingNames, id: \.self) { name in
                        HStack {
                            ProgressView()
                            Text(name).lineLimit(1)
                        }
                    }
                }
            }

            Section {
                Button {
                    showImporter = true
                } label: {
                    Label("Загрузить файл с iPhone в эту папку", systemImage: "square.and.arrow.up")
                }

                Button {
                    Task { await openOnPC(folder.path) }
                } label: {
                    Label("Открыть эту папку на ПК", systemImage: "arrow.up.forward.app.fill")
                }
            }

            ForEach(filtered) { item in
                if item.isFolder {
                    NavigationLink(value: item) {
                        ExplorerRow(item: item)
                    }
                } else {
                    Button {
                        Task { await download(item, destination: .preview) }
                    } label: {
                        HStack {
                            ExplorerRow(item: item)
                            Spacer(minLength: 8)
                            if downloadingPath == item.path { ProgressView() }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            Task { await download(item, destination: .preview) }
                        } label: {
                            Label("Открыть на iPhone", systemImage: "iphone")
                        }

                        Button {
                            Task { await download(item, destination: .export) }
                        } label: {
                            Label("Сохранить в «Файлы»", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            Task { await download(item, destination: .share) }
                        } label: {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                        }

                        Button {
                            Task { await openOnPC(item.path) }
                        } label: {
                            Label("Открыть на ПК", systemImage: "desktopcomputer")
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DesktopBackgroundView().ignoresSafeArea())
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Загрузить с iPhone")
            }
        }
        .navigationDestination(for: FileItem.self) { item in
            FolderView(folder: item).environmentObject(settings)
        }
        .task { await load() }
        .refreshable { await load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task { await upload(urls) }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $previewFile) { file in
            FilePreviewContainer(url: file.url)
        }
        .sheet(item: $shareFile) { file in
            ActivityShareView(url: file.url)
        }
        .sheet(item: $exportFile) { file in
            DocumentExportPicker(url: file.url)
        }
    }

    private enum DownloadDestination { case preview, share, export }

    @MainActor
    private func load() async {
        errorMessage = ""
        guard let client else { return }
        do { items = try await client.list(path: folder.path) }
        catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func download(_ item: FileItem, destination: DownloadDestination) async {
        guard let client else { return }
        downloadingPath = item.path
        errorMessage = ""
        do {
            let localURL = try await client.downloadFile(item: item)
            let value = PreviewFile(url: localURL)
            switch destination {
            case .preview: previewFile = value
            case .share: shareFile = value
            case .export: exportFile = value
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        downloadingPath = nil
    }

    @MainActor
    private func upload(_ urls: [URL]) async {
        guard let client else { return }
        errorMessage = ""
        for url in urls {
            let hasAccess = url.startAccessingSecurityScopedResource()
            uploadingNames.append(url.lastPathComponent)
            do {
                _ = try await client.uploadFile(localURL: url, toFolder: folder.path)
            } catch {
                errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
            uploadingNames.removeAll { $0 == url.lastPathComponent }
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        await load()
    }

    private func openOnPC(_ path: String) async {
        guard let client else { return }
        do { try await client.openOnPC(path: path) }
        catch {
            await MainActor.run { errorMessage = error.localizedDescription }
        }
    }
}

struct ExplorerRow: View {
    let item: FileItem

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(iconGradient)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: fileSymbol).foregroundStyle(.white))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                if let size = item.size, !item.isFolder {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var fileExtension: String { URL(fileURLWithPath: item.name).pathExtension.lowercased() }

    private var fileSymbol: String {
        if item.isFolder { return "folder.fill" }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "tif", "tiff"].contains(fileExtension) { return "photo.fill" }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(fileExtension) { return "play.rectangle.fill" }
        if ["mp3", "m4a", "wav", "aac", "flac", "ogg"].contains(fileExtension) { return "waveform" }
        if fileExtension == "pdf" { return "doc.richtext.fill" }
        if ["zip", "7z", "rar", "tar", "gz"].contains(fileExtension) { return "archivebox.fill" }
        return "doc.fill"
    }

    private var iconGradient: LinearGradient {
        if item.isFolder { return LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing) }
        if ["jpg", "jpeg", "png", "heic", "gif", "webp", "bmp", "tif", "tiff"].contains(fileExtension) {
            return LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        if fileExtension == "pdf" { return LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing) }
        return LinearGradient(colors: [.indigo, .blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct FilePreviewContainer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var showShare = false
    @State private var showExport = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            QuickLookPreview(url: url).ignoresSafeArea(edges: .bottom)

            HStack(spacing: 9) {
                Button { dismiss() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Назад")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)

                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())

                Spacer(minLength: 0)

                Button { showExport = true } label: {
                    Image(systemName: "square.and.arrow.down")
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Button { showShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .interactiveDismissDisabled(false)
        .sheet(isPresented: $showShare) { ActivityShareView(url: url) }
        .sheet(isPresented: $showExport) { DocumentExportPicker(url: url) }
    }
}

private struct ActivityShareView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DocumentExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
