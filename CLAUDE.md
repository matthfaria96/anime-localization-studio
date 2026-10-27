# Notas para agentes

- Build e testes só com `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (as Command
  Line Tools não expandem as macros do SwiftUI/FoundationModels). Trabalhe pelo caminho real
  `/Volumes/MacMiniDev/Moved/VSCode Temp/Anime Localization Studio`.
- `./Scripts/build-app.sh` (roda `swift test`; `SKIP_TESTS=1` pula) gera `dist/Anime Localization Studio.app`
  e carimba o SDK real com `vtool` — sem isso não há Liquid Glass.
- Interface: confira por captura da janela real com `Scripts/ui-capture.sh` (pasta pessoal
  temporária via `CFFIXED_USER_HOME`; ganchos `ALS_OPEN`, `ALS_SELECT`, `ALS_SEEK`,
  `ALS_TRANSLATE=1`, `ALS_DUB=1|run`, `ALS_IDENTIFY=1`, `ALS_MODE=subtitles|dubbing` (sem ele abre a Visão geral),
  `ALS_TASK=edit|translate`, `ALS_SIZE=LxA`, `APPEARANCE=light|dark`). Não use os dados reais do usuário.
- Regras que não podem quebrar: o arquivo original nunca é escrito; documentos ASS não editados
  fazem round-trip byte a byte; tradução só altera o campo `Text` (`StructureCheck`); mux grava
  em parcial, verifica e renomeia sem sobrescrever.
- O app tem `defaultIsolation(MainActor)`; tipos usados fora do MainActor precisam de `nonisolated`.
- Antes de mudar estado de fases, atualize ROADMAP.md e CHANGELOG.md. Referências e licenças:
  REFERENCES.md e THIRD_PARTY_NOTICES.md (nenhum código de terceiros foi incorporado).
- libass vem do Homebrew (`brew install libass`); `Scripts/build-app.sh` copia as dylibs para `Contents/Frameworks`, reescreve os caminhos para `@rpath` (inclusive referências `@rpath` internas do Homebrew) e falha se algo ainda apontar para fora do app. Sempre testar abrindo o app compilado: dylib faltando só aparece ao carregar.
- Todo botão, ícone, seletor e campo da interface precisa de explicação ao passar o mouse com `.hint("Título", "o que faz")` (balão de `DesignSystem/HoverHint.swift`, o mesmo do Wineup), nunca `.help` — o usuário pediu isso explicitamente. Ícones sem texto são prioridade.
- `Scripts/ui-capture.sh` captura só as janelas do processo que ele abriu (filtra por PID): o usuário costuma estar com o app instalado aberto. Janelas extras (sheets) saem como `OUT-2.png`…
- Navegação (pedido do usuário em 27/10/2026, vale acima de pedidos anteriores): **nunca** menu lateral. Tela inicial explica o app e recebe UM vídeo; com ele aberto, só o seletor segmentado Visão geral | Legendar | Dublar no topo, nada mais de botões na barra superior. Cada troca de página recarrega os dados do vídeo. Biblioteca, Fila e Recentes saíram.
- Legendar (0.16.0, pedido do usuário): sem tela inicial de opções; abre direto no editor e as ações ficam na barra (Nova legenda, Traduzir, Editando/Ao lado ⇄). O texto a seguir sobre o formulário é histórico.
- Legendar: formulário único (legenda do vídeo + "Mostrar ao lado" opcional, ou legenda nova com idioma, base e tradução automática). Edições são rascunho; o único salvamento no vídeo é "Gravar no vídeo…"; sair com alterações pergunta Gravar / Rascunho / Descartar. Abas do topo: ícone + nome, atual em rosa com sublinhado (o usuário escolheu sublinhado, não cápsula). Dublar: resumo + Dublar…, histórico logo abaixo (apagar confirma e pode zerar vozes), vozes recolhidas.
- Voz do Mac = Chatterbox Multilingual via speech-swift (revisão fixa no Package.swift) + MLX. Requer o Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`); nos testes o `default.metallib` é copiado para junto do .xctest como `mlx.metallib` (ver ClonedVoiceTests); no app, `build-app.sh` copia os bundles SwiftPM para Contents/Resources. Gancho `ALS_VOICE_TEST=<ref.wav> ALS_VOICE_OUT=<out.wav>` gera uma fala no app instalado.
- Dublagem: dois motores apenas — ElevenLabs (`DubbingKit/ElevenLabsDubbing.swift` + `StudioCore/ElevenLabsWorkflow.swift`, chave no Keychain `api.elevenlabs.io`, `project.remoteDub` retoma sem cobrar de novo) e Voz original no Mac. O usuário mandou remover VoiceStudio e vozes do macOS da interface (`SystemVoiceSynthesizer` ficou só para os testes gerarem fala).
- Fontes: `WorkspaceModel+Fonts.swift`; adicionadas ficam em `Projects/<id>/Fonts` e entram em todo `MuxPlan.attachments`. Estilos: `ASSStyleEditing.swift`. Dublagem "voz original" = PocketTTS no idioma de saída, referência por fala (`OriginalVoices.lineClips`) quando `dubbingPerLineVoice`.
- Textos: plurais com `Plural.count`, idiomas com `Languages` (`DesignSystem/Wording.swift`); nunca "UND", nunca "Incorporar" (é "Gravar no vídeo").
- UX que o usuário rejeitou: operações longas que rodam sem perguntar o destino e sem mostrar onde gravaram (usar janela guiada: confirmar → etapas → resultado com o arquivo).
- Também rejeitado: estrelas para faixa padrão (usar "Tornar padrão" na Visão geral) e menus que escondem qual legenda é a base (usar lista de opções). Legendar sempre separa "editar existente" de "criar tradução"; Dublar sempre diz o áudio de base, que o texto vem da legenda traduzida e o idioma do resultado.
