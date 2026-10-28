import DubbingKit
import SwiftUI

/// The ElevenLabs key (kept only in the Keychain) and what the account has left.
struct ElevenLabsAccountView: View {
    @Environment(AppModel.self) private var app
    @State private var draft = ""
    @State private var editing = false
    @State private var account: ElevenLabsDubbing.Account?
    @State private var problem: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if app.elevenLabsKey == nil || editing {
                HStack {
                    SecureField("Cole aqui a sua chave de API", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 300)
                        .onSubmit(save)
                    Button("Salvar", action: save).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editing { Button("Cancelar") { editing = false; draft = "" } }
                }
                .hint("Chave da ElevenLabs", "A chave fica só no Keychain do macOS e nunca é gravada em arquivos ou registros.")
                Link("Criar uma chave em elevenlabs.io › Developers › API Keys", destination: URL(string: "https://elevenlabs.io/app/developers/api-keys")!)
                    .font(.caption)
            } else {
                HStack(spacing: Theme.Spacing.s) {
                    if checking {
                        ProgressView().controlSize(.small)
                        Text("Conferindo a conta…").foregroundStyle(.secondary)
                    } else if let account {
                        Label(accountText(account), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.translated)
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    }
                    Button("Trocar chave") { editing = true }.buttonStyle(.link)
                        .hint("Trocar chave", "Cole outra chave da ElevenLabs.")
                }
            }
        }
        .task(id: app.elevenLabsKeyRevision) { await check() }
    }

    private func accountText(_ account: ElevenLabsDubbing.Account) -> String {
        var parts = [String(localized: "Conectada")]
        if let tier = account.tier { parts.append("plano \(tier)") }
        if let remaining = account.remaining { parts.append(String(localized: "\(remaining.formatted()) créditos restantes")) }
        return parts.joined(separator: " · ")
    }

    private func save() {
        do {
            try app.saveElevenLabsKey(draft)
            draft = ""
            editing = false
        } catch {
            problem = error.localizedDescription
        }
    }

    private func check() async {
        guard let key = app.elevenLabsKey else { account = nil; return }
        checking = true
        defer { checking = false }
        do {
            account = try await ElevenLabsDubbing(apiKey: key).account()
            problem = nil
        } catch {
            account = nil
            problem = error.localizedDescription
        }
    }
}
