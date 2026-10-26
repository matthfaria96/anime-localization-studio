# Roadmap

Atualizado em 26/10/2026. Legenda: ✅ feito e testado · 🟡 parcial · ⬜ não iniciado.

## Fase 1 — Fundação nativa ✅

- ✅ Ambiente inspecionado (macOS 27.0.1, Xcode 27, Swift 6.4, M4 16 GB; FFmpeg 9.0.2; MKVToolNix 103.0 instalado via Homebrew)
- ✅ Pacote Swift modular (SubtitleKit, MediaKit, TranslationKit, DubbingKit, StudioCore, app)
- ✅ Documentação exigida (README, REFERENCES, THIRD_PARTY_NOTICES, ARCHITECTURE, ROADMAP, CHANGELOG)
- ✅ Base visual: tokens (`Theme`), componentes, Liquid Glass na barra de transporte e botões principais, temas claro e escuro verificados por captura da janela real
- ✅ Importação de mídia (abrir, arrastar, Finder "Abrir com")
- ✅ Inspeção de MKV (faixas, idiomas, flags, anexos, capítulos)
- ✅ Player (AVPlayer + prévia remuxada sem recodificar) com legenda sobreposta
- ✅ Projetos persistentes por arquivo

## Fase 2 — Editor de legendas ✅ (com pendências menores)

- ✅ Parser ASS/SSA/SRT com round-trip byte a byte
- ✅ Editor: lista, detalhe, tempos (campos, ±100 ms, início/fim no vídeo), estilo, personagem
- ✅ Original × tradução lado a lado e sobre o vídeo
- ✅ Busca e substituição só no texto visível (tags nunca alteradas)
- ✅ Desfazer/refazer pelo UndoManager da janela
- ✅ Editor de estilos (fonte, tamanho, cores, negrito/itálico, contorno, sombra, alinhamento, margem)
- ✅ Deslocamento de tempos (tudo ou seleção)
- ✅ Tradução em lote com contexto, glossário, retentativas, checkpoints, retomada, cancelamento e relatório
- ✅ Incorporação de nova faixa e verificação do MKV (incluindo prova de não recodificação)
- ✅ Exportação externa da legenda
- 🟡 Pré-visualização aproximada (sem `\t`, `\move`, `\fad`, karaokê, desenhos, clipes, tags inline de cor/itálico)
- ⬜ Inserir/excluir falas na interface (já suportado no `ASSDocument`)
- ⬜ Verificação ortográfica (NSSpellChecker) e contador de CPS configurável
- ⬜ Renderização fiel de ASS com libass (via libmpv; avaliar licença LGPL e empacotamento)
- ⬜ OCR de legendas PGS/VobSub (Vision framework)

## Fase 3 — Integração de IA 🟡

- ✅ VoiceStudio investigado (licença, API, compatibilidade com Apple silicon)
- ✅ Adaptador HTTP (`VoiceStudioClient`: capacidades, vozes, TTS, transcrição) com testes
- ✅ Motores de tradução: Apple Translation, Apple Foundation Models, servidor compatível com OpenAI
- ✅ Voice casting: personagens a partir do campo Ator do ASS, voz por personagem, velocidade, estilo (VoiceStudio), amostra
- ✅ Elenco salvo na série (ou no projeto, sem série) e reaproveitado entre episódios e na fila
- ⬜ Transcrição (VoiceStudio `/v1/audio/transcriptions` ou `SpeechAnalyzer` nativo) para vídeos sem legenda
- ⬜ Diarização (pyannote via VoiceStudio; exige token do Hugging Face) e correção manual de falantes
- ⬜ Clonagem de voz com registro de consentimento (o VoiceStudio já tem `/profiles/{id}/consent`)

## Fase 4 — Dublagem e mixagem 🟡

- ⬜ Separação diálogo × acompanhamento (Demucs/BS-RoFormer via VoiceStudio; avaliar licença dos pesos)
- ✅ Síntese por fala com o elenco: vozes do macOS (`say`, básicas) ou VoiceStudio; clipes em cache para retomar
- ✅ Ajuste de duração: corte de silêncio, aceleração até 30% (`atempo`, sem mudar o tom); falas que não cabem ou que se sobreporiam são listadas
- ✅ Mixagem voice-over: `sidechaincompress` (original abaixa sob a voz), `amix`, `loudnorm` EBU R128 (−16 LUFS), AAC 192k
- ✅ "Dublar episódio inteiro" e fila "Traduzir e dublar": novo `Nome [PT-BR DUB].mkv` com áudio dublado + legenda pt-BR, originais preservados, verificado
- 🟡 Revisão de falas problemáticas (lista clicável; falta regravar uma fala isolada)
- ⬜ Modo "Substituir falas" (exige a separação acima)
- ⬜ Teste com o VoiceStudio real (o adaptador só foi testado contra servidor simulado)

## Fase 5 — Automação 🟡

- ✅ Biblioteca de pastas, status de tradução/dublagem por arquivo
- ✅ Fila persistente: ordem, progresso, cancelamento, retomada após fechar o app, registro por trabalho
- ✅ Glossário por série reaproveitado na fila
- ⬜ Reprocessar só falas novas/alteradas
- ⬜ Relatório da temporada (exportável)
- ⬜ Contexto entre episódios (resumo do episódio anterior enviado como nota)

## Fase 6 — Acabamento e distribuição ⬜

- ⬜ Revisão completa de VoiceOver e navegação por teclado (rótulos básicos já existem)
- ⬜ Textos extraídos para String Catalog (o código já usa `LocalizedStringKey`)
- ⬜ Teste de desempenho com legendas de 5 000+ falas
- ⬜ Assinatura com Developer ID, notarização, Sparkle (padrão dos outros apps witchmymac)
- ⬜ Instalação em ambiente limpo

## Testes atuais

`swift test`: 68 testes em 5 alvos, todos passando em 26/10/2026.

| Alvo | O que cobre |
|---|---|
| SubtitleKitTests (27) | Round-trip byte a byte (BOM + CRLF), SSA, campos com vírgula, tags, desenho, karaokê, marcadores, fallback por partes, quebra de linha, SRT, busca/substituição, deslocamento, verificação de estrutura, `\r` solto que não quebra a linha |
| MediaKitTests (11) | MKV real gerado no teste: inspeção, extração, mux pt-BR com verificação, original inalterado (SHA-256), não sobrescrita, detecção de vídeo recodificado, prévia, cancelamento de processo |
| TranslationKitTests (13) | Contexto e glossário por lote, traduções existentes preservadas, queda do servidor interrompe sem multiplicar pedidos, fallback de marcadores, isolamento de fala com erro, checkpoint/retomada, cancelamento, **tradução real com a Apple Translation** |
| StudioCoreTests (8) | **Dublagem de ponta a ponta num MKV real** (2 áudios, 2 legendas, verificação, original intacto); Fila em ordem, persistência, interrupção e retomada, cancelamento, redação de segredos, projetos, séries, ajustes tolerantes |
| DubbingKitTests (9) | Plano de segmentos, elenco, cliente VoiceStudio contra servidor simulado, **dublagem real com voz do sistema + FFmpeg** (aceleração, cache, falas sem voz, sobreposição) |

Validação visual: `Scripts/ui-capture.sh` abre o app compilado com uma pasta pessoal temporária
e captura só a janela (tema claro, escuro, dublagem, episódio traduzido).

## Revisão de código (26/10/2026)

Corrigido depois da revisão: tradução repetida preservava só o checkpoint e apagava edições
manuais (agora mantém tudo o que já difere do original, com opção explícita "Traduzir tudo de
novo"); rascunhos da fala selecionada passaram para o modelo e são aplicados antes de
incorporar/traduzir/exportar; desfazer é limpo ao trocar de faixa; parciais com nome único;
`\r`/U+2028 nunca quebram uma linha ASS/SRT e a estrutura é conferida no arquivo serializado;
erros temporários esgotados interrompem a tradução (sem dividir lotes); corrida no
cancelamento de processos; troca de faixa só apaga a tradução se o backup deu certo;
`project.json` ilegível é movido de lado; o Keychain atualiza antes de apagar.

Pendente:
- ✅ Trava por projeto entre a fila e o episódio aberto (`ProjectActivity`).
- ⬜ Preservar terminadores de linha mistos (CRLF + LF) por linha; hoje usa o da maioria.
- ⬜ Reextrair a legenda quando o vídeo for substituído no mesmo caminho (guardar tamanho e data).
- ⬜ Não cair para Windows-1252 quando o arquivo é quase todo UTF-8 com um byte inválido.
- ⬜ Redigir nos logs também o valor literal da chave configurada (tokens sem prefixo conhecido).

## Bloqueios conhecidos

- O VoiceStudio não está instalado neste Mac; o adaptador foi testado contra um servidor simulado.
- O FFmpeg do Homebrew não tem libass, então a prévia fiel de ASS depende da integração futura com libmpv.
- A Apple Translation exige os idiomas baixados (Ajustes do Sistema › Geral › Idioma e Região).
