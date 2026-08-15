import SwiftUI
@main
struct PCRemoteApp: App {
    @StateObject private var settings = ConnectionSettings()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(settings)
        }
    }
}
