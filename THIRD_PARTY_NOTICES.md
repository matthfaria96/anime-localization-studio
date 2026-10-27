# Avisos de terceiros

Verificado em 26/10/2026. Este arquivo lista apenas o que o Anime Localization Studio **usa ou
distribui de fato**. Referências que serviram só de inspiração estão em
[REFERENCES.md](REFERENCES.md).

## Código incorporado ao aplicativo

Nenhum código-fonte de terceiros foi copiado para este repositório. Nenhum arquivo de
VoiceStudio, Subtitle Edit, Aegisub, MKVToolNix, FFmpeg ou OpenDub foi copiado, adaptado ou
vinculado ao binário.

## Bibliotecas distribuídas dentro do aplicativo (desde 0.5.0)

Para a pré-visualização fiel de ASS, o app vincula dinamicamente o **libass** e o
`Scripts/build-app.sh` copia estas bibliotecas (builds do Homebrew, sem modificação) para
`Contents/Frameworks`. Os textos das licenças vão em `Contents/Resources/Licenses`. Todas são
bibliotecas dinâmicas separadas e podem ser substituídas por outras versões compatíveis, como a
LGPL exige.

| Biblioteca | Versão | Licença | Código-fonte |
|---|---|---|---|
| libass | 0.17.5 | ISC | https://github.com/libass/libass |
| FreeType | 2.15.0 | FreeType License (FTL) | https://freetype.org |
| HarfBuzz | 15.0.0 | MIT ("Old MIT") | https://github.com/harfbuzz/harfbuzz |
| FriBidi | 1.0.17 | LGPL-2.1-or-later | https://github.com/fribidi/fribidi |
| libunibreak | 8.0 | Zlib | https://github.com/adah1972/libunibreak |
| GLib (dependência do HarfBuzz) | 2.90.1 | LGPL-2.1-or-later | https://gitlab.gnome.org/GNOME/glib |
| gettext / libintl (dependência do GLib) | — | LGPL-2.1-or-later (libintl) | https://www.gnu.org/software/gettext/ |
| PCRE2 (dependência do GLib) | 10.49 | BSD-3-Clause (com exceção de biblioteca) | https://github.com/PCRE2Project/pcre2 |
| Graphite2 (dependência do HarfBuzz) | — | LGPL-2.1-or-later ou MPL-2.0 | https://github.com/silnrsi/graphite |
| libpng (dependência do FreeType) | — | libpng License | http://www.libpng.org |
| Brotli (dependência do FreeType) | 1.2.1 | MIT | https://github.com/google/brotli |

Os créditos do FreeType exigidos pela FTL: "Portions of this software are copyright © The
FreeType Project (www.freetype.org). All rights reserved." 

O aplicativo depende apenas de frameworks do sistema da Apple (SwiftUI, AppKit, AVFoundation,
AVKit, AudioToolbox, Speech, Vision, Translation, FoundationModels, NaturalLanguage, CryptoKit, Security,
Observation) e do utilitário `/usr/bin/say`, que são
parte do macOS e não são redistribuídos.

## Pacotes Swift vinculados ao aplicativo (desde 0.6.0)

| Pacote | Versão | Licença | Uso |
|---|---|---|---|
| FluidAudio — Fluid Inference | 0.17.x | Apache-2.0 | Diarização (quem fala) no Neural Engine. Só o pipeline offline é usado; o binário opcional NemoTextProcessing está desligado (`traits: []`). O texto da licença e os avisos do código que ele porta de outros projetos (fastcluster, BSD-2-Clause; VBx, Apache-2.0; e os demais da pasta `ThirdPartyLicenses` do FluidAudio) vão em `Contents/Resources/Licenses` |

## Modelos baixados pelo aplicativo (com confirmação)

| Modelo | Origem | Licença | Atribuição |
|---|---|---|---|
| Segmentation, FBank, Embedding, PLDA (`FluidInference/speaker-diarization-coreml`, ~22 MB) | Conversões Core ML modificadas do pyannote/speaker-diarization-community-1, WeSpeaker e parâmetros PLDA da BUT Speech@FIT | CC-BY-4.0 (https://creativecommons.org/licenses/by/4.0/) | pyannote, WeSpeaker, BUT Speech@FIT e Fluid Inference; arquivos convertidos para Core ML pela Fluid Inference |

| Pocket TTS, pacote português e codificador de clonagem (`FluidInference/pocket-tts-coreml`, ~500 MB) | Conversão Core ML do Pocket TTS da Kyutai (kyutai/pocket-tts) | CC-BY-4.0 | Kyutai e Fluid Inference; arquivos convertidos para Core ML pela Fluid Inference |

Os modelos são baixados do Hugging Face só depois que o usuário confirma (identificação de
falantes) ou começa uma dublagem com “Voz original (no Mac)”, e ficam em
`~/Library/Application Support/Anime Localization Studio/Models/`. O áudio nunca sai do Mac.

## Programas externos executados (não distribuídos)

O aplicativo **não inclui** estes programas. Ele os localiza no Mac (Homebrew, MacPorts ou o
pacote oficial) e os executa como processos separados, passando argumentos pela linha de
comando. Nenhuma biblioteca deles é vinculada ao aplicativo.

| Programa | Versão testada | Licença | Uso |
|---|---|---|---|
| MKVToolNix (`mkvmerge`, `mkvextract`, `mkvpropedit`) — Moritz Bunkus | 103.0 (Homebrew) | GPL-2.0-or-later | Inspeção de MKV, extração de legendas, criação do novo MKV sem recodificação |
| FFmpeg (`ffmpeg`, `ffprobe`) | 9.0.2 (Homebrew) | LGPL-2.1-or-later; a build do Homebrew é GPL-3.0-or-later por incluir componentes GPL | Pré-visualização (remux para MP4), extração de áudio, comparação de pacotes de vídeo, inspeção de arquivos não Matroska |

Se uma versão futura **distribuir** esses executáveis dentro do aplicativo, será preciso:
incluir o texto completo das licenças, oferecer o código-fonte correspondente (ou um link
válido por três anos, no caso da GPL) e documentar as opções de compilação do FFmpeg
(`--enable-gpl`/`--enable-nonfree` mudam a licença resultante).

## Serviços locais opcionais (instalados separadamente)

| Serviço | Licença | Forma de uso |
|---|---|---|
| speech-swift — soniqo | Apache-2.0 (biblioteca Swift incorporada: ChatterboxTTS e AudioCommon) |
| Chatterbox Multilingual — Resemble AI | MIT (modelo, baixado sob demanda; conversão MLX `aufklarer/Chatterbox-Multilingual-MLX-fp16`) |
| MLX / mlx-swift — Apple | MIT (biblioteca incorporada) |
| swift-transformers — Hugging Face | Apache-2.0 (biblioteca incorporada) |
| ElevenLabs (serviço online, opcional) | Termos de uso da ElevenLabs; acessado pela API com a chave da pessoa. Nenhum código incorporado | Comunicação HTTP com o backend local (`127.0.0.1:3900`) quando o usuário o instala e executa. Nenhum código é incorporado |
| Ollama, LM Studio ou outro servidor compatível com a API OpenAI | Licença de cada servidor e de cada modelo baixado | Requisições HTTP para tradução, configuradas pelo usuário |

Os modelos usados por esses serviços **não** são baixados pelo aplicativo. Cada serviço mostra o
tamanho e a licença do modelo antes de instalá-lo. Licenças de pesos (por exemplo, a Model Use
License da bilibili para o IndexTTS, ou a licença do pyannote) não são cobertas pela licença
deste aplicativo.

## Fontes e mídia de teste

Os testes automatizados geram vídeo e áudio sintéticos com os filtros `testsrc2` e `sine` do
FFmpeg e anexam a fonte Arial do próprio macOS a um MKV temporário, apagado ao final. Nenhuma
mídia ou fonte de terceiros é distribuída com o projeto.
