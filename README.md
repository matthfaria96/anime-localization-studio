# Anime Localization Studio

Aplicativo nativo para macOS que junta, numa janela só, o trabalho de abrir um episódio,
editar a legenda, traduzir tudo para o português do Brasil e criar um novo MKV com a faixa
traduzida — sem recodificar o vídeo e sem tocar no arquivo original. O foco é anime e fansubs
(ASS com estilos, posicionamento, karaokê e desenhos), mas funciona com filmes, séries e
documentários.

Escrito em Swift e SwiftUI para macOS 27 em Apple silicon.

## O que já funciona

- **Abrir e inspecionar** MKV, MP4 e MOV: faixas de vídeo, áudio e legenda, idiomas, flags
  padrão/forçada, fontes anexadas e capítulos.
- **Assistir** dentro do app com a legenda original, a tradução ou as duas sobre o vídeo. MKVs
  são reproduzidos por uma cópia de pré-visualização em cache, feita sem recodificar o vídeo.
- **Editar** falas, tempos, estilos e personagens, com original e tradução lado a lado, busca e
  substituição que nunca altera tags `{\…}`, deslocamento de tempos, filtro de falas sem
  tradução ou com leitura rápida demais, e ⌘Z/⇧⌘Z.
- **Traduzir o episódio inteiro** com um clique, preservando cabeçalhos, estilos, tempos,
  camadas, margens, efeitos, tags, quebras de linha, comentários, karaokê e desenhos. Só o texto
  muda, e isso é verificado antes de salvar.
- **Glossário por série**: nomes, técnicas, lugares, honoríficos e notas para o tradutor.
- **Incorporar ao MKV**: um novo arquivo `Nome [PT-BR].mkv` com a legenda em português como
  faixa adicional (idioma, nome, padrão e ordem configuráveis). Todas as faixas, fontes e
  capítulos originais são mantidos. Antes de dizer que deu certo, o app confere o arquivo e
  compara os pacotes de vídeo com o original.
- **Temporadas**: biblioteca de pastas e fila persistente para traduzir (e incorporar) vários
  episódios, que continua de onde parou se o app for fechado.
- **Dublar episódio inteiro**: uma voz por personagem (vozes do macOS ou do VoiceStudio), cada
  fala ajustada ao seu tempo, em dois modos: *voice-over* (por cima do original, que abaixa) ou
  *substituir falas* (as vozes originais são separadas da trilha no próprio Mac e trocadas). O
  resultado é um novo `Nome [PT-BR DUB].mkv` com o áudio dublado e a legenda em português. O
  elenco fica salvo na série.
- **Transcrever** o áudio de vídeos sem legenda, no próprio Mac, para depois traduzir.

## O que ainda não está implementado

- A separação de voz é aproximada: em cenas com música ou efeitos densos ficam restos das falas
  originais. As vozes do macOS são robóticas; vozes naturais dependem do VoiceStudio, que só foi
  testado contra um servidor simulado.
- Identificação automática de quem fala (diarização) na transcrição.
- Pré-visualização fiel de animações ASS (`\t`, `\move`, `\fad`), karaokê e desenhos — o arquivo
  final os preserva, mas a prévia mostra o texto estático.
- OCR de legendas em imagem (PGS/VobSub).

Detalhes e próximos passos em [ROADMAP.md](ROADMAP.md).

## Requisitos

- macOS 27 em Apple silicon (o pacote declara `.macOS("27.0")`).
- [MKVToolNix](https://mkvtoolnix.download/) e [FFmpeg](https://ffmpeg.org/):

  ```sh
  brew install mkvtoolnix ffmpeg
  ```

  O app encontra os programas no Homebrew, MacPorts ou no `MKVToolNix.app`; outro caminho
  pode ser indicado em Ajustes › Ferramentas. A tela **Diagnóstico** mostra o que falta.
- Para compilar: Xcode 27 (as macros do SwiftUI e do Foundation Models não funcionam só com as
  Command Line Tools).

## Motores de tradução

Escolha em Ajustes › Tradução ou no inspetor do episódio.

| Motor | Onde roda | Contexto e glossário | Observações |
|---|---|---|---|
| Tradução da Apple | No Mac | Não (fala por fala; glossário só conferido) | Baixe os idiomas em Ajustes do Sistema › Geral › Idioma e Região › Idiomas de Tradução |
| Apple Intelligence | No Mac | Sim | Precisa da Apple Intelligence ativada; modelo pequeno, lotes de 10 falas |
| Servidor compatível com OpenAI | Local (Ollama, LM Studio, llama.cpp) ou online | Sim | Melhor qualidade com modelos grandes. Chave de API fica no Keychain |

Com Ollama, por exemplo: `ollama pull qwen3:8b`, deixe o Ollama aberto e escolha a predefinição
"Ollama (local)". Nenhum modelo é baixado pelo próprio app.

Serviços online recebem o texto das legendas. Os motores locais não enviam nada para fora do Mac.

## Dublagem com o VoiceStudio

O [VoiceStudio](https://github.com/debpalash/VoiceStudio) (AGPL-3.0) é instalado à parte
(`curl -fsSL https://voicestudio.sh/install | sh` ou o DMG oficial para Apple silicon) e roda os
modelos de voz com Metal/MLX. O Anime Localization Studio conversa com a API local dele em
`http://127.0.0.1:3900` (configurável em Ajustes › Ferramentas). Os modelos são baixados pelo
VoiceStudio, que mostra tamanho e licença antes. Clone vozes só com permissão de quem fala.

## Compilar e executar

```sh
# testes (precisam de mkvmerge e ffmpeg para os testes de mídia)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# app em dist/Anime Localization Studio.app (roda os testes antes; SKIP_TESTS=1 pula)
./Scripts/build-app.sh

# compila, testa e instala em /Applications
./Scripts/install.sh

open "dist/Anime Localization Studio.app"
```

O script carimba no binário a versão real do SDK (o SwiftPM grava a do sistema mínimo), sem a
qual o macOS mostraria o app com a aparência antiga, sem Liquid Glass. A assinatura padrão é
ad hoc; `SIGN_IDENTITY="Developer ID Application: …"` assina para distribuição.

Para conferir a interface sem mexer no seu ambiente:

```sh
ALS_SELECT=3 ALS_SEEK=5000 APPEARANCE=light ./Scripts/ui-capture.sh caminho/do/episodio.mkv /tmp/janela.png
```

## Onde ficam os dados

`~/Library/Application Support/Anime Localization Studio/`: projetos (legenda de origem,
tradução, checkpoint e cópias de segurança por arquivo), séries, fila, ajustes e registros.
Pré-visualizações ficam em `~/Library/Caches/Anime Localization Studio/` e podem ser apagadas a
qualquer momento. Os vídeos originais nunca são modificados.

## Documentação

- [ARCHITECTURE.md](ARCHITECTURE.md) — módulos, fluxos e tratamento de falhas
- [REFERENCES.md](REFERENCES.md) — projetos open source investigados e licenças verificadas
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — o que é efetivamente usado
- [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## Licença

GPL-3.0 — veja [LICENSE](LICENSE).
