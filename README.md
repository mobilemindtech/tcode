# tcode

Editor/console para avaliação rápida de código em várias linguagens, escrito em
Tcl/Tk. Não é uma IDE: é **um arquivo só** (`tcode.tcl`), sem dependências além
de Tcl/Tk 8.6 ou 9.x.

Inspirado no *groovyConsole*: editor em cima, saída da execução embaixo. O
código roda em um processo separado, então a interface não trava e a execução
pode ser interrompida a qualquer momento.

![tcode executando um programa Scala Native](screen.png)

> Internamente o programa se identifica como **qconsole** (versão 2.0): esse é
> o nome usado no arquivo de configuração e no diretório de linguagens do
> usuário.

## Recursos

- Destaque de sintaxe, números de linha, realce da linha atual e de pares de
  parênteses/chaves/colchetes
- Parênteses coloridos por nível de aninhamento ("rainbow") em Scheme, Tcl e
  OCaml; os que ficam sem par (ou com o par trocado, ex.: `(]`) em vermelho
- Em Scheme, `define` e `lambda` aparecem como `λ` (só na tela: o arquivo não muda; a
  palavra sob o cursor volta a aparecer para edição). Exibir > Símbolos no
  lugar de palavras liga/desliga
- Abas: cada arquivo aberto tem a sua (com desfazer, cursor e linguagem
  próprios); ● marca alterações não salvas, o botão do meio fecha, o botão
  direito tem Fechar / Fechar as outras / Copiar caminho. As abas são
  reabertas na próxima vez
- Ir para definição (F12 ou Ctrl+clique, Alt+← volta): com Ctrl
  pressionado, os nomes que têm definição ficam sublinhados. Procura nas abas abertas e nos
  arquivos da pasta aberta; com mais de uma definição, mostra um menu para
  escolher. Ao parar o mouse sobre um nome, uma dica mostra a linha da
  definição e os comentários logo acima dela (Exibir > Mostrar definição ao
  passar o mouse). As definições vêm das palavras `defWords` da linguagem
  (`proc`, `let rec`, `def`, `define`…) e das regexes `defPatterns`. Em Tcl e
  Scheme, nomes que não são do projeto são procurados nas bibliotecas
  instaladas (indexadas em segundo plano): os `proc`s do Tcl/Tk/tcllib (pelo
  nome completo, ex.: `tk::TextKeySelect`) com os comentários acima deles, e
  no Guile os procedimentos embutidos (`guile-procedures.txt`, com
  assinatura e documentação) e os `define` dos módulos, com a docstring
- Home vai ao primeiro caractere não branco da linha (de novo: coluna 0);
  Shift+Home seleciona até lá
- Indentação automática por linguagem, Tab/Shift+Tab em blocos, comentar e
  descomentar linhas, duplicar linha
- Fechamento automático de parênteses, colchetes, chaves e aspas; com texto
  selecionado, o par envolve a seleção
- Vários cursores no estilo Sublime: Ctrl+D seleciona a próxima ocorrência da
  seleção, Alt+F3 todas, Alt+clique, Ctrl+clique (fora de um nome com definição) ou
  Shift+Alt+↑/↓ adicionam cursores; o
  que for digitado vale para todos
- Autocompletar (Ctrl+Espaço, ou sozinho ao digitar 3 letras): sugere palavras
  do arquivo aberto, palavras-chave da linguagem e, com uma pasta aberta,
  palavras dos arquivos da pasta da mesma linguagem (indexados em segundo
  plano). ↑/↓ escolhem, Enter/Tab aceitam, Esc fecha; Editar > Sugerir ao
  digitar liga/desliga o modo automático
- Painel lateral com a árvore de arquivos de uma pasta (Arquivo > Abrir pasta,
  Ctrl+Shift+O; Ctrl+B mostra/esconde; `tcode pasta/` abre direto)
- Terminal embutido (Exibir > Terminal, Ctrl+'): um xterm com as cores do
  editor, aberto na pasta do projeto, ao lado da saída ou no lugar dela
  (Exibir > Terminal ao lado / no lugar da saída). No modo "no lugar", a
  saída volta à frente ao executar. O teclado vai para o terminal enquanto o
  mouse estiver sobre ele; `exit` fecha o painel e ⟳ reinicia o shell.
  Exibir > Comando do terminal… troca o emulador (`%W` = id da janela onde
  ele é embutido, `%D` = pasta; ex.: `urxvt -embed %W -cd %D`, `st -w %W`).
  Requer X11 (no Wayland funciona via XWayland)
- Comandos de projeto: um arquivo `.qconsole` na raiz do projeto define o que
  o Ctrl+Alt+R executa (ex.: `sbt run`); Ctrl+R continua executando o arquivo
  e Ctrl+Shift+R a seleção (veja abaixo)
- Localizar/substituir (com regex e diferenciação de maiúsculas), ir para linha
- Executar o arquivo inteiro ou só a seleção, com opções do interpretador e
  argumentos do programa configuráveis por linguagem
- Mensagens de erro clicáveis na saída: levam direto à linha (e coluna) do
  erro no editor
- Saída com cores ANSI, stderr, avisos e mensagens informativas destacados
- Detecção automática do interpretador e da versão instalada
- Modelos de código (Arquivo > Novo a partir de modelo)
- Arquivos recentes, tamanho de fonte, quebra de linha, geometria da janela e
  linguagem são lembrados entre sessões
- Tema escuro inspirado no Darcula
- Novas linguagens podem ser adicionadas por arquivos externos, sem mexer no
  script

## Linguagens embutidas

| Linguagem | Extensões | Interpretadores |
|-----------|-----------|-----------------|
| Tcl/Tk    | `.tcl .tk .tm .test` | `tclsh` (de preferência o da mesma instalação do `wish`) |
| Scala 3   | `.sc .scala` | `scala`, `scala-cli` |
| Scheme    | `.scm .ss .sls .sps .sld` | Guile, Chez Scheme |
| OCaml     | `.ml .mli .mlx` | `ocaml`, OxCaml (switch do opam) |
| Shell     | `.sh .bash .zsh .ksh` | `bash`, `sh`, `zsh`, `dash` |

Detalhes por linguagem:

- **Tcl** — o script roda num wrapper que mostra o valor de retorno do script
  ("Resultado: …") e o `errorInfo` em caso de erro. Se o script criar janelas
  Tk, elas permanecem abertas até serem fechadas.
- **Scala 3** — detecta se o código é um script (`.sc`, instruções soltas) ou
  um fonte com `@main`/`def main`/`extends App` (`.scala`). Há modelos para
  JVM, Scala.js e Scala Native usando diretivas `//> using` do scala-cli.
- **Scheme** — indentação no estilo Lisp. No Guile o código é compilado antes
  de rodar, para que os erros tragam linha e coluna.
- **OCaml** — o runner OxCaml procura o toplevel no switch ativo do opam
  (`OPAM_SWITCH_PREFIX`) ou em `~/.opam/*ox*/bin/ocaml`.

## Uso

```sh
wish tcode.tcl ?-lang tcl|scala|scheme|ocaml|shell? ?arquivo?
```

Ou, com permissão de execução:

```sh
./tcode.tcl exemplo.scm
```

Sem `-lang`, a linguagem é escolhida pela extensão do arquivo; sem arquivo, é
usada a última linguagem da sessão anterior.

Se o interpretador não for encontrado no `PATH`, indique o executável em
**Executar > Opções de execução** (Ctrl+E). Na mesma janela é possível escolher
o interpretador, as opções passadas a ele e os argumentos do programa.

## Atalhos de teclado

| Atalho | Ação |
|--------|------|
| Ctrl+R / Ctrl+Enter | Executar o arquivo |
| Ctrl+Shift+R | Executar seleção |
| Ctrl+Alt+R | Executar o comando do projeto (`.qconsole`) |
| Ctrl+Shift+O | Abrir pasta |
| Ctrl+B | Mostrar/esconder o painel de arquivos |
| Ctrl+' / Ctrl+` | Mostrar/esconder o terminal |
| Ctrl+Break | Interromper execução |
| Ctrl+W | Limpar saída |
| Ctrl+E | Opções de execução |
| Ctrl+N / Ctrl+O / Ctrl+S | Novo / Abrir / Salvar |
| Ctrl+Shift+S | Salvar como |
| Ctrl+F4 | Fechar aba |
| Ctrl+Tab / Ctrl+PgDn | Próxima aba |
| Ctrl+Shift+Tab / Ctrl+PgUp | Aba anterior |
| Ctrl+Q | Sair |
| Ctrl+Z / Ctrl+Y | Desfazer / Refazer |
| Ctrl+F / Ctrl+H | Localizar / Substituir |
| F3 / Shift+F3 | Próximo / Anterior |
| Ctrl+L | Ir para linha |
| F12 / Alt+← | Ir para definição / Voltar |
| Ctrl+D | Selecionar palavra / próxima ocorrência (vários cursores) |
| Alt+F3 | Selecionar todas as ocorrências |
| Ctrl+clique | Ir para definição (com Ctrl, o nome que tem definição fica sublinhado); fora de um nome assim, adicionar cursor |
| Alt+clique | Adicionar cursor |
| Shift+Alt+↑ / Shift+Alt+↓ | Adicionar cursor na linha acima / abaixo |
| Esc | Voltar a um cursor só |
| Ctrl+Shift+D | Duplicar linha |
| Ctrl+/ | Comentar/descomentar linhas |
| Ctrl+Espaço | Completar palavra |
| Tab / Shift+Tab | Indentar / Desindentar |
| Ctrl++ / Ctrl+- / Ctrl+0 | Aumentar / diminuir / restaurar fonte |

## Comandos de projeto (`.qconsole`)

Um arquivo `.qconsole` na raiz do projeto lista comandos, um por linha, no
formato `nome {comando}`. Linhas começando com `#` são comentários:

```tcl
# projeto sbt
run   {sbt run}
test  {sbt test}
build {sbt compile}
```

- **Ctrl+Alt+R** executa o primeiro comando (sem `.qconsole`, executa o
  arquivo). Os outros ficam em Executar > Comandos do projeto.
- **Ctrl+R** continua executando o arquivo atual e **Ctrl+Shift+R** a
  seleção.
- O arquivo é procurado subindo a partir da pasta do arquivo aberto (e da
  pasta aberta no painel lateral).
- Os comandos rodam com `sh -c` na pasta do `.qconsole`. `%F` vira o arquivo
  aberto no editor e `%R` a raiz do projeto.
- O arquivo aberto é salvo antes de executar. Referências `arquivo:linha:coluna`
  na saída (erros do sbt/scalac, por exemplo) viram links.
- Executar > Editar comandos do projeto abre o `.qconsole`, ou cria um modelo
  (com comandos sbt se houver `build.sbt`, make se houver `Makefile`).

## Configuração

As preferências ficam em `~/.qconsolerc` (um dicionário Tcl, gravado ao sair).
Opções de execução são guardadas por linguagem.

## Adicionando linguagens

Arquivos `*.tcl` nestes diretórios são carregados na inicialização:

- `<diretório do tcode.tcl>/lang/`
- `~/.config/qconsole/lang/`

Um arquivo pode definir uma linguagem nova ou redefinir uma embutida. Exemplo
para Lua:

```tcl
qc::language lua {
    name     Lua
    ext      {.lua}
    comment  --                  ;# prefixo de comentário (Ctrl+/)
    indent   2
    tokens {                     ;# ordem = prioridade em empates
        comment {--[^\n]*}       ;# regex ARE, sem grupos de captura...
        string  {"(?:[^"\\\n]|\\.)*"?}
        number  {\m[0-9]+(?:\.[0-9]+)?\M}
        word    {[A-Za-z_][A-Za-z0-9_]*}   ;# "word": classificado por "words"
        brace   {[][(){}]}
    }                            ;# ...ou com UM grupo: só ele é colorido
    words    { keyword {local function end if then else return} }
    defWords {function}          ;# a palavra seguinte recebe a tag defname
    indentAfter {(?:\mthen|\mdo|\mfunction\M.*\)|\{)\s*$}
    runners {
        {name lua exe {lua5.4 lua} args {%O %F %A} version {-v}
         versionRe {Lua ([0-9.]+)}}
    }
    errPatterns {{%F:([0-9]+):}} ;# grupo 1 = linha, grupo 2 = coluna
}
```

Nos `args` do runner:

| Marcador | Significado |
|----------|-------------|
| `%F` | arquivo a executar |
| `%W` | wrapper (chave `wrapper` do runner) |
| `%O` | opções do interpretador definidas pelo usuário |
| `%A` | argumentos do programa |
| `%--A` | `-- args`, se houver argumentos |

Outras chaves aceitas: `capType`, `numberWord`, `sub`, `styles`, `commentRe`,
`commentEnd`, `dedentChars`, `autoPairs`, `defThroughBrace`, `col0`, `infoRe`, `warnRe`,
`grayInfo`, `rainbow` (1 = parênteses coloridos por nível), `pretty` (palavra →
símbolo exibido no lugar dela, ex.: `{define λ}`) (veja `langDefaults` no código).

Hooks opcionais podem ser definidos como procs em `::qc::lang::<id>::` —
`init`, `wordTag`, `prepare`, `defaultExt`, `newlineIndent`, `stderrLine`,
`findExe` (as linguagens embutidas servem de exemplo).

Modelos de código são registrados com `qc::template`:

```tcl
qc::template lua "Olá" {print("olá, mundo")}
```

Tags de cor disponíveis: `keyword`, `defname`, `type`, `string`, `comment`,
`number`, `var`, `interp`, `option`, `annot`, `brace`, `directive`, `builtin`,
`constant`, `symbol`. A chave `styles` permite definir novas.

Erros ao carregar arquivos de linguagem aparecem na saída ao iniciar e em
**Ajuda > Sobre**.

## Requisitos

- Tcl/Tk 8.6 ou 9.x
- Os interpretadores das linguagens que você quiser executar
