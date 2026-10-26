# Arquitetura

O aplicativo é um pacote Swift (SwiftPM) com cinco bibliotecas e um executável SwiftUI.
As bibliotecas não importam SwiftUI e podem ser testadas sem interface.

```
AnimeLocalizationStudio (SwiftUI, isolamento padrão MainActor)
 ├── StudioCore      projetos, séries/glossários, ajustes, Keychain, fila, logs, fluxo do episódio
 │    ├── TranslationKit   motores, glossário, pipeline em lotes com checkpoints
 │    │    └── SubtitleKit      ASS/SSA/SRT, tags, tempos, verificação de estrutura
 │    ├── DubbingKit       cliente VoiceStudio, elenco, plano de segmentos
 │    └── MediaKit         ferramentas externas, inspeção, extração, mux, verificação, prévia
```

## Correspondência com os 14 módulos pedidos

| Módulo | Onde está | Estado |
|---|---|---|
| 1. Media Inspector | `MediaKit/MediaInspector.swift`, `MediaInfo.swift` | Pronto (mkvmerge -J, fallback ffprobe) |
| 2. Video Player | `App/Player/PlayerModel.swift`, `PlayerView.swift`, `MediaKit/PreviewProxy.swift` | Pronto (AVPlayer + prévia remuxada) |
| 3. Subtitle Parser | `SubtitleKit/*` | Pronto (ASS/SSA/SRT com preservação byte a byte) |
| 4. Subtitle Editor | `App/Editor/*` | Pronto (lista, detalhe, busca/substituição, estilos, tempos, desfazer) |
| 5. Translation Engine | `TranslationKit/*Engine.swift`, `TranslationPipeline.swift` | Pronto (3 motores) |
| 6. Glossary Manager | `TranslationKit/Glossary.swift`, `StudioCore/ProjectStore.swift` (Series), `App/Translation/SeriesView.swift` | Pronto |
| 7. VoiceStudio Adapter | `DubbingKit/VoiceStudioClient.swift`, `SpeechSynthesizer.swift` | Pronto (testado contra servidor simulado) |
| 8. Audio Separation and Mixing | `DubbingKit/VoiceSeparator.swift`, `AudioMixer.swift`, `DubbingPipeline.swift` | Pronto (separação nativa aproximada, voice-over e substituir falas) |
| 9. Voice Casting | `DubbingKit/DubbingPlan.swift`, `App/Dubbing/DubbingView.swift` | Pronto (elenco salvo na série/projeto) |
| 10. MKV Muxing Engine | `MediaKit/MKVMuxer.swift`, `IntegrityVerifier.swift` | Pronto (legendas; áudio usa o mesmo caminho) |
| 11. Job Queue | `StudioCore/JobQueue.swift` | Pronto (persistente, retomada) |
| 12. Project Storage | `StudioCore/ProjectStore.swift`, `AppPaths.swift` | Pronto (JSON atômico) |
| 13. Settings | `StudioCore/Settings.swift`, `App/Settings/SettingsView.swift` | Pronto |
| 14. Logging and Diagnostics | `StudioCore/AppLog.swift`, `App/Diagnostics/DiagnosticsView.swift` | Pronto |

## Decisões principais

**Preservação de ASS sem regex sobre o documento.** `ASSDocument` guarda todas as linhas em
ordem. Seções desconhecidas, comentários, `[Fonts]`, `[Graphics]` e dados do Aegisub ficam como
texto bruto. Linhas `Style:` e de evento são divididas pelos campos do `Format:` da seção (o
último campo, `Text`, mantém suas vírgulas) e guardam a linha original: enquanto nenhum campo
muda, a linha sai idêntica. Um documento não editado faz round-trip byte a byte, inclusive BOM
e CRLF (testado). Só o campo alterado é reescrito; os demais mantêm a grafia original
(`0000` continua `0000`).

**Tradução que não quebra tags.** `TranslatableText` separa o texto de uma fala em prefixo de
tags (`{\an8\pos(…)}` nunca chega ao tradutor), corpo com tags internas trocadas por marcadores
`⟦n⟧` e sufixo. A resposta precisa devolver cada marcador uma vez; se não devolver (ou se o
motor não sabe preservar marcadores, como a Tradução da Apple), a fala é traduzida por partes
entre as tags. Desenhos `\p1`, karaokê, comentários e linhas sem palavras não são enviados.
Chaves e barras invertidas vindas do tradutor são neutralizadas para não criarem tags.
`StructureCheck` confirma, antes de salvar, que só o campo `Text` mudou.

**Pipeline em lotes.** `TranslationPipeline` manda lotes com as falas anteriores já traduzidas,
os termos do glossário que aparecem no lote e as notas da série. Erros temporários têm
retentativa com espera exponencial (1 s, 3 s, 9 s); um lote que continua falhando é dividido ao
meio até isolar a fala problemática, que fica no original e entra no relatório. Erros
permanentes (chave recusada, idioma sem suporte) param a tradução depois de salvar o
checkpoint. O checkpoint é gravado após cada lote e só é reaproveitado se o hash da legenda de
origem, o motor e o idioma forem os mesmos. Não há limite artificial de falas.

**Motores.** Todos implementam `TranslationEngine`:
- `AppleTranslationEngine` — framework Translation, no dispositivo, sem contexto.
- `FoundationModelsEngine` — modelo local da Apple Intelligence com `@Generable`, contexto e
  glossário; lotes de 10 falas por causa da janela de contexto.
- `OpenAICompatibleEngine` — qualquer servidor `/v1/chat/completions` (Ollama, LM Studio,
  llama.cpp, serviços online), com resposta em JSON validada por id.

**MKV sem recodificar e sem tocar no original.** `MKVMuxer` confere espaço livre, grava em um
arquivo oculto `.<nome>.partial.mkv` na pasta de destino, roda o `IntegrityVerifier` e só então
renomeia para um nome livre (`Nome [PT-BR].mkv`, `Nome [PT-BR] (2).mkv`…). A verificação
confere: arquivo legível, número de faixas, cada faixa original (codec, idioma, nome,
resolução, canais), a nova faixa (idioma, nome, flags), uma única faixa padrão por tipo,
anexos, capítulos, duração e — com `ffmpeg -c copy -f framemd5` — tamanho e MD5 dos primeiros
240 pacotes de vídeo, idênticos ao original. Qualquer falha apaga o parcial e informa o motivo.

**Pré-visualização.** O AVFoundation não abre Matroska. `PreviewProxy` gera em cache um MP4 com
o vídeo copiado (`-c:v copy`) e um áudio em AAC; só recodifica, para uma prévia de 720p via
VideoToolbox, quando o codec não toca no AVFoundation (H.264 10-bit, VP9, MPEG-2…). A legenda
é desenhada pelo app (`SubtitleOverlay`) com fonte, tamanho, cores, contorno, `\an`, `\pos`,
margens e resolução de referência; animações, karaokê, desenhos e clipes não aparecem na
prévia (avisado no editor). Uma renderização fiel com libass (via libmpv, como no Santo Video
Player) está no roadmap.

**Ferramentas externas.** `ToolLocator` procura MKVToolNix e FFmpeg nos caminhos do Homebrew,
MacPorts e no `.app` oficial, porque apps abertos pelo Finder não herdam o `PATH`. Um caminho
definido em Ajustes tem prioridade. `ProcessRunner` executa sem shell (nomes com espaços, aspas
e `$` são seguros), lê saída em fluxo para progresso e encerra o processo quando a `Task` é
cancelada.

**Persistência.** JSON com escrita atômica em `~/Library/Application Support/Anime Localization
Studio/` (`Projects/<id>/`, `Series/`, `jobs.json`, `settings.json`, `library.json`, `Logs/`).
Cada projeto guarda `source.<ext>`, `translation.pt-BR.<ext>`, `checkpoint.pt-BR.json` e
`Backups/` (cópia da tradução antes de ser substituída). O id do projeto é o SHA-256 do caminho
do vídeo. SQLite foi considerado e descartado por ora: os volumes (centenas de projetos, uma
fila curta) não justificam o esquema, e JSON é legível para diagnóstico.

**Segredos.** Chaves de API ficam só no Keychain (`KeychainStore`) e viajam apenas no cabeçalho
`Authorization`. `LogRedactor` remove tokens Bearer, chaves com prefixos conhecidos,
`api_key=…` e o caminho da pasta pessoal de tudo que vai para logs, fila e mensagens de erro.

**Concorrência.** O alvo do app usa `defaultIsolation(MainActor)`. Modelos de tela são
`@Observable` no MainActor; trabalho pesado roda em funções `async` das bibliotecas
(subprocessos, rede, tradução) e devolve progresso por closures `@Sendable` que voltam ao
MainActor. Nenhuma operação longa bloqueia a interface; todas podem ser canceladas.

**Dublagem voice-over.** `DubbingPipeline` sintetiza cada fala (`SpeechSynthesizer`: `say` do
macOS ou VoiceStudio), guarda o clipe em cache pelo hash de texto + voz + motor, corta silêncio
e acelera até `maxSpeedup` com `atempo` quando a fala não cabe. `AudioMixer` grava uma trilha de
voz mono em fluxo (sem carregar o episódio na memória), adiando uma fala que se sobreporia à
anterior, e mixa com FFmpeg: o áudio original passa por `sidechaincompress` usando a voz como
sinal de controle, as duas são somadas e normalizadas (`loudnorm`). O MKV final recebe o áudio
e a legenda pt-BR pelo mesmo `MKVMuxer` verificado.

**Separação de diálogo.** `VoiceSeparator` renderiza offline o áudio original pela Audio Unit
`AUSoundIsolation` da Apple (modo voz de alta qualidade), descarta a latência da unidade para
alinhar amostra por amostra e obtém o fundo subtraindo a voz isolada do original com FFmpeg.
O fundo fica em cache por faixa. No modo "Substituir falas" a nova voz é mixada sobre esse
fundo com um ducking leve que disfarça restos das vozes originais.

**Transcrição.** `SpeechTranscription` usa `SpeechAnalyzer` + `SpeechTranscriber` com
`audioTimeRange`, divide frases longas em linhas de legenda e grava um SRT como legenda de
origem do projeto. O download do modelo de um idioma (gerenciado pelo macOS via
`AssetInventory`) só acontece depois da confirmação na interface.

**OCR de PGS.** `PGSDecoder` lê os segmentos do `.sup` (composição, paleta YCbCr+alfa, objetos
em RLE, fim de conjunto), compõe cada legenda como imagem em tons de cinza (texto escuro sobre
branco) e calcula início e fim pelos conjuntos que mostram e limpam a tela. `SubtitleOCR` lê cada
imagem com `RecognizeTextRequest` do Vision no idioma escolhido e monta um SRT.

**Trava por projeto.** `ProjectActivity` (MainActor) registra qual projeto está em operação
longa. A fila espera enquanto o episódio aberto traduz/incorpora/dubla o mesmo arquivo, e o
episódio avisa quando a fila está usando o arquivo.

## Fluxos

**Traduzir episódio inteiro:** inspeção → escolha da legenda (ASS antes de SRT, idioma
preferido, evitando "Signs/Songs" e forçadas) → `mkvextract` para `source.ass` → pipeline →
`translation.pt-BR.ass` (com backup da anterior) → editor (desfazível com ⌘Z).

**Incorporar ao MKV:** salva edições pendentes → `MuxPlan` (nova faixa pt-BR, nome, padrão,
ordem) → mkvmerge → verificação → renomeação → relatório na tela.

**Temporada:** Biblioteca (pastas) → seleção → `JobQueue` (persistida a cada mudança) →
`EpisodeJobPerformer` usa o mesmo `EpisodeWorkflow`. Trabalhos em andamento quando o app fecha
voltam como "Interrompido" e retomam do checkpoint.

## Tratamento de falhas

| Situação | Comportamento |
|---|---|
| Ferramenta ausente | Erro com o comando de instalação; Diagnóstico mostra versão e caminho |
| Arquivo corrompido ou não reconhecido | `mkvmerge -J` com erro → tentativa com ffprobe → mensagem clara |
| Legenda em imagem (PGS/VobSub) | Aviso de que precisa de OCR (não implementado) |
| Falta de espaço | Verificado antes do mux; nada é escrito |
| Mux com erro ou verificação reprovada | Parcial apagado, motivo listado |
| Motor indisponível | Mensagem do próprio motor (idiomas não baixados, Apple Intelligence desligada, servidor fechado) |
| Fala que o motor não devolve | Fica no original, listada no relatório e no filtro "Sem tradução" |
| App fechado no meio | Checkpoint por lote; fila marca "Interrompido" e retoma |
