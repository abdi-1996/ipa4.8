import SwiftUI

struct RootView: View {
    @EnvironmentObject var settings: ConnectionSettings

    var body: some View {
        Group {
            if settings.isConnected {
                MainView()
            } else {
                SetupView()
            }
        }
        .preferredColorScheme(settings.preferredColorScheme)
    }
}
