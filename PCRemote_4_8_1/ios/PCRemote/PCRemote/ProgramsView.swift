import SwiftUI
import UIKit

struct DesktopBackgroundView: View {
    @AppStorage("theme_style") private var themeStyleRaw: String = ThemeStyle.windowsBlue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var style: ThemeStyle {
        ThemeStyle(rawValue: themeStyleRaw) ?? .windowsBlue
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                baseGradient

                switch style {
                case .windowsBlue:
                    windowsShapes(size: proxy.size)
                case .glass:
                    glassShapes(size: proxy.size)
                case .graphite:
                    graphiteShapes(size: proxy.size)
                case .aurora:
                    auroraShapes(size: proxy.size)
                }

                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(colorScheme == .dark ? 0.24 : 0.08)],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var baseGradient: LinearGradient {
        switch style {
        case .windowsBlue:
            return LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.06, green: 0.24, blue: 0.56), Color(red: 0.01, green: 0.12, blue: 0.38), Color.black]
                    : [Color(red: 0.47, green: 0.72, blue: 0.96), Color(red: 0.08, green: 0.39, blue: 0.88), Color(red: 0.02, green: 0.19, blue: 0.62)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .glass:
            return LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.07, blue: 0.20), Color(red: 0.12, green: 0.25, blue: 0.48), Color(red: 0.03, green: 0.06, blue: 0.13)]
                    : [Color(red: 0.65, green: 0.84, blue: 1.0), Color(red: 0.52, green: 0.66, blue: 0.98), Color(red: 0.30, green: 0.49, blue: 0.90)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .graphite:
            return LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.04, green: 0.05, blue: 0.07), Color.black]
                    : [Color(red: 0.65, green: 0.68, blue: 0.73), Color(red: 0.38, green: 0.42, blue: 0.49), Color(red: 0.20, green: 0.23, blue: 0.28)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .aurora:
            return LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.02, green: 0.22, blue: 0.24), Color(red: 0.12, green: 0.06, blue: 0.33), Color(red: 0.02, green: 0.04, blue: 0.12)]
                    : [Color(red: 0.26, green: 0.80, blue: 0.75), Color(red: 0.35, green: 0.51, blue: 0.98), Color(red: 0.55, green: 0.38, blue: 0.91)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func windowsShapes(size: CGSize) -> some View {
        Circle()
            .fill(Color.white.opacity(0.14))
            .frame(width: size.width * 1.15, height: size.width * 1.15)
            .blur(radius: 34)
            .offset(x: -size.width * 0.42, y: -size.height * 0.34)

        RoundedRectangle(cornerRadius: 120, style: .continuous)
            .fill(Color.cyan.opacity(0.20))
            .frame(width: size.width * 1.1, height: size.height * 0.28)
            .rotationEffect(.degrees(17))
            .offset(x: -size.width * 0.12, y: -size.height * 0.25)

        RoundedRectangle(cornerRadius: 140, style: .continuous)
            .fill(Color.blue.opacity(0.42))
            .frame(width: size.width * 1.35, height: size.height * 0.34)
            .rotationEffect(.degrees(-13))
            .offset(x: size.width * 0.30, y: -size.height * 0.08)

        RoundedRectangle(cornerRadius: 150, style: .continuous)
            .fill(Color.indigo.opacity(0.38))
            .frame(width: size.width * 1.45, height: size.height * 0.37)
            .rotationEffect(.degrees(22))
            .offset(x: size.width * 0.16, y: size.height * 0.34)
    }

    @ViewBuilder
    private func glassShapes(size: CGSize) -> some View {
        Circle()
            .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28))
            .frame(width: size.width * 0.95, height: size.width * 0.95)
            .blur(radius: 18)
            .offset(x: -size.width * 0.25, y: -size.height * 0.25)

        Circle()
            .fill(Color.purple.opacity(0.24))
            .frame(width: size.width * 0.9, height: size.width * 0.9)
            .blur(radius: 38)
            .offset(x: size.width * 0.32, y: size.height * 0.12)

        RoundedRectangle(cornerRadius: 90, style: .continuous)
            .stroke(Color.white.opacity(0.16), lineWidth: 1)
            .frame(width: size.width * 0.76, height: size.height * 0.34)
            .rotationEffect(.degrees(-18))
            .offset(x: size.width * 0.12, y: size.height * 0.24)
    }

    @ViewBuilder
    private func graphiteShapes(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 120, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .frame(width: size.width * 1.25, height: size.height * 0.28)
            .rotationEffect(.degrees(-18))
            .offset(x: size.width * 0.15, y: -size.height * 0.18)

        RoundedRectangle(cornerRadius: 150, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .frame(width: size.width * 1.3, height: size.height * 0.34)
            .rotationEffect(.degrees(26))
            .offset(x: -size.width * 0.2, y: size.height * 0.31)
    }

    @ViewBuilder
    private func auroraShapes(size: CGSize) -> some View {
        Circle()
            .fill(Color.green.opacity(0.24))
            .frame(width: size.width * 1.15, height: size.width * 1.15)
            .blur(radius: 48)
            .offset(x: -size.width * 0.38, y: -size.height * 0.18)

        Circle()
            .fill(Color.purple.opacity(0.30))
            .frame(width: size.width * 1.0, height: size.width * 1.0)
            .blur(radius: 52)
            .offset(x: size.width * 0.42, y: size.height * 0.05)

        Circle()
            .fill(Color.cyan.opacity(0.20))
            .frame(width: size.width * 0.85, height: size.width * 0.85)
            .blur(radius: 44)
            .offset(x: -size.width * 0.05, y: size.height * 0.36)
    }
}

private final class RemoteIconMemoryCache {
    static let shared = RemoteIconMemoryCache()
    let images = NSCache<NSString, UIImage>()
}

struct AppGlyphView: View {
    let app: RemoteApp
    let device: SavedDevice?
    var size: CGFloat = 56

    @State private var realIcon: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .fill(appGradient)

            if app.isComfyUI {
                ComfyGlyphMark(size: size)
                    .padding(size * 0.12)
            } else if let realIcon {
                Image(uiImage: realIcon)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.10)
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .task(id: cacheKey as String) { await loadRealIcon() }
    }

    private var cacheKey: NSString {
        let deviceKey = device?.storageKey ?? "none"
        return "\(deviceKey)|\(app.id)" as NSString
    }

    @MainActor
    private func loadRealIcon() async {
        if let cached = RemoteIconMemoryCache.shared.images.object(forKey: cacheKey) {
            realIcon = cached
            return
        }
        guard let device else { return }
        do {
            guard let data = try await APIClient(device: device).appIconData(app: app),
                  let image = UIImage(data: data) else { return }
            RemoteIconMemoryCache.shared.images.setObject(image, forKey: cacheKey)
            realIcon = image
        } catch { }
    }

    private var symbolName: String {
        switch app.icon {
        case "comfyui": return "circle.hexagongrid.fill"
        case "browser": return "globe"
        case "game": return "gamecontroller.fill"
        case "chat": return "message.fill"
        case "music": return "music.note"
        case "doc": return "doc.text.fill"
        case "sheet": return "tablecells.fill"
        case "slides": return "play.rectangle.fill"
        case "design": return "paintpalette.fill"
        case "dev": return "chevron.left.forwardslash.chevron.right"
        case "settings": return "gearshape.fill"
        case "folder": return "folder.fill"
        default: return "app.fill"
        }
    }

    private var appGradient: LinearGradient {
        if app.isComfyUI {
            return LinearGradient(colors: [Color(red: 0.12, green: 0.10, blue: 0.32), Color(red: 0.16, green: 0.48, blue: 0.96), Color.cyan.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        switch app.icon {
        case "comfyui": return LinearGradient(colors: [Color(red: 0.12, green: 0.10, blue: 0.32), Color(red: 0.16, green: 0.48, blue: 0.96), Color.cyan.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "browser": return LinearGradient(colors: [Color.blue, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "game": return LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "chat": return LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "music": return LinearGradient(colors: [Color.black.opacity(0.9), Color.green.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "doc": return LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "sheet": return LinearGradient(colors: [Color.green, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "slides": return LinearGradient(colors: [Color.orange, Color.red], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "design": return LinearGradient(colors: [Color.black.opacity(0.95), Color.blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "dev": return LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "settings": return LinearGradient(colors: [Color.gray, Color.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "folder": return LinearGradient(colors: [Color.yellow.opacity(0.95), Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        default: return LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}


private struct ComfyGlyphMark: View {
    let size: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let dot = max(5, w * 0.18)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: w * 0.18, y: w * 0.28))
                    path.addLine(to: CGPoint(x: w * 0.53, y: w * 0.18))
                    path.addLine(to: CGPoint(x: w * 0.82, y: w * 0.43))
                    path.addLine(to: CGPoint(x: w * 0.57, y: w * 0.78))
                    path.addLine(to: CGPoint(x: w * 0.22, y: w * 0.66))
                    path.addLine(to: CGPoint(x: w * 0.18, y: w * 0.28))
                    path.move(to: CGPoint(x: w * 0.53, y: w * 0.18))
                    path.addLine(to: CGPoint(x: w * 0.57, y: w * 0.78))
                }
                .stroke(Color.white.opacity(0.82), style: StrokeStyle(lineWidth: max(1.8, w * 0.045), lineCap: .round, lineJoin: .round))

                node(x: 0.18, y: 0.28, dot: dot, width: w)
                node(x: 0.53, y: 0.18, dot: dot, width: w)
                node(x: 0.82, y: 0.43, dot: dot, width: w)
                node(x: 0.57, y: 0.78, dot: dot, width: w)
                node(x: 0.22, y: 0.66, dot: dot, width: w)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func node(x: CGFloat, y: CGFloat, dot: CGFloat, width: CGFloat) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.cyan.opacity(0.75), lineWidth: max(1, width * 0.025)))
            .frame(width: dot, height: dot)
            .position(x: width * x, y: width * y)
    }
}
