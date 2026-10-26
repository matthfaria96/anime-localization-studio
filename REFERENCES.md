# Referências open source

Verificação feita em **26/10/2026**, por leitura dos repositórios (API do GitHub/GitLab,
README, arquivos de licença e código-fonte citado) e por testes no Mac de desenvolvimento
(Apple M4, 16 GB, macOS 27.0.1, Xcode 27.0).

**Resumo:** nenhum código destes projetos foi copiado para o aplicativo. Tudo o que está abaixo
é **inspiração conceitual** ou **integração por processo/HTTP** com programas instalados
separadamente. O que é efetivamente usado em tempo de execução está em
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

| Projeto | Licença verificada | Roda no Mac (Apple silicon)? | Como o app usa |
|---|---|---|---|
| VoiceStudio | AGPL-3.0 | Sim (Metal/MPS, MLX) | Serviço local via HTTP (adaptador pronto; dublagem completa pendente) |
| Subtitle Edit | MIT | Não nativamente (.NET/Windows; há builds multiplataforma) | Só inspiração |
| Aegisub | BSD-3-Clause (núcleo) + partes com licenças próprias | Sim, mas sem manutenção ativa desde 01/2025 | Só inspiração (formato ASS) |
| MKVToolNix | GPL-2.0-or-later | Sim (Homebrew 103.0, bottle arm64) | Executáveis externos `mkvmerge`/`mkvextract` |
| Inviska MKV Extract | Não verificável | Não verificável | Nada (site fora do ar) |
| Dynamic Subtitles Translator | Serviço proprietário pago | Web/API | Nada (só referência de fluxo) |
| OpenDub | MIT (código); modelos com licenças próprias | Sim, prévia não assinada | Só inspiração |
| FFmpeg | LGPL-2.1+ / GPL conforme a build | Sim (Homebrew 9.0.2) | Executáveis externos `ffmpeg`/`ffprobe` |

---

## VoiceStudio — referência principal para dublagem

- **URL:** https://github.com/debpalash/VoiceStudio · documentação: https://voicestudio.sh/docs
- **Versão examinada:** v0.5.7 (release de 26/10/2026), branch `main` do mesmo dia.
- **Licença verificada:** AGPL-3.0 para a aplicação (arquivo `LICENSE`, campo SPDX da API do GitHub
  e seção "License & responsible use" do README). O próprio README avisa que pesos de modelos,
  tokenizadores, vozes e condições sobre o áudio gerado têm termos separados.
- **Arquitetura observada:** app desktop em Electron (o app Tauri foi arquivado) + backend Python
  (FastAPI) que mantém os modelos carregados. Motores de TTS: OmniVoice (padrão), VoxCPM2,
  MLX-Audio (Kokoro, CSM, Dia), CosyVoice 3, IndexTTS 2.5, entre outros. ASR: WhisperX,
  Faster-Whisper, MLX Whisper, whisper.cpp, Parakeet (MLX e NeMo). Diarização com
  `pyannote/speaker-diarization-3.1` (modelo com acesso restrito no Hugging Face) ou FunASR.
  Separação de fundo no pipeline de dublagem (`backend/services/dub_background.py`).
- **Compatibilidade com macOS:** documentada em `docs/install/macos.md`. Apple silicon M1–M5 com
  aceleração Metal (MPS) e backends MLX escolhidos automaticamente; macOS 13.3 ou mais novo;
  ~10 GB livres. **Macs Intel não rodam o backend local** (o PyTorch parou de publicar wheels
  x86_64 para macOS depois da 2.2). Vários motores são só CUDA/CPU (MOSS-TTS, CosyVoice, IndexTTS
  "CUDA · CPU") — no Mac eles cairiam para CPU, o que não presumimos ser utilizável.
- **API local verificada no código** (`backend/api/routers/openai_compat.py`, `docs/speech-platform.md`):
  - `GET /.well-known/voicestudio-speech` — documento de capacidades `voicestudio.speech.v1`;
  - `GET /v1/audio/voices` — perfis de voz e aliases;
  - `POST /v1/audio/speech` — TTS compatível com OpenAI (`model`, `input` até 4096 caracteres,
    `voice`, `language`, `speed` 0,25–4, `instructions`, `response_format` wav/mp3/…);
  - `POST /v1/audio/transcriptions` — ASR compatível com OpenAI (`verbose_json`, srt, vtt);
  - rotas próprias de dublagem (`/dub/upload`, `/dub/transcribe/{job}`, `/dub/generate/{job}`…),
    ainda não usadas.
  - Porta padrão 3900, sem credencial no loopback; chave Bearer opcional para acesso remoto.
- **Integração escolhida:** HTTP contra o backend local, que o usuário instala e abre.
  Avaliadas também: CLI (`python -m backend.speech_client`, só transcrição), MCP (voltado a
  agentes), reaproveitar módulos Python isolados (exigiria embutir Python + PyTorch e herdar a
  AGPL) e serviço auxiliar empacotado (mesmo problema de licença e ~10 GB). O HTTP mantém o
  aplicativo Swift independente, sem obrigações da AGPL sobre o nosso código, e permite trocar
  o motor de voz no futuro.
- **Componentes reutilizados:** nenhum. Implementado `DubbingKit/VoiceStudioClient.swift`
  (cliente HTTP escrito do zero a partir da documentação pública da API).
- **Custos e limites:** modelos de 1–8 GB por motor; memória unificada compartilhada com o
  sistema (16 GB é o mínimo prático); o VoiceStudio pede confirmação antes de baixar modelos.
  A manutenção é alta: o projeto muda quase diariamente, então o adaptador usa só as rotas
  compatíveis com OpenAI, que são as mais estáveis.

## Subtitle Edit — edição e tradução

- **URL:** https://github.com/SubtitleEdit/subtitleedit · https://subtitleedit.github.io/subtitleedit/
- **Licença verificada:** MIT (API do GitHub, arquivo `LICENSE`). Linguagem: C#.
- **Compatibilidade com macOS:** a interface clássica é WinForms/Windows. A biblioteca `libse`
  (formatos) é .NET e poderia rodar no Mac via .NET, mas exigiria embutir um runtime .NET.
- **Inspiração conceitual:** lista de falas com original × tradução lado a lado, filtros de
  problemas, velocidade de leitura (caracteres por segundo), deslocamento de tempos, busca e
  substituição, tradução em lote com retentativa.
- **Componentes reutilizados:** nenhum. O parser foi escrito em Swift para preservar campos
  brutos, o que o modelo de objetos do Subtitle Edit (que normaliza ao salvar) não garante.

## Aegisub — fansubs e ASS

- **URL:** https://github.com/Aegisub/Aegisub · https://aegisub.org/
- **Licença verificada:** o arquivo `LICENCE` traz uma licença BSD de 3 cláusulas
  ("Copyright (c) 2004-2012, Aegisub Project") e avisa que diretórios com arquivo de licença
  próprio têm outros termos (a API do GitHub mostra `NOASSERTION` por isso). Último push no
  repositório oficial: 01/01/2025.
- **Compatibilidade com macOS:** existem builds para macOS; o projeto oficial está parado.
- **Inspiração conceitual:** estrutura de documentos ASS (`[Script Info]`, `[V4+ Styles]`,
  `[Events]`, `[Fonts]`, `[Graphics]`, `[Aegisub Project Garbage]`), campos de evento, tags de
  override, karaokê (`\k`), desenhos (`\p`), PlayResX/PlayResY, editor de estilos, edição de
  tempos com "início/fim no vídeo".
- **Componentes reutilizados:** nenhum. A semântica de tags segue a documentação pública do
  formato e o comportamento do libass.

## MKVToolNix — manipulação de MKV

- **URL:** https://mkvtoolnix.download/ · https://gitlab.com/mbunkus/mkvtoolnix
- **Licença verificada:** GPL-2.0-or-later (fórmula do Homebrew, metadados do pacote).
- **Compatibilidade com macOS:** `brew install mkvtoolnix` instala a 103.0 com bottle arm64 para
  macOS 27 — instalado e testado neste Mac. Há também o `.app` oficial (procurado pelo app em
  `/Applications/MKVToolNix-*.app/Contents/MacOS`).
- **Uso efetivo:** `mkvmerge -J` (inspeção em JSON), `mkvextract tracks` (extração sem perdas
  da legenda), `mkvmerge` com `--language`, `--track-name`, `--default-track-flag`,
  `--forced-display-flag`, `--sub-charset`, `--track-order` e `--gui-mode` (progresso).
  Vídeo, áudios, legendas, fontes anexadas, capítulos e tags do original são copiados sem
  recodificação.
- **Forma de integração:** processos externos, sem shell, com detecção de caminho, versão e
  instruções de instalação na tela de Diagnóstico. Nenhum binário é distribuído.

## Inviska MKV Extract — extração opcional

- **URL informada:** https://www.inviska.com/mkv-extract/
- **Resultado da verificação:** em 26/10/2026 o domínio mostra apenas "This domain may be for
  sale". Não foi possível confirmar plataformas, licença nem código-fonte.
- **Decisão:** nada foi usado. A extração opcional é feita com `mkvextract` (já verificado), e a
  experiência de "escolher faixa e extrair" está no inspetor de faixas do episódio.

## Dynamic Subtitles Translator — tradução

- **URLs:** https://www.syedgakbar.com/projects/dst · https://www.syedgakbar.com/app/docs/subtitles-api.html
- **Condições verificadas:** API em `https://api.syedgakbar.com/projects/dst-api/` com chave
  Bearer; rotas `get-balance`, `calculate-cost`, `translate` (assíncrona, cobra do saldo em USD)
  e `order-status`. Repassa para DeepL, Microsoft, OpenAI, Gemini, DeepSeek, xAI, Anthropic ou
  Mistral. Modos `batch`, `perline` e `json`. A documentação não informa limites de tamanho,
  limites de taxa, lista completa de formatos nem se tags de formatação são preservadas.
- **Decisão:** o aplicativo **não depende** do serviço. Ideias aproveitadas como conceito:
  orçamento por lotes, sinopse/regras adicionais enviadas ao modelo (aqui: "Notas da obra") e
  o modo 1:1 por fala (aqui: ids por fala com validação).

## OpenDub — dublagem

- **URL:** https://opendub.app/ · repositório confirmado: https://github.com/estebanstifli/OpenDub
- **Licença verificada:** MIT para o código original (C#). O README avisa que bibliotecas,
  runtimes e pesos mantêm seus termos: IndexTTS usa a Model Use License da bilibili; Nemotron 3
  Diarization usa OpenMDW-1.1; a procedência do checkpoint BS-RoFormer ep368 está "não
  resolvida" pelo próprio projeto.
- **Compatibilidade com macOS:** DMG para Apple silicon (macOS 14+), prévia não assinada, com
  runtimes Metal para áudio e tradução (audio.cpp e llama.cpp). Recomenda 16 GB de memória
  unificada "como ponto de partida, não um limite validado". A geração IndexTTS só suporta
  zh, en, ja, es e ar — **não suporta português**.
- **Inspiração conceitual:** separação opcional diálogo × fundo, revisão contra o vídeo antes
  da renderização, ajuste de duração com tentativas limitadas e esticamento de tempo, avisos
  honestos de que separação e diarização erram e de que ajuste de duração não é sincronia labial.
- **Componentes reutilizados:** nenhum.

## FFmpeg — processamento multimídia

- **URL:** https://ffmpeg.org/ · https://github.com/FFmpeg/FFmpeg
- **Licença verificada:** LGPL-2.1-or-later por padrão; GPL quando compilado com componentes
  GPL. A fórmula do Homebrew (9.0.2) declara GPL-3.0-or-later. A build do Homebrew deste Mac
  **não inclui libass** (os filtros `ass`/`subtitles` não existem), por isso a
  pré-visualização das legendas é feita pelo próprio app.
- **Uso efetivo:** remux da pré-visualização (`-c:v copy` + AAC), extração de áudio em WAV,
  `framemd5` com `-c copy` para provar que o vídeo não foi recodificado, `ffprobe` para perfis
  de vídeo (H.264 10-bit não toca no AVFoundation e ganha uma prévia recodificada à parte).
  Filtros `loudnorm`, `amix`, `atempo` e `sidechaincompress` foram confirmados na build e serão
  usados na mixagem da dublagem.
- **Forma de integração:** processos externos; nenhum binário distribuído.

## Motores nativos da Apple (não são open source, mas foram verificados)

- **Translation framework** (`TranslationSession(installedSource:target:)`, macOS 26+):
  inglês → pt-BR e japonês → pt-BR estão instalados neste Mac e traduzem sem interface;
  testado de ponta a ponta (`AppleTranslationIntegrationTests`).
- **Foundation Models** (`SystemLanguageModel`, macOS 26+; `LanguageModelError` no macOS 27):
  disponível neste Mac, com português entre os idiomas suportados. Usado com saída estruturada
  (`@Generable`) e `guardrails: .permissiveContentTransformations`.
- **Speech** (`SpeechAnalyzer` + `SpeechTranscriber`, macOS 26+): 45 idiomas suportados neste
  Mac (inglês e português instalados; japonês exige download do sistema). Usado para transcrever
  vídeos sem legenda; testado com fala sintética.
- **AUSoundIsolation** (AudioToolbox, macOS 13+; modo `HighQualityVoice` no macOS 15+): isola a
  voz no dispositivo. Usado para o modo "Substituir falas" em vez do Demucs, que exigiria
  instalar Python + PyTorch (o Python 3.15 do Homebrew ainda não tem wheels do PyTorch) e
  baixar pesos. Medição num teste sintético: diálogo restante ~18 dB abaixo do original.
- **Vision** (`RecognizeTextRequest`): reconhecimento de texto no dispositivo para o OCR de
  legendas PGS. O formato PGS foi implementado a partir da sua estrutura pública de segmentos
  (PCS, WDS, PDS, ODS, END); nenhum código de decodificadores existentes foi usado.
- **`say`** (macOS): vozes do sistema para a dublagem básica, executado como processo.
