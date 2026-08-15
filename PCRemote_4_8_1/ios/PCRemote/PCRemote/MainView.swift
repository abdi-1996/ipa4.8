import SwiftUI
import UIKit
import CoreTransferable
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var settings: ConnectionSettings

    @State private var desktopApps: [RemoteApp] = []
    @State private var allApps: [RemoteApp] = []
    @State private var recentApps: [RemoteApp] = []
    @State private var loading = true
    @State private var error = ""
    @State private var showExplorer = false
    @State private var showSettings = false
    @State private var showStart = false
    @State private var showRemoteScreen = false
    @State private var showComfyUI = false
    @State private var comfyApp: RemoteApp?
    @State private var showCorelDRAW = false
    @State private var corelApp: RemoteApp?
    @State private var currentPage = 0

    private let appsPerPage = 24 // 4 columns × 6 rows.

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    private var desktopIDs: Set<String> {
        Set(desktopApps.map(\.id))
    }

    private var homeApps: [RemoteApp] {
        var result = desktopApps
        var existing = Set(result.map(\.id))
        let pinned = settings.pinnedIDs(for: settings.currentDevice)
        let map = Dictionary(uniqueKeysWithValues: allApps.map { ($0.id, $0) })

        for id in pinned where !existing.contains(id) {
            if let app = map[id] {
                result.append(app)
                existing.insert(id)
            }
        }
        return result
    }

    private var pages: [[RemoteApp]] {
        let apps = homeApps
        guard !apps.isEmpty else { return [[]] }
        return stride(from: 0, to: apps.count, by: appsPerPage).map { start in
            Array(apps[start..<min(start + appsPerPage, apps.count)])
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let height = max(1, geometry.size.height)

            ZStack {
                DesktopBackgroundView()
                    .frame(width: width, height: height)
                    .clipped()

                VStack(spacing: 0) {
                    topBar
                        .frame(width: max(0, width - 32))
                        .padding(.top, 8)

                    if loading {
                        Spacer()
                        ProgressView("Загружаем рабочий стол...")
                            .tint(.white)
                        Spacer()
                    } else {
                        if !error.isEmpty {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.96))
                                .multilineTextAlignment(.center)
                                .frame(width: max(0, width - 32))
                                .padding(.top, 7)
                        }

                        TabView(selection: $currentPage) {
                            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, page in
                                HomePageGrid(
                                    apps: page,
                                    width: width,
                                    device: settings.currentDevice,
                                    desktopIDs: desktopIDs,
                                    isPinned: { app in settings.isPinned(app, for: settings.currentDevice) },
                                    onLaunch: { app in Task { await launch(app) } },
                                    onRemove: { app in settings.unpin(app, for: settings.currentDevice) }
                                )
                                .tag(pageIndex)
                                .frame(width: width)
                                .clipped()
                            }
                        }
                        .frame(width: width)
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .clipped()
                    }
                    if !showStart {
                        VStack(spacing: 7) {
                            if pages.count > 1 {
                                HStack(spacing: 7) {
                                    ForEach(0..<pages.count, id: \.self) { index in
                                        Circle()
                                            .fill(index == currentPage ? Color.white : Color.white.opacity(0.35))
                                            .frame(width: index == currentPage ? 8 : 7, height: index == currentPage ? 8 : 7)
                                    }
                                }
                            }

                            dockPanel
                                .frame(width: max(0, width - 24))
                                .clipped()
                        }
                        .padding(.top, 3)
                        .padding(.bottom, 8)
                    }
                }
                .frame(width: width, height: height)
                .clipped()

                if showStart {
                    StartMenuOverlay(
                        apps: allApps,
                        recentApps: recentApps,
                        desktopIDs: desktopIDs,
                        device: settings.currentDevice,
                        onLaunch: { app in
                            showStart = false
                            Task {
                                await launch(app)
                                await reloadRecents()
                            }
                        },
                        onClose: { showStart = false },
                        onDropToHome: { app in
                            if !desktopIDs.contains(app.id) {
                                settings.pin(app, for: settings.currentDevice)
                            }
                            showStart = false
                        },
                        onPower: { action in
                            showStart = false
                            Task { await performPower(action) }
                        }
                    )
                    .environmentObject(settings)
                    .frame(width: width, height: height)
                    .clipped()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .task { await loadApps() }
        .task { await monitorStatusLoop() }
        .sheet(isPresented: $showExplorer) {
            ExplorerRootsView().environmentObject(settings)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showRemoteScreen) {
            if let device = settings.currentDevice {
                RemoteScreenView(device: device, initialMode: settings.remoteQualityMode)
                    .environmentObject(settings)
            }
        }
        .fullScreenCover(isPresented: $showComfyUI) {
            if let device = settings.currentDevice, let comfyApp {
                ComfyUIView(device: device, app: comfyApp)
            }
        }
        .fullScreenCover(isPresented: $showCorelDRAW) {
            if let device = settings.currentDevice, let corelApp {
                CorelDrawView(device: device, app: corelApp)
            }
        }
        .onChange(of: pages.count) { count in
            if currentPage >= count {
                currentPage = max(0, count - 1)
            }
        }
    }

    private var connectionBadgeText: String {
        guard let status = settings.currentStatus else { return "" }
        switch status.transport?.lowercased() {
        case "tailscale":
            return "Tailscale • \(status.tailscaleIP ?? settings.currentDevice?.tailscaleHost ?? status.ip)"
        case "zerotier":
            return "ZeroTier • \(status.zerotierIP ?? settings.currentDevice?.zerotierHost ?? status.ip)"
        default:
            return "LAN • \(status.ip)"
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(settings.currentDevice?.name ?? "ПК")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                HStack(spacing: 7) {
                    Text(settings.currentStatus?.locked == true ? "Заблокирован" : "Подключено")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                    Circle()
                        .fill(settings.currentStatus?.locked == true ? Color.orange : Color.green)
                        .frame(width: 9, height: 9)
                    Text(connectionBadgeText)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                showSettings = true
            } label: {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: "gearshape")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(width: 48, height: 48)
        }
    }

    private var dockPanel: some View {
        HStack(spacing: 0) {
            DockMainButton(system: "square.grid.2x2.fill", title: "Пуск") {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    showStart.toggle()
                }
            }
            dockDivider
            DockMainButton(system: "folder.fill", title: "Проводник") { showExplorer = true }
            dockDivider
            DockMainButton(system: "display", title: "Экран") { showRemoteScreen = true }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .stroke(Color.white.opacity(0.17), lineWidth: 1)
                )
        )
        .shadow(color: .blue.opacity(0.24), radius: 18, y: 9)
    }

    private var dockDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.13))
            .frame(width: 1, height: 56)
            .padding(.horizontal, 2)
    }

    @MainActor
    private func loadApps() async {
        loading = true
        error = ""
        guard let client else {
            settings.disconnect()
            return
        }

        do {
            async let desktop = client.desktopApps()
            async let all = client.allApps()
            async let recent = client.recentApps()
            let (desktopResult, allResult, recentResult) = try await (desktop, all, recent)
            desktopApps = desktopResult
            allApps = allResult
            recentApps = recentResult
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func launch(_ app: RemoteApp) async {
        if app.isComfyUI {
            await MainActor.run {
                comfyApp = app
                showComfyUI = true
                showStart = false
            }
            return
        }
        guard let client else { return }
        if app.isCorelDRAW {
            do {
                // Launch the real Windows app first, then open the native iPhone controller.
                try await client.launch(app: app)
                try? await client.corelLaunch()
                await reloadRecents()
                await MainActor.run {
                    corelApp = app
                    showCorelDRAW = true
                    showStart = false
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            return
        }
        do {
            try await client.launch(app: app)
            await reloadRecents()
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }

    @MainActor
    private func reloadRecents() async {
        guard let client else { return }
        if let result = try? await client.recentApps() {
            recentApps = result
        }
    }

    @MainActor
    private func performPower(_ action: String) async {
        guard let client else { return }
        do {
            try await client.powerAction(action)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func monitorStatusLoop() async {
        while !Task.isCancelled {
            guard let client else { return }
            if let status = try? await client.status() {
                await MainActor.run { settings.currentStatus = status }
            }
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
        }
    }
}

private struct HomePageGrid: View {
    let apps: [RemoteApp]
    let width: CGFloat
    let device: SavedDevice?
    let desktopIDs: Set<String>
    let isPinned: (RemoteApp) -> Bool
    let onLaunch: (RemoteApp) -> Void
    let onRemove: (RemoteApp) -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = 12
            let columnSpacing: CGFloat = 8
            let rowSpacing: CGFloat = 4
            let usableWidth = max(0, proxy.size.width - horizontalPadding * 2 - columnSpacing * 3)
            let cellWidth = floor(usableWidth / 4)
            let usableHeight = max(0, proxy.size.height - 12 - rowSpacing * 5)
            let cellHeight = floor(usableHeight / 6)
            let labelHeight = min(28, max(20, cellHeight * 0.30))
            let iconSize = min(60, max(38, min(cellWidth * 0.68, cellHeight - labelHeight - 8)))
            let columns = Array(repeating: GridItem(.fixed(cellWidth), spacing: columnSpacing), count: 4)

            LazyVGrid(columns: columns, alignment: .center, spacing: rowSpacing) {
                ForEach(apps) { app in
                    Button {
                        onLaunch(app)
                    } label: {
                        VStack(spacing: 4) {
                            AppGlyphView(app: app, device: device, size: iconSize)
                            Text(app.displayName)
                                .font(.system(size: min(11, max(9.5, cellWidth * 0.12)), weight: .medium))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.68)
                                .frame(width: cellWidth, height: labelHeight)
                        }
                        .frame(width: cellWidth, height: cellHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !desktopIDs.contains(app.id) && isPinned(app) {
                            Button(role: .destructive) {
                                onRemove(app)
                            } label: {
                                Label("Убрать с главного экрана", systemImage: "minus.circle")
                            }
                        }

                        Button {
                            onLaunch(app)
                        } label: {
                            Label("Запустить", systemImage: "play.fill")
                        }
                    }
                }
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.top, 6)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .clipped()
        }
        .frame(width: width)
        .clipped()
    }
}

private struct StartMenuOverlay: View {
    @EnvironmentObject var settings: ConnectionSettings

    let apps: [RemoteApp]
    let recentApps: [RemoteApp]
    let desktopIDs: Set<String>
    let device: SavedDevice?
    let onLaunch: (RemoteApp) -> Void
    let onClose: () -> Void
    let onDropToHome: (RemoteApp) -> Void
    let onPower: (String) -> Void

    @State private var search = ""
    @State private var showAllApps = false
    @State private var dropTargeted = false
    @State private var showPower = false

    private var filtered: [RemoteApp] {
        let value = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return apps }
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        return apps
            .filter { app in
                let haystack = app.searchableText
                return tokens.allSatisfy { token in
                    haystack.localizedCaseInsensitiveContains(token)
                }
            }
            .sorted { lhs, rhs in
                let l = searchRank(lhs, query: value)
                let r = searchRank(rhs, query: value)
                if l != r { return l < r }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func searchRank(_ app: RemoteApp, query: String) -> Int {
        let name = app.displayName.lowercased()
        if name == query { return 0 }
        if name.hasPrefix(query) { return 1 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 2 }
        if (app.aliases ?? []).contains(where: { $0.lowercased().hasPrefix(query) }) { return 3 }
        return 4
    }

    private var displayedRecent: [RemoteApp] {
        if search.isEmpty { return Array(recentApps.prefix(8)) }
        return Array(filtered.prefix(12))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let panelWidth = max(0, width - 20)

            ZStack(alignment: .bottom) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { onClose() }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.42))
                        .frame(width: 42, height: 5)
                        .padding(.top, 9)
                        .padding(.bottom, 12)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Поиск приложений", text: $search)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)

                    if !showAllApps {
                        HStack {
                            Text(search.isEmpty ? "Недавние" : "Результаты")
                                .font(.system(size: 18, weight: .bold))
                            Spacer()
                            if search.isEmpty {
                                Button("Все приложения") { showAllApps = true }
                                    .font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 17)
                        .padding(.bottom, 8)

                        if displayedRecent.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "clock")
                                    .font(.system(size: 26))
                                    .foregroundStyle(.secondary)
                                Text(search.isEmpty ? "Недавно запущенных программ пока нет" : "Ничего не найдено")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)
                        } else {
                            StartAppsGrid(
                                apps: displayedRecent,
                                device: device,
                                desktopIDs: desktopIDs,
                                onLaunch: onLaunch,
                                onDropToHome: onDropToHome
                            )
                            .environmentObject(settings)
                            .frame(maxHeight: 245)
                        }
                    } else {
                        HStack {
                            Button {
                                showAllApps = false
                            } label: {
                                Label("Назад", systemImage: "chevron.left")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("Все приложения")
                                .font(.system(size: 18, weight: .bold))
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 17)
                        .padding(.bottom, 8)

                        ScrollView(showsIndicators: false) {
                            StartAppsGrid(
                                apps: filtered,
                                device: device,
                                desktopIDs: desktopIDs,
                                onLaunch: onLaunch,
                                onDropToHome: onDropToHome
                            )
                            .environmentObject(settings)
                            .padding(.bottom, 12)
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.blue.opacity(0.20))
                            .frame(width: 38, height: 38)
                            .overlay(Image(systemName: "desktopcomputer").foregroundStyle(.blue))

                        Text(device?.name ?? "ПК")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Spacer()

                        Button {
                            showPower = true
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .background(Color.secondary.opacity(0.12), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.secondary.opacity(0.06))
                }
                .frame(width: panelWidth, height: min(proxy.size.height * 0.72, 610))
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .padding(.bottom, 8)

                VStack(spacing: 7) {
                    Image(systemName: dropTargeted ? "plus.circle.fill" : "hand.draw")
                        .font(.system(size: 20, weight: .semibold))
                    Text(dropTargeted ? "Отпустите — программа появится на главном экране" : "Удерживайте иконку и перетащите сюда")
                        .font(.system(size: 12, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .foregroundStyle(.white)
                .frame(width: max(0, width - 48), height: 70)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(dropTargeted ? Color.blue.opacity(0.9) : Color.black.opacity(0.32))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.white.opacity(dropTargeted ? 0.6 : 0.16), lineWidth: 1)
                        )
                )
                .position(x: width / 2, y: 54)
                .dropDestination(for: String.self) { values, _ in
                    guard let id = values.first,
                          let app = apps.first(where: { $0.id == id }) else { return false }
                    onDropToHome(app)
                    return true
                } isTargeted: { targeted in
                    dropTargeted = targeted
                }
            }
            .frame(width: width, height: proxy.size.height)
            .clipped()
            .confirmationDialog("Питание ПК", isPresented: $showPower, titleVisibility: .visible) {
                Button("Заблокировать") { onPower("lock") }
                Button("Спящий режим") { onPower("sleep") }
                Button("Перезагрузить", role: .destructive) { onPower("restart") }
                Button("Выключить", role: .destructive) { onPower("shutdown") }
                Button("Отмена", role: .cancel) { }
            }
        }
    }
}

private struct StartAppsGrid: View {
    @EnvironmentObject var settings: ConnectionSettings
    let apps: [RemoteApp]
    let device: SavedDevice?
    let desktopIDs: Set<String>
    let onLaunch: (RemoteApp) -> Void
    let onDropToHome: (RemoteApp) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(apps) { app in
                Button {
                    onLaunch(app)
                } label: {
                    VStack(spacing: 6) {
                        AppGlyphView(app: app, device: device, size: 52)
                        Text(app.displayName)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .frame(height: 26)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .draggable(app.id)
                .contextMenu {
                    Button {
                        onLaunch(app)
                    } label: {
                        Label("Запустить", systemImage: "play.fill")
                    }
                    if !desktopIDs.contains(app.id) {
                        if settings.isPinned(app, for: device) {
                            Button(role: .destructive) {
                                settings.unpin(app, for: device)
                            } label: {
                                Label("Убрать с главного экрана", systemImage: "minus.circle")
                            }
                        } else {
                            Button {
                                settings.pin(app, for: device)
                            } label: {
                                Label("Добавить на главный экран", systemImage: "plus.circle")
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }
}

private struct DockMainButton: View {
    let system: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: system)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(title == "Проводник" ? Color.yellow : Color.white)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Remote screen

private final class RemoteScreenModel: ObservableObject {
    @Published var image: UIImage?
    @Published var info: RemoteScreenInfo?
    @Published var errorMessage: String = ""
    @Published var mode: RemoteQualityMode
    @Published var isReceiving = false

    private let client: APIClient
    private var loopTask: Task<Void, Never>?

    init(device: SavedDevice, mode: RemoteQualityMode) {
        self.client = APIClient(device: device)
        self.mode = mode
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            do {
                let info = try await self.client.remoteInfo()
                await MainActor.run {
                    self.info = info
                    self.errorMessage = ""
                }
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }

            while !Task.isCancelled {
                let currentMode = self.mode
                do {
                    let data = try await self.client.remoteFrame(mode: currentMode)
                    if let image = UIImage(data: data) {
                        await MainActor.run {
                            self.image = image
                            self.isReceiving = true
                            self.errorMessage = ""
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.isReceiving = false
                        self.errorMessage = error.localizedDescription
                    }
                }

                do {
                    try await Task.sleep(nanoseconds: currentMode.intervalNanoseconds)
                } catch {
                    break
                }
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    deinit { loopTask?.cancel() }
}

struct RemoteScreenView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss

    let device: SavedDevice
    @StateObject private var model: RemoteScreenModel
    @State private var keyboardActive = false

    init(device: SavedDevice, initialMode: RemoteQualityMode) {
        self.device = device
        _model = StateObject(wrappedValue: RemoteScreenModel(device: device, mode: initialMode))
    }

    private var client: APIClient { APIClient(device: device) }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("Качество", selection: modeBinding) {
                        ForEach(RemoteQualityMode.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)

                    ZStack {
                        if let image = model.image {
                            RemoteDisplaySurface(
                                image: image,
                                info: model.info,
                                device: device,
                                requestKeyboard: {
                                    keyboardActive = true
                                }
                            )
                        } else {
                            VStack(spacing: 12) {
                                ProgressView().tint(.white)
                                Text("Подключаем трансляцию...")
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }

                        if !model.errorMessage.isEmpty {
                            VStack {
                                Spacer()
                                Text(model.errorMessage)
                                    .font(.footnote)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color.red.opacity(0.78), in: Capsule())
                                    .padding(.bottom, 10)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    HStack(spacing: 8) {
                        Label("Тап", systemImage: "hand.tap")
                        Text("•")
                        Text("свайп — как касание Windows")
                        Spacer(minLength: 4)
                        Button {
                            keyboardActive.toggle()
                        } label: {
                            Image(systemName: keyboardActive ? "keyboard.chevron.compact.down" : "keyboard")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 40, height: 34)
                                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }

                RemoteKeyboardBridge(
                    active: $keyboardActive,
                    onText: { text in
                        Task { try? await client.remoteText(text) }
                    },
                    onBackspace: {
                        Task { try? await client.remoteKey("backspace") }
                    },
                    onReturn: {
                        Task { try? await client.remoteKey("enter") }
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            }
            .navigationTitle("Удалённый экран")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        keyboardActive = false
                        dismiss()
                    } label: {
                        Label("Назад", systemImage: "chevron.left")
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { try? await client.remoteKey("esc") }
                        } label: {
                            Label("Esc", systemImage: "escape")
                        }
                        Button {
                            Task { try? await client.remoteKey("tab") }
                        } label: {
                            Label("Tab", systemImage: "arrow.right.to.line")
                        }
                        Button {
                            Task { try? await client.remoteKey("win") }
                        } label: {
                            Label("Win", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    private var modeBinding: Binding<RemoteQualityMode> {
        Binding(
            get: { model.mode },
            set: { newMode in
                model.mode = newMode
                settings.remoteQualityRaw = newMode.rawValue
            }
        )
    }
}

private struct RemoteDisplaySurface: View {
    let image: UIImage
    let info: RemoteScreenInfo?
    let device: SavedDevice
    let requestKeyboard: () -> Void

    @State private var lastTouchLocation: CGPoint = .zero
    @State private var dragStartedAt: Date?
    @State private var longPressTriggered = false

    private var client: APIClient { APIClient(device: device) }

    var body: some View {
        GeometryReader { proxy in
            let rect = fittedRect(in: proxy.size)

            ZStack {
                Color.black

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)

                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .local)
                            .onChanged { value in
                                lastTouchLocation = value.location
                                if dragStartedAt == nil { dragStartedAt = Date() }
                            }
                            .onEnded { value in
                                defer {
                                    dragStartedAt = nil
                                    longPressTriggered = false
                                }
                                if longPressTriggered { return }

                                let start = normalized(value.startLocation, size: rect.size)
                                let end = normalized(value.location, size: rect.size)
                                let distance = hypot(value.translation.width, value.translation.height)
                                let duration = min(1.2, max(0.08, Date().timeIntervalSince(dragStartedAt ?? Date())))

                                if distance < 12 {
                                    sendTouch(kind: "tap", start: end, end: nil, duration: 0.04, checkTextFocus: true)
                                } else {
                                    sendTouch(kind: "swipe", start: start, end: end, duration: duration, checkTextFocus: false)
                                }
                            }
                    )
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.58, maximumDistance: 14)
                            .onEnded { _ in
                                longPressTriggered = true
                                let point = normalized(lastTouchLocation, size: rect.size)
                                sendTouch(kind: "long", start: point, end: nil, duration: 0.65, checkTextFocus: false)
                            }
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let sourceWidth = CGFloat(info?.width ?? Int(image.size.width))
        let sourceHeight = CGFloat(info?.height ?? Int(image.size.height))
        guard sourceWidth > 0, sourceHeight > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let scale = min(size.width / sourceWidth, size.height / sourceHeight)
        let width = sourceWidth * scale
        let height = sourceHeight * scale
        return CGRect(
            x: (size.width - width) / 2,
            y: (size.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: max(0, min(1, point.x / size.width)),
            y: max(0, min(1, point.y / size.height))
        )
    }

    private func sendTouch(kind: String, start: CGPoint, end: CGPoint?, duration: Double, checkTextFocus: Bool) {
        Task {
            try? await client.remoteTouch(
                kind: kind,
                x1: Double(start.x),
                y1: Double(start.y),
                x2: end.map { Double($0.x) },
                y2: end.map { Double($0.y) },
                duration: duration
            )

            if checkTextFocus {
                try? await Task.sleep(nanoseconds: 160_000_000)
                if let focus = try? await client.remoteFocusInfo(), focus.text_input {
                    await MainActor.run { requestKeyboard() }
                }
            }
        }
    }
}

private struct RemoteKeyboardBridge: UIViewRepresentable {
    @Binding var active: Bool
    let onText: (String) -> Void
    let onBackspace: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onBackspace: onBackspace, onReturn: onReturn)
    }

    func makeUIView(context: Context) -> InstantRemoteTextField {
        let field = InstantRemoteTextField(frame: .zero)
        field.delegate = context.coordinator
        field.onInsertText = context.coordinator.onText
        field.onDeleteBackward = context.coordinator.onBackspace
        field.onReturn = context.coordinator.onReturn
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.textContentType = nil
        field.returnKeyType = .done
        field.keyboardType = .default
        field.backgroundColor = .clear
        field.textColor = .clear
        field.tintColor = .clear
        field.accessibilityLabel = "Клавиатура удалённого ПК"
        return field
    }

    func updateUIView(_ uiView: InstantRemoteTextField, context: Context) {
        uiView.onInsertText = onText
        uiView.onDeleteBackward = onBackspace
        uiView.onReturn = onReturn
        context.coordinator.onText = onText
        context.coordinator.onBackspace = onBackspace
        context.coordinator.onReturn = onReturn

        if active && !uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        } else if !active && uiView.isFirstResponder {
            DispatchQueue.main.async { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var onText: (String) -> Void
        var onBackspace: () -> Void
        var onReturn: () -> Void

        init(onText: @escaping (String) -> Void, onBackspace: @escaping () -> Void, onReturn: @escaping () -> Void) {
            self.onText = onText
            self.onBackspace = onBackspace
            self.onReturn = onReturn
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onReturn()
            return false
        }
    }
}

private final class InstantRemoteTextField: UITextField {
    var onInsertText: ((String) -> Void)?
    var onDeleteBackward: (() -> Void)?
    var onReturn: (() -> Void)?

    override func insertText(_ text: String) {
        if text == "\n" {
            onReturn?()
        } else if !text.isEmpty {
            onInsertText?(text)
        }
        self.text = ""
    }

    override func deleteBackward() {
        onDeleteBackward?()
        self.text = ""
    }
}

// MARK: - ComfyUI native module

@MainActor
private final class ComfyUIModel: ObservableObject {
    @Published var dashboard: ComfyDashboardResponse?
    @Published var parameters = ComfyParameters(
        positive: "", negative: "", steps: 20, cfg: 7.0, seed: 0,
        sampler: "", scheduler: "", width: 512, height: 512,
        checkpoint: "", lora: "", vae: ""
    )
    @Published var selectedWorkflowID = ""
    @Published var errorMessage = ""
    @Published var busy = false
    @Published var savedMessage = ""

    let device: SavedDevice
    let app: RemoteApp
    private let client: APIClient
    private var pollTask: Task<Void, Never>?

    init(device: SavedDevice, app: RemoteApp) {
        self.device = device
        self.app = app
        self.client = APIClient(device: device)
    }

    var available: Bool { dashboard?.available == true }
    var running: Bool { dashboard?.running == true }
    var workflows: [ComfyWorkflow] { dashboard?.workflows ?? [] }
    var images: [ComfyImageItem] { dashboard?.images ?? [] }

    var selectedWorkflow: ComfyWorkflow? {
        workflows.first(where: { $0.id == selectedWorkflowID })
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh(loadParameters: true)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_100_000_000) }
                catch { return }
                await self.refresh(loadParameters: false)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(loadParameters: Bool) async {
        do {
            let requested = selectedWorkflowID.isEmpty ? nil : selectedWorkflowID
            let value = try await client.comfyDashboard(workflowID: requested)
            let oldSelection = selectedWorkflowID
            dashboard = value
            errorMessage = value.error ?? ""

            if selectedWorkflowID.isEmpty, let selected = value.selectedWorkflow {
                selectedWorkflowID = selected
            }

            if loadParameters || (oldSelection.isEmpty && !selectedWorkflowID.isEmpty) {
                parameters = value.parameters
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectWorkflow(_ workflow: ComfyWorkflow) async {
        selectedWorkflowID = workflow.id
        await refresh(loadParameters: true)
    }

    func startComfyUI() async {
        busy = true
        defer { busy = false }
        do {
            try await client.launch(app: app)
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            await refresh(loadParameters: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func generate() async {
        guard available else {
            errorMessage = "Сначала запустите ComfyUI на ПК."
            return
        }
        guard !selectedWorkflowID.isEmpty else {
            errorMessage = "Сначала выберите workflow."
            return
        }
        busy = true
        errorMessage = ""
        defer { busy = false }
        do {
            _ = try await client.comfyGenerate(workflowID: selectedWorkflowID, parameters: parameters)
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func interrupt() async {
        do {
            try await client.comfyInterrupt()
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearQueue() async {
        do {
            try await client.comfyClearQueue()
            await refresh(loadParameters: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openFullUIOnPC() async {
        do { try await client.comfyOpenFullUIOnPC() }
        catch { errorMessage = error.localizedDescription }
    }

    func openImageOnPC(_ item: ComfyImageItem) async {
        do { try await client.comfyOpenImageOnPC(item) }
        catch { errorMessage = error.localizedDescription }
    }

    func saveImage(_ item: ComfyImageItem) async {
        do {
            let data = try await client.comfyImageData(item)
            guard let image = UIImage(data: data) else { throw APIError.badResponse }
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
            savedMessage = "Сохранено в Фото"
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            savedMessage = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ComfyUIView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ComfyUIModel
    @State private var showWorkflowPicker = false
    @State private var selectedImage: ComfyImageItem?
    @State private var editWorkflow: ComfyWorkflow?
    @State private var showTemplates = false
    @State private var showSaveTemplate = false

    init(device: SavedDevice, app: RemoteApp) {
        _model = StateObject(wrappedValue: ComfyUIModel(device: device, app: app))
    }

    var body: some View {
        ZStack {
            ComfyBackground()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    header
                        .padding(.top, 6)

                    if model.available {
                        systemStatusBar
                    }

                    if let message = model.dashboard?.message, !model.available {
                        unavailableCard(message: message)
                    } else if model.dashboard == nil {
                        ProgressView("Подключаемся к ComfyUI…")
                            .tint(.white)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        workflowCard
                        promptCard(
                            title: "Positive Prompt",
                            systemImage: "sparkles",
                            text: $model.parameters.positive,
                            withTemplates: true
                        )
                        promptCard(
                            title: "Negative Prompt",
                            systemImage: "minus.circle",
                            text: $model.parameters.negative,
                            withTemplates: false
                        )

                        if !model.selectedWorkflowID.isEmpty {
                            ComfyAdvancedPanel(device: model.device, workflowID: model.selectedWorkflowID)
                                .id(model.selectedWorkflowID)
                        }

                        queueSection
                        resultsSection
                    }

                    if !model.errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(model.errorMessage)
                                .font(.system(size: 13, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Color.orange)
                        .padding(14)
                        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }

                    if !model.savedMessage.isEmpty {
                        Label(model.savedMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                            .padding(.vertical, 8)
                    }

                    Color.clear.frame(height: 12)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .sheet(isPresented: $showWorkflowPicker) {
            ComfyWorkflowPicker(
                device: model.device,
                workflows: model.workflows,
                selectedID: model.selectedWorkflowID,
                onSelect: { workflow in
                    showWorkflowPicker = false
                    Task { await model.selectWorkflow(workflow) }
                },
                onEdit: { workflow in
                    showWorkflowPicker = false
                    editWorkflow = workflow
                },
                onReload: { Task { await model.refresh(loadParameters: false) } }
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showTemplates) {
            ComfyPromptTemplatesView(
                profile: model.dashboard?.modelProfile ?? "generic_image",
                mediaType: model.dashboard?.mediaType ?? "image",
                prompt: $model.parameters.positive
            )
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSaveTemplate) {
            ComfySaveTemplateView(
                profile: model.dashboard?.modelProfile ?? "generic_image",
                initialText: model.parameters.positive
            )
            .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $editWorkflow) { workflow in
            ComfyNodeEditorView(device: model.device, workflow: workflow)
                .preferredColorScheme(.dark)
        }
        .fullScreenCover(item: $selectedImage) { item in
            ComfyResultViewer(device: model.device, item: item)
                .preferredColorScheme(.dark)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text("ComfyUI")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.available ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(model.available ? "Connected" : "Offline")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    if model.available {
                        Text("•")
                            .foregroundStyle(.white.opacity(0.30))
                        Text(profileTitle)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.76))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Menu {
                if model.available {
                    Button { Task { await model.openFullUIOnPC() } } label: {
                        Label("Полный интерфейс на ПК", systemImage: "macwindow")
                    }
                    Button { Task { await model.clearQueue() } } label: {
                        Label("Очистить очередь", systemImage: "trash")
                    }
                }
                Button { Task { await model.refresh(loadParameters: false) } } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
    }

    private var profileTitle: String {
        switch model.dashboard?.modelProfile ?? "generic_image" {
        case "wan": return "WAN • Video"
        case "zimage": return "Z-Image • Image"
        case "generic_video": return "Video workflow"
        default: return "Image workflow"
        }
    }

    private var systemStatusBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if let stats = model.dashboard?.system {
                    if let gpu = stats.gpuPercent {
                        ComfyStatusChip(
                            icon: "memorychip.fill",
                            title: "GPU",
                            value: "\(Int(gpu))%" + (stats.gpuTemperature.map { "  \(Int($0))°" } ?? ""),
                            tint: .cyan
                        )
                    }
                    ComfyStatusChip(
                        icon: "cpu.fill",
                        title: "CPU",
                        value: "\(Int(stats.cpuPercent))%",
                        tint: .blue
                    )
                    ComfyStatusChip(
                        icon: "memorychip",
                        title: "RAM",
                        value: String(format: "%.1f/%.1f GB", stats.ramUsedGB, stats.ramTotalGB),
                        tint: .purple
                    )
                    if let used = stats.vramUsedGB, let total = stats.vramTotalGB {
                        ComfyStatusChip(
                            icon: "rectangle.stack.fill",
                            title: "VRAM",
                            value: String(format: "%.1f/%.1f GB", used, total),
                            tint: .green
                        )
                    }
                } else if let vram = model.dashboard?.vram {
                    ComfyStatusChip(icon: "memorychip", title: "VRAM", value: vram, tint: .cyan)
                }
            }
        }
    }

    private func unavailableCard(message: String) -> some View {
        ComfyGlassCard {
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.18)).frame(width: 82, height: 82)
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 35, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
                Text("ComfyUI не запущен")
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.62))
                    .multilineTextAlignment(.center)
                Button {
                    Task { await model.startComfyUI() }
                } label: {
                    HStack(spacing: 8) {
                        if model.busy { ProgressView().tint(.white) }
                        Image(systemName: "play.fill")
                        Text("Запустить ComfyUI")
                    }
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.85)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 16)
        }
    }

    private var workflowCard: some View {
        Button { showWorkflowPicker = true } label: {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [.blue.opacity(0.92), .purple.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "circle.hexagongrid.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 4) {
                    Text("WORKFLOW")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.cyan.opacity(0.86))
                    Text(model.selectedWorkflow?.name ?? "Выберите workflow")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let workflow = model.selectedWorkflow {
                        Text("\(workflow.nodeCount) нод • \(workflow.source)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
        }
        .buttonStyle(.plain)
    }

    private func promptCard(title: String, systemImage: String, text: Binding<String>, withTemplates: Bool) -> some View {
        ComfyGlassCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Label(title, systemImage: systemImage)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                    Spacer(minLength: 4)
                    if withTemplates {
                        Button { showTemplates = true } label: {
                            Text("Templates")
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.cyan.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { showSaveTemplate = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 30, height: 30)
                                .background(Color.white.opacity(0.08), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextEditor(text: text)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 82, maxHeight: 116)
                    .padding(9)
                    .background(Color.black.opacity(0.20), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    )
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Queue Status", symbol: "clock.arrow.2.circlepath")
            ComfyGlassCard {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.running ? "Generating…" : "Ready")
                                .font(.system(size: 16, weight: .bold))
                            Text(queueSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer()
                        Text(model.running ? "\(Int((model.dashboard?.progress ?? 0) * 100))%" : "Idle")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(model.running ? Color.cyan : Color.green)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.09))
                            Capsule()
                                .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                                .frame(width: proxy.size.width * CGFloat(max(0, min(1, model.dashboard?.progress ?? 0))))
                        }
                    }
                    .frame(height: 9)
                    .animation(.easeOut(duration: 0.25), value: model.dashboard?.progress)
                }
            }
        }
    }

    private var queueSubtitle: String {
        let remaining = model.dashboard?.queueRemaining ?? 0
        if let node = model.dashboard?.currentNode, model.running {
            return "Node \(node) • Queue: \(remaining)"
        }
        return remaining > 0 ? "В очереди: \(remaining)" : "Очередь пуста"
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Results", symbol: "photo.on.rectangle.angled")
                Spacer()
                if !model.images.isEmpty {
                    Text("\(model.images.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            if model.images.isEmpty {
                ComfyGlassCard {
                    VStack(spacing: 9) {
                        Image(systemName: "photo.stack")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.30))
                        Text("Результаты появятся здесь")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.50))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)], spacing: 9) {
                    ForEach(model.images) { item in
                        Button { selectedImage = item } label: {
                            ComfyRemoteImage(device: model.device, item: item)
                                .aspectRatio(1, contentMode: .fill)
                                .frame(maxWidth: .infinity)
                                .clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { Task { await model.saveImage(item) } } label: {
                                Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                            }
                            Button { Task { await model.openImageOnPC(item) } } label: {
                                Label("Открыть на ПК", systemImage: "display")
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button { Task { await model.interrupt() } } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.red.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!model.running)
            .opacity(model.running ? 1 : 0.45)

            Button { Task { await model.generate() } } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(!model.available || model.selectedWorkflowID.isEmpty || model.busy || model.selectedWorkflow?.canExecute == false)

            Button { Task { await model.generate() } } label: {
                HStack(spacing: 7) {
                    if model.busy { ProgressView().tint(.white) }
                    Image(systemName: "sparkles")
                    Text("Generate")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    LinearGradient(colors: [.blue, .cyan.opacity(0.88)], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .disabled(!model.available || model.selectedWorkflowID.isEmpty || model.busy || model.selectedWorkflow?.canExecute == false)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func sectionTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.90))
    }
}

private struct ComfyStatusChip: View {
    let icon: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
                Text(value)
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}

private struct ComfyPromptTemplate: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let category: String
    let text: String
    let profile: String
    let custom: Bool
}

private enum ComfyPromptTemplateLibrary {
    static func builtIns(profile: String, mediaType: String) -> [ComfyPromptTemplate] {
        func t(_ id: String, _ title: String, _ category: String, _ text: String, _ profile: String) -> ComfyPromptTemplate {
            ComfyPromptTemplate(id: id, title: title, category: category, text: text, profile: profile, custom: false)
        }

        let commonImage = [
            t("skin-natural", "Natural skin", "Кожа", "natural realistic skin texture, visible pores, subtle skin imperfections, lifelike subsurface scattering", "image"),
            t("face-detail", "Face detail", "Лицо", "highly detailed facial features, natural eyes, realistic eyelashes, fine facial hair, balanced facial proportions", "image"),
            t("body-natural", "Natural body", "Тело", "natural body proportions, anatomically coherent pose, realistic hands and fingers", "image"),
            t("light-window", "Soft window light", "Освещение", "soft directional window light, gentle shadow falloff, realistic bounce light", "image"),
            t("light-cinema", "Cinematic lighting", "Освещение", "cinematic key light, subtle rim light, controlled contrast, realistic practical lights", "image"),
            t("camera-50", "50mm portrait", "Камера", "shot on a 50mm lens, shallow depth of field, natural perspective, realistic optical rendering", "image"),
            t("camera-35", "35mm scene", "Камера", "shot on a 35mm lens, environmental composition, natural perspective, subtle depth of field", "image"),
            t("angle-low", "Low angle", "Ракурс", "low-angle camera view, subject framed with strong perspective", "image"),
            t("angle-over", "Over shoulder", "Ракурс", "over-the-shoulder composition, cinematic framing", "image"),
            t("style-photo", "Photoreal", "Стиль", "photorealistic, physically plausible materials, natural color response, fine micro-detail", "image"),
            t("detail-scene", "Scene detail", "Детали", "rich environmental detail, believable materials, subtle wear, fine surface texture", "image")
        ]

        let wan = [
            t("wan-subject", "Subject + scene", "Сцена", "A clearly described subject in a specific environment; establish time of day, atmosphere, and spatial context.", "wan"),
            t("wan-action", "Primary action", "Экшен", "The subject performs one clear continuous action with readable body motion and natural secondary motion.", "wan"),
            t("wan-camera-push", "Slow push-in", "Камера", "The camera slowly pushes in toward the subject with smooth cinematic motion and stable framing.", "wan"),
            t("wan-camera-orbit", "Orbit shot", "Камера", "The camera performs a controlled orbit around the subject while preserving subject consistency.", "wan"),
            t("wan-motion", "Natural motion", "Кинематика", "Natural acceleration and deceleration, coherent momentum, realistic cloth and hair motion, consistent temporal movement.", "wan"),
            t("wan-light", "Cinematic video light", "Освещение", "cinematic lighting remains temporally consistent as the camera and subject move, realistic highlights and shadows", "wan"),
            t("wan-shot", "Wide establishing shot", "Ракурс", "wide establishing shot, clear foreground-midground-background separation, cinematic composition", "wan"),
            t("wan-style", "Live-action cinema", "Стиль", "live-action cinematic look, realistic texture, natural motion blur, filmic contrast, coherent frames", "wan")
        ]

        let zimage = [
            t("z-subject", "Detailed subject", "Сцена", "A detailed natural-language description of the main subject, appearance, clothing, expression, and surroundings.", "zimage"),
            t("z-skin", "Realistic skin", "Кожа", "realistic skin with fine pores, subtle imperfections, natural specular highlights and lifelike texture", "zimage"),
            t("z-face", "Portrait face", "Лицо", "precise facial details, natural eyes and teeth, fine hair strands, coherent facial anatomy", "zimage"),
            t("z-light", "Studio softbox", "Освещение", "soft studio lighting with a large diffused key light, gentle fill, realistic skin highlights", "zimage"),
            t("z-camera", "Full camera description", "Камера", "professional photography, 50mm lens, f/2.8, shallow depth of field, natural exposure, realistic lens rendering", "zimage"),
            t("z-angle", "Eye level", "Ракурс", "eye-level camera angle, balanced composition, natural perspective", "zimage"),
            t("z-detail", "Micro detail", "Детали", "fine material texture, realistic fabric fibers, skin micro-detail, physically plausible reflections", "zimage"),
            t("z-style", "Editorial photo", "Стиль", "premium editorial photography, natural color grading, clean composition, photorealistic finish", "zimage")
        ]

        let genericVideo = [
            t("v-action", "Action", "Экшен", "clear continuous action, natural body movement, readable motion progression", "video"),
            t("v-camera", "Camera motion", "Камера", "smooth controlled camera movement, stable framing, cinematic pacing", "video"),
            t("v-kinematics", "Motion dynamics", "Кинематика", "realistic momentum, coherent acceleration and deceleration, natural secondary motion", "video"),
            t("v-light", "Temporal lighting", "Освещение", "consistent lighting across frames, physically plausible moving highlights and shadows", "video")
        ]

        if profile == "wan" { return wan + commonImage.filter { ["Освещение", "Камера", "Ракурс", "Стиль"].contains($0.category) } }
        if profile == "zimage" { return zimage + commonImage }
        if mediaType == "video" { return genericVideo + commonImage.filter { ["Камера", "Освещение", "Ракурс", "Стиль"].contains($0.category) } }
        return commonImage
    }

    static func custom(profile: String) -> [ComfyPromptTemplate] {
        guard let data = UserDefaults.standard.data(forKey: "pcremote.comfy.templates.\(profile)"),
              let values = try? JSONDecoder().decode([ComfyPromptTemplate].self, from: data) else { return [] }
        return values
    }

    static func saveCustom(_ item: ComfyPromptTemplate, profile: String) {
        var values = custom(profile: profile)
        values.insert(item, at: 0)
        if let data = try? JSONEncoder().encode(Array(values.prefix(100))) {
            UserDefaults.standard.set(data, forKey: "pcremote.comfy.templates.\(profile)")
        }
    }
}

private struct ComfyPromptTemplatesView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let mediaType: String
    @Binding var prompt: String
    @State private var search = ""
    @State private var selectedCategory = "Все"

    private var allTemplates: [ComfyPromptTemplate] {
        ComfyPromptTemplateLibrary.custom(profile: profile) + ComfyPromptTemplateLibrary.builtIns(profile: profile, mediaType: mediaType)
    }

    private var categories: [String] {
        ["Все", "Мои"] + Array(Set(allTemplates.map(\.category))).sorted()
    }

    private var filtered: [ComfyPromptTemplate] {
        allTemplates.filter { item in
            let categoryOK = selectedCategory == "Все" || (selectedCategory == "Мои" ? item.custom : item.category == selectedCategory)
            let searchOK = search.isEmpty || item.title.localizedCaseInsensitiveContains(search) || item.text.localizedCaseInsensitiveContains(search)
            return categoryOK && searchOK
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                VStack(spacing: 12) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.white.opacity(0.45))
                        TextField("Поиск шаблонов", text: $search)
                            .foregroundStyle(.white)
                            .textInputAutocapitalization(.never)
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(categories, id: \.self) { category in
                                Button { selectedCategory = category } label: {
                                    Text(category)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 8)
                                        .background(selectedCategory == category ? Color.blue.opacity(0.72) : Color.white.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }

                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 9) {
                            ForEach(filtered) { item in
                                Button {
                                    let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                                    prompt = clean.isEmpty ? item.text : clean + ", " + item.text
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(item.title)
                                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                            Spacer()
                                            Text(item.custom ? "Мой" : item.category)
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.cyan)
                                        }
                                        Text(item.text)
                                            .font(.system(size: 11.5, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .multilineTextAlignment(.leading)
                                            .lineLimit(4)
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(13)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 24)
                    }
                }
                .padding(.top, 8)
            }
            .navigationTitle(profile == "wan" ? "Templates · WAN" : (profile == "zimage" ? "Templates · Z-Image" : "Templates"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

private struct ComfySaveTemplateView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: String
    let initialText: String
    @State private var name = ""
    @State private var category = "Мои"
    @State private var text: String

    init(profile: String, initialText: String) {
        self.profile = profile
        self.initialText = initialText
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Шаблон") {
                    TextField("Название", text: $name)
                    TextField("Категория", text: $category)
                    TextEditor(text: $text).frame(minHeight: 150)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ComfyBackground())
            .navigationTitle("Новый template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        let item = ComfyPromptTemplate(
                            id: UUID().uuidString,
                            title: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Мой шаблон" : name,
                            category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Мои" : category,
                            text: text,
                            profile: profile,
                            custom: true
                        )
                        ComfyPromptTemplateLibrary.saveCustom(item, profile: profile)
                        dismiss()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct ComfyAdvancedItem: Codable, Identifiable, Hashable {
    var id: String
    var nodeID: String
    var inputName: String
    var secondInputName: String?
    var label: String
    var kind: String
}

private enum ComfyAdvancedStore {
    static func key(_ workflowID: String) -> String { "pcremote.comfy.advanced.\(workflowID)" }

    static func load(_ workflowID: String) -> [ComfyAdvancedItem]? {
        guard let data = UserDefaults.standard.data(forKey: key(workflowID)) else { return nil }
        return try? JSONDecoder().decode([ComfyAdvancedItem].self, from: data)
    }

    static func save(_ items: [ComfyAdvancedItem], workflowID: String) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key(workflowID))
        }
    }
}

private struct ComfyAdvancedPanel: View {
    let device: SavedDevice
    let workflowID: String
    @State private var expanded = false
    @State private var nodes: [ComfyNodeInfo] = []
    @State private var items: [ComfyAdvancedItem] = []
    @State private var loading = false
    @State private var showPicker = false
    @State private var renameItem: ComfyAdvancedItem?
    @State private var error = ""

    private let client: APIClient

    init(device: SavedDevice, workflowID: String) {
        self.device = device
        self.workflowID = workflowID
        self.client = APIClient(device: device)
    }

    var body: some View {
        VStack(spacing: 9) {
            Button {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) { expanded.toggle() }
                if expanded && nodes.isEmpty { Task { await load() } }
            } label: {
                HStack {
                    Label("Advanced", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Spacer()
                    Text(items.isEmpty ? "" : "\(items.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.45))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if expanded {
                ComfyGlassCard {
                    VStack(spacing: 10) {
                        if loading {
                            ProgressView().tint(.white).padding(.vertical, 20)
                        } else {
                            ForEach(items) { item in
                                advancedRow(item)
                            }

                            Button { showPicker = true } label: {
                                Label("Добавить параметр", systemImage: "plus")
                                    .font(.system(size: 13, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                        if !error.isEmpty {
                            Text(error)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPicker) {
            ComfyAdvancedPicker(nodes: nodes) { selection in
                add(selection)
                showPicker = false
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $renameItem) { item in
            ComfyRenameAdvancedView(initialName: item.label) { newName in
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].label = newName
                    persistItems()
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func advancedRow(_ item: ComfyAdvancedItem) -> some View {
        if item.kind == "size" {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(sizeText(item))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Menu {
                    Button("1:1 · 1024×1024") { setSize(item, width: 1024, height: 1024) }
                    Button("4:3 · 1152×864") { setSize(item, width: 1152, height: 864) }
                    Button("3:4 · 864×1152") { setSize(item, width: 864, height: 1152) }
                    Button("16:9 · 1344×768") { setSize(item, width: 1344, height: 768) }
                    Button("9:16 · 768×1344") { setSize(item, width: 768, height: 1344) }
                } label: {
                    Label("Ratio", systemImage: "aspectratio")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                rowMenu(item)
            }
            .padding(11)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                    Text(nodeTitle(item.nodeID))
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.55))
                }
                .frame(width: 86, alignment: .leading)

                if let input = input(for: item), let options = input.options, !options.isEmpty {
                    Menu {
                        ForEach(options.prefix(200), id: \.self) { option in
                            Button(option) { setValue(item, option) }
                        }
                    } label: {
                        HStack {
                            Text(input.value.isEmpty ? "—" : input.value)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    TextField("Значение", text: valueBinding(item))
                        .keyboardType(input(for: item).map { ($0.valueType == "int" || $0.valueType == "float") ? .numbersAndPunctuation : .default } ?? .default)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .onSubmit { commit(item) }
                }

                rowMenu(item)
            }
            .padding(10)
            .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func rowMenu(_ item: ComfyAdvancedItem) -> some View {
        Menu {
            Button { renameItem = item } label: { Label("Переименовать", systemImage: "pencil") }
            if let index = items.firstIndex(of: item), index > 0 {
                Button { move(item, offset: -1) } label: { Label("Выше", systemImage: "arrow.up") }
            }
            if let index = items.firstIndex(of: item), index < items.count - 1 {
                Button { move(item, offset: 1) } label: { Label("Ниже", systemImage: "arrow.down") }
            }
            Button(role: .destructive) { remove(item) } label: { Label("Убрать из Advanced", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.50))
        }
    }

    @MainActor
    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let details = try await client.comfyWorkflowDetails(workflowID: workflowID)
            nodes = details.nodes
            if let saved = ComfyAdvancedStore.load(workflowID), !saved.isEmpty {
                items = saved.filter { item in nodes.contains(where: { $0.id == item.nodeID }) }
            } else {
                items = defaults(from: nodes)
                persistItems()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func defaults(from nodes: [ComfyNodeInfo]) -> [ComfyAdvancedItem] {
        var result: [ComfyAdvancedItem] = []
        if let pair = findInput(named: "steps", in: nodes) {
            result.append(.init(id: UUID().uuidString, nodeID: pair.0.id, inputName: pair.1.name, secondInputName: nil, label: "Steps", kind: "value"))
        }
        if let pair = findInput(named: "seed", in: nodes) ?? findInput(named: "noise_seed", in: nodes) {
            result.append(.init(id: UUID().uuidString, nodeID: pair.0.id, inputName: pair.1.name, secondInputName: nil, label: "Seed", kind: "value"))
        }
        if let sizeNode = nodes.first(where: { node in
            node.inputs.contains(where: { $0.name.lowercased() == "width" }) && node.inputs.contains(where: { $0.name.lowercased() == "height" })
        }) {
            result.append(.init(id: UUID().uuidString, nodeID: sizeNode.id, inputName: "width", secondInputName: "height", label: "Size", kind: "size"))
        }
        return result
    }

    private func findInput(named name: String, in nodes: [ComfyNodeInfo]) -> (ComfyNodeInfo, ComfyNodeInput)? {
        for node in nodes {
            if let input = node.inputs.first(where: { $0.name.lowercased() == name.lowercased() && !$0.isConnection }) {
                return (node, input)
            }
        }
        return nil
    }

    private func add(_ selection: ComfyAdvancedSelection) {
        let item = ComfyAdvancedItem(
            id: UUID().uuidString,
            nodeID: selection.node.id,
            inputName: selection.input.name,
            secondInputName: selection.secondInput?.name,
            label: selection.label,
            kind: selection.secondInput == nil ? "value" : "size"
        )
        guard !items.contains(where: { $0.nodeID == item.nodeID && $0.inputName == item.inputName && $0.secondInputName == item.secondInputName }) else { return }
        items.append(item)
        persistItems()
    }

    private func remove(_ item: ComfyAdvancedItem) {
        items.removeAll { $0.id == item.id }
        persistItems()
    }

    private func move(_ item: ComfyAdvancedItem, offset: Int) {
        guard let old = items.firstIndex(of: item) else { return }
        let new = max(0, min(items.count - 1, old + offset))
        guard old != new else { return }
        let value = items.remove(at: old)
        items.insert(value, at: new)
        persistItems()
    }

    private func persistItems() { ComfyAdvancedStore.save(items, workflowID: workflowID) }

    private func nodeTitle(_ id: String) -> String { nodes.first(where: { $0.id == id })?.title ?? "Node \(id)" }

    private func input(for item: ComfyAdvancedItem) -> ComfyNodeInput? {
        nodes.first(where: { $0.id == item.nodeID })?.inputs.first(where: { $0.name == item.inputName })
    }

    private func valueBinding(_ item: ComfyAdvancedItem) -> Binding<String> {
        Binding(
            get: { input(for: item)?.value ?? "" },
            set: { newValue in
                guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }),
                      let ii = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) else { return }
                nodes[ni].inputs[ii].value = newValue
            }
        )
    }

    private func setValue(_ item: ComfyAdvancedItem, _ value: String) {
        guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }),
              let ii = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) else { return }
        nodes[ni].inputs[ii].value = value
        commit(item)
    }

    private func commit(_ item: ComfyAdvancedItem) {
        guard let node = nodes.first(where: { $0.id == item.nodeID }) else { return }
        Task {
            do { try await client.comfyUpdateNode(workflowID: workflowID, node: node) }
            catch { await MainActor.run { self.error = error.localizedDescription } }
        }
    }

    private func sizeText(_ item: ComfyAdvancedItem) -> String {
        guard let node = nodes.first(where: { $0.id == item.nodeID }) else { return "—" }
        let w = node.inputs.first(where: { $0.name == item.inputName })?.value ?? "?"
        let h = node.inputs.first(where: { $0.name == item.secondInputName })?.value ?? "?"
        return "\(w) × \(h)"
    }

    private func setSize(_ item: ComfyAdvancedItem, width: Int, height: Int) {
        guard let ni = nodes.firstIndex(where: { $0.id == item.nodeID }) else { return }
        if let wi = nodes[ni].inputs.firstIndex(where: { $0.name == item.inputName }) { nodes[ni].inputs[wi].value = "\(width)" }
        if let second = item.secondInputName, let hi = nodes[ni].inputs.firstIndex(where: { $0.name == second }) { nodes[ni].inputs[hi].value = "\(height)" }
        commit(item)
    }
}

private struct ComfyAdvancedSelection {
    let node: ComfyNodeInfo
    let input: ComfyNodeInput
    let secondInput: ComfyNodeInput?
    let label: String
}

private struct ComfyAdvancedPicker: View {
    @Environment(\.dismiss) private var dismiss
    let nodes: [ComfyNodeInfo]
    let onSelect: (ComfyAdvancedSelection) -> Void
    @State private var search = ""

    private var filteredNodes: [ComfyNodeInfo] {
        guard !search.isEmpty else { return nodes }
        return nodes.filter { node in
            node.title.localizedCaseInsensitiveContains(search) || node.classType.localizedCaseInsensitiveContains(search) || node.inputs.contains(where: { $0.name.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredNodes) { node in
                    Section(node.title) {
                        if let width = node.inputs.first(where: { $0.name.lowercased() == "width" && !$0.isConnection }),
                           let height = node.inputs.first(where: { $0.name.lowercased() == "height" && !$0.isConnection }) {
                            Button {
                                onSelect(.init(node: node, input: width, secondInput: height, label: "Size"))
                            } label: {
                                Label("Size · width + height", systemImage: "aspectratio")
                            }
                        }
                        ForEach(node.inputs.filter { !$0.isConnection }) { input in
                            Button {
                                onSelect(.init(node: node, input: input, secondInput: nil, label: input.name.replacingOccurrences(of: "_", with: " ").capitalized))
                            } label: {
                                HStack {
                                    Text(input.name)
                                    Spacer()
                                    Text(input.value)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Нода или настройка")
            .navigationTitle("Добавить в Advanced")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }
}

private struct ComfyRenameAdvancedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let onSave: (String) -> Void

    init(initialName: String, onSave: @escaping (String) -> Void) {
        _name = State(initialValue: initialName)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form { TextField("Название", text: $name) }
                .scrollContentBackground(.hidden)
                .background(ComfyBackground())
                .navigationTitle("Переименовать")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            onSave(clean.isEmpty ? "Parameter" : clean)
                            dismiss()
                        }
                    }
                }
        }
    }
}


private struct ComfyBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.025, green: 0.035, blue: 0.075),
                        Color(red: 0.035, green: 0.055, blue: 0.13),
                        Color.black,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.blue.opacity(0.23))
                    .frame(width: proxy.size.width * 0.95)
                    .blur(radius: 70)
                    .offset(x: proxy.size.width * 0.35, y: -proxy.size.height * 0.32)
                Circle()
                    .fill(Color.purple.opacity(0.16))
                    .frame(width: proxy.size.width * 0.85)
                    .blur(radius: 80)
                    .offset(x: -proxy.size.width * 0.42, y: proxy.size.height * 0.15)
            }
            .ignoresSafeArea()
        }
    }
}

private struct ComfyGlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.065))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.11), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.20), radius: 18, y: 8)
    }
}

private struct ComfyMiniGraph: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: w * 0.17, y: h * 0.50))
                    p.addCurve(to: CGPoint(x: w * 0.49, y: h * 0.30), control1: CGPoint(x: w * 0.30, y: h * 0.50), control2: CGPoint(x: w * 0.34, y: h * 0.30))
                    p.move(to: CGPoint(x: w * 0.17, y: h * 0.50))
                    p.addCurve(to: CGPoint(x: w * 0.49, y: h * 0.72), control1: CGPoint(x: w * 0.30, y: h * 0.50), control2: CGPoint(x: w * 0.34, y: h * 0.72))
                    p.move(to: CGPoint(x: w * 0.64, y: h * 0.30))
                    p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.50), control1: CGPoint(x: w * 0.72, y: h * 0.30), control2: CGPoint(x: w * 0.74, y: h * 0.50))
                    p.move(to: CGPoint(x: w * 0.64, y: h * 0.72))
                    p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.50), control1: CGPoint(x: w * 0.72, y: h * 0.72), control2: CGPoint(x: w * 0.74, y: h * 0.50))
                }
                .stroke(Color.cyan.opacity(0.52), style: StrokeStyle(lineWidth: 2, lineCap: .round))

                graphNode("Load Model", x: 0.16, y: 0.50, tint: .purple, width: w, height: h)
                graphNode("Positive", x: 0.53, y: 0.30, tint: .green, width: w, height: h)
                graphNode("Negative", x: 0.53, y: 0.72, tint: .orange, width: w, height: h)
                graphNode("KSampler", x: 0.85, y: 0.50, tint: .blue, width: w, height: h)
            }
        }
        .background(Color.black.opacity(0.17), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func graphNode(_ title: String, x: CGFloat, y: CGFloat, tint: Color, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .position(x: width * x, y: height * y)
    }
}

private struct ComfyValueCardContent: View {
    let title: String
    let value: String
    let systemImage: String
    var trailing: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer(minLength: 3)
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct ComfyValueCard: View {
    let title: String
    let value: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ComfyValueCardContent(title: title, value: value, systemImage: systemImage, trailing: "arrow.clockwise")
        }
        .buttonStyle(.plain)
    }
}

private struct ComfyStepperCard: View {
    let title: String
    let value: String
    let systemImage: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.52))
            HStack(spacing: 7) {
                Button(action: onMinus) {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                Button(action: onPlus) {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
            }
            .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private enum ComfyWorkflowFilter: String, CaseIterable, Identifiable {
    case recent = "Недавние"
    case favorites = "Избранные"
    case all = "Все"
    var id: String { rawValue }
}

private struct ComfyWorkflowPicker: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let workflows: [ComfyWorkflow]
    let selectedID: String
    let onSelect: (ComfyWorkflow) -> Void
    let onEdit: (ComfyWorkflow) -> Void
    let onReload: () -> Void

    @State private var search = ""
    @State private var filter: ComfyWorkflowFilter = .recent
    @State private var showIPhoneImporter = false
    @State private var showPCPicker = false
    @State private var importBusy = false
    @State private var importError = ""
    @AppStorage("comfy_favorite_workflows") private var favoriteRaw = ""

    private var favoriteIDs: Set<String> {
        Set(favoriteRaw.split(separator: "\n").map(String.init))
    }

    private var selectedWorkflow: ComfyWorkflow? {
        workflows.first(where: { $0.id == selectedID })
    }

    private var filtered: [ComfyWorkflow] {
        var values: [ComfyWorkflow]
        switch filter {
        case .recent:
            values = workflows.filter(\.isRecent)
            if values.isEmpty { values = Array(workflows.prefix(8)) }
        case .favorites:
            values = workflows.filter { favoriteIDs.contains($0.id) }
        case .all:
            values = workflows
        }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            values = values.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                || $0.source.localizedCaseInsensitiveContains(query)
            }
        }
        return values
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                VStack(spacing: 12) {
                    filterBar
                        .padding(.horizontal, 14)
                        .padding(.top, 8)

                    if filtered.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(.cyan.opacity(0.85))
                            Text(filter == .favorites ? "Нет избранных workflow" : "Workflow не найдены")
                                .font(.system(size: 18, weight: .bold, design: .rounded))
                            Text(filter == .favorites ? "Добавьте workflow в избранное звездой." : "Нажмите +, чтобы импортировать workflow с ПК или iPhone.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.52))
                                .multilineTextAlignment(.center)
                        }
                        .foregroundStyle(.white)
                        .padding(28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 10) {
                                ForEach(filtered) { workflow in
                                    workflowRow(workflow)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 24)
                        }
                    }

                    if !importError.isEmpty {
                        Text(importError)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 8)
                    }
                }
            }
            .navigationTitle("Workflows")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Найти workflow")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Готово") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            showPCPicker = true
                        } label: {
                            Label("Импорт с ПК", systemImage: "desktopcomputer")
                        }
                        Button {
                            showIPhoneImporter = true
                        } label: {
                            Label("Импорт с iPhone", systemImage: "iphone")
                        }
                    } label: {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.20))
                            if importBusy {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "plus")
                                    .font(.system(size: 17, weight: .bold))
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .disabled(importBusy)
                }
            }
        }
        .fileImporter(
            isPresented: $showIPhoneImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importFromIPhone(url)
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showPCPicker) {
            ComfyPCWorkflowPicker(device: device) { path in
                showPCPicker = false
                importFromPC(path)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(ComfyWorkflowFilter.allCases) { item in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { filter = item }
                } label: {
                    Text(item.rawValue)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(
                            filter == item ? Color.blue.opacity(0.75) : Color.white.opacity(0.07),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button {
                if let selectedWorkflow { onEdit(selectedWorkflow) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Изменить")
                }
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selectedWorkflow == nil)
            .opacity(selectedWorkflow == nil ? 0.4 : 1)
        }
        .foregroundStyle(.white)
    }

    private func workflowRow(_ workflow: ComfyWorkflow) -> some View {
        HStack(spacing: 12) {
            Button {
                onSelect(workflow)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: workflow.isRecent ? [.cyan.opacity(0.82), .blue.opacity(0.86)] : [.blue.opacity(0.82), .purple.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 50, height: 50)
                        Image(systemName: "circle.hexagongrid.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(workflow.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text("\(workflow.nodeCount) нод")
                            Text("•")
                            Text(workflow.source)
                                .lineLimit(1)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        if !workflow.canExecute {
                            Label("Редактор доступен • для запуска нужен API-format", systemImage: "info.circle")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.orange.opacity(0.9))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if workflow.id == selectedID {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.cyan)
                    }
                }
            }
            .buttonStyle(.plain)

            VStack(spacing: 7) {
                Button {
                    toggleFavorite(workflow.id)
                } label: {
                    Image(systemName: favoriteIDs.contains(workflow.id) ? "star.fill" : "star")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(favoriteIDs.contains(workflow.id) ? .yellow : .white.opacity(0.58))
                }
                .buttonStyle(.plain)

                Button {
                    onEdit(workflow)
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 30)
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 1))
    }

    private func toggleFavorite(_ id: String) {
        var values = favoriteIDs
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
        favoriteRaw = values.sorted().joined(separator: "\n")
    }

    private func importFromPC(_ path: String) {
        importBusy = true
        importError = ""
        Task {
            defer { importBusy = false }
            do {
                _ = try await APIClient(device: device).comfyImportWorkflowFromPC(path: path)
                onReload()
                filter = .all
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func importFromIPhone(_ url: URL) {
        importBusy = true
        importError = ""
        Task {
            defer { importBusy = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try await APIClient(device: device).comfyImportWorkflowFromIPhone(filename: url.lastPathComponent, data: data)
                onReload()
                filter = .all
            } catch {
                importError = error.localizedDescription
            }
        }
    }
}

private struct ComfyPCWorkflowPicker: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let onPick: (String) -> Void
    @State private var roots: [FileItem] = []
    @State private var error = ""

    var body: some View {
        NavigationStack {
            List(roots) { item in
                NavigationLink(value: item) {
                    Label(item.name, systemImage: item.icon == "drive" ? "externaldrive.fill" : "folder.fill")
                }
            }
            .navigationTitle("Workflow с ПК")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FileItem.self) { item in
                ComfyPCWorkflowFolder(device: device, folder: item, onPick: { path in
                    onPick(path)
                    dismiss()
                })
            }
            .overlay {
                if roots.isEmpty && error.isEmpty { ProgressView() }
            }
            .safeAreaInset(edge: .bottom) {
                if !error.isEmpty {
                    Text(error)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task {
                do { roots = try await APIClient(device: device).roots() }
                catch { self.error = error.localizedDescription }
            }
        }
    }
}

private struct ComfyPCWorkflowFolder: View {
    let device: SavedDevice
    let folder: FileItem
    let onPick: (String) -> Void
    @State private var items: [FileItem] = []
    @State private var error = ""

    private var visibleItems: [FileItem] {
        items.filter { $0.isFolder || URL(fileURLWithPath: $0.name).pathExtension.lowercased() == "json" }
    }

    var body: some View {
        List(visibleItems) { item in
            if item.isFolder {
                NavigationLink(value: item) {
                    Label(item.name, systemImage: "folder.fill")
                }
            } else {
                Button {
                    onPick(item.path)
                } label: {
                    HStack {
                        Label(item.name, systemImage: "doc.text.fill")
                        Spacer()
                        Text("JSON")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FileItem.self) { item in
            ComfyPCWorkflowFolder(device: device, folder: item, onPick: onPick)
        }
        .overlay { if items.isEmpty && error.isEmpty { ProgressView() } }
        .safeAreaInset(edge: .bottom) {
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
        }
        .task(id: folder.path) {
            do { items = try await APIClient(device: device).list(path: folder.path) }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor
private final class ComfyNodeEditorModel: ObservableObject {
    struct Snapshot {
        let nodes: [ComfyNodeInfo]
        let connections: [ComfyNodeConnection]
    }

    @Published var nodes: [ComfyNodeInfo] = []
    @Published var connections: [ComfyNodeConnection] = []
    @Published var loading = true
    @Published var error = ""
    @Published var executable = false
    @Published var format = ""
    @Published var catalog: [ComfyNodeCatalogItem] = []

    let device: SavedDevice
    let workflow: ComfyWorkflow
    private let client: APIClient
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(device: SavedDevice, workflow: ComfyWorkflow) {
        self.device = device
        self.workflow = workflow
        self.client = APIClient(device: device)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let value = try await client.comfyWorkflowDetails(workflowID: workflow.id)
            nodes = value.nodes
            connections = value.connections
            executable = value.executable
            format = value.format
            error = value.error ?? ""
            if catalog.isEmpty {
                catalog = (try? await client.comfyNodeCatalog())?.nodes ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshGraph() async {
        do {
            let value = try await client.comfyWorkflowDetails(workflowID: workflow.id)
            nodes = value.nodes
            connections = value.connections
            executable = value.executable
            format = value.format
        } catch {
            self.error = error.localizedDescription
        }
    }

    func updatePositionLive(nodeID: String, x: Double, y: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[idx].position_x = max(20, x)
        nodes[idx].position_y = max(20, y)
    }

    func commitPosition(nodeID: String, original: ComfyNodeInfo) async {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
        pushUndo(replacingCurrentNodeWith: original)
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func updateSizeLive(nodeID: String, width: Double, height: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[idx].node_width = min(520, max(170, width))
        nodes[idx].node_height = min(520, max(125, height))
    }

    func commitSize(nodeID: String, original: ComfyNodeInfo) async {
        guard let node = nodes.first(where: { $0.id == nodeID }) else { return }
        pushUndo(replacingCurrentNodeWith: original)
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func update(_ node: ComfyNodeInfo) async {
        guard let idx = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        let old = nodes[idx]
        pushUndo(replacingCurrentNodeWith: old)
        nodes[idx] = node
        do { try await client.comfyUpdateNode(workflowID: workflow.id, node: node) }
        catch { self.error = error.localizedDescription }
    }

    func addNode(_ item: ComfyNodeCatalogItem, at point: CGPoint) async {
        do {
            _ = try await client.comfyAddNode(
                workflowID: workflow.id,
                classType: item.classType,
                x: Double(point.x),
                y: Double(point.y)
            )
            redoStack.removeAll()
            await refreshGraph()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func deleteNode(_ node: ComfyNodeInfo) async {
        do {
            try await client.comfyDeleteNode(workflowID: workflow.id, nodeID: node.id)
            undoStack.removeAll()
            redoStack.removeAll()
            await refreshGraph()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func connect(from node: ComfyNodeInfo, output: ComfyNodePort, to target: ComfyNodeInfo, input: ComfyNodeInput) async -> Bool {
        let before = Snapshot(nodes: nodes, connections: connections)
        do {
            try await client.comfyConnectNodes(
                workflowID: workflow.id,
                fromNode: node.id,
                fromSlot: output.slot,
                toNode: target.id,
                toInput: input.name,
                toSlot: input.slot ?? 0
            )
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
            await refreshGraph()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func disconnect(target: ComfyNodeInfo, input: ComfyNodeInput) async -> Bool {
        guard input.connectedFrom != nil else { return false }
        let before = Snapshot(nodes: nodes, connections: connections)
        do {
            try await client.comfyDisconnectNodes(workflowID: workflow.id, toNode: target.id, toInput: input.name)
            undoStack.append(before)
            if undoStack.count > 80 { undoStack.removeFirst() }
            redoStack.removeAll()
            await refreshGraph()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func undo() async -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        let current = Snapshot(nodes: nodes, connections: connections)
        redoStack.append(current)
        await applySnapshot(previous, from: current)
        return true
    }

    func redo() async -> Bool {
        guard let next = redoStack.popLast() else { return false }
        let current = Snapshot(nodes: nodes, connections: connections)
        undoStack.append(current)
        await applySnapshot(next, from: current)
        return true
    }

    private func pushUndo(replacingCurrentNodeWith oldNode: ComfyNodeInfo) {
        var previousNodes = nodes
        if let idx = previousNodes.firstIndex(where: { $0.id == oldNode.id }) {
            previousNodes[idx] = oldNode
        }
        undoStack.append(Snapshot(nodes: previousNodes, connections: connections))
        if undoStack.count > 80 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func applySnapshot(_ target: Snapshot, from current: Snapshot) async {
        nodes = target.nodes
        connections = target.connections
        do {
            for node in target.nodes {
                try await client.comfyUpdateNode(workflowID: workflow.id, node: node)
            }

            let currentIDs = Set(current.connections.map(\.id))
            let targetIDs = Set(target.connections.map(\.id))

            for connection in current.connections where !targetIDs.contains(connection.id) {
                if let inputName = connection.inputName {
                    try? await client.comfyDisconnectNodes(workflowID: workflow.id, toNode: connection.to, toInput: inputName)
                }
            }
            for connection in target.connections where !currentIDs.contains(connection.id) {
                guard let inputName = connection.inputName else { continue }
                try? await client.comfyConnectNodes(
                    workflowID: workflow.id,
                    fromNode: connection.from,
                    fromSlot: connection.fromSlot,
                    toNode: connection.to,
                    toInput: inputName,
                    toSlot: connection.toSlot
                )
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ComfyConnectorDraft {
    let nodeID: String
    let port: ComfyNodePort
    var current: CGPoint
}

private struct ComfyNodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: ComfyNodeEditorModel
    @State private var focusedNode: ComfyNodeInfo?
    @State private var showNodeBrowser = false
    @State private var connectorDraft: ComfyConnectorDraft?
    @State private var zoom: CGFloat = 1.0
    @State private var lastZoom: CGFloat = 1.0
    @State private var gestureToast = ""

    private let baseCanvasWidth: CGFloat = 2400
    private let baseCanvasHeight: CGFloat = 3200

    init(device: SavedDevice, workflow: ComfyWorkflow) {
        _model = StateObject(wrappedValue: ComfyNodeEditorModel(device: device, workflow: workflow))
    }

    private var canvasWidth: CGFloat {
        max(baseCanvasWidth, CGFloat(model.nodes.map { $0.positionX + $0.nodeWidth + 300 }.max() ?? Double(baseCanvasWidth)))
    }

    private var canvasHeight: CGFloat {
        max(baseCanvasHeight, CGFloat(model.nodes.map { $0.positionY + $0.nodeHeight + 400 }.max() ?? Double(baseCanvasHeight)))
    }

    var body: some View {
        ZStack {
            ComfyBackground()

            if model.loading {
                ProgressView("Загружаем ноды…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 8) {
                    editorHeader
                        .padding(.horizontal, 12)
                        .padding(.top, 6)

                    GeometryReader { viewport in
                        ScrollViewReader { proxy in
                            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                                ZStack(alignment: .topLeading) {
                                    nodeCanvas
                                        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                                        .scaleEffect(zoom, anchor: .topLeading)

                                    Color.clear
                                        .frame(width: 1, height: 1)
                                        .position(x: fitCenter.x * zoom, y: fitCenter.y * zoom)
                                        .id("fit-all-center")
                                }
                                .frame(width: canvasWidth * zoom, height: canvasHeight * zoom, alignment: .topLeading)
                            }
                            .background(Color.black.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .simultaneousGesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        zoom = min(1.8, max(0.18, lastZoom * value))
                                    }
                                    .onEnded { _ in lastZoom = zoom }
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Button { fitAllNodes(viewport: viewport.size, proxy: proxy) } label: {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 48, height: 48)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
                                        .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Показать все ноды")
                                .padding(14)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }

            if let focusedNode {
                Color.black.opacity(0.66)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { withAnimation(.spring()) { self.focusedNode = nil } }

                VStack(spacing: 8) {
                    ComfyNodeInspector(node: focusedNode) { saved in
                        Task { await model.update(saved) }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { self.focusedNode = nil }
                    } onCancel: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { self.focusedNode = nil }
                    }
                    Button(role: .destructive) {
                        let deleting = focusedNode
                        self.focusedNode = nil
                        Task { await model.deleteNode(deleting) }
                    } label: {
                        Label("Удалить ноду", systemImage: "trash")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.red.opacity(0.15), in: Capsule())
                    }
                }
                .padding(.horizontal, 18)
                .transition(.scale(scale: 0.78).combined(with: .opacity))
                .zIndex(5)
            }

            if !gestureToast.isEmpty {
                Text(gestureToast)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(8)
            }
        }
        .preferredColorScheme(.dark)
        .background(
            ComfyUndoRedoGestureLayer(
                onUndo: { Task { await performUndo() } },
                onRedo: { Task { await performRedo() } }
            )
            .frame(width: 0, height: 0)
        )
        .sheet(isPresented: $showNodeBrowser) {
            ComfyNodeBrowser(nodes: model.catalog) { item in
                showNodeBrowser = false
                let point = CGPoint(x: 420 / zoom + 140, y: 320 / zoom + 140)
                Task { await model.addNode(item, at: point) }
            }
            .preferredColorScheme(.dark)
        }
        .task { await model.load() }
    }

    private var editorHeader: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.workflow.name)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .lineLimit(1)
                Text("Свободная схема • \(model.nodes.count) нод • \(Int(zoom * 100))%")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { Task { await performUndo() } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(model.canUndo ? 1 : 0.35)

            Button { Task { await performRedo() } } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(model.canRedo ? 1 : 0.35)

            Button { showNodeBrowser = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.84)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .overlay(alignment: .bottomLeading) {
            if !model.error.isEmpty {
                Text(model.error)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.orange)
                    .offset(y: 15)
            }
        }
    }

    private var nodeCanvas: some View {
        ZStack(alignment: .topLeading) {
            ComfyFreeConnectorLayer(nodes: model.nodes, connections: model.connections, draft: connectorDraft)
                .frame(width: canvasWidth, height: canvasHeight)
                .allowsHitTesting(false)

            ForEach(model.nodes) { node in
                ComfyFreeNodeCard(
                    node: node,
                    canvasZoom: zoom,
                    activeConnectorType: connectorDraft?.port.type,
                    onExpand: {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) { focusedNode = node }
                    },
                    onMove: { point in
                        model.updatePositionLive(nodeID: node.id, x: Double(point.x), y: Double(point.y))
                    },
                    onMoveEnd: { original in
                        Task { await model.commitPosition(nodeID: node.id, original: original) }
                    },
                    onResize: { width, height in
                        model.updateSizeLive(nodeID: node.id, width: Double(width), height: Double(height))
                    },
                    onResizeEnd: { original in
                        Task { await model.commitSize(nodeID: node.id, original: original) }
                    },
                    onOutputDrag: { port, location in
                        connectorDraft = ComfyConnectorDraft(nodeID: node.id, port: port, current: location)
                    },
                    onOutputEnd: { port, location in
                        connectNearest(from: node, port: port, at: location)
                        connectorDraft = nil
                    },
                    onInputTap: { input in
                        ComfyHaptics.connectorTap()
                        if input.connectedFrom != nil {
                            Task { _ = await model.disconnect(target: node, input: input) }
                        }
                    }
                )
                .frame(width: CGFloat(node.nodeWidth), height: CGFloat(node.nodeHeight))
                .position(
                    x: CGFloat(node.positionX + node.nodeWidth / 2),
                    y: CGFloat(node.positionY + node.nodeHeight / 2)
                )
            }
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
        .coordinateSpace(name: "FreeNodeCanvas")
        .background(
            Canvas { context, size in
                let step: CGFloat = 28
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(path, with: .color(.white.opacity(0.025)), lineWidth: 0.7)
            }
        )
    }

    private func connectNearest(from source: ComfyNodeInfo, port: ComfyNodePort, at location: CGPoint) {
        var best: (ComfyNodeInfo, ComfyNodeInput, CGFloat)?
        for node in model.nodes where node.id != source.id {
            for (index, input) in node.inputs.enumerated() where ComfyNodeGeometry.isConnectorInput(input) {
                guard ComfyNodeGeometry.compatible(outputType: port.type, inputType: input.inputType) else { continue }
                let point = ComfyNodeGeometry.inputPoint(node: node, inputIndex: index)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance < 72, best == nil || distance < best!.2 {
                    best = (node, input, distance)
                }
            }
        }
        guard let best else { return }
        Task {
            if await model.connect(from: source, output: port, to: best.0, input: best.1) {
                ComfyHaptics.connected()
            } else {
                ComfyHaptics.connectorMiss()
            }
        }
    }

    private var nodeBounds: CGRect {
        guard let first = model.nodes.first else { return CGRect(x: 0, y: 0, width: 800, height: 600) }
        var minX = CGFloat(first.positionX)
        var minY = CGFloat(first.positionY)
        var maxX = CGFloat(first.positionX + first.nodeWidth)
        var maxY = CGFloat(first.positionY + first.nodeHeight)
        for node in model.nodes.dropFirst() {
            minX = min(minX, CGFloat(node.positionX))
            minY = min(minY, CGFloat(node.positionY))
            maxX = max(maxX, CGFloat(node.positionX + node.nodeWidth))
            maxY = max(maxY, CGFloat(node.positionY + node.nodeHeight))
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY)).insetBy(dx: -90, dy: -90)
    }

    private var fitCenter: CGPoint {
        CGPoint(x: nodeBounds.midX, y: nodeBounds.midY)
    }

    private func fitAllNodes(viewport: CGSize, proxy: ScrollViewProxy) {
        guard !model.nodes.isEmpty else { return }
        let bounds = nodeBounds
        let availableWidth = max(120, viewport.width - 34)
        let availableHeight = max(120, viewport.height - 34)
        let target = min(1.25, max(0.18, min(availableWidth / bounds.width, availableHeight / bounds.height)))
        ComfyHaptics.connectorTap()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            zoom = target
            lastZoom = target
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                proxy.scrollTo("fit-all-center", anchor: .center)
            }
        }
    }

    private func performUndo() async {
        if await model.undo() { showToast("↶ Отменено") }
    }

    private func performRedo() async {
        if await model.redo() { showToast("↷ Возвращено") }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring()) { gestureToast = text }
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            await MainActor.run { withAnimation(.easeOut(duration: 0.18)) { gestureToast = "" } }
        }
    }
}

@MainActor
private enum ComfyHaptics {
    static func connectorTap() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func nodePickedUp() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred(intensity: 0.78)
    }

    static func connected() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }

    static func connectorMiss() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.45)
    }
}

private enum ComfyNodeGeometry {
    static func isConnectorInput(_ input: ComfyNodeInput) -> Bool {
        let type = input.inputType.uppercased()
        return input.isConnection || !["INT", "FLOAT", "STRING", "BOOLEAN", "COMBO", "ENUM"].contains(type)
    }

    static func compatible(outputType: String, inputType: String) -> Bool {
        let out = outputType.uppercased()
        let input = inputType.uppercased()
        return out == input || out == "*" || input == "*" || input == "ANY" || out == "ANY"
    }

    static func inputPoint(node: ComfyNodeInfo, inputIndex: Int) -> CGPoint {
        CGPoint(x: CGFloat(node.positionX + 8), y: CGFloat(node.positionY + 72 + Double(inputIndex) * 28))
    }

    static func outputPoint(node: ComfyNodeInfo, outputIndex: Int) -> CGPoint {
        CGPoint(x: CGFloat(node.positionX + node.nodeWidth - 8), y: CGFloat(node.positionY + 72 + Double(outputIndex) * 28))
    }

    static func color(for type: String?) -> Color {
        let value = (type ?? "").uppercased()
        if value.contains("MODEL") { return .purple }
        if value.contains("CLIP") { return .yellow }
        if value.contains("CONDITION") { return .orange }
        if value.contains("LATENT") { return .pink }
        if value.contains("IMAGE") { return .green }
        if value.contains("VAE") { return .blue }
        if value.contains("MASK") { return .red }
        return .cyan
    }
}

private struct ComfyFreeConnectorLayer: View {
    let nodes: [ComfyNodeInfo]
    let connections: [ComfyNodeConnection]
    let draft: ComfyConnectorDraft?

    var body: some View {
        Canvas { context, _ in
            for link in connections {
                guard let source = nodes.first(where: { $0.id == link.from }),
                      let target = nodes.first(where: { $0.id == link.to }) else { continue }
                let start = ComfyNodeGeometry.outputPoint(node: source, outputIndex: link.fromSlot)
                let targetIndex = target.inputs.firstIndex(where: { $0.name == link.inputName }) ?? link.toSlot
                let end = ComfyNodeGeometry.inputPoint(node: target, inputIndex: targetIndex)
                drawConnection(context: context, start: start, end: end, color: ComfyNodeGeometry.color(for: link.type ?? link.label))
            }

            if let draft, let source = nodes.first(where: { $0.id == draft.nodeID }) {
                let start = ComfyNodeGeometry.outputPoint(node: source, outputIndex: draft.port.slot)
                drawConnection(context: context, start: start, end: draft.current, color: ComfyNodeGeometry.color(for: draft.port.type), dashed: true)
            }
        }
    }

    private func drawConnection(context: GraphicsContext, start: CGPoint, end: CGPoint, color: Color, dashed: Bool = false) {
        let dx = max(60, abs(end.x - start.x) * 0.45)
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + dx, y: start.y),
            control2: CGPoint(x: end.x - dx, y: end.y)
        )
        context.stroke(path, with: .color(color.opacity(0.16)), style: StrokeStyle(lineWidth: 8, lineCap: .round, dash: dashed ? [9, 7] : []))
        context.stroke(path, with: .color(color.opacity(0.52)), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dashed ? [9, 7] : []))
        context.stroke(path, with: .color(color.opacity(0.96)), style: StrokeStyle(lineWidth: 1.7, lineCap: .round, dash: dashed ? [9, 7] : []))
    }
}

private struct ComfyFreeNodeCard: View {
    let node: ComfyNodeInfo
    let canvasZoom: CGFloat
    let activeConnectorType: String?
    let onExpand: () -> Void
    let onMove: (CGPoint) -> Void
    let onMoveEnd: (ComfyNodeInfo) -> Void
    let onResize: (CGFloat, CGFloat) -> Void
    let onResizeEnd: (ComfyNodeInfo) -> Void
    let onOutputDrag: (ComfyNodePort, CGPoint) -> Void
    let onOutputEnd: (ComfyNodePort, CGPoint) -> Void
    let onInputTap: (ComfyNodeInput) -> Void

    @State private var moveOrigin: CGPoint?
    @State private var moveOriginalNode: ComfyNodeInfo?
    @State private var resizeOrigin: CGSize?
    @State private var resizeOriginalNode: ComfyNodeInfo?
    @State private var activeOutputPortID: String?
    @State private var isMoving = false

    private var tint: Color { Color(comfyHex: node.color) ?? .blue }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(red: 0.045, green: 0.055, blue: 0.095).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.20), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(tint.opacity(node.muted ? 0.22 : 0.58), lineWidth: 1.2))
                .shadow(color: tint.opacity(node.muted ? 0.03 : (isMoving ? 0.34 : 0.18)), radius: isMoving ? 28 : 18, y: isMoving ? 14 : 8)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(tint)
                        .frame(width: 9, height: 9)
                        .shadow(color: tint.opacity(0.95), radius: 6)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(node.classType)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.40))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Button(action: onExpand) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10.5, weight: .bold))
                            .frame(width: 29, height: 29)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().overlay(Color.white.opacity(0.07))

                ForEach(node.inputs.filter { !$0.isConnection }.prefix(3)) { input in
                    HStack(spacing: 6) {
                        Text(input.name)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.43))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(input.value.isEmpty ? "—" : input.value)
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 0)
                if node.muted {
                    Label("Muted", systemImage: "speaker.slash.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(13)

            ForEach(Array(node.inputs.enumerated()), id: \.element.id) { index, input in
                if ComfyNodeGeometry.isConnectorInput(input) {
                    Button { onInputTap(input) } label: {
                        ZStack {
                            Circle().fill(Color.clear).frame(width: 42, height: 42)
                            Circle()
                                .fill(ComfyNodeGeometry.color(for: input.inputType))
                                .frame(width: 15, height: 15)
                                .overlay(Circle().stroke(Color.white.opacity(0.82), lineWidth: input.connectedFrom == nil ? 1.0 : 2.0))
                                .shadow(color: ComfyNodeGeometry.color(for: input.inputType).opacity(0.92), radius: compatibleGlow(for: input) ? 10 : 6)
                                .scaleEffect(compatibleGlow(for: input) ? 1.18 : 1.0)
                        }
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .position(x: 8, y: CGFloat(72 + Double(index) * 28))
                }
            }

            ForEach(node.outputs ?? []) { port in
                ZStack {
                    Circle().fill(Color.clear).frame(width: 42, height: 42)
                    Circle()
                        .fill(ComfyNodeGeometry.color(for: port.type))
                        .frame(width: 15, height: 15)
                        .overlay(Circle().stroke(Color.white.opacity(0.82), lineWidth: 1.1))
                        .shadow(color: ComfyNodeGeometry.color(for: port.type).opacity(0.95), radius: activeOutputPortID == port.id ? 11 : 6)
                        .scaleEffect(activeOutputPortID == port.id ? 1.18 : 1.0)
                }
                .contentShape(Circle())
                .position(x: CGFloat(node.nodeWidth) - 8, y: CGFloat(72 + Double(port.slot) * 28))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("FreeNodeCanvas"))
                        .onChanged { value in
                            if activeOutputPortID != port.id {
                                activeOutputPortID = port.id
                                ComfyHaptics.connectorTap()
                            }
                            onOutputDrag(port, value.location)
                        }
                        .onEnded { value in
                            onOutputEnd(port, value.location)
                            activeOutputPortID = nil
                        }
                )
            }

            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.055), in: Circle())
                .position(x: CGFloat(node.nodeWidth) - 16, y: CGFloat(node.nodeHeight) - 16)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizeOrigin == nil {
                                resizeOrigin = CGSize(width: CGFloat(node.nodeWidth), height: CGFloat(node.nodeHeight))
                                resizeOriginalNode = node
                            }
                            guard let origin = resizeOrigin else { return }
                            onResize(origin.width + value.translation.width, origin.height + value.translation.height)
                        }
                        .onEnded { _ in
                            if let original = resizeOriginalNode { onResizeEnd(original) }
                            resizeOrigin = nil
                            resizeOriginalNode = nil
                        }
                )
        }
        .opacity(node.muted ? 0.56 : 1)
        .scaleEffect(isMoving ? 1.035 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.76), value: isMoving)
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .gesture(
            LongPressGesture(minimumDuration: 0.26, maximumDistance: 22)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("FreeNodeCanvas")))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag?):
                        if moveOrigin == nil {
                            moveOrigin = CGPoint(x: CGFloat(node.positionX), y: CGFloat(node.positionY))
                            moveOriginalNode = node
                            isMoving = true
                            ComfyHaptics.nodePickedUp()
                        }
                        guard let origin = moveOrigin else { return }
                        let scale = max(0.18, canvasZoom)
                        onMove(CGPoint(
                            x: origin.x + drag.translation.width / scale,
                            y: origin.y + drag.translation.height / scale
                        ))
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    if let original = moveOriginalNode { onMoveEnd(original) }
                    moveOrigin = nil
                    moveOriginalNode = nil
                    isMoving = false
                }
        )
    }

    private func compatibleGlow(for input: ComfyNodeInput) -> Bool {
        guard let activeConnectorType else { return false }
        return ComfyNodeGeometry.compatible(outputType: activeConnectorType, inputType: input.inputType)
    }
}

private struct ComfyNodeBrowser: View {
    @Environment(\.dismiss) private var dismiss
    let nodes: [ComfyNodeCatalogItem]
    let onPick: (ComfyNodeCatalogItem) -> Void
    @State private var search = ""

    private var filtered: [ComfyNodeCatalogItem] {
        let clean = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return nodes.sorted { lhs, rhs in
                if lhs.recommended != rhs.recommended { return lhs.recommended && !rhs.recommended }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
        let q = clean.lowercased()
        return nodes.filter { item in
            let hay = "\(item.displayName) \(item.classType) \(item.category)".lowercased()
            return hay.contains(q) || hay.split(separator: " ").contains(where: { $0.hasPrefix(q) })
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ComfyBackground()
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 9) {
                        if search.isEmpty {
                            HStack {
                                Label("Рекомендуемые ноды", systemImage: "sparkles")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                            }
                            .foregroundStyle(.white.opacity(0.70))
                            .padding(.horizontal, 14)
                        }
                        ForEach(filtered.prefix(160)) { item in
                            Button {
                                onPick(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                                        .fill(LinearGradient(colors: [.blue.opacity(0.78), .purple.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 48, height: 48)
                                        .overlay(Image(systemName: nodeSymbol(item)).foregroundStyle(.white).font(.system(size: 19, weight: .bold)))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.displayName)
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                        Text("\(item.category) • \(item.classType)")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.44))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if item.recommended {
                                        Image(systemName: "star.fill")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.yellow)
                                    }
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.cyan)
                                }
                                .padding(11)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 30)
                }
            }
            .searchable(text: $search, prompt: "Поиск ноды: lo, load, sampler…")
            .navigationTitle("Добавить ноду")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
    }

    private func nodeSymbol(_ item: ComfyNodeCatalogItem) -> String {
        let low = item.classType.lowercased()
        if low.contains("loadimage") { return "photo" }
        if low.contains("checkpoint") { return "brain.head.profile" }
        if low.contains("lora") { return "wand.and.stars" }
        if low.contains("sampler") { return "waveform.path.ecg" }
        if low.contains("save") { return "square.and.arrow.down" }
        if low.contains("vae") { return "circle.hexagongrid" }
        if low.contains("clip") { return "text.quote" }
        return "square.stack.3d.up.fill"
    }
}

private struct ComfyUndoRedoGestureLayer: UIViewRepresentable {
    let onUndo: () -> Void
    let onRedo: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUndo: onUndo, onRedo: onRedo) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
        DispatchQueue.main.async { context.coordinator.attach(from: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) { coordinator.detach() }

    final class Coordinator: NSObject {
        var onUndo: () -> Void
        var onRedo: () -> Void
        weak var window: UIWindow?
        var undoRecognizer: UITapGestureRecognizer?
        var redoRecognizer: UITapGestureRecognizer?

        init(onUndo: @escaping () -> Void, onRedo: @escaping () -> Void) {
            self.onUndo = onUndo
            self.onRedo = onRedo
        }

        func attach(from view: UIView) {
            guard let target = view.window, target !== window else { return }
            detach()
            window = target
            let undo = UITapGestureRecognizer(target: self, action: #selector(handleUndo))
            undo.numberOfTouchesRequired = 2
            undo.numberOfTapsRequired = 2
            undo.cancelsTouchesInView = false
            let redo = UITapGestureRecognizer(target: self, action: #selector(handleRedo))
            redo.numberOfTouchesRequired = 3
            redo.numberOfTapsRequired = 1
            redo.cancelsTouchesInView = false
            target.addGestureRecognizer(undo)
            target.addGestureRecognizer(redo)
            undoRecognizer = undo
            redoRecognizer = redo
        }

        func detach() {
            if let undoRecognizer { window?.removeGestureRecognizer(undoRecognizer) }
            if let redoRecognizer { window?.removeGestureRecognizer(redoRecognizer) }
            undoRecognizer = nil
            redoRecognizer = nil
            window = nil
        }

        @objc private func handleUndo() { onUndo() }
        @objc private func handleRedo() { onRedo() }
    }
}


private struct ComfyNodeInspector: View {
    @State private var draft: ComfyNodeInfo
    let onSave: (ComfyNodeInfo) -> Void
    let onCancel: () -> Void

    private let palette = ["#6D5DFB", "#2DA8FF", "#22C55E", "#F5A623", "#EF4444", "#EC4899", "#9B59B6", "#607D8B"]

    init(node: ComfyNodeInfo, onSave: @escaping (ComfyNodeInfo) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: node)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(comfyHex: draft.color) ?? .blue)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)
                    Text(draft.classType)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    inspectorSection("Название") {
                        TextField("Название ноды", text: $draft.title)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }

                    inspectorSection("Цвет") {
                        HStack(spacing: 9) {
                            ForEach(palette, id: \.self) { hex in
                                Button {
                                    draft.color = hex
                                } label: {
                                    Circle()
                                        .fill(Color(comfyHex: hex) ?? .blue)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Circle().stroke(Color.white, lineWidth: draft.color.lowercased() == hex.lowercased() ? 2.5 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    inspectorSection("Размер на полотне") {
                        HStack {
                            Label("\(Int(draft.nodeWidth)) × \(Int(draft.nodeHeight))", systemImage: "aspectratio")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text("Меняй маркером ↘ на ноде")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                        }
                        .padding(11)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    Toggle(isOn: $draft.muted) {
                        Label("Заглушить ноду", systemImage: "speaker.slash.fill")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .tint(.orange)

                    if !draft.inputs.isEmpty {
                        inspectorSection("Настройки ноды") {
                            VStack(spacing: 11) {
                                ForEach($draft.inputs) { $input in
                                    ComfyNodeInputEditor(input: $input)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
            .frame(maxHeight: 520)

            Button {
                onSave(draft)
            } label: {
                Label("Сохранить изменения", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        LinearGradient(colors: [.blue, .cyan.opacity(0.88)], startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .foregroundStyle(.white)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 15)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            content()
        }
    }
}

private struct ComfyNodeInputEditor: View {
    @Binding var input: ComfyNodeInput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(input.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer()
                if input.isConnection {
                    Label("Connector", systemImage: "link")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }

            if input.isConnection {
                Text(input.value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            } else if input.valueType == "bool" {
                Toggle("", isOn: Binding(
                    get: { ["true", "1", "yes", "on", "да"].contains(input.value.lowercased()) },
                    set: { input.value = $0 ? "true" : "false" }
                ))
                .labelsHidden()
                .tint(.blue)
            } else if let options = input.options, !options.isEmpty {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button(option) { input.value = option }
                    }
                } label: {
                    HStack {
                        Text(input.value.isEmpty ? "Выбрать" : input.value)
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                TextField("Значение", text: $input.value, axis: input.valueType == "string" ? .vertical : .horizontal)
                    .keyboardType((input.valueType == "int" || input.valueType == "float") ? .numbersAndPunctuation : .default)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }
}

private extension Color {
    init?(comfyHex: String) {
        var value = comfyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let rgb = Int(value, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}


private final class ComfyImageMemoryCache {
    static let shared = ComfyImageMemoryCache()
    let images = NSCache<NSString, UIImage>()
}

private struct ComfyRemoteImage: View {
    let device: SavedDevice
    let item: ComfyImageItem
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.white.opacity(0.045)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.35))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: cacheKey as String) { await load() }
    }

    private var cacheKey: NSString { "\(device.storageKey)|\(item.id)" as NSString }

    @MainActor
    private func load() async {
        if let cached = ComfyImageMemoryCache.shared.images.object(forKey: cacheKey) {
            image = cached
            return
        }
        do {
            let data = try await APIClient(device: device).comfyImageData(item)
            guard let loaded = UIImage(data: data) else { throw APIError.badResponse }
            ComfyImageMemoryCache.shared.images.setObject(loaded, forKey: cacheKey)
            image = loaded
        } catch {
            failed = true
        }
    }
}

private struct ComfyResultViewer: View {
    @Environment(\.dismiss) private var dismiss
    let device: SavedDevice
    let item: ComfyImageItem

    @State private var image: UIImage?
    @State private var errorMessage = ""
    @State private var showShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImage(image: image)
                    .ignoresSafeArea(edges: .horizontal)
            } else {
                ProgressView("Загружаем результат…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }

            VStack {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if image != nil {
                        Button { save() } label: {
                            Image(systemName: "square.and.arrow.down")
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Button { showShare = true } label: {
                            Image(systemName: "square.and.arrow.up")
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    Button {
                        Task { try? await APIClient(device: device).comfyOpenImageOnPC(item) }
                    } label: {
                        Image(systemName: "display")
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                Spacer()
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showShare) {
            if let image {
                ActivityView(items: [image])
            }
        }
    }

    @MainActor
    private func load() async {
        do {
            let data = try await APIClient(device: device).comfyImageData(item)
            guard let value = UIImage(data: data) else { throw APIError.badResponse }
            image = value
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() {
        guard let image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
    }
}

private struct ZoomableImage: View {
    let image: UIImage
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = max(1, min(5, lastScale * value))
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                scale = 1
                                lastScale = 1
                                offset = .zero
                                lastOffset = .zero
                            }
                        }
                    }
            )
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in lastOffset = offset }
            )
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
