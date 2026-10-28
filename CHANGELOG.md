# Changelog

## 0.27.0 — 28/10/2026

### Adicionado
- **Karaokê.** No painel da fala (ASS): o botão de microfone na barra de formatação transforma a fala em karaokê **por sílaba** (romaji separado do jeito japonês: sa·ka·ra·u, consoante dobrada e n final à parte; kana e kanji um por caractere) ou **por palavra**, com o tempo da fala repartido pelas letras. A seção **Karaokê** mostra cada sílaba com o seu tempo (− e + de 0,05 s), o jeito de acender (**Troca de cor** `\k`, **Preenche** `\kf`, **Contorno** `\ko`), se as sílabas somam o tempo da fala, e **Distribuir pela fala**, **Marcar no tempo…** (a fala toca e você aperta Return quando cada sílaba começa, como no Aegisub) e **Remover**. A pré-visualização no vídeo já mostrava o karaokê acendendo (libass).
- **Tempos da legenda ao lado.** Quando a legenda editada está vazia e a de Ao lado tem outros tempos, o app pergunta, sem opção de pular: *Usar os tempos de “English” nesta legenda?* **Sim** cria as mesmas falas, nos mesmos tempos, estilos, personagens e posições, em branco (⌘Z desfaz); **Não** volta Ao lado para Nenhuma. Uma legenda com texto nunca é perguntada: continua casando as falas pelo tempo. *Novo › Legenda…* abre a nova com a legenda que você editava ao lado.
- **Painel da fala fixo na lateral.** O ícone no canto do painel faz ele ocupar toda a lateral direita, ao lado do vídeo e da lista; clicar de novo o devolve para junto da lista. A largura arrastada vale nos dois jeitos.

### Mudou
- **← →** voltam e avançam 15 s de novo (só pelo teclado, sem botões no player).
- Com Ao lado preenchido, a legenda editada fica na coluna da **direita** e a de consulta à esquerda. A coluna Personagem estreita quando a lista é estreita.

## 0.26.0 — 28/10/2026

### Adicionado
- **Formatação sem digitar códigos.** Acima do texto da fala: **Itálico** (⌘I), **Negrito** (⌘B), **Sublinhado** (⌘U), **Riscado**, **Cor** (9 cores) e **Tamanho** (em relação ao estilo da fala), mais **Limpar formatação**. Valem para o trecho selecionado ou, sem seleção, para a fala inteira; clicar de novo tira. Uma seleção nunca corta um código ao meio, e depois de um trecho colorido ou de outro tamanho a fala volta ao estilo. No SRT usa `<i>`, `<b>`, `<u>`, `<s>` e `<font color>` (sem tamanho). Limpar não mexe em posição, tempo, animação nem karaokê.
- **Como fica:** abaixo do texto, a fala aparece como no vídeo (itálico, negrito, cores), sem os códigos, sempre que ela tem formatação.

## 0.25.0 — 28/10/2026

Legendar reorganizado (pedido do usuário): uma legenda editada por vez e uma barra só.

### Mudou
- Barra de Legendar: **Editando ▾** e **Ao lado ▾** à esquerda (Ao lado aparece sempre e fica desativado quando o vídeo não tem outra legenda), **Traduzir** no meio, **Novo ▾** e **Salvar ▾** à direita. Saíram o selo "Rascunho", o ícone de exportar, o menu Traduzir antigo e o painel lateral da tradução.
- **Traduzir** abre uma janela: *Traduzir de* Legenda do vídeo (qual) ou Áudio do vídeo (idioma falado, faixa, separar as vozes para a dublagem), cada um desativado quando o vídeo não tem aquilo; *Idioma de saída*; motor e glossário. Do áudio no mesmo idioma falado, só escreve o que é dito. "Criar a partir do áudio" virou essa opção.
- A tradução passa a ser a legenda editada (Editando: "Tradução · Português"), com a original em Ao lado, só para consulta; não se editam duas legendas ao mesmo tempo.
- **Novo ▾**: *Legenda…* (janela com nome e idioma, sempre em branco) e *Importar arquivo…*.
- **Salvar ▾**: *Gravar no vídeo…* (janela com nome e flags da faixa nova, ou o aviso de que a corrigida substitui a antiga, e onde gravar) e *Exportar arquivo…*.
- Sem rascunho na tela: as edições continuam guardadas em silêncio contra travamento, mas trocar de tela ou de legenda, abrir outro vídeo ou sair do app (⌘Q) com alterações não salvas pergunta **Gravar no vídeo / Exportar / Descartar / Continuar editando**. Descartar volta tudo ao que está no vídeo. Ao reabrir um vídeo com alterações guardadas, um aviso diz isso.
- O painel da fala pode ser alargado arrastando a borda (a largura mínima continua a mesma); as colunas **Texto** e **Ao lado** têm sempre a mesma largura e encolhem por igual.
- Player: saíram os botões −15/+15 s e as teclas ← →; **Espaço** toca ou pausa também com o foco num texto que não está sendo editado.

### Removido
- "Trazer uma tradução pronta" (alinhar uma tradução existente pelo tempo) e o modo de mostrar original e tradução juntos no vídeo.

## 0.24.0 — 28/10/2026

### Corrigido
- **Posição marcada errada.** A grade pintava o lado de ancoragem (que vem do estilo, quase sempre "embaixo, no centro") e não onde a fala aparece: uma fala com ponto exato no meio da tela, à esquerda, saía marcada como embaixo. Agora o app calcula o ponto real de cada fala (`\pos`, início do `\move`, ou alinhamento + margens + resolução do script) e só pinta uma área quando a fala está mesmo nela; fala num ponto livre fica sem área pintada e ganha um pontinho no lugar real, na grade do painel e no mini-ícone da lista.
- A tag de alinhamento antiga do SSA (`\a5`, `\a10`…), que o libass ainda respeita, era ignorada.

### Adicionado
- Teclado em Legendar, com o foco em qualquer lugar menos num campo de texto: **↑ ↓** trocam de fala (seguindo o filtro e a busca da lista) e levam o vídeo até ela, **← →** voltam e avançam 15 s, **Espaço** reproduz ou pausa. Antes as setas só funcionavam com a lista em foco, que um clique no vídeo, no texto ou num botão tirava.
- Player: botões **−15 s** e **+15 s**.

## 0.23.0 — 27/10/2026

### Adicionado
- **Mover a legenda no vídeo.** Com uma fala selecionada, o vídeo pausado e a fala na tela, aparece uma alça rosa no ponto onde ela se ancora: arraste e a fala vai para lá (`\pos(x,y)` no ASS). Enquanto arrasta, uma linha tracejada e as coordenadas mostram o destino. ⌘Z desfaz.
- No painel da fala, **Posição na tela** ganhou setas ← ↑ ↓ → (1% da tela por clique; com ⌥, 1 ponto) e campos **X** e **Y** para o ponto exato.
- Selecionar uma fala com o vídeo pausado leva o vídeo até ela, para você ver e mover o que está editando.

### Mudou
- A grade 3×3 agora põe a fala de fato naquela área da tela também quando ela tinha um ponto exato (`\pos` é retirado). Antes, nessas falas, a grade só mudava o lado de ancoragem e a fala parecia não sair do lugar. "Usar a do estilo" tira `\an` e `\pos`.
- Falas que se movem sozinhas (`\move`) mantêm a animação: arrastar e as setas não se aplicam a elas, e o painel diz por quê. Em SRT, que não tem ponto exato, só a grade.

## 0.22.0 — 27/10/2026

### Corrigido
- **Voz dublada pouco parecida com o personagem.** Com "Voz e emoção de cada fala" (ligado por padrão), cada fala era clonada só do trecho original daquela fala, muitas vezes 2 s, e o Chatterbox tira o timbre de até 10 s de referência. Medido com um modelo de reconhecimento de voz independente (WeSpeaker) sobre gravações reais de 4 pessoas (CMU ARCTIC, inglês → português): a semelhança com a voz real era 0,41 com o trecho curto contra 0,74 com a amostra de ~12 s do personagem. Agora a referência é o trecho da fala (emoção) seguido da amostra do personagem (voz): 0,72. Para comparar, duas gravações reais diferentes da mesma pessoa dão 0,91: o clone se parece com a pessoa, mas não é idêntico a ela. Teste de medição: `ALS_VOICE_EVAL=<pasta> swift test --filter VoiceCloneEvaluation`.
- "Identificar falantes no áudio" e a identificação automática da dublagem ouviam sempre o áudio padrão do arquivo, mesmo com outro áudio de base escolhido em Dublar (por exemplo quando o padrão é uma dublagem anterior).
- Um personagem renomeado em Dublar a partir de uma legenda do vídeo ficava sem voz na dublagem seguinte: a escolha automática das vozes procurava só pelo nome, não pelo nome antigo guardado.

### Mudou
- Painel da fala em Legendar: o **texto** vem primeiro (era preciso rolar para chegar nele); tempo, estilo, personagem e posição na tela vêm depois.
- Dublar abre na **Voz original no Mac** enquanto não houver chave da ElevenLabs salva e você não tiver escolhido um motor, em vez de uma tela que não consegue dublar.
- Visão geral: o "Tornar padrão" de "Nenhuma legenda ligada ao abrir" alinhado com os de cima.

### Testes
- De ponta a ponta com as ferramentas reais: legenda criada **só a partir do áudio** (transcrição → faixa nova no idioma falado, conferida) e legenda **traduzida a partir de outra** (tags de posição e itálico e personagens mantidos → faixa nova pt-BR ao lado da original → exportada como arquivo).

## 0.21.0 — 27/10/2026

Revisão do app inteiro: fluxo, textos e código sem uso.

### Corrigido
- **Velocidade** de cada personagem (Dublar › Ajustar vozes) não fazia nada com a voz do Mac. Agora as falas do personagem saem mais lentas ou mais rápidas, e as que ainda não cabem no tempo são aceleradas um pouco além disso. Mudar a velocidade não gera a fala de novo, só reencaixa.
- Renomear um personagem em Dublar mudava a legenda aberta em Legendar, que podia ser outra, e com texto de uma legenda do vídeo o nome novo "sumia" (o personagem ficava com 0 falas). Agora: vozes achadas pelo áudio ("Voz 1") são renomeadas no app; nomes da tradução feita no app são renomeados nela; nomes de uma legenda do vídeo viram outro nome do mesmo personagem, sem mexer na legenda.
- "Ouvir dublada" falava sempre no idioma de saída dos Ajustes e com uma frase em português; agora fala uma fala real do personagem no idioma do texto falado.
- Menu Arquivo › "Abrir legenda externa…" trocava a legenda sem perguntar sobre alterações não gravadas. Virou "Importar arquivo de legenda…" (⇧⌘O), o mesmo caminho do botão Nova legenda, só em Legendar.
- A janela Dublar dizia que "a legenda" entraria no arquivo também quando o texto falado já era uma legenda do vídeo (ela não é adicionada de novo), e o nome do novo arquivo usava o idioma dos Ajustes em vez do idioma da dublagem.

### Mudou
- Corrigindo uma legenda, o menu ⋯ (com "Editar séries e glossários", que só vale para traduzir) virou um botão "Salvar como arquivo" (⇧⌘E). O glossário continua no painel da tradução.
- Textos: sem "Falante N" nas dicas (as vozes se chamam "Voz 1, 2…"), sem "no estúdio", sem "incorporar"; tela inicial e aba Dublar explicam também a ElevenLabs.

### Removido (código sem uso)
- A fila de episódios e o relatório da temporada (`JobQueue`, `EpisodeJobPerformer`, `SeasonReport`), fora da interface desde a 0.11.0, e os testes deles.
- A identificação de falantes que escrevia nomes na legenda (só um gancho de teste ainda chamava), e funções, propriedades e imports que nada usava (achados com o Periphery).
- `style` e `speed` do protocolo de síntese de voz: o Chatterbox não usa nenhum dos dois.

## 0.20.0 — 27/10/2026

### Adicionado
- Visão geral: **Excluir…** em cada áudio e legenda, com confirmação. A janela mostra o que depende da faixa (padrão, único áudio, legenda aberta em Legendar, áudio de base da dublagem) e pergunta onde gravar: novo arquivo sem ela ou este arquivo (regravado sem recodificar, conferido, versão anterior na Lixeira).
- Ao excluir uma legenda, as fontes ficam no arquivo (são do arquivo inteiro, não de uma legenda; duas legendas com a mesma fonte usam o mesmo anexo). A confirmação mostra as fontes que **só aquela legenda** usa e deixa excluí-las junto; fontes que outra legenda usa nunca são excluídas.

### Corrigido
- Regravar o próprio arquivo renumera as faixas: agora o app atualiza as referências que guarda (legenda em edição, legenda ao lado, áudio e texto da dublagem, vozes identificadas, dublagem online pendente) em todas as operações que regravam o arquivo, e extrai de novo cópias de legenda mais antigas que o vídeo.

## 0.19.0 — 27/10/2026

### Adicionado
- **Posição na tela** de cada fala: no painel da fala, uma grade 3×3 mostra onde ela aparece (em cima, no meio, embaixo; esquerda, centro, direita) e se a posição vem do estilo ou da própria fala; clicar muda só aquela fala (`{\anN}`), e "Usar a do estilo" volta ao padrão. Falas com ponto exato (`\pos`) são indicadas. Na lista, cada fala tem um mini-indicador da posição, e o menu do botão direito muda a posição de várias falas de uma vez.
- **Personagem** virou um campo de digitar com lista dos nomes que você já escreveu (seta ▾), gravado ao apertar Return ou sair do campo, para nunca escrever o mesmo personagem de dois jeitos. Aparece também em legendas SRT.

### Mudou
- O app não escreve mais "Falante N" em lugar nenhum: as vozes separadas pelo áudio (agora "Voz 1, 2…") ficam guardadas no app para a dublagem, inclusive na transcrição, e você dá o nome de cada personagem. "Identificar quem fala pelo áudio" saiu do Legendar.
- A coluna Personagem não mostra mais o nome do estilo quando a fala não tem personagem ("—" e o estilo embaixo, em cinza).

## 0.18.1 — 27/10/2026

### Corrigido
- Escolher outra legenda em "Editando" (por exemplo Português) mostrava o seletor certo mas continuava carregando o texto da faixa anterior (Inglês): o app comparava a faixa escolhida com a própria escolha, não com a faixa de onde o arquivo tinha sido extraído. Agora ele guarda de qual faixa o arquivo veio e extrai de novo quando é outra. Projetos antigos sem rascunho pendente são extraídos de novo uma vez.

## 0.18.0 — 27/10/2026

### Corrigido
- Dublar (voz do Mac) só aceitava a tradução feita no app e dizia "Ainda não há legenda traduzida" mesmo com o vídeo já tendo legenda em português. Agora há **Texto falado**: a tradução do app ou qualquer legenda do vídeo; a dublagem sai no idioma dessa legenda, e uma legenda que já está no vídeo não é adicionada de novo.
- A dublagem identificava os falantes sozinha e **gravava "Falante 1, 2…" na legenda**. Agora quem fala, achado pelo áudio, fica guardado no app e a legenda não muda. Em Dublar › Personagens aparece de onde vieram os nomes e **Limpar** esquece os identificados e tira da legenda os "Falante N" gravados antes. Renomear um personagem vale também para os guardados no app.
- O ⇄ da barra do Legendar só aparece quando há uma legenda "Ao lado" (antes ficava desativado sem explicação).

## 0.17.0 — 27/10/2026

### Mudou
- A **Voz original no Mac** agora usa o **Chatterbox Multilingual** (Resemble AI, MIT) pelo speech-swift (Apache-2.0) e MLX, na GPU do Apple silicon, no lugar do Pocket TTS. Clona a voz de cada personagem a partir do trecho original de cada fala (voz e emoção), em 23 idiomas, inclusive português e japonês. O modelo (~2 GB) é baixado uma vez, com progresso na janela da dublagem. Teste real: o reconhecimento de fala da Apple leu de volta a frase gerada sem erros.
- Ajustes › Armazenamento mostra e limpa o modelo novo, o tokenizador e o modelo antigo (Pocket TTS).

### Notas de build
- Compilar exige o Metal Toolchain do Xcode (`xcodebuild -downloadComponent MetalToolchain`); `Scripts/build-app.sh` copia os kernels do MLX para o app e falha se faltarem.

## 0.16.0 — 27/10/2026

### Mudou
- Legendar abre direto no editor, sem tela de escolhas nem "Voltar". Tudo fica na barra: **Editando [▾] ⇄ Ao lado [▾]**, **Nova legenda** (em branco no idioma escolhido, importar arquivo, criar a partir do áudio) e **Traduzir** (traduz a legenda atual para o idioma escolhido, automaticamente; na tradução, "Voltar a editar só a original").
- "Criar a partir do áudio" virou uma janela curta (áudio, idioma falado, identificar quem fala, traduzir em seguida).
- Vídeo sem legenda de texto: o editor oferece começar em branco, importar ou criar do áudio.
- Trocar para uma legenda nova com alterações não gravadas pergunta antes (gravar no vídeo, descartar e trocar ou continuar).

## 0.15.0 — 27/10/2026

### Mudou
- **Dublar com a ElevenLabs** (novo padrão): só a faixa de áudio vai para o serviço, que separa os personagens, traduz e dubla com a voz de cada um, mantendo emoção e música. Não precisa de legenda traduzida. Você escolhe o áudio, o idioma falado (ou automático) e o idioma de saída; a chave fica no Keychain e a conta mostra plano e créditos. O resultado entra no MKV como faixa nova, verificado, e vai para o histórico. Um trabalho interrompido é retomado sem enviar nem cobrar de novo.
- A dublagem local ficou só com a **Voz original no Mac** (Pocket TTS). As vozes do macOS e o VoiceStudio saíram.
- O áudio de base da dublagem passa a ser o do idioma original (não uma dublagem anterior que esteja como padrão).

## 0.14.0 — 27/10/2026

### Adicionado
- Legendar começa com cinco caminhos: **Corrigir uma legenda do vídeo** (sozinha ou comparando com outra), **Traduzir uma legenda** (com "Importar arquivo…" como base), **Criar a partir do áudio** (escolhe o áudio e o idioma falado, cria a legenda no tempo certo no idioma original, identifica quem fala e, se quiser, já traduz em seguida), **Começar em branco** (só ela na tela, no idioma escolhido) e **Importar um arquivo de legenda**.
- Legendas que não vieram do vídeo (em branco, importadas, transcritas) são gravadas como faixa nova, com nome e idioma certos; o idioma pode ser trocado na barra.
- Visão geral: **Extrair todas as fontes…** de uma vez, em Anexos.

### Corrigido
- A transcrição usava sempre o áudio padrão; agora usa o escolhido. O pedido para baixar o modelo de fala aparece em qualquer tela e retoma a transcrição com as mesmas opções.

## 0.13.0 — 27/10/2026

### Adicionado
- **Estilos e fontes** (Legendar): criar, duplicar, renomear (as falas acompanham) e apagar estilos (escolhendo para qual estilo vão as falas), além de editar; seletor de fonte com as fontes do Mac, do vídeo e as adicionadas. Aba **Fontes**: cada fonte que a legenda usa aparece como anexada ao vídeo, só neste Mac ou faltando; **Adicionar fontes…** (anexadas ao vídeo em "Gravar no vídeo…", verificadas) e **Extrair fontes do vídeo…**.
- Barra do Legendar com as duas legendas à vista: **Editando [▾] ⇄ Ao lado [▾]** (o ⇄ inverte) ou **Legenda nova em [idioma] a partir de [base]**. Trocar a legenda editada ou a base pergunta antes se houver rascunho.
- **Personagens** no Legendar: definir quem fala em várias falas de uma vez (com sugestões) e identificar falantes pelo áudio. No ASS o nome vai no campo `Name` (não aparece na tela); no SRT, que não tem esse campo, fica guardado no projeto e o arquivo não muda.
- Dublagem com **a voz e a emoção de cada fala**: com a voz original, cada fala é recriada a partir do próprio trecho original (sem a música); falas com menos de 1,5 s usam a amostra do personagem. Pode ser desligado em "Ajustar vozes".

### Corrigido
- A voz original no Mac falava sempre português: agora segue o idioma de saída (português, espanhol, inglês, francês, alemão, italiano; cada idioma baixa o seu pacote). Para japonês, coreano e chinês o app avisa e oferece as outras vozes.
- Ao corrigir uma legenda, o painel da direita quase vazio saiu; "Salvar como arquivo" e glossários ficam no menu ⋯ da barra, e avisos aparecem logo abaixo dela.

## 0.12.0 — 27/10/2026

### Mudou
- Legendar começa por um formulário único, "O que você vai editar?":
  - **Uma legenda do vídeo**: corrigir uma faixa, com **"Mostrar ao lado"** opcional para ver outra legenda (por exemplo a inglesa ao corrigir a portuguesa) numa coluna só de leitura, casada pelo tempo.
  - **Uma legenda nova**: escolher o **idioma**, a legenda **base** e, se quiser, **traduzir automaticamente** com o motor escolhido ao começar.
- Um só jeito de salvar no vídeo: **"Gravar no vídeo…"** (⌘S), na barra do Legendar. Tudo o que você muda fica como **rascunho** no app até ser gravado; o selo "Rascunho" permite descartá-lo.
- Sair do Legendar depois de mudar algo pergunta: **Gravar no vídeo…**, **Manter como rascunho**, **Descartar alterações** ou **Continuar editando**.
- O painel da direita ficou enxuto: ao corrigir, só "Mostrar ao lado"; na legenda nova, tradução (motor, glossário, traduzir, trazer uma tradução pronta) e a faixa no vídeo (nome, ligada ao abrir, primeira da lista).
- Abas do topo refeitas: ícone e nome, a atual em rosa com sublinhado que desliza.
- Dublar reorganizado: resumo (voz e fundo, texto falado, resultado, vozes) com o botão **Dublar…**, depois **Dublagens feitas**, depois "Ajustar vozes e personagens" recolhido, e **Recomeçar do zero…** no fim.
- Vocabulário unificado ("Gravar no vídeo", "Este arquivo", "sem idioma" no lugar de "UND") e plurais corretos ("1 fala", "1 fonte").

### Corrigido
- Apagar os arquivos guardados ou trocar o áudio de base deixava o elenco apontando para amostras de voz apagadas; agora as vozes são zeradas junto.
- Apagar uma dublagem do histórico não atualizava a página: agora oferece "apagar e recomeçar do zero" (vozes, arquivos e "Última dublagem" somem na hora) ou "só tirar do histórico".
- O nome da faixa acompanha o idioma de saída (antes ficava "Português (Brasil)" mesmo em outro idioma).
- O app não carrega mais sozinho uma faixa traduzida do vídeo como tradução; use "Trazer uma tradução pronta".

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
