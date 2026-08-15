import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: ConnectionSettings
    @Environment(\.dismiss) private var dismiss
    @State private var statusText = ""

    private var client: APIClient? {
        guard let device = settings.currentDevice else { return nil }
        return APIClient(device: device)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Текущее устройство") {
                    LabeledContent("ПК", value: settings.currentDevice?.name ?? "—")
                    LabeledContent("Статус", value: "Подключено")
                    if settings.currentDevice?.connectionID != nil {
                        Text("Это устройство было добавлено старым способом через Device ID. Новые подключения используют ваш пароль.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }


                Section("Подключение") {
                    Picker("Маршрут", selection: $settings.connectionRouteRaw) {
                        ForEach(ConnectionRouteMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(settings.connectionRouteMode.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if let device = settings.currentDevice {
                        LabeledContent("LAN", value: "\(device.host):\(device.port)")
                        if let zero = device.zerotierHost, !zero.isEmpty {
                            LabeledContent("ZeroTier", value: "\(zero):\(device.port)")
                        }
                        if let tail = device.tailscaleHost, !tail.isEmpty {
                            LabeledContent("Tailscale", value: "\(tail):\(device.port)")
                        }
                        if let dns = device.tailscaleDNS, !dns.isEmpty {
                            LabeledContent("MagicDNS", value: dns)
                        }
                        if let transport = settings.currentStatus?.transport {
                            LabeledContent("Сейчас", value: transportLabel(transport))
                        }
                    }
                }

                Section("Оформление") {
                    Picker("Режим", selection: $settings.appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Тема", selection: $settings.themeStyleRaw) {
                        ForEach(ThemeStyle.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }

                    ThemePreviewRow(style: settings.themeStyle)
                }

                Section("Удалённый экран") {
                    Picker("Режим", selection: $settings.remoteQualityRaw) {
                        ForEach(RemoteQualityMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }

                    Text(remoteModeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }


                Section("Питание") {
                    if let device = settings.currentDevice, device.macAddress != nil, device.broadcastAddress != nil {
                        Button {
                            do {
                                try WakeOnLAN.send(device: device)
                                statusText = "Wake-on-LAN пакет отправлен."
                            } catch {
                                statusText = error.localizedDescription
                            }
                        } label: {
                            Label("Разбудить ПК (Wake-on-LAN)", systemImage: "power")
                        }
                    }

                    Button { Task { await power("lock") } } label: {
                        Label("Заблокировать Windows", systemImage: "lock")
                    }
                    Button { Task { await power("sleep") } } label: {
                        Label("Спящий режим", systemImage: "moon.zzz")
                    }
                    Button(role: .destructive) { Task { await power("restart") } } label: {
                        Label("Перезагрузить ПК", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) { Task { await power("shutdown") } } label: {
                        Label("Выключить ПК", systemImage: "power")
                    }
                }

                Section("Главный экран") {
                    Text("На главном экране автоматически показываются ярлыки с рабочего стола Windows. Из «Пуска» программу можно добавить долгим нажатием и перетаскиванием.")
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: "4.8.1")
                }

                Section("Действия") {
                    Button("Проверить соединение") { Task { await test() } }
                    if !statusText.isEmpty {
                        Text(statusText)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        settings.disconnect()
                        dismiss()
                    } label: {
                        Text("Отключиться")
                    }
                }
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func transportLabel(_ transport: String) -> String {
        switch transport.lowercased() {
        case "tailscale": return "Tailscale"
        case "zerotier": return "ZeroTier"
        default: return "LAN"
        }
    }

    private var remoteModeDescription: String {
        switch settings.remoteQualityMode {
        case .quality:
            return "Максимально чёткая картинка. Подходит для быстрого LAN, но задержка выше."
        case .balanced:
            return "Оптимальный баланс качества, плавности и нагрузки."
        case .latency:
            return "Меньше задержка и больше кадров, но изображение сильнее сжимается."
        }
    }

    @MainActor
    private func power(_ action: String) async {
        guard let client else { return }
        do {
            try await client.powerAction(action)
            statusText = "Команда отправлена."
        } catch {
            statusText = error.localizedDescription
        }
    }

    @MainActor
    private func test() async {
        guard let client else { return }
        do {
            let status = try await client.status()
            let route = status.transport?.lowercased() == "tailscale" ? "Tailscale" : "LAN"
            statusText = "Подключено к \(status.computer) • \(route)"
        } catch {
            statusText = error.localizedDescription
        }
    }
}

private struct ThemePreviewRow: View {
    let style: ThemeStyle

    var body: some View {
        HStack(spacing: 12) {
            Text("Предпросмотр")
            Spacer()
            HStack(spacing: -8) {
                Circle().fill(colors.0).frame(width: 28, height: 28)
                Circle().fill(colors.1).frame(width: 28, height: 28)
                Circle().fill(colors.2).frame(width: 28, height: 28)
            }
        }
    }

    private var colors: (Color, Color, Color) {
        switch style {
        case .windowsBlue: return (.cyan, .blue, .indigo)
        case .glass: return (.blue.opacity(0.55), .purple.opacity(0.7), .cyan.opacity(0.65))
        case .graphite: return (.gray, .secondary, .black)
        case .aurora: return (.green, .cyan, .purple)
        }
    }
}
