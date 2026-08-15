import Foundation
import SwiftUI

final class ConnectionSettings: ObservableObject {
    @Published var savedDevices: [SavedDevice] = [] {
        didSet { persistDevices() }
    }

    @Published var pinnedAppsByDevice: [String: [String]] = [:] {
        didSet { persistPinnedApps() }
    }

    @Published var currentDevice: SavedDevice? = nil
    @Published var currentStatus: StatusResponse? = nil
    @Published var lastError: String = ""

    @Published var appearanceRaw: String = AppearanceMode.automatic.rawValue {
        didSet { UserDefaults.standard.set(appearanceRaw, forKey: "appearance_mode") }
    }

    @Published var themeStyleRaw: String = ThemeStyle.windowsBlue.rawValue {
        didSet { UserDefaults.standard.set(themeStyleRaw, forKey: "theme_style") }
    }

    @Published var remoteQualityRaw: String = RemoteQualityMode.balanced.rawValue {
        didSet { UserDefaults.standard.set(remoteQualityRaw, forKey: "remote_quality_mode") }
    }

    @Published var connectionRouteRaw: String = ConnectionRouteMode.automatic.rawValue {
        didSet { UserDefaults.standard.set(connectionRouteRaw, forKey: "connection_route_mode") }
    }

    @Published var preLoginLANHost: String = "" {
        didSet { UserDefaults.standard.set(preLoginLANHost, forKey: "prelogin_lan_host") }
    }

    @Published var preLoginTailscaleHost: String = "" {
        didSet { UserDefaults.standard.set(preLoginTailscaleHost, forKey: "prelogin_tailscale_host") }
    }

    @Published var preLoginZeroTierHost: String = "" {
        didSet { UserDefaults.standard.set(preLoginZeroTierHost, forKey: "prelogin_zerotier_host") }
    }

    @Published var preLoginPortText: String = "8765" {
        didSet { UserDefaults.standard.set(preLoginPortText, forKey: "prelogin_port") }
    }

    init() {
        appearanceRaw = UserDefaults.standard.string(forKey: "appearance_mode") ?? AppearanceMode.automatic.rawValue
        themeStyleRaw = UserDefaults.standard.string(forKey: "theme_style") ?? ThemeStyle.windowsBlue.rawValue
        remoteQualityRaw = UserDefaults.standard.string(forKey: "remote_quality_mode") ?? RemoteQualityMode.balanced.rawValue
        connectionRouteRaw = UserDefaults.standard.string(forKey: "connection_route_mode") ?? ConnectionRouteMode.automatic.rawValue
        preLoginLANHost = UserDefaults.standard.string(forKey: "prelogin_lan_host") ?? ""
        preLoginTailscaleHost = UserDefaults.standard.string(forKey: "prelogin_tailscale_host") ?? ""
        preLoginZeroTierHost = UserDefaults.standard.string(forKey: "prelogin_zerotier_host") ?? ""
        preLoginPortText = UserDefaults.standard.string(forKey: "prelogin_port") ?? "8765"
        loadDevices()
        loadPinnedApps()
        primePreLoginFromSavedDeviceIfNeeded()
    }

    var isConnected: Bool { currentDevice != nil }

    var appearanceMode: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .automatic
    }

    var themeStyle: ThemeStyle {
        ThemeStyle(rawValue: themeStyleRaw) ?? .windowsBlue
    }

    var remoteQualityMode: RemoteQualityMode {
        get { RemoteQualityMode(rawValue: remoteQualityRaw) ?? .balanced }
        set { remoteQualityRaw = newValue.rawValue }
    }

    var connectionRouteMode: ConnectionRouteMode {
        get { ConnectionRouteMode(rawValue: connectionRouteRaw) ?? .automatic }
        set { connectionRouteRaw = newValue.rawValue }
    }

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .automatic: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    func connect(device: SavedDevice, status: StatusResponse) {
        var updated = device
        updated.name = status.computer
        if let mac = status.mac { updated.macAddress = mac }
        if let broadcast = status.broadcast { updated.broadcastAddress = broadcast }
        if let tailscaleIP = status.tailscaleIP, !tailscaleIP.isEmpty { updated.tailscaleHost = tailscaleIP }
        if let tailscaleDNS = status.tailscaleDNS, !tailscaleDNS.isEmpty { updated.tailscaleDNS = tailscaleDNS }
        if let zerotierIP = status.zerotierIP, !zerotierIP.isEmpty { updated.zerotierHost = zerotierIP }
        currentDevice = updated
        currentStatus = status
        lastError = ""
        preLoginLANHost = updated.host
        preLoginTailscaleHost = updated.tailscaleHost ?? updated.tailscaleDNS ?? preLoginTailscaleHost
        preLoginZeroTierHost = updated.zerotierHost ?? preLoginZeroTierHost
        preLoginPortText = String(updated.port)
        upsertDevice(updated)
    }

    func disconnect() {
        currentDevice = nil
        currentStatus = nil
        lastError = ""
    }

    func upsertDevice(_ device: SavedDevice) {
        if let idx = savedDevices.firstIndex(where: { existing in
            if let lhs = existing.connectionID, let rhs = device.connectionID {
                return lhs == rhs
            }
            return existing.host == device.host && existing.port == device.port
        }) {
            savedDevices[idx] = device
        } else {
            savedDevices.insert(device, at: 0)
        }
    }

    func removeDevice(_ device: SavedDevice) {
        savedDevices.removeAll { $0.id == device.id }
        pinnedAppsByDevice.removeValue(forKey: device.storageKey)
    }

    func pinnedIDs(for device: SavedDevice?) -> [String] {
        guard let device else { return [] }
        return pinnedAppsByDevice[device.storageKey] ?? []
    }

    func isPinned(_ app: RemoteApp, for device: SavedDevice?) -> Bool {
        pinnedIDs(for: device).contains(app.id)
    }

    func pin(_ app: RemoteApp, for device: SavedDevice?) {
        guard let device else { return }
        var ids = pinnedAppsByDevice[device.storageKey] ?? []
        if !ids.contains(app.id) {
            ids.append(app.id)
            pinnedAppsByDevice[device.storageKey] = ids
        }
    }

    func unpin(_ app: RemoteApp, for device: SavedDevice?) {
        guard let device else { return }
        var ids = pinnedAppsByDevice[device.storageKey] ?? []
        ids.removeAll { $0 == app.id }
        pinnedAppsByDevice[device.storageKey] = ids
    }

    var preLoginPort: Int {
        let value = Int(preLoginPortText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 8765
        return min(max(value, 1), 65535)
    }

    func useConnectionDetails(from device: SavedDevice) {
        preLoginLANHost = device.host
        preLoginTailscaleHost = device.tailscaleHost ?? device.tailscaleDNS ?? ""
        preLoginZeroTierHost = device.zerotierHost ?? ""
        preLoginPortText = String(device.port)
    }

    private func primePreLoginFromSavedDeviceIfNeeded() {
        guard let first = savedDevices.first else { return }
        if preLoginLANHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preLoginLANHost = first.host
        }
        if preLoginTailscaleHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preLoginTailscaleHost = first.tailscaleHost ?? first.tailscaleDNS ?? ""
        }
        if preLoginZeroTierHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            preLoginZeroTierHost = first.zerotierHost ?? ""
        }
        if Int(preLoginPortText) == nil {
            preLoginPortText = String(first.port)
        }
    }

    private func loadDevices() {
        guard let data = UserDefaults.standard.data(forKey: "saved_devices"),
              let decoded = try? JSONDecoder().decode([SavedDevice].self, from: data) else {
            savedDevices = []
            return
        }
        savedDevices = decoded
    }

    private func persistDevices() {
        guard let data = try? JSONEncoder().encode(savedDevices) else { return }
        UserDefaults.standard.set(data, forKey: "saved_devices")
    }

    private func loadPinnedApps() {
        guard let data = UserDefaults.standard.data(forKey: "pinned_apps_by_device"),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            pinnedAppsByDevice = [:]
            return
        }
        pinnedAppsByDevice = decoded
    }

    private func persistPinnedApps() {
        guard let data = try? JSONEncoder().encode(pinnedAppsByDevice) else { return }
        UserDefaults.standard.set(data, forKey: "pinned_apps_by_device")
    }
}
