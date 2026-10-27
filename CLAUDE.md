# Notas para agentes

- Build e testes só com `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (as Command
  Line Tools não expandem as macros do SwiftUI/FoundationModels). Trabalhe pelo caminho real
  `/Volumes/MacMiniDev/Moved/VSCode Temp/Anime Localization Studio`.
- `./Scripts/build-app.sh` (roda `swift test`; `SKIP_TESTS=1` pula) gera `dist/Anime Localization Studio.app`
  e carimba o SDK real com `vtool` — sem isso não há Liquid Glass.
- Interface: confira por captura da janela real com `Scripts/ui-capture.sh` (pasta pessoal
  temporária via `CFFIXED_USER_HOME`; ganchos `ALS_OPEN`, `ALS_SELECT`, `ALS_SEEK`,
  `ALS_TRANSLATE=1`, `ALS_MODE=dubbing`, `APPEARANCE=light|dark`). Não use os dados reais do usuário.
- Regras que não podem quebrar: o arquivo original nunca é escrito; documentos ASS não editados
  fazem round-trip byte a byte; tradução só altera o campo `Text` (`StructureCheck`); mux grava
  em parcial, verifica e renomeia sem sobrescrever.
- O app tem `defaultIsolation(MainActor)`; tipos usados fora do MainActor precisam de `nonisolated`.
- Antes de mudar estado de fases, atualize ROADMAP.md e CHANGELOG.md. Referências e licenças:
  REFERENCES.md e THIRD_PARTY_NOTICES.md (nenhum código de terceiros foi incorporado).
- libass vem do Homebrew (`brew install libass`); `Scripts/build-app.sh` copia as dylibs para `Contents/Frameworks`, reescreve os caminhos para `@rpath` (inclusive referências `@rpath` internas do Homebrew) e falha se algo ainda apontar para fora do app. Sempre testar abrindo o app compilado: dylib faltando só aparece ao carregar.
- Todo botão, ícone, seletor e campo da interface precisa de explicação ao passar o mouse com `.hint("Título", "o que faz")` (balão de `DesignSystem/HoverHint.swift`, o mesmo do Wineup), nunca `.help` — o usuário pediu isso explicitamente. Ícones sem texto são prioridade.
