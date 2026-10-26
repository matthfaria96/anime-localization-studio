# Changelog

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
