# Avisos de terceiros

Verificado em 26/10/2026. Este arquivo lista apenas o que o Anime Localization Studio **usa ou
distribui de fato**. Referências que serviram só de inspiração estão em
[REFERENCES.md](REFERENCES.md).

## Código incorporado ao aplicativo

Nenhum. Todo o código-fonte deste repositório foi escrito para o projeto. Nenhum arquivo de
VoiceStudio, Subtitle Edit, Aegisub, MKVToolNix, FFmpeg ou OpenDub foi copiado, adaptado ou
vinculado ao binário.

O aplicativo depende apenas de frameworks do sistema da Apple (SwiftUI, AppKit, AVFoundation,
AVKit, Translation, FoundationModels, NaturalLanguage, CryptoKit, Security, Observation), que são
parte do macOS e não são redistribuídos.

## Programas externos executados (não distribuídos)

O aplicativo **não inclui** estes programas. Ele os localiza no Mac (Homebrew, MacPorts ou o
pacote oficial) e os executa como processos separados, passando argumentos pela linha de
comando. Nenhuma biblioteca deles é vinculada ao aplicativo.

| Programa | Versão testada | Licença | Uso |
|---|---|---|---|
| MKVToolNix (`mkvmerge`, `mkvextract`) — Moritz Bunkus | 103.0 (Homebrew) | GPL-2.0-or-later | Inspeção de MKV, extração de legendas, criação do novo MKV sem recodificação |
| FFmpeg (`ffmpeg`, `ffprobe`) | 9.0.2 (Homebrew) | LGPL-2.1-or-later; a build do Homebrew é GPL-3.0-or-later por incluir componentes GPL | Pré-visualização (remux para MP4), extração de áudio, comparação de pacotes de vídeo, inspeção de arquivos não Matroska |

Se uma versão futura **distribuir** esses executáveis dentro do aplicativo, será preciso:
incluir o texto completo das licenças, oferecer o código-fonte correspondente (ou um link
válido por três anos, no caso da GPL) e documentar as opções de compilação do FFmpeg
(`--enable-gpl`/`--enable-nonfree` mudam a licença resultante).

## Serviços locais opcionais (instalados separadamente)

| Serviço | Licença | Forma de uso |
|---|---|---|
| VoiceStudio — Palash Debnath e colaboradores | AGPL-3.0 (aplicação). Pesos de modelos, tokenizadores e vozes têm licenças próprias | Comunicação HTTP com o backend local (`127.0.0.1:3900`) quando o usuário o instala e executa. Nenhum código é incorporado |
| Ollama, LM Studio ou outro servidor compatível com a API OpenAI | Licença de cada servidor e de cada modelo baixado | Requisições HTTP para tradução, configuradas pelo usuário |

Os modelos usados por esses serviços **não** são baixados pelo aplicativo. Cada serviço mostra o
tamanho e a licença do modelo antes de instalá-lo. Licenças de pesos (por exemplo, a Model Use
License da bilibili para o IndexTTS, ou a licença do pyannote) não são cobertas pela licença
deste aplicativo.

## Fontes e mídia de teste

Os testes automatizados geram vídeo e áudio sintéticos com os filtros `testsrc2` e `sine` do
FFmpeg e anexam a fonte Arial do próprio macOS a um MKV temporário, apagado ao final. Nenhuma
mídia ou fonte de terceiros é distribuída com o projeto.
