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
                    // Test hook for captures: ALS_DOCKED=1 opens Legendar with the line panel pinned to the side.
                    if ProcessInfo.processInfo.environment["ALS_DOCKED"] == "1" { UserDefaults.standard.set(true, forKey: "linePanelDocked") }
                    if let path = ProcessInfo.processInfo.environment["ALS_OPEN"] { app.open(URL(fileURLWithPath: path)) }
                    // Test hook: ALS_VOICE_TEST=<reference.wav> speaks one line with the Mac's voice into ALS_VOICE_OUT.
                    if let reference = ProcessInfo.processInfo.environment["ALS_VOICE_TEST"],
                       let output = ProcessInfo.processInfo.environment["ALS_VOICE_OUT"] {
                        let synthesizer = app.settings.makeSynthesizer(paths: app.paths)
                        Task {
                            do {
                                try await synthesizer.synthesize("Eu não vou deixar você machucar os meus amigos.", voice: reference, to: URL(fileURLWithPath: output))
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
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandGroup(replacing: .newItem) {
                Button("Abrir vídeo…") { app.presentOpenPanel() }.keyboardShortcut("o")
                Button("Fechar vídeo") { app.closeVideo() }.disabled(app.workspace == nil)
                Divider()
                Button("Nova legenda…") { app.workspace?.showNewSubtitleSheet = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!inSubtitles)
                Button("Importar arquivo de legenda…") { app.workspace?.requestNewSubtitle(.importFile) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(!inSubtitles)
            }
            CommandGroup(after: .saveItem) {
                Button("Gravar legenda no vídeo…") { app.workspace?.requestWriteToVideo() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!inSubtitles)
                Button("Exportar legenda…") { app.workspace?.exportCurrent() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!inSubtitles)
            }
            CommandMenu("Episódio") {
                Button("Traduzir…") { app.workspace?.translateSheet = TranslateSheetStart() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(!inSubtitles || app.workspace?.isBusy == true)
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

    private var inSubtitles: Bool { app.workspace != nil && app.screen == .subtitles }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var app: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppUpdater.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        _ = app?.openDropped(urls)
    }

    /// ⌘Q with unsaved subtitle changes asks first (save, discard or keep editing).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app, !app.quitting, let workspace = app.workspace, workspace.hasUnsavedSubtitleChanges(on: app.screen) else { return .terminateNow }
        workspace.pendingLeave = .quit
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        app?.workspace?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
