import AppKit
import SwiftUI

/// The yak artwork used inside the app. The application icon itself is authored
/// in Resources/PodCraft.icon and rendered by Icon Composer during packaging.
enum Logo {
    /// The square logo: from the app bundle when packaged, else from app/Resources next to the build.
    static let image: NSImage? = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("logo.png")) }
        // Built but not packaged: walk up from the program (app/.build/…/PodCraft) to app/Resources/logo.png.
        let starts = [Bundle.main.executableURL, URL(fileURLWithPath: CommandLine.arguments[0])].compactMap { $0 }
        for start in starts {
            var dir = start.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
            for _ in 0..<6 {
                candidates.append(dir.appendingPathComponent("Resources/logo.png"))
                dir = dir.deletingLastPathComponent()
            }
        }
        for c in candidates { if let img = NSImage(contentsOf: c) { return img } }
        return nil
    }()

}

/// The logo as a rounded tile for the app's screens.
struct LogoView: View {
    var size: CGFloat
    var body: some View {
        if let img = Logo.image {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: size * 0.06, y: size * 0.03)
        } else {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(.tint)
        }
    }
}
