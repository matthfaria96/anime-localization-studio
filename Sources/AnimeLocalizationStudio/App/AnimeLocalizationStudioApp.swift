import AppKit
import StudioCore
import SwiftUI

@main
struct AnimeLocalizationStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Anime Localization Studio", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 640)
                .onAppear {
                    delegate.app = app
                    // Test hook for captures: force an appearance without changing the system's.
                    switch ProcessInfo.processInfo.environment["ALS_APPEARANCE"] {
                    case "light": NSApp.appearance = NSAppearance(named: .aqua)
                    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
                    default: break
                    }
                    if let path = ProcessInfo.processInfo.environment["ALS_OPEN"] { app.open(URL(fileURLWithPath: path)) }
                    // Test hook: ALS_VOICE_TEST=<reference.wav> speaks one line with the Mac's voice into ALS_VOICE_OUT.
                    if let reference = ProcessInfo.processInfo.environment["ALS_VOICE_TEST"],
                       let output = ProcessInfo.processInfo.environment["ALS_VOICE_OUT"] {
                        let synthesizer = app.settings.makeSynthesizer(paths: app.paths)
                        Task {
                            do {
                                try await synthesizer.synthesize("Eu não vou deixar você machucar os meus amigos.", voice: reference, style: nil, speed: 1,
                                                                 to: URL(fileURLWithPath: output))
                                AppLog.shared.info("Teste de voz: \(output)")
                            } catch {
                                try? error.localizedDescription.write(toFile: output + ".error", atomically: true, encoding: .utf8)
                            }
                        }
                    }
                    // Test hook for captures: ALS_SIZE=1080x700 sets the window's content size.
                    if let size = ProcessInfo.processInfo.environment["ALS_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }?.setContentSize(NSSize(width: size[0], height: size[1]))
                        }
                    }
                }
        }
        .defaultSize(width: 1_440, height: 900)
        // The window cannot get smaller than its content needs, so nothing is clipped.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir vídeo…") { app.presentOpenPanel() }.keyboardShortcut("o")
                Button("Fechar vídeo") { app.closeVideo() }.disabled(app.workspace == nil)
                Button("Abrir legenda externa…") { app.workspace?.openExternalSubtitle() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(app.workspace == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Salvar legenda como arquivo…") {
                    if app.workspace?.isEditingOriginal == true { app.workspace?.exportSource() } else { app.workspace?.exportTranslation() }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(app.workspace?.project.subtitleTask == nil || app.screen != .subtitles)
            }
            CommandMenu("Episódio") {
                Button("Gravar legenda no vídeo…") { app.workspace?.requestWriteToVideo() }
                    .disabled(app.workspace?.project.subtitleTask == nil || app.screen != .subtitles)
                Button("Cancelar operação") { app.workspace?.cancelOperation() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(app.workspace?.isBusy != true)
                Divider()
                Button("Reproduzir ou pausar") { app.workspace?.player.togglePlay() }
                Button("Fala anterior") { app.workspace?.jumpLine(by: -1) }
                Button("Próxima fala") { app.workspace?.jumpLine(by: 1) }
            }
        }

        Settings {
            SettingsView().environment(app)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = app?.openDropped(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.workspace?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
