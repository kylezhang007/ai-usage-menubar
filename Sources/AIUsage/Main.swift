import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        StatusController.pinLeftmost()
        controller = StatusController(state: state)
        let args = CommandLine.arguments
        if args.contains("--open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.controller?.open() }
        }
        // Debug aid: `AIUsage --snapshot out.png` renders the panel with live data and exits.
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Task {
                while state.lastUpdated == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
                Self.snapshot(state: state, to: args[i + 1])
                NSApp.terminate(nil)
            }
        }
    }

    private static func snapshot(state: AppState, to path: String) {
        print("claude:", state.claude, "\ncodex:", state.codex,
              "\nanthropic:", state.anthropic, "\nopenAI:", state.openAI, "\ndeepSeek:", state.deepSeek)
        let view = PanelView().environmentObject(state).environment(\.colorScheme, .light)
            .padding(30)
            .background(LinearGradient(colors: [Color(hex: 0xFFF4C2), Color(hex: 0xB5E4FF), Color(hex: 0xBDEFB2)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let cg = renderer.cgImage {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}

@main
enum AIUsageMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
