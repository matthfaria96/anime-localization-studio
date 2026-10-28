# Anime Localization Studio

Aplicativo nativo para macOS que junta, numa janela só, o trabalho de abrir um episódio,
editar a legenda, traduzir tudo para o português do Brasil e criar um novo MKV com a faixa
traduzida — sem recodificar o vídeo e sem tocar no arquivo original. O foco é anime e fansubs
(ASS com estilos, posicionamento, karaokê e desenhos), mas funciona com filmes, séries e
documentários.

Escrito em Swift e SwiftUI para macOS 27 em Apple silicon.

A interface está em português do Brasil e em inglês (segue o idioma do macOS).

## O que já funciona

- **Abrir e inspecionar** MKV, MP4 e MOV na Visão geral: tamanho, duração, codecs, faixas de
  vídeo, áudio e legenda, idiomas, fontes anexadas e capítulos. Escolha o áudio e a legenda
  padrão e extraia qualquer faixa como arquivo, sem converter. Daqui você vai para Legendar ou
  Dublar.
- **Editar uma legenda existente**: corrija texto, tempos e estilos e grave a versão corrigida
  no MKV, no lugar da faixa original (novo arquivo ou o próprio).
- **Assistir** dentro do app com a legenda original, a tradução ou as duas sobre o vídeo, com
  renderização fiel de ASS pelo libass (animações, karaokê, desenhos e as fontes do MKV). MKVs
  são reproduzidos por uma cópia de pré-visualização em cache, feita sem recodificar o vídeo.
- **Criar uma tradução** a partir de uma legenda: falas, tempos, estilos e personagens, com original e tradução lado a lado, busca e
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
- **Um vídeo por vez**: a tela inicial explica o app e recebe um vídeo (arrastar ou escolher).
  Com ele aberto, três páginas no topo da janela: Visão geral, Legendar e Dublar. Não há menu
  lateral.
- **Dublar o vídeo** de dois jeitos:
  - **ElevenLabs** (online, com a sua conta): só o áudio é enviado; o serviço separa cada
    personagem, traduz e fala com a voz de cada um, mantendo a emoção e a música. Não precisa de
    legenda. Um trabalho interrompido é retomado sem enviar nem cobrar de novo.
  - **Voz original no Mac** (gratuita, offline): fala a legenda traduzida com um clone da voz de
    cada personagem e a emoção de cada fala (Chatterbox Multilingual, 23 idiomas, na GPU do Mac),
    em *substituir falas* ou *voice-over*.
  O resultado entra no MKV como faixa de áudio nova, verificada, num arquivo novo ou no próprio.
- **Identificar quem fala** no áudio (no Mac), na transcrição ou numa legenda sem personagens,
  para montar o elenco da dublagem.
- **Transcrever** o áudio de vídeos sem legenda, ou **reconhecer o texto (OCR)** de legendas em
  imagem PGS de Blu-ray, no próprio Mac, para depois traduzir.

## O que ainda não está implementado

- Na voz do Mac, a separação de voz é aproximada: em cenas com música densa ficam restos das
  falas originais. A integração com a ElevenLabs foi testada contra um servidor simulado; o
  primeiro uso real depende da sua chave.
- OCR de legendas VobSub (DVD); PGS já é reconhecido.

Detalhes e próximos passos em [ROADMAP.md](ROADMAP.md).

## Requisitos

- macOS 27 em Apple silicon (o pacote declara `.macOS("27.0")`).
- [MKVToolNix](https://mkvtoolnix.download/) e [FFmpeg](https://ffmpeg.org/):

  ```sh
  brew install mkvtoolnix ffmpeg
  ```

  O app encontra os programas no Homebrew, MacPorts ou no `MKVToolNix.app`; outro caminho
  pode ser indicado em Ajustes › Ferramentas. Ajustes › **Diagnóstico** mostra o que falta e
  Ajustes › **Armazenamento** mostra e limpa o que o app guarda.
- Para compilar: `brew install libass` (o build copia o libass e as dependências para dentro
  do app) e Xcode 27 (as macros do SwiftUI e do Foundation Models não funcionam só com as
  Command Line Tools).

## Motores de tradução

Escolha em Ajustes › Tradução ou no painel da direita de Legendar.

| Motor | Onde roda | Contexto e glossário | Observações |
|---|---|---|---|
| Tradução da Apple | No Mac | Não (fala por fala; glossário só conferido) | Baixe os idiomas em Ajustes do Sistema › Geral › Idioma e Região › Idiomas de Tradução |
| Apple Intelligence | No Mac | Sim | Precisa da Apple Intelligence ativada; modelo pequeno, lotes de 10 falas |
| Servidor compatível com OpenAI | Local (Ollama, LM Studio, llama.cpp) ou online | Sim | Melhor qualidade com modelos grandes. Chave de API fica no Keychain |

Com Ollama, por exemplo: `ollama pull qwen3:8b`, deixe o Ollama aberto e escolha a predefinição
"Ollama (local)". Nenhum modelo é baixado pelo próprio app.

Serviços online recebem o texto das legendas. Os motores locais não enviam nada para fora do Mac.

## Dublagem com a ElevenLabs

Crie uma chave em [elevenlabs.io › Developers › API Keys](https://elevenlabs.io/app/developers/api-keys)
e cole em Dublar (ou Ajustes › Ferramentas). A chave fica só no Keychain. O app usa a API de
dublagem (`POST /v1/dubbing`, `GET /v1/dubbing/{id}`, `GET /v1/dubbing/{id}/audio/{idioma}`):
envia só a faixa de áudio escolhida, nunca o vídeo, e cada dublagem usa créditos da sua conta.
Clone vozes só em conteúdo que você tem direito de dublar.

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
tradução, checkpoint, histórico de dublagens e cópias de segurança por arquivo), séries, ajustes e registros.
Pré-visualizações ficam em `~/Library/Caches/Anime Localization Studio/` e podem ser apagadas a
qualquer momento. Os vídeos originais nunca são modificados.

## Documentação

- [ARCHITECTURE.md](ARCHITECTURE.md) — módulos, fluxos e tratamento de falhas
- [REFERENCES.md](REFERENCES.md) — projetos open source investigados e licenças verificadas
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) — o que é efetivamente usado
- [ROADMAP.md](ROADMAP.md) · [CHANGELOG.md](CHANGELOG.md)

## Licença

GPL-3.0 — veja [LICENSE](LICENSE).
