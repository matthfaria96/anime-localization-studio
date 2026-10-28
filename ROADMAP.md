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
- ✅ Pré-visualização fiel de ASS com libass: `\t`, `\move`, `\fad`, karaokê, desenhos, clipes, rotação, desfoque, tags inline e fontes anexadas ao MKV (SRT usa a sobreposição própria)
- ✅ Inserir e excluir falas (menu de contexto, botão +, ⌫), desfazível, nos dois documentos
- ✅ Filtro "Possíveis erros de ortografia" (corretor do macOS no idioma de destino)
- ✅ Limite de caracteres por segundo configurável (Ajustes › Geral › Revisão)
- ✅ OCR de legendas PGS (decodificador PGS próprio + reconhecimento de texto do Vision, no Mac)
- ⬜ OCR de VobSub (DVD, `.idx/.sub`)

## Fase 3 — Integração de IA 🟡

- ✅ VoiceStudio investigado (licença, API, compatibilidade com Apple silicon)
- ✅ Adaptador HTTP (`VoiceStudioClient`: capacidades, vozes, TTS, transcrição) com testes
- ✅ Motores de tradução: Apple Translation, Apple Foundation Models, servidor compatível com OpenAI
- ✅ Voice casting: personagens a partir do campo Ator do ASS, voz por personagem, velocidade, estilo (VoiceStudio), amostra
- ✅ Elenco salvo na série (ou no projeto, sem série) e reaproveitado entre episódios
- ✅ Transcrição no Mac (`SpeechAnalyzer`/`SpeechTranscriber`, 45 idiomas) para vídeos sem legenda, com confirmação antes de o macOS baixar o modelo de um idioma
- ✅ Identificação de falantes (FluidAudio: pyannote Community-1 + WeSpeaker + PLDA/VBx em Core ML, ~22 MB baixados com confirmação): na transcrição ou numa legenda existente sem personagens; renomear "Falante N" aplica o nome a todas as falas
- ⬜ Clonagem de voz com registro de consentimento (o VoiceStudio já tem `/profiles/{id}/consent`)

## Fase 4 — Dublagem e mixagem ✅ (qualidade de voz depende do motor)

- ✅ Separação diálogo × acompanhamento no Mac com `AUSoundIsolation` (voz de alta qualidade, sem download). Medida num teste sintético: a fala restante fica ~18 dB abaixo da original. Aproximada em trilhas densas; Demucs/BS-RoFormer continuam como alternativa futura de maior qualidade
- ✅ Síntese por fala com o elenco: vozes do macOS (`say`, básicas) ou VoiceStudio; clipes em cache para retomar
- ✅ Ajuste de duração: corte de silêncio, aceleração até 30% (`atempo`, sem mudar o tom); falas que não cabem ou que se sobreporiam são listadas
- ✅ Mixagem voice-over: `sidechaincompress` (original abaixa sob a voz), `amix`, `loudnorm` EBU R128 (−16 LUFS), AAC 192k
- ✅ "Dublar episódio inteiro" e fila "Traduzir e dublar": novo `Nome [PT-BR DUB].mkv` com áudio dublado + legenda pt-BR, originais preservados, verificado
- ✅ Revisão de falas problemáticas (lista clicável). Para refazer uma fala basta editar a tradução e dublar de novo: só as falas alteradas são sintetizadas (cache)
- ✅ Modo "Substituir falas": novas vozes sobre a trilha sem o diálogo original (fundo em cache por faixa)
- ⬜ Teste com o VoiceStudio real (o adaptador só foi testado contra servidor simulado)

## Fase 4b — Dublagem automática ✅

- ✅ Amostra da voz original de cada personagem (voz isolada, ~12 s) para reconhecer quem é
- ✅ Elenco automático: clone da voz original via VoiceStudio (`POST /profiles`, testado contra servidor simulado) ou voz do macOS pelo tom (autocorrelação, testado)
- ⬜ Testar a clonagem com o VoiceStudio instalado de verdade

## Fase 5 — Automação 🟡

- 🚫 Biblioteca de pastas (removida da interface na 0.11.0)
- 🚫 Fila persistente e relatório da temporada (fora da interface desde a 0.11.0; código removido na 0.21.0)
- ✅ Glossário por série
- ⬜ Reprocessar só falas novas/alteradas
- ✅ Contexto entre episódios: as últimas falas traduzidas do episódio anterior (mesma pasta, ordem do nome) entram como contexto do início do próximo

## Fase 6 — Acabamento e distribuição ⬜

- ⬜ Revisão completa de VoiceOver e navegação por teclado (rótulos básicos já existem)
- ⬜ Textos extraídos para String Catalog (o código já usa `LocalizedStringKey`)
- ✅ Teste de desempenho do núcleo com 5 000 falas (leitura, regravação idêntica e tradução em lotes)
- ⬜ Medir a interface (tabela e editor) com 5 000+ falas
- ⬜ Assinatura com Developer ID, notarização, Sparkle (padrão dos outros apps witchmymac)
- ⬜ Instalação em ambiente limpo

## Interface (0.10.0)

- ✅ (0.11.0) Sem menu lateral: tela inicial para um vídeo; Visão geral, Legendar e Dublar num seletor no topo, cada troca recarrega os dados
- ✅ (0.11.0) Legendar: "Voltar" à escolha da tarefa; sair com alterações pergunta salvar ou descartar
- ✅ (0.11.0) Dublar: histórico de dublagens, apagar com confirmação (só do histórico ou com o arquivo)
- 🚫 (0.11.0) Biblioteca, Fila e Recentes saíram da interface (um vídeo por vez)
- ✅ (0.12.0) Formulário único de Legendar: corrigir com referência ao lado, ou legenda nova com idioma e tradução automática
- ✅ (0.12.0) Rascunho + "Gravar no vídeo…" como único salvamento; sair pergunta gravar, rascunho ou descartar
- ✅ (0.12.0) Abas com sublinhado rosa; Dublar com resumo, histórico e "Recomeçar do zero"
- ⬜ Referência ao lado a partir de um arquivo do disco (hoje só faixas do vídeo)
- ✅ (0.13.0) Estilos: criar, duplicar, renomear, apagar; Fontes: estado, adicionar (anexadas ao gravar), extrair
- ✅ (0.13.0) ⇄ inverter legenda editada e de referência; personagens em lote; SRT guarda personagens no projeto
- ✅ (0.13.0) Dublagem com referência por fala (voz + emoção) e voz original no idioma de saída
- ✅ (0.14.0) Legenda em branco, importada ou criada do áudio (idioma falado escolhido, tradução em seguida); extrair todas as fontes na Visão geral
- ✅ (0.15.0) Dublagem online com a ElevenLabs (retomada sem cobrar de novo); VoiceStudio e vozes do macOS removidos
- ✅ (0.17.0) Voz do Mac com Chatterbox Multilingual (MLX, 23 idiomas, clonagem por fala), testada com reconhecimento de fala
- ⬜ Testar a ElevenLabs com uma conta real (testes atuais usam servidor simulado)
- ⬜ Tradução de fala para fala com sincronia labial (não há modelo local com licença livre para isso)
- ✅ Visão geral com dados do arquivo, faixas, faixas padrão e extração de faixas
- ✅ Legendar pergunta "editar existente" ou "criar tradução"; edição salva no lugar da faixa original
- ✅ Dublar mostra áudio de base, origem do texto e idioma do resultado; "gerar tudo do zero"
- ✅ Ajustes › Armazenamento com limpeza por tipo
- ⬜ Editar uma legenda em imagem (PGS) e gravá-la de volta como imagem

## Testes atuais

`swift test`: cerca de 105 testes em 6 alvos, todos passando em 27/10/2026 (os de diarização rodam quando os modelos estão em cache ou com `ALS_DIARIZATION=1`).

| Alvo | O que cobre |
|---|---|
| SubtitleKitTests (27) | Round-trip byte a byte (BOM + CRLF), SSA, campos com vírgula, tags, desenho, karaokê, marcadores, fallback por partes, quebra de linha, SRT, busca/substituição, deslocamento, verificação de estrutura, `\r` solto que não quebra a linha |
| MediaKitTests (11) | MKV real gerado no teste: inspeção, extração, mux pt-BR com verificação, original inalterado (SHA-256), não sobrescrita, detecção de vídeo recodificado, prévia, cancelamento de processo |
| TranslationKitTests (13) | Contexto e glossário por lote, traduções existentes preservadas, queda do servidor interrompe sem multiplicar pedidos, fallback de marcadores, isolamento de fala com erro, checkpoint/retomada, cancelamento, **tradução real com a Apple Translation** |
| StudioCoreTests (10) | **Dublagem de ponta a ponta num MKV real** (2 áudios, 2 legendas, verificação, original intacto); **legenda editada substitui a faixa antiga** num MKV real; inventário e limpeza do armazenamento; redação de segredos, projetos, séries, ajustes tolerantes |
| ASSRenderingTests (5) | libass real: `\fad` muda a opacidade, `\move` muda a posição, desenho vetorial em escala, karaokê muda a cor das sílabas, nada fora do tempo |
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
- ✅ Trava por projeto: uma operação longa por vez (`ProjectActivity`).
- ✅ Arquivos não editados com terminadores mistos voltam idênticos (bytes originais guardados); editados usam o terminador da maioria.
- ✅ Legenda reextraída quando o vídeo é substituído no mesmo caminho (tamanho + data), com cópia da tradução anterior.
- ✅ Arquivo quase todo UTF-8 com bytes inválidos continua UTF-8 (bytes ruins viram U+FFFD) em vez de virar Windows-1252.
- ✅ O valor exato da chave configurada também é ocultado nos logs.

## Bloqueios conhecidos

- O VoiceStudio não está instalado neste Mac; o adaptador foi testado contra um servidor simulado.
- O FFmpeg do Homebrew não tem libass, então a prévia fiel de ASS depende da integração futura com libmpv.
- A Apple Translation exige os idiomas baixados (Ajustes do Sistema › Geral › Idioma e Região).
