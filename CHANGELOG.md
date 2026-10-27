# Changelog

## 0.11.0 — 27/10/2026

### Mudou
- Sem menu lateral. A tela inicial explica o app e recebe um vídeo por vez (arrastar ou "Escolher vídeo…"; pastas e vários arquivos são recusados com aviso).
- Com o vídeo aberto, o topo da janela tem só o seletor **Visão geral | Legendar | Dublar**; cada troca de página carrega os dados do vídeo de novo. "Fechar vídeo" fica na Visão geral (e no menu Arquivo).
- Legendar não tem mais botões na barra superior: depois da escolha entre editar uma legenda existente e criar uma tradução, uma barra própria tem **Voltar** (volta à escolha e recarrega tudo), o aviso de alterações não salvas, **Descartar** e **Salvar** (⌘S). Traduzir (⇧⌘T), incorporar, salvar no MKV e exportar ficam no painel da direita, que agora está sempre visível.
- Sair de Legendar com alterações (trocar de página, Voltar, fechar ou abrir outro vídeo) pergunta: Salvar, Descartar alterações ou Continuar editando. Descartar volta a legenda para como estava quando a tela carregou.

### Adicionado
- Histórico de dublagens em Dublar: arquivo, data, vozes, modo, áudio de base, falas e se passou na verificação, com "Mostrar no Finder" e apagar. Apagar sempre confirma e oferece tirar só do histórico ou também mandar o arquivo dublado para a Lixeira (nunca o vídeo aberto nem um arquivo gravado sobre o original).
- Apagar os arquivos guardados da dublagem agora pede confirmação.

### Removido
- Biblioteca, Fila e Recentes da interface.

## 0.10.0 — 27/10/2026

### Mudou
- Menu lateral simplificado: sob o episódio aberto, **Visão geral**, **Legendar** e **Dublar**; depois Abrir episódio, Biblioteca, Fila e Recentes. Diagnóstico foi para Ajustes › Diagnóstico e Séries e glossários abre por "Editar séries e glossários…" em Legendar.
- Nova **Visão geral** do episódio: tamanho, duração, contêiner, codecs e resolução; faixas de vídeo, áudio e legenda listadas com clareza; "Tornar padrão" em cada áudio e legenda (sem estrelas), gravado no próprio arquivo ou numa cópia; **Extrair…** salva qualquer faixa como arquivo separado, sem converter.
- **Legendar** começa perguntando o que fazer: **editar uma legenda existente** (uma coluna só, sem tradução; "Salvar no MKV…" grava a versão corrigida no lugar da faixa original, com o mesmo idioma, nome e flags, num arquivo novo ou no próprio) ou **criar uma tradução** (original e tradução lado a lado, como antes). O painel da direita foi refeito: legenda base em lista de opções, tradução, motor, glossário e gravação; "Trocar" volta à escolha.
- **Dublar** diz o que vai acontecer: qual **áudio de base** é usado (escolhível quando há mais de um; as vozes e o fundo saem dele), que o **texto falado** é a legenda traduzida (o áudio não é interpretado) e qual o **idioma do resultado**.
- A janela não encolhe mais do que o conteúdo precisa (o menu lateral não se desmonta em janelas baixas).

### Adicionado
- "Gerar tudo do zero" na janela de dublagem: apaga as falas, vozes e fundo já gerados e refaz tudo, inclusive a escolha das vozes.
- Tamanho dos arquivos guardados de cada dublagem, com botão para apagar.
- Ajustes › **Armazenamento**: tamanho de pré-visualizações, fontes extraídas, temporários, arquivos de dublagem, projetos e modelos baixados, cada um com "Apagar" (episódios abertos ou em processamento são pulados).

### Corrigido
- Os Recentes no menu lateral não respondiam ao clique; agora abrem o episódio (e avisam se o arquivo sumiu).

## 0.9.0 — 27/10/2026

### Adicionado
- "Voz original (no Mac)", o novo padrão da dublagem: cada personagem fala português com um clone da própria voz do episódio, feito no Mac pelo Pocket TTS da Kyutai (Core ML via FluidAudio, CC-BY-4.0, ~500 MB baixados uma vez com aviso). Cerca de 0,7 s por fala depois de carregado; o reconhecimento de fala em português lê de volta as frases geradas.
- Botão ↻ para procurar de novo o VoiceStudio.
- A janela de dublagem diz quantas falas já geradas serão reaproveitadas.

### Corrigido
- "Capítulos preservados: 11 de 6": o FFmpeg copiava os capítulos do vídeo para o áudio dublado e o mkvmerge os somava aos originais. Agora o áudio é gerado sem capítulos e arquivos adicionados nunca trazem capítulos, tags ou anexos.
- Layout que quebrava ao redimensionar: o inspetor fica ao lado quando cabe e se recolhe sozinho em janelas estreitas (abre como gaveta pelo botão ⌥⌘I); a barra do editor e o painel da fala se compactam; início e fim viraram uma coluna "Tempo"; a barra superior ficou com Traduzir, Arquivo e Inspetor. Janela mínima 960×640.
- A tabela de falas era refeita 30 vezes por segundo durante a reprodução (avisos de reentrada do NSTableView, que podiam derrubar o app); o acompanhamento do vídeo agora fica isolado.

## 0.8.0 — 26/10/2026

### Mudou
- "Legendar" e "Dublar" agora são itens do menu lateral, sob o episódio aberto, em vez de um seletor no topo da janela.
- Dublagem numa janela guiada: antes, mostra o que vai acontecer (vozes, modo, personagens, falas), avisa se o VoiceStudio não está aberto e pergunta onde gravar (novo arquivo ou o próprio arquivo); durante, mostra cada etapa; no fim, mostra o arquivo criado, a pasta e os botões para abri-lo, ou explica o erro e o que fazer.
- A dublagem também pode ser gravada no próprio arquivo (verificado antes, original na Lixeira).
- Operações de dublagem são registradas no log do app.

### Corrigido
- O nome sugerido não repete mais o sufixo quando o arquivo já é dublado.

## 0.7.0 — 26/10/2026

### Adicionado
- Faixas padrão: uma estrela em cada áudio e legenda escolhe qual abre ligada nos players; aplicar no próprio arquivo (instantâneo, `mkvpropedit`, sem regravar o vídeo) ou numa cópia.
- "Incorporar ao MKV" pergunta onde gravar: novo arquivo ou o próprio arquivo (o novo é verificado antes e o original vai para a Lixeira).
- Escolha manual da legenda original (qualquer faixa ou arquivo externo) e da tradução (vincular outra faixa do arquivo, um arquivo de legenda, ou começar do zero). Legendas com linhas diferentes são casadas pelo tempo.
- Ao abrir um arquivo que já tem a faixa em português (por exemplo, um MKV incorporado antes), ela é carregada como tradução automaticamente.
- Tudo é recarregado depois de importar uma legenda, incorporar ou mudar faixas; avisos com botão para abrir o arquivo criado.
- Dublagem automática com a voz original: o app identifica quem fala (se preciso), separa a voz de cada personagem, clona com o VoiceStudio ou escolhe uma voz do macOS de tom parecido, e dubla tudo num clique. "Ouvir original" mostra quem é cada personagem; escolher vozes à mão é opcional.
- Modo e motor de dublagem em cartões com explicação própria (antes a dica do "Substituir falas" repetia a do voice-over). "Substituir falas" passa a ser o modo padrão.

## 0.6.2 — 26/10/2026

### Melhorado
- Todos os botões, ícones, seletores e campos mostram uma explicação ao passar o mouse (título e o que fazem), num balão próprio que aparece rápido — inclusive os ícones da barra do editor e do painel da fala selecionada.

## 0.6.1 — 26/10/2026

### Corrigido
- "Espaço insuficiente… há Zero KB" ao incorporar em discos exFAT, FAT32, NTFS ou de rede: o macOS informa 0 de espaço "para uso importante" nesses volumes mesmo com terabytes livres. O app agora usa a maior medida disponível (espaço livre do volume e `statfs`) e não bloqueia quando nenhuma informa.

## 0.6.0 — 26/10/2026

### Adicionado
- Identificar quem fala, no Mac (FluidAudio, Neural Engine): ao transcrever ("Transcrever e identificar quem fala") ou numa legenda já existente sem personagens ("Identificar falantes no áudio", na aba Dublagem). As falas recebem "Falante 1", "Falante 2"…; renomear um falante no elenco muda todas as falas dele. Os modelos (~22 MB, CC-BY-4.0) só são baixados com confirmação.
- O elenco pode ser montado antes de traduzir.

## 0.5.0 — 26/10/2026

### Adicionado
- Pré-visualização fiel de ASS com libass, o mesmo renderizador de mpv, VLC e Aegisub: animações (`\t`, `\move`, `\fad`), karaokê, desenhos vetoriais, clipes, rotação, desfoque e as fontes anexadas ao MKV, renderizados na densidade de pixels da tela. Pode ser desligada em Ajustes › Geral.
- O libass e as bibliotecas de que ele depende vão dentro do app (`Contents/Frameworks`), com os textos das licenças em `Contents/Resources/Licenses`.

## 0.4.0 — 26/10/2026

### Adicionado
- OCR de legendas em imagem PGS (Blu-ray): decodificação própria do formato e reconhecimento de texto do Vision no Mac; o resultado vira a legenda de origem, pronta para traduzir.
- Contexto entre episódios: o fim do episódio anterior já traduzido orienta o início do próximo.
- Limite de leitura (caracteres por segundo) configurável.
- Teste de desempenho com 5 000 falas.

## 0.3.0 — 26/10/2026

### Adicionado
- Dublagem no modo "Substituir falas": as vozes originais são separadas da música e dos efeitos no próprio Mac (isolamento de voz da Apple, `AUSoundIsolation`) e trocadas pelas novas.
- Transcrição do áudio no Mac (`SpeechAnalyzer`) para vídeos sem legenda, em 45 idiomas, com confirmação antes de baixar o modelo de um idioma.
- Inserir e excluir falas no editor (desfazível).
- Filtro "Possíveis erros de ortografia".
- Relatório da temporada em Markdown na Fila.

### Corrigido
- Arquivos não editados com fins de linha mistos voltam idênticos.
- Arquivos quase todos em UTF-8 com bytes inválidos não viram mais Windows-1252.
- A legenda é reextraída quando o vídeo é trocado no mesmo caminho.
- A chave de API configurada nunca aparece nos logs, mesmo sem prefixo conhecido.

## 0.2.0 — 26/10/2026

### Adicionado
- "Dublar episódio inteiro" (voice-over): síntese de cada fala com o elenco (vozes do macOS ou VoiceStudio), ajuste ao tempo de cada fala, mixagem com ducking e normalização EBU R128, e novo `Nome [PT-BR DUB].mkv` com o áudio dublado e a legenda pt-BR, verificado e com todas as faixas originais.
- Elenco de vozes salvo na série (ou no projeto) e reaproveitado entre episódios; fila "Traduzir e dublar" na Biblioteca.
- Trava por projeto: a fila e o episódio aberto não processam o mesmo arquivo ao mesmo tempo.
- `Scripts/install.sh`: compila, testa e instala em /Applications.
- Licença GPL-3.0.

### Corrigido
- Traduzir de novo mantém as falas já traduzidas ou editadas à mão (opção explícita para refazer tudo).
- Rascunhos não aplicados da fala selecionada são aplicados antes de incorporar, traduzir, exportar ou fechar.
- Desfazer não restaura documentos de outra faixa depois de trocar a legenda de origem.
- `\r` e outros terminadores de linha vindos do tradutor não quebram mais uma linha ASS/SRT.
- Erros temporários esgotados interrompem a tradução em vez de multiplicar pedidos.
- Arquivos parciais com nome único; corrida no cancelamento de processos; troca de faixa só apaga a tradução se a cópia de segurança deu certo; `project.json` ilegível é preservado; Keychain atualiza antes de apagar.
- Falas sem palavras ("♪ ♪") não interrompem a dublagem.

## 0.1.0 — 26/10/2026 (não publicado)

Primeira versão funcional.

### Adicionado
- Parser e gravador ASS/SSA/SRT que preserva o arquivo byte a byte quando nada muda e altera só o campo editado.
- Abertura de MKV/MP4/MOV, inspeção de faixas com MKVToolNix (fallback FFprobe), player com prévia remuxada sem recodificar e legenda sobreposta.
- Editor de falas: original × tradução, tempos, estilos, personagens, busca e substituição que não toca em tags, deslocamento de tempos, desfazer/refazer, salvamento automático.
- "Traduzir episódio inteiro" com Tradução da Apple, Apple Intelligence (modelo local) ou servidor compatível com OpenAI (Ollama, LM Studio, serviços online); lotes com contexto, glossário, retentativas, checkpoints e relatório.
- Séries com glossário e notas para o tradutor.
- "Incorporar ao MKV": novo arquivo com a faixa pt-BR (idioma, nome, padrão, ordem), verificado antes de salvar — inclusive prova de que o vídeo não foi recodificado. O original nunca é alterado.
- Biblioteca de pastas e fila persistente para temporadas, com retomada após fechar o app.
- Dublagem: cliente da API local do VoiceStudio, elenco por personagem e amostras de voz (pipeline completo ainda não implementado).
- Diagnóstico de ferramentas, motores e VoiceStudio; ajustes; chaves de API no Keychain; logs sem segredos.
- Ícone próprio, tema claro e escuro, interface em português do Brasil.
