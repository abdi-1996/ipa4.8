import SwiftUI

struct SetupView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @State private var password = ""
    @State private var loading = false
    @State private var errorMessage = ""
    @State private var showConnectionSettings = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesktopBackgroundView().ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        header.padding(.top, 18)
                        connectionChip

                        VStack(alignment: .leading, spacing: 11) {
                            HStack {
                                Text("Пароль")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.82))
                                Spacer()
                                Button {
                                    showConnectionSettings = true
                                } label: {
                                    Label("Подключение", systemImage: "gearshape.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.cyan)
                            }

                            SecureField("Пароль PC Remote", text: $password)
                                .textContentType(.password)
                                .submitLabel(.go)
                                .onSubmit { Task { await connectByPassword() } }
                                .font(.system(size: 18, weight: .semibold))
                                .padding(.horizontal, 15)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                                        .fill(Color.white.opacity(0.10))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                )

                            Text("Пароль задаётся в окне PC Remote Server на компьютере.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(18)
                        .background(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        )

                        Button {
                            Task { await connectByPassword() }
                        } label: {
                            HStack(spacing: 12) {
                                if loading { ProgressView().tint(.white) }
                                else { Image(systemName: "arrow.right.to.line") }
                                Text(loading ? "Подключаем..." : "Войти")
                                    .font(.system(size: 19, weight: .bold))
                            }
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(.white)
                            .padding(.vertical, 17)
                            .background(
                                LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                            )
                            .shadow(color: .blue.opacity(0.32), radius: 14, y: 8)
                        }
                        .buttonStyle(.plain)
                        .disabled(loading || password.isEmpty)

                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red.opacity(0.96))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        savedDevices
                    }
                    .frame(width: max(0, geometry.size.width - 36))
                    .padding(.bottom, 26)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .sheet(isPresented: $showConnectionSettings) {
            PreLoginConnectionSettingsView()
                .environmentObject(settings)
                .presentationDetents([.medium, .large])
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 88, height: 88)
                .overlay(
                    Image(systemName: "display")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .blue.opacity(0.35), radius: 18, y: 10)

            Text("PC Remote")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.white)
            Text("Вход по вашему паролю")
                .font(.system(size: 17))
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionChip: some View {
        Button {
            showConnectionSettings = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: settings.connectionRouteMode == .tailscale || settings.connectionRouteMode == .zerotier ? "network.badge.shield.half.filled" : "network")
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.connectionRouteMode.title)
                        .font(.system(size: 14, weight: .bold))
                    Text(connectionSummary)
                        .font(.system(size: 12))
                        .opacity(0.7)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .opacity(0.65)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var connectionSummary: String {
        switch settings.connectionRouteMode {
        case .tailscale:
            return settings.preLoginTailscaleHost.isEmpty ? "Укажите Tailscale адрес" : "\(settings.preLoginTailscaleHost):\(settings.preLoginPort)"
        case .zerotier:
            return settings.preLoginZeroTierHost.isEmpty ? "Укажите ZeroTier адрес" : "\(settings.preLoginZeroTierHost):\(settings.preLoginPort)"
        case .lan:
            return settings.preLoginLANHost.isEmpty ? "Укажите LAN адрес" : "\(settings.preLoginLANHost):\(settings.preLoginPort)"
        case .automatic:
            let lan = settings.preLoginLANHost.isEmpty ? "LAN —" : settings.preLoginLANHost
            let zero = settings.preLoginZeroTierHost.isEmpty ? "ZeroTier —" : settings.preLoginZeroTierHost
            let tail = settings.preLoginTailscaleHost.isEmpty ? "Tailscale —" : settings.preLoginTailscaleHost
            return "\(lan) • \(zero) • \(tail)"
        }
    }

    private var savedDevices: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Ранее подключались")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)

            if settings.savedDevices.isEmpty {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .frame(height: 78)
                    .overlay(Text("Пока пусто").foregroundStyle(.white.opacity(0.62)))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(settings.savedDevices.enumerated()), id: \.element.id) { index, device in
                        Button {
                            Task { await connectSaved(device) }
                        } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(LinearGradient(colors: [Color.blue.opacity(0.85), Color.cyan.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 52, height: 52)
                                    .overlay(Image(systemName: "desktopcomputer").font(.title3).foregroundStyle(.white))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.system(size: 17, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text(device.zerotierHost ?? device.tailscaleHost ?? device.host)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 13)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                settings.useConnectionDetails(from: device)
                                showConnectionSettings = true
                            } label: {
                                Label("Настроить подключение", systemImage: "network")
                            }
                            if device.macAddress != nil && device.broadcastAddress != nil {
                                Button {
                                    do { try WakeOnLAN.send(device: device) }
                                    catch { errorMessage = error.localizedDescription }
                                } label: {
                                    Label("Разбудить ПК", systemImage: "power")
                                }
                            }
                            Button(role: .destructive) { settings.removeDevice(device) } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                        if index < settings.savedDevices.count - 1 {
                            Divider().overlay(Color.white.opacity(0.12)).padding(.leading, 78)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.13), lineWidth: 1))
                )
            }
        }
    }

    @MainActor
    private func connectByPassword() async {
        loading = true
        errorMessage = ""
        do {
            let result = try await APIClient.loginWithPassword(
                password: password,
                lanHost: settings.preLoginLANHost,
                tailscaleHost: settings.preLoginTailscaleHost,
                zerotierHost: settings.preLoginZeroTierHost,
                port: settings.preLoginPort,
                routeMode: settings.connectionRouteMode
            )
            settings.connect(device: result.0, status: result.1)
            password = ""
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    @MainActor
    private func connectSaved(_ device: SavedDevice) async {
        loading = true
        errorMessage = ""
        settings.useConnectionDetails(from: device)
        do {
            let status = try await APIClient(device: device).status()
            settings.connect(device: device, status: status)
        } catch {
            errorMessage = "Сохранённый вход больше не действует. Введите пароль подключения."
        }
        loading = false
    }
}

private struct PreLoginConnectionSettingsView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var testingConnection = false
    @State private var connectionTestMessage = ""
    @State private var connectionTestOK = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Маршрут") {
                    Picker("Подключение", selection: $settings.connectionRouteRaw) {
                        ForEach(ConnectionRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.connectionRouteMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Адрес компьютера") {
                    TextField("LAN, например 192.168.8.248", text: $settings.preLoginLANHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("ZeroTier, например 10.204.78.78", text: $settings.preLoginZeroTierHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Tailscale, например 100.x.x.x", text: $settings.preLoginTailscaleHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Порт", text: $settings.preLoginPortText)
                        .keyboardType(.numberPad)

                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            if testingConnection {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "wave.3.right.circle")
                            }
                            Text(testingConnection ? "Проверка…" : "Проверить соединение")
                        }
                    }
                    .disabled(testingConnection)

                    if !connectionTestMessage.isEmpty {
                        Label(connectionTestMessage, systemImage: connectionTestOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(connectionTestOK ? Color.green : Color.red)
                    }
                }

                if !settings.savedDevices.isEmpty {
                    Section("Сохранённые ПК") {
                        ForEach(settings.savedDevices) { device in
                            Button {
                                settings.useConnectionDetails(from: device)
                            } label: {
                                HStack {
                                    Image(systemName: "desktopcomputer")
                                    Text(device.name)
                                    Spacer()
                                    Text(device.zerotierHost ?? device.tailscaleHost ?? device.host)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Section {
                    Text("Эти настройки доступны до входа. Вне дома можно выбрать ZeroTier или Tailscale; в режиме Авто приложение пробует LAN → ZeroTier → Tailscale.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Подключение")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    @MainActor
    private func testConnection() async {
        testingConnection = true
        connectionTestMessage = ""
        connectionTestOK = false
        defer { testingConnection = false }
        do {
            let result = try await APIClient.probeConnection(
                lanHost: settings.preLoginLANHost,
                tailscaleHost: settings.preLoginTailscaleHost,
                zerotierHost: settings.preLoginZeroTierHost,
                port: settings.preLoginPort,
                routeMode: settings.connectionRouteMode
            )
            connectionTestOK = true
            let route = result.1.transport == "zerotier" ? "ZeroTier" : (result.1.transport == "tailscale" ? "Tailscale" : "LAN")
            let passwordText = result.1.passwordSet ? "пароль задан" : "пароль ещё не задан"
            connectionTestMessage = "Связь есть: \(result.1.computer) • \(route) • \(result.0):\(result.1.port) • \(passwordText)"
        } catch {
            connectionTestMessage = error.localizedDescription
        }
    }
}
