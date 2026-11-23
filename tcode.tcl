#!/usr/bin/env wish
# qconsole.tcl -- editor/console para avaliação rápida de código em várias
# linguagens (Tcl, Scala 3, Scheme...). Não é uma IDE: é um arquivo só, sem
# dependências além de Tcl/Tk 8.6 ou 9.x.
#
# Inspirado no groovyConsole: editor em cima, saída da execução embaixo. O
# código roda em um processo separado (a interface não trava e a execução
# pode ser interrompida).
#
# Uso: wish qconsole.tcl ?-lang tcl|scala|scheme|scheme-kawa|...? ?arquivo?
#
# ---------------------------------------------------------------------------
# Definição de linguagens
# ---------------------------------------------------------------------------
# As linguagens embutidas estão no fim deste arquivo. Outras podem ser
# adicionadas em arquivos *.tcl nos diretórios
#     <diretório deste script>/lang/      ~/.config/qconsole/lang/
# com o mesmo formato (um arquivo pode também redefinir uma embutida):
#
#   qc::language lua {
#       name     Lua
#       ext      {.lua}
#       comment  --                  ;# prefixo de comentário (Ctrl+/)
#       indent   2
#       tokens {                     ;# ordem = prioridade em empates
#           comment {--[^\n]*}       ;# regex ARE, sem grupos de captura...
#           string  {"(?:[^"\\\n]|\\.)*"?}
#           number  {\m[0-9]+(?:\.[0-9]+)?\M}
#           word    {[A-Za-z_][A-Za-z0-9_]*}   ;# "word": classificado abaixo
#           brace   {[][(){}]}
#       }                            ;# ...ou com UM grupo: só ele é colorido
#       words    { keyword {local function end if then else return} }
#       defWords {function}          ;# a palavra seguinte recebe a tag defname
#       indentAfter {(?:\mthen|\mdo|\mfunction\M.*\)|\{)\s*$}
#       runners {
#           {name lua exe {lua5.4 lua} args {%O %F %A} version {-v}
#            versionRe {Lua ([0-9.]+)}}
#       }
#       errPatterns {{%F:([0-9]+):}} ;# grupo 1 = linha, grupo 2 = coluna
#   }
#
# Nos args do runner: %F arquivo, %W wrapper (chave "wrapper" do runner),
# %O opções do usuário, %A argumentos do programa, %--A "-- args" se houver.
# Outras chaves: capType, numberWord, sub, styles, commentRe, dedentChars,
# autoPairs (pares fechados automaticamente, ex.: {() [] \"\"}),
# defThroughBrace, col0, infoRe, warnRe, grayInfo, rainbow (1 = parênteses
# coloridos por nível de aninhamento; ver qc::rainbow), defPatterns (regexes
# extras de definição para o F12, com UM grupo = o nome; as palavras de
# defWords já geram uma), defWordsRe (substitui essa regex gerada pelas
# defWords: %W = alternativas das defWords, %N = regex de palavra; UM grupo), docString (1 = string logo após a assinatura é
# documentação, como em Scheme), pretty (palavra -> símbolo exibido no lugar
# dela, ex.: {define λ}; o texto não muda), linters e formatters
# (ferramentas externas; ver "Verificação (linter) e formatação") (ver
# langDefaults).
# Hooks opcionais: procs em ::qc::lang::<id>:: -- init, wordTag, prepare,
# defaultExt, newlineIndent, stderrLine, findExe, reformat (formatador
# embutido), run (substitui a execução: Markdown), apiSources, apiParse,
# defQual (ver as embutidas; as três últimas montam o índice de biblioteca
# usado na dica e no F12).
# Tags de cor disponíveis: veja qc::S; "styles" define novas.

package require Tk 8.6-

namespace eval qc {
    variable version 2.0
    variable scriptPath [file normalize [info script]]
    variable ed "" ;# editor da aba ativa
    variable dockCur "" ;# aba exibida na janela principal (pode não ser a ativa)
    variable tabs {} ;# editores abertos (um widget text por aba), em ordem
    variable TB ;# TB(<editor>,file|lang|hltags): estado de cada aba
    array set TB {}
    variable tabSeq 0
    variable con "" ;# console de saída
    variable gut "" ;# canvas com números de linha
    variable file "" ;# arquivo atual ("" = sem nome)
    variable status ""
    variable lncol ""
    variable folderName ""
    variable interp ""
    variable hlAfter ""
    variable gutPending 0
    variable curPending 0
    variable linkSeq 0
    variable foldSeq 0 ;# tags fold:N dos blocos recolhidos
    variable mcur {} ;# ids dos cursores extras (multi-cursor)
    variable mseq 0
    variable mlast "" ;# último cursor adicionado com Ctrl+D
    variable mword "" ;# seleção criada pelo Ctrl+D sem seleção (busca palavras inteiras)
    variable mapplying 0
    variable mcol 0 ;# coluna usada pelo Shift+Alt+↑/↓
    variable atomicDepth 0
    variable langs {} ;# ids das linguagens, em ordem de registro
    variable L ;# L(<id>) = dicionário da linguagem
    array set L {}
    variable lang "" ;# linguagem corrente
    variable langName ""
    variable H ;# dados compilados da linguagem corrente
    array set H {tags {}}
    variable inited {}
    variable V ;# versões detectadas: V(<lang>,<runner>)
    array set V {}
    variable loadErrors {}
    variable R ;# estado da execução corrente
    array set R {}
    variable find
    array set find {pat "" rep "" case 0 regex 0}
    variable cfg
    array set cfg {
        fontsize 11 wrap 0 autoclear 1 recent {} geometry 1100x800
        lastdir "" lang "" folder "" sidebar 0 sidew 240 autocomp 1
        terminal 0 termpos side termcmd "" tabs {} tabcur "" hoverdef 1
        pretty 1 mdpreview 1 mdw 0 recentdirs {} floats {}
        rulers {80 120} rulerson 1 indentguides 1
    }
    variable T ;# terminal embutido: T(chan), T(pid), T(shown)
    array set T {}
    # Paleta escura (inspirada no Darcula; editor igual ao Emacs timu-macos)
    variable C
    array set C {
        ui       #202125   uifg     #bbbbbb   uiactive #393939
        field    #222327   border   #222327   trough   #1c1d20
        accent   #4b6eaf   sel      #214283   thumb    #3e4046
        edbg     #222327   edfg     #ffffff   caret    #e0e0e0
        gutbg    #222327   gutfg    #b3b3b3   gutcur   #ffffff
        curline  #3e3e3e   found    #32593d   bmatch   #3b514d
        bbad     #7a2e2e   errline  #52302f   warnline #49442c
        conbg    #1e1f22   confg    #c8c8c8
        stderr   #ff6b68   warn     #e0c46c   info     #6f7f8f
        result   #8fbf6a   thumbact #64666d   ruler    #3a3b40
        indguide #34353a   indguideact #6b6d74
    }
    # Tags de destaque de sintaxe: cor e estilo (B negrito, I itálico)
    variable S {
        keyword   {#cc7832 B}   defname   {#ffc66d B}   type      {#6fafbd {}}
        string    {#6a8759 {}}  comment   {#808080 I}   number    {#6897bb {}}
        var       {#9876aa {}}  interp    {#9876aa {}}  option    {#bbb529 {}}
        annot     {#bbb529 {}}  brace     {#d0a86a {}}  directive {#629755 I}
        builtin   {#ffc66d {}}  constant  {#6897bb B}   symbol    {#9876aa {}}
    }
    # Cores dos parênteses por nível (linguagens com "rainbow 1")
    variable rainbow {#d0a86a #c586c0 #4fb3d9 #8fbf6a #e07b53 #9b9bf5}
    variable langDefaults {
        name ? ext {} comment "#" commentEnd "" commentRe "" indent 4 tokens {} words {}
        defWords {} defTag defname defThroughBrace 0 capType "" numberWord ""
        sub {} styles {} indentAfter {[\{\[\(]\s*$} dedentChars "\}\)\]"
        runners {} errPatterns {} col0 0 infoRe "" warnRe "" grayInfo 0
        templates {} autoPairs {() [] \{\} \"\" ''} rainbow 0 defPatterns {}
        docString 0 pretty {} linters {} formatters {} defWordsRe ""
    }
    namespace eval lang {}
}

# ---------------------------------------------------------------------------
# Registro de linguagens
# ---------------------------------------------------------------------------

proc qc::language {id def} {
    variable langs
    variable L
    variable langDefaults
    if {$id ni $langs} {lappend langs $id}
    set L($id) [dict merge $langDefaults $def]
    namespace eval ::qc::lang::$id {}
}

# Modelo de código para Arquivo > Novo a partir de modelo. @VERSION@ é
# trocado pela versão detectada do interpretador.
proc qc::template {id label text} {
    variable L
    dict set L($id) templates $label $text
}

proc qc::ldict {{id ""}} {
    if {$id eq ""} {set id $::qc::lang}
    return $::qc::L($id)
}

proc qc::lget {key {id ""}} {
    return [dict get [ldict $id] $key]
}

proc qc::hook {name {id ""}} {
    if {$id eq ""} {set id $::qc::lang}
    set p ::qc::lang::${id}::$name
    return [expr {[info commands $p] ne "" ? $p : ""}]
}

proc qc::loadLanguageFiles {} {
    variable loadErrors
    set dirs [list [file join [file dirname $::qc::scriptPath] lang] \
        [file join [homeDir] .config qconsole lang]]
    foreach d $dirs {
        foreach f [lsort [glob -nocomplain -directory $d *.tcl]] {
            if {[catch {uplevel #0 [list source -encoding utf-8 $f]} err]} {
                lappend loadErrors "$f: $err"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------

proc qc::homeDir {} {
    if {![catch {file home} h]} {return $h}
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)]} {return $::env($v)}
    }
    return [pwd]
}

proc qc::tmpDir {} {
    variable tmpdir
    if {[info exists tmpdir] && [file isdirectory $tmpdir]} {return $tmpdir}
    if {![catch {file tempdir} d]} {return [set tmpdir $d]}
    set base /tmp
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)]} {set base $::env($v); break}
    }
    set tmpdir [file join $base qconsole-[pid]-[clock clicks]]
    file mkdir $tmpdir
    return $tmpdir
}

proc qc::setEncoding {chan} {
    fconfigure $chan -encoding utf-8
    catch {fconfigure $chan -profile replace} ;# Tcl 9
}

proc qc::readFile {path} {
    set f [open $path r]
    setEncoding $f
    set data [read $f]
    close $f
    return $data
}

proc qc::writeFile {path data} {
    set f [open $path w]
    setEncoding $f
    puts -nonewline $f $data
    close $f
}

proc qc::reQuote {s} {
    return [regsub -all {[][\\{}()*+?.^$|]} $s {\\&}]
}

# Converte uma string de opções em lista (aceita sintaxe de lista Tcl para
# argumentos com espaços; senão divide nos espaços).
proc qc::splitArgs {s} {
    if {[catch {llength $s}]} {return [regexp -all -inline {\S+} $s]}
    return $s
}

proc qc::stripAnsi {s} {
    return [regsub -all {\x1b\[[0-9;?]*[A-Za-z]} $s ""]
}

proc qc::pickFont {} {
    set fams [font families]
    foreach f {"Adwaita Mono" "JetBrains Mono" "Fira Code" "Source Code Pro" "Cascadia Code"
               "Hack" "DejaVu Sans Mono" "Liberation Mono" "Consolas" "Menlo"
               "Monaco" "Courier New"} {
        if {[lsearch -nocase -exact $fams $f] >= 0} {return $f}
    }
    return [font actual TkFixedFont -family]
}

# Configurações por linguagem ficam em cfg(<chave>.<lang>).
proc qc::lcfg {key {id ""}} {
    variable cfg
    if {$id eq ""} {set id $::qc::lang}
    return [expr {[info exists cfg($key.$id)] ? $cfg($key.$id) : ""}]
}

proc qc::loadCfg {} {
    variable cfg
    set rc [file join [homeDir] .qconsolerc]
    if {[file readable $rc]} {
        catch {
            dict for {k v} [readFile $rc] {set cfg($k) $v}
        }
    }
    if {![string is integer -strict $cfg(fontsize)]} {set cfg(fontsize) 11}
}

proc qc::saveCfg {} {
    variable cfg
    catch {
        set cfg(geometry) [wm geometry .]
    }
    catch {
        if {".side" in [.hp panes]} {set cfg(sidew) [.hp sashpos 0]}
        if {".md" in [.hp panes]} {set cfg(mdw) [winfo width .md]}
    }
    set out ""
    foreach k [lsort [array names cfg]] {append out [list $k $cfg($k)] \n}
    catch {writeFile [file join [homeDir] .qconsolerc] $out}
}

# ---------------------------------------------------------------------------
# Tema
# ---------------------------------------------------------------------------

# Cor entre fg e bg, com fg na proporção a (0..1).
proc qc::blend {fg bg a} {
    lassign [winfo rgb . $fg] r1 g1 b1
    lassign [winfo rgb . $bg] r2 g2 b2
    format #%02x%02x%02x {*}[lmap c1 [list $r1 $g1 $b1] c2 [list $r2 $g2 $b2] {
        expr {round(($c1 * $a + $c2 * (1 - $a)) / 257.0)}}]
}

# Imagem w x h de um retângulo com pontas arredondadas (raio = metade do lado
# menor), já misturado ao fundo bg; a borda é suavizada por supersampling 4x4.
proc qc::roundImg {w h fg bg} {
    set img [image create photo -width $w -height $h]
    set r [expr {min($w, $h) / 2.0}]
    set rows {}
    for {set y 0} {$y < $h} {incr y} {
        set row {}
        for {set x 0} {$x < $w} {incr x} {
            set n 0
            foreach sy {0.125 0.375 0.625 0.875} {
                foreach sx {0.125 0.375 0.625 0.875} {
                    set px [expr {$x + $sx}]
                    set py [expr {$y + $sy}]
                    set cx [expr {max($r, min($w - $r, $px))}]
                    set cy [expr {max($r, min($h - $r, $py))}]
                    if {hypot($px - $cx, $py - $cy) <= $r} {incr n}
                }
            }
            lappend row [blend $fg $bg [expr {$n / 16.0}]]
        }
        lappend rows $row
    }
    $img put $rows
    return $img
}

# Barra de rolagem fina, sem setas, com polegar arredondado sobre o fundo bg.
# prefix "" redefine o estilo padrão; "Con." cria Con.Vertical.TScrollbar etc.
proc qc::scrollStyle {prefix bg} {
    variable C
    set e Qc$prefix
    set tr [image create photo -width 10 -height 10]
    $tr put $bg -to 0 0 10 10
    foreach o {Vertical Horizontal} {
        if {$o eq "Vertical"} {
            set wh {6 16}; set b {3 6 3 6}; set st ns; set dim -width
        } else {
            set wh {16 6}; set b {6 3 6 3}; set st we; set dim -height
        }
        set n [roundImg {*}$wh $C(thumb) $bg]
        set a [roundImg {*}$wh $C(thumbact) $bg]
        ttk::style element create $e.$o.Scrollbar.trough image $tr -border 0 $dim 10
        ttk::style element create $e.$o.Scrollbar.thumb image \
            [list $n active $a pressed $a] -border $b -sticky $st
        ttk::style layout $prefix$o.TScrollbar [list $e.$o.Scrollbar.trough \
            -sticky $st -children [list $e.$o.Scrollbar.thumb -expand 1]]
    }
}

proc qc::setupTheme {} {
    variable C
    variable cfg
    set fam [pickFont]
    font create QcMono -family $fam -size $cfg(fontsize)
    font create QcMonoB -family $fam -size $cfg(fontsize) -weight bold
    font create QcMonoI -family $fam -size $cfg(fontsize) -slant italic

    tk_setPalette background $C(ui) foreground $C(uifg) \
        activeBackground $C(accent) activeForeground #ffffff \
        selectBackground $C(sel) selectForeground #ffffff \
        highlightColor $C(accent) highlightBackground $C(ui) \
        insertBackground $C(caret) disabledForeground #6d6d6d \
        troughColor $C(trough) selectColor $C(field)
    option add *Menu.relief flat
    option add *Menu.activeBorderWidth 0
    option add *Menu.borderWidth 1
    option add *TCombobox*Listbox.background $C(field)
    option add *TCombobox*Listbox.foreground $C(edfg)

    ttk::style theme use clam
    ttk::style configure . -background $C(ui) -foreground $C(uifg) \
        -fieldbackground $C(field) -bordercolor $C(border) \
        -lightcolor $C(ui) -darkcolor $C(ui) -troughcolor $C(trough) \
        -selectbackground $C(sel) -selectforeground #ffffff \
        -insertcolor $C(caret) -arrowcolor $C(uifg) -focuscolor $C(accent)
    ttk::style map . -background [list disabled $C(ui) active $C(uiactive)] \
        -foreground [list disabled #6d6d6d]
    ttk::style configure TButton -padding {8 3} -background $C(uiactive) \
        -bordercolor #555555 -lightcolor $C(uiactive) -darkcolor $C(uiactive)
    ttk::style map TButton -background [list disabled $C(ui) pressed $C(accent) active #56595c]
    ttk::style configure Tool.TButton -padding {8 3} -width 0 -background $C(ui) \
        -bordercolor $C(ui) -lightcolor $C(ui) -darkcolor $C(ui) -relief flat
    ttk::style map Tool.TButton -background [list disabled $C(ui) pressed $C(accent) active $C(uiactive)] \
        -bordercolor [list active #5e6164]
    ttk::style configure TEntry -fieldbackground $C(field) -foreground $C(edfg) \
        -bordercolor #555555 -lightcolor $C(field) -darkcolor $C(field) -padding 3
    ttk::style map TEntry -bordercolor [list focus $C(accent)]
    ttk::style configure TCombobox -fieldbackground $C(field) -foreground $C(edfg) \
        -bordercolor #555555 -lightcolor $C(field) -darkcolor $C(field) \
        -background $C(uiactive) -arrowcolor $C(uifg) -padding 2
    ttk::style map TCombobox -fieldbackground [list readonly $C(field)] \
        -foreground [list readonly $C(edfg)] -selectbackground [list readonly $C(field)] \
        -selectforeground [list readonly $C(edfg)]
    ttk::style configure NotFound.TEntry -fieldbackground #5a2a2a
    ttk::style configure TCheckbutton -indicatorbackground $C(field) \
        -indicatorforeground $C(uifg)
    ttk::style map TCheckbutton -indicatorbackground [list selected $C(accent)] \
        -background [list active $C(ui)]
    scrollStyle "" $C(edbg)
    scrollStyle Con. $C(conbg)
    ttk::style configure Sash -sashthickness 6 -gripcount 0 -background $C(ui)
    ttk::style configure Status.TLabel -padding {6 2} -foreground #9a9a9a
    ttk::style configure Head.TLabel -padding {6 2} -foreground #8a8a8a \
        -background $C(trough)
    ttk::style configure Head.TFrame -background $C(trough)
    ttk::style configure Head.TButton -padding {4 0} -width 0 -background $C(trough) \
        -bordercolor $C(trough) -lightcolor $C(trough) -darkcolor $C(trough) -relief flat
    ttk::style map Head.TButton -background [list pressed $C(accent) active $C(uiactive)]
    ttk::style configure Treeview -background $C(gutbg) -fieldbackground $C(gutbg) \
        -foreground $C(edfg) -bordercolor $C(gutbg) -lightcolor $C(gutbg) \
        -darkcolor $C(gutbg) -indent 14 \
        -rowheight [expr {[font metrics TkDefaultFont -linespace] + 5}]
    ttk::style map Treeview -background [list selected $C(sel)] \
        -foreground [list selected #ffffff]
}

# ---------------------------------------------------------------------------
# Interface
# ---------------------------------------------------------------------------

proc qc::buildUI {} {
    variable C
    variable cfg
    variable ed
    variable con
    variable gut
    variable langs

    wm title . qconsole
    wm geometry . $cfg(geometry)
    wm minsize . 500 350
    . configure -background $C(ui)

    buildMenus

    # Barra de ferramentas
    ttk::frame .tb -padding {4 3}
    set i 0
    foreach {name label cmd} {
        new   "Novo"         qc::newFile
        open  "Abrir…"       qc::openFile
        save  "Salvar"       qc::save
        -     -              -
        undo  "↶"            {qc::editCmd undo}
        redo  "↷"            {qc::editCmd redo}
        -     -              -
        run   "▶ Executar"   {qc::run 0}
        stop  "■ Parar"      qc::stop
        clear "⌫ Limpar"     qc::clearConsole
        opts  "Opções…"      qc::optionsDialog
        -     -              -
        find  "Localizar"    {qc::showFind 0}
    } {
        if {$name eq "-"} {
            ttk::separator .tb.s[incr i] -orient vertical
            pack .tb.s$i -side left -fill y -padx 4 -pady 2
            continue
        }
        ttk::button .tb.$name -text $label -style Tool.TButton -command $cmd \
            -takefocus 0
        pack .tb.$name -side left
    }
    .tb.stop state disabled
    ttk::combobox .tb.lang -state readonly -width 15 -takefocus 0 \
        -textvariable ::qc::langName
    bind .tb.lang <<ComboboxSelected>> {
        qc::setLang [lindex $::qc::langs [.tb.lang current]]
        focus $::qc::ed
    }
    pack .tb.lang -side right -padx 4

    # Painel lateral (árvore de arquivos) | painéis editor / console
    ttk::panedwindow .hp -orient horizontal
    buildSide
    buildPreview .md .pw.ed
    ttk::panedwindow .pw -orient vertical

    # editor: barra de abas em cima; cada aba é um widget text (ver newEditor)
    # na coluna 1 da linha 1, e só o da aba ativa fica visível
    set f [ttk::frame .pw.ed]
    buildTabBar $f.tabs
    set gut [canvas $f.gut -background $C(gutbg) -highlightthickness 0 -bd 0 -width 40]
    ttk::scrollbar $f.sy -orient vertical -command {qc::hostScroll .pw.ed yview}
    ttk::scrollbar $f.sx -orient horizontal -command {qc::hostScroll .pw.ed xview}
    buildFindBar $f.find
    grid $f.tabs -row 0 -column 0 -columnspan 3 -sticky ew
    grid $gut -row 1 -column 0 -sticky nsew
    grid $f.sy -row 1 -column 2 -sticky ns
    grid $f.sx -row 2 -column 1 -sticky ew
    grid $f.find -row 3 -column 0 -columnspan 3 -sticky ew
    grid columnconfigure $f 1 -weight 1
    grid rowconfigure $f 1 -weight 1
    grid remove $f.find
    if {$cfg(wrap)} {grid remove $f.sx}

    # parte de baixo: saída | terminal (lado a lado ou um no lugar do outro)
    ttk::panedwindow .pw.bot -orient horizontal
    set f [ttk::frame .pw.co]
    ttk::frame $f.head -style Head.TFrame
    ttk::label $f.head.l -text "Saída" -style Head.TLabel -anchor w
    ttk::button $f.head.t -text "Terminal" -style Head.TButton -takefocus 0 \
        -command {qc::showTerminal 1}
    pack $f.head.l -side left -fill x -expand 1
    set con [text $f.t -background $C(conbg) -foreground $C(confg) \
        -insertbackground $C(caret) -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -font QcMono -wrap char -bd 0 -highlightthickness 0 -padx 6 -pady 4 \
        -state disabled -cursor xterm -yscrollcommand [list $f.sy set]]
    ttk::scrollbar $f.sy -orient vertical -style Con.Vertical.TScrollbar \
        -command [list $con yview]
    grid $f.head - -sticky ew
    grid $con $f.sy -sticky nsew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure $f 1 -weight 1

    buildTerminal

    .pw add .pw.ed -weight 3
    .pw add .pw.bot -weight 1
    .pw.bot add .pw.co -weight 1
    .hp add .pw -weight 1

    # Barra de status
    ttk::frame .sb
    # -width 1: mensagens longas não podem alargar a janela (evita loop com as abas)
    ttk::label .sb.msg -textvariable ::qc::status -style Status.TLabel -anchor w -width 1
    ttk::label .sb.pos -textvariable ::qc::lncol -style Status.TLabel -width 16
    ttk::label .sb.run -textvariable ::qc::interp -style Status.TLabel
    pack .sb.run .sb.pos -side right
    pack .sb.msg -side left -fill x -expand 1

    pack .tb -side top -fill x
    pack .sb -side bottom -fill x
    pack .hp -side top -fill both -expand 1

    setupTags
    setupBindings
    activateTab [newEditor]

    bind $gut <Configure> qc::schedGutter
    wm protocol . WM_DELETE_WINDOW qc::quit

    # divisor em 70% editor / 30% console até o usuário arrastá-lo
    bind .pw <Configure> qc::initSash
    bind .pw <ButtonPress-1> {+bind .pw <Configure> {}}
}

proc qc::initSash {} {
    set h [winfo height .pw]
    if {$h > 50} {catch {.pw sashpos 0 [expr {int($h * 0.70)}]}}
}

proc qc::buildMenus {} {
    variable cfg
    variable langs
    menu .mb -tearoff 0
    . configure -menu .mb

    set m [menu .mb.file -tearoff 0]
    .mb add cascade -label Arquivo -menu $m
    $m add command -label "Novo" -accelerator Ctrl+N -command qc::newFile
    $m add cascade -label "Novo a partir de modelo" -menu [menu $m.tpl -tearoff 0]
    $m add command -label "Abrir…" -accelerator Ctrl+O -command qc::openFile
    $m add cascade -label "Arquivos recentes" -menu [menu $m.recent -tearoff 0]
    $m add command -label "Abrir pasta…" -accelerator Ctrl+Shift+O -command qc::openFolder
    $m add cascade -label "Pastas recentes" -menu [menu $m.recentdirs -tearoff 0]
    $m add command -label "Fechar pasta" -command qc::closeFolder
    $m add separator
    $m add command -label "Salvar" -accelerator Ctrl+S -command qc::save
    $m add command -label "Salvar como…" -accelerator Ctrl+Shift+S -command qc::saveAs
    $m add command -label "Exportar para HTML…" -accelerator Ctrl+Shift+E -command qc::mdExport
    $m add command -label "Abrir no navegador" -command qc::mdBrowser
    $m add command -label "Fechar aba" -accelerator Ctrl+F4 -command qc::closeFile
    $m add command -label "Próxima aba" -accelerator Ctrl+Tab -command {qc::cycleTab 1}
    $m add command -label "Aba anterior" -accelerator Ctrl+Shift+Tab -command {qc::cycleTab -1}
    $m add command -label "Desacoplar / acoplar aba" -accelerator Ctrl+Shift+T -command qc::toggleDock
    $m add separator
    $m add command -label "Sair" -accelerator Ctrl+Q -command qc::quit
    updateRecentMenu

    set m [menu .mb.edit -tearoff 0]
    .mb add cascade -label Editar -menu $m
    $m add command -label "Desfazer" -accelerator Ctrl+Z -command {qc::editCmd undo}
    $m add command -label "Refazer" -accelerator Ctrl+Y -command {qc::editCmd redo}
    $m add separator
    $m add command -label "Recortar" -accelerator Ctrl+X -command {event generate $::qc::ed <<Cut>>}
    $m add command -label "Copiar" -accelerator Ctrl+C -command {event generate [focus] <<Copy>>}
    $m add command -label "Colar" -accelerator Ctrl+V -command {qc::paste $::qc::ed}
    $m add command -label "Selecionar tudo" -accelerator Ctrl+A -command {qc::selectAll $::qc::ed}
    $m add separator
    $m add command -label "Duplicar linha" -accelerator Ctrl+Shift+D -command qc::duplicateLine
    $m add command -label "Mover linha para cima" -accelerator Ctrl+Shift+↑ -command {qc::moveLines -1}
    $m add command -label "Mover linha para baixo" -accelerator Ctrl+Shift+↓ -command {qc::moveLines 1}
    $m add command -label "Comentar/descomentar" -accelerator Ctrl+/ -command qc::toggleComment
    $m add command -label "Formatar código" -accelerator Ctrl+Shift+F -command qc::formatCode
    $m add checkbutton -label "Formatar ao salvar"
    $m add command -label "Verificar código (linter)" -accelerator F8 -command qc::lint
    $m add separator
    $m add command -label "Completar palavra" -accelerator Ctrl+Espaço -command {focus $::qc::ed; qc::acShow 1}
    $m add checkbutton -label "Sugerir ao digitar" -variable ::qc::cfg(autocomp)
    $m add separator
    $m add command -label "Selecionar próxima ocorrência" -accelerator Ctrl+D -command {focus $::qc::ed; qc::selectNext}
    $m add command -label "Selecionar todas as ocorrências" -accelerator Alt+F3 \
        -command {focus $::qc::ed; qc::selectAllOcc}
    $m add separator
    $m add command -label "Localizar…" -accelerator Ctrl+F -command {qc::showFind 0}
    $m add command -label "Substituir…" -accelerator Ctrl+H -command {qc::showFind 1}
    $m add command -label "Localizar próximo" -accelerator F3 -command {qc::findNext 1}
    $m add command -label "Localizar anterior" -accelerator Shift+F3 -command {qc::findNext 0}
    $m add command -label "Ir para linha…" -accelerator Ctrl+L -command qc::gotoDialog
    $m add command -label "Ir para definição" -accelerator F12 -command qc::goToDefinition
    $m add command -label "Voltar" -accelerator Alt+← -command qc::navBack

    set m [menu .mb.lang -tearoff 0]
    .mb add cascade -label Linguagem -menu $m
    foreach id $langs {
        $m add radiobutton -label [lget name $id] -value $id -variable ::qc::langSel \
            -command [list qc::setLang $id]
    }
    if {[info commands ::qc::lang::scheme::writeHeader] ne ""} {
        $m add separator
        $m add command -label "Indicar implementação de Scheme no arquivo" \
            -command ::qc::lang::scheme::writeHeader
    }

    set m [menu .mb.script -tearoff 0]
    .mb add cascade -label Executar -menu $m
    $m add command -label "Executar" -accelerator Ctrl+R -command {qc::run 0}
    $m add command -label "Executar seleção" -accelerator Ctrl+Shift+R -command {qc::run 1}
    $m add command -label "Interromper" -accelerator Ctrl+Break -command qc::stop -state disabled
    $m add command -label "Executar comando do projeto" -accelerator Ctrl+Alt+R -command qc::runMain
    $m add cascade -label "Comandos do projeto" -menu [menu $m.proj -tearoff 0 \
        -postcommand qc::updateProjMenu]
    $m add command -label "Editar comandos do projeto (.qconsole)" -command qc::editProjectFile
    $m add separator
    $m add command -label "Limpar saída" -accelerator Ctrl+W -command qc::clearConsole
    $m add checkbutton -label "Limpar saída antes de executar" -variable ::qc::cfg(autoclear)
    $m add separator
    $m add command -label "Opções de execução…" -accelerator Ctrl+E -command qc::optionsDialog

    set m [menu .mb.view -tearoff 0]
    .mb add cascade -label Exibir -menu $m
    $m add command -label "Aumentar fonte" -accelerator Ctrl++ -command {qc::zoom 1}
    $m add command -label "Diminuir fonte" -accelerator Ctrl+- -command {qc::zoom -1}
    $m add command -label "Fonte padrão" -accelerator Ctrl+0 -command {qc::zoom 0}
    $m add separator
    $m add checkbutton -label "Quebra de linha" -variable ::qc::cfg(wrap) -command qc::applyWrap
    $m add checkbutton -label "Guias de coluna" -variable ::qc::cfg(rulerson) -command qc::applyRulers
    $m add command -label "Colunas das guias…" -command qc::rulersDialog
    $m add checkbutton -label "Guias de indentação" -variable ::qc::cfg(indentguides) \
        -command qc::applyRulers
    $m add separator
    $m add command -label "Recolher bloco" -accelerator Ctrl+Shift+\[ -command qc::foldCursor
    $m add command -label "Expandir bloco" -accelerator Ctrl+Shift+\] -command qc::unfoldCursor
    $m add command -label "Recolher tudo" -command qc::foldAll
    $m add command -label "Expandir tudo" -command qc::unfoldAll
    $m add separator
    $m add checkbutton -label "Mostrar definição ao passar o mouse" -variable ::qc::cfg(hoverdef) \
        -command qc::tipHide
    $m add checkbutton -label "Símbolos no lugar de palavras (define, lambda → λ)" \
        -variable ::qc::cfg(pretty) -command qc::highlight
    $m add checkbutton -label "Painel de arquivos" -accelerator Ctrl+B \
        -variable ::qc::cfg(sidebar) -command qc::applySide
    $m add checkbutton -label "Pré-visualização do Markdown" -accelerator Ctrl+Shift+M \
        -variable ::qc::cfg(mdpreview) -command qc::mdApply
    $m add separator
    $m add checkbutton -label "Terminal" -accelerator Ctrl+' \
        -variable ::qc::cfg(terminal) -command qc::applyTerminal
    $m add radiobutton -label "Terminal ao lado da saída" -value side \
        -variable ::qc::cfg(termpos) -command qc::applyTerminal
    $m add radiobutton -label "Terminal no lugar da saída" -value replace \
        -variable ::qc::cfg(termpos) -command qc::applyTerminal
    $m add command -label "Comando do terminal…" -command qc::termDialog

    set m [menu .mb.help -tearoff 0]
    .mb add cascade -label Ajuda -menu $m
    $m add command -label "Atalhos" -command qc::showShortcuts
    $m add command -label "Sobre" -command qc::about

    # menus de contexto
    set m [menu .edpop -tearoff 0]
    $m add command -label "Ir para definição" -accelerator F12 -command qc::goToDefinition
    $m add separator
    $m add command -label "Recortar" -command {event generate $::qc::ed <<Cut>>}
    $m add command -label "Copiar" -command {event generate $::qc::ed <<Copy>>}
    $m add command -label "Colar" -command {qc::paste $::qc::ed}
    $m add separator
    $m add command -label "Selecionar tudo" -command {qc::selectAll $::qc::ed}
    $m add command -label "Executar seleção" -command {qc::run 1}
    $m add separator
    $m add command -label "Formatar código" -accelerator Ctrl+Shift+F -command qc::formatCode
    $m add command -label "Verificar código (linter)" -accelerator F8 -command qc::lint

    set m [menu .conpop -tearoff 0]
    $m add command -label "Copiar" -command {event generate $::qc::con <<Copy>>}
    $m add command -label "Selecionar tudo" -command {$::qc::con tag add sel 1.0 end}
    $m add separator
    $m add command -label "Limpar saída" -command qc::clearConsole
}

proc qc::updateTemplateMenu {} {
    set m .mb.file.tpl
    $m delete 0 end
    set t [lget templates]
    if {![dict size $t]} {
        $m add command -label "(nenhum para [lget name])" -state disabled
        return
    }
    foreach label [dict keys $t] {
        $m add command -label $label -command [list qc::newFromTemplate $label]
    }
}

proc qc::buildFindBar {w} {
    ttk::frame $w -padding {4 3}
    ttk::label $w.l1 -text "Localizar:"
    ttk::entry $w.pat -textvariable ::qc::find(pat) -width 28
    ttk::button $w.prev -text "▲" -width 3 -command {qc::findNext 0} -takefocus 0
    ttk::button $w.next -text "▼" -width 3 -command {qc::findNext 1} -takefocus 0
    ttk::checkbutton $w.case -text "Aa" -variable ::qc::find(case) -command qc::markAll -takefocus 0
    ttk::checkbutton $w.re -text ".*" -variable ::qc::find(regex) -command qc::markAll -takefocus 0
    ttk::label $w.l2 -text "Substituir:"
    ttk::entry $w.rep -textvariable ::qc::find(rep) -width 22
    ttk::button $w.r1 -text "Substituir" -command qc::replaceOne -takefocus 0
    ttk::button $w.ra -text "Todos" -command qc::replaceAll -takefocus 0
    ttk::button $w.x -text "✕" -width 3 -style Tool.TButton -command qc::hideFind -takefocus 0
    ttk::label $w.info -textvariable ::qc::find(info) -foreground #8a8a8a
    pack $w.l1 $w.pat $w.prev $w.next $w.case $w.re -side left -padx 2
    pack $w.l2 -side left -padx {12 2}
    pack $w.rep $w.r1 $w.ra -side left -padx 2
    pack $w.info -side left -padx 8
    pack $w.x -side right

    if {![info exists ::qc::findTrace]} {
        set ::qc::findTrace 1
        trace add variable ::qc::find(pat) write {apply {args {after idle qc::markAll}}}
    }
    foreach e [list $w.pat $w.rep] {
        bindtags $e [list $e QcKeys TEntry [winfo toplevel $e] all]
        bind $e <Return> {qc::findNext 1; break}
        bind $e <Shift-Return> {qc::findNext 0; break}
        bind $e <Escape> {qc::hideFind; break}
    }
}

# Tags fixas de um editor (as de sintaxe vêm da linguagem).
proc qc::setupEdTags {ed} {
    variable C
    $ed tag configure curline -background $C(curline)
    $ed tag configure errline -background $C(errline)
    $ed tag configure warnline -background $C(warnline)
    $ed tag configure found -background $C(found)
    $ed tag configure bmatch -background $C(bmatch) -font QcMonoB
    $ed tag configure bbad -background $C(bbad)
    $ed tag configure msel -background $C(sel)
    $ed tag configure deflink -underline 1
    $ed tag configure pel -elide 1
    $ed tag lower curline
}

# Tags do console.
proc qc::setupTags {} {
    variable con
    variable C
    $con tag configure stdout -foreground $C(confg)
    $con tag configure stderr -foreground $C(stderr)
    $con tag configure warn -foreground $C(warn)
    $con tag configure result -foreground $C(result)
    $con tag configure info -foreground $C(info) -font QcMonoI
    $con tag configure link -underline 1
    $con tag bind link <Enter> [list $con configure -cursor hand2]
    $con tag bind link <Leave> [list $con configure -cursor xterm]
    # cores ANSI na saída do programa
    foreach {n c} {
        30 #7f7f7f 31 #ff6b68 32 #8fbf6a 33 #d7ba7d 34 #6897bb 35 #b294bb 36 #5fb3b3 37 #d0d0d0
        90 #9a9a9a 91 #ff8b88 92 #a8d88a 93 #f0d58d 94 #8ab4e0 95 #cfa8d8 96 #7fd3d3 97 #ffffff
    } {
        $con tag configure ansi$n -foreground $c
    }
    $con tag configure ansiB -font QcMonoB
    $con tag raise sel
}

proc qc::updateTabs {} {
    $::qc::ed configure -tabs [expr {[lget indent] * [font measure QcMono 0]}]
}

# Atalhos globais: a tag QcKeys fica antes da classe dos widgets para que
# atalhos como Ctrl+O/Ctrl+F não executem as ações "emacs" do Text/Entry.
proc qc::setupBindings {} {
    variable ed
    variable con
    variable globalKeys
    set keys {
        <Control-T>         qc::toggleDock
        <Control-n>         qc::newFile
        <Control-o>         qc::openFile
        <Control-s>         qc::save
        <Control-S>         qc::saveAs
        <Control-F4>        qc::closeFile
        <Control-Tab>       {qc::cycleTab 1}
        <Control-Shift-Tab> {qc::cycleTab -1}
        <Control-ISO_Left_Tab> {qc::cycleTab -1}
        <Control-Next>      {qc::cycleTab 1}
        <Control-Prior>     {qc::cycleTab -1}
        <Control-q>         qc::quit
        <Control-r>         {qc::run 0}
        <Control-Return>    {qc::run 0}
        <Control-Alt-r>     qc::runMain
        <Control-R>         {qc::run 1}
        <Control-O>         qc::openFolder
        <Control-b>         qc::toggleSide
        <Control-M>         qc::mdToggle
        <Control-E>         qc::mdExport
        <Control-apostrophe> qc::toggleTerminal
        <Control-grave>     qc::toggleTerminal
        <Control-Break>     qc::stop
        <Control-Pause>     qc::stop
        <Control-w>         qc::clearConsole
        <Control-e>         qc::optionsDialog
        <Control-f>         {qc::showFind 0}
        <Control-h>         {qc::showFind 1}
        <F3>                {qc::findNext 1}
        <Shift-F3>          {qc::findNext 0}
        <Alt-F3>            {focus $::qc::ed; qc::selectAllOcc}
        <Control-l>         qc::gotoDialog
        <Control-F>         qc::formatCode
        <Control-braceleft> qc::foldCursor
        <Control-braceright> qc::unfoldCursor
        <F8>                qc::lint
        <F12>               qc::goToDefinition
        <Alt-Left>          qc::navBack
        <Control-plus>      {qc::zoom 1}
        <Control-equal>     {qc::zoom 1}
        <Control-KP_Add>    {qc::zoom 1}
        <Control-minus>     {qc::zoom -1}
        <Control-KP_Subtract> {qc::zoom -1}
        <Control-0>         {qc::zoom 0}
        <Control-a>         {qc::selectAll %W}
    }
    set globalKeys $keys
    foreach {seq cmd} $keys {
        catch {bind QcKeys $seq "$cmd; break"}
        catch {bind . $seq $cmd}
    }
    event add <<Redo>> <Control-y>

    # teclas específicas do editor
    bind QcEdit <Tab> {qc::indent 1; break}
    bind QcEdit <Shift-Tab> {qc::indent 0; break}
    catch {bind QcEdit <ISO_Left_Tab> {qc::indent 0; break}}
    bind QcEdit <Return> {qc::newline; break}
    bind QcEdit <KP_Enter> {qc::newline; break}
    bind QcEdit <KeyPress> {if {[qc::keyChar %A %s]} break}
    bind QcEdit <BackSpace> {qc::backspace; break}
    # com seleção, ←/→ vão para o início/fim dela
    bind QcEdit <Left> {if {[qc::selJump Left %s]} break}
    bind QcEdit <Right> {if {[qc::selJump Right %s]} break}
    # Home vai ao primeiro caractere não branco (Shift+Home seleciona até ele)
    bind QcEdit <Home> {qc::moveCaret Home 0; %W see insert; break}
    bind QcEdit <Shift-Home> {qc::moveCaret Home 1; %W see insert; break}
    bind QcEdit <Control-d> {qc::selectNext; break}
    bind QcEdit <Control-D> {qc::duplicateLine; break}
    bind QcEdit <Control-Shift-Up> {qc::moveLines -1; break}
    bind QcEdit <Control-Shift-Down> {qc::moveLines 1; break}
    bind QcEdit <Shift-Alt-Up> {qc::addCaretLine -1; break}
    bind QcEdit <Shift-Alt-Down> {qc::addCaretLine 1; break}
    bind QcEdit <Control-slash> {qc::toggleComment; break}
    bind QcEdit <<Paste>> {qc::paste %W; break}
    bind QcEdit <Control-MouseWheel> {qc::zoom [expr {%D > 0 ? 1 : -1}]; break}
    bind QcEdit <Button-3> {qc::edPopup %W %x %y %X %Y; break}
    bind QcEdit <<Undo>> {qc::editCmd undo; break}
    bind QcEdit <<Redo>> {qc::editCmd redo; break}

    # QcMulti vem antes de tudo: com vários cursores ativos, aplica a tecla
    # em cada um deles
    # QcComp vem antes de tudo: com o popup de sugestões aberto, as setas,
    # Enter, Tab e Esc são dele
    bind QcComp <KeyPress> {qc::acKey %K %A %s}
    bind QcComp <Control-space> {qc::acShow 1; break}
    bind QcComp <Button> {qc::acHide}
    bind QcComp <MouseWheel> {qc::acHide}
    bind QcComp <FocusOut> {qc::acHide}
    bind QcComp <Configure> {qc::acHide}

    # dica com a definição da palavra sob o mouse
    bind QcHover <Motion> {qc::hoverSched %W %x %y %s}
    bind QcHover <Leave> {qc::tipHide; qc::linkClear}
    bind QcHover <FocusOut> qc::linkClear
    # Ctrl sobre um nome com definição: sublinhado (Ctrl+clique vai até ela)
    foreach k {Control_L Control_R} {
        bind QcHover <KeyPress-$k> {qc::tipHide; qc::linkAtPointer %W}
        bind QcHover <KeyRelease-$k> qc::linkClear
    }
    bind QcHover <KeyPress> qc::tipHide
    bind QcHover <Button> qc::tipHide
    bind QcHover <MouseWheel> qc::tipHide

    bind QcMulti <KeyPress> {qc::multiKey %K %A %s}
    bind QcMulti <Button-1> {qc::multiClear}
    bind QcMulti <Button-2> {qc::multiClear}
    # Ctrl+clique num nome com definição vai até ela; fora disso (ou com
    # Alt+clique) adiciona um cursor
    bind QcMulti <Control-Button-1> {qc::ctrlClick %W %x %y; break}
    bind QcMulti <Alt-Button-1> {qc::addCaretAt %x %y; break}
    bind QcMulti <<Paste>> {if {[llength $::qc::mcur]} {qc::multiApply {qc::paste $::qc::ed}; break}}

    bindtags $con [list $con QcKeys Text . all]
    bind $con <Button-3> {tk_popup .conpop %X %Y}
    bind $con <1> {focus %W}

    bindGutter $::qc::gut
}

# Números de linha: rolam/clicam o editor exibido naquela janela.
proc qc::bindGutter {g} {
    bind $g <MouseWheel> {[qc::hostEd [winfo parent %W]] yview scroll [expr {%D > 0 ? -3 : 3}] units}
    catch {bind $g <Button-4> {[qc::hostEd [winfo parent %W]] yview scroll -3 units}}
    catch {bind $g <Button-5> {[qc::hostEd [winfo parent %W]] yview scroll 3 units}}
    bind $g <1> {qc::activateTab [qc::hostEd [winfo parent %W]]; qc::gutterClick %x %y}
    bind $g <Enter> {qc::gutHover %W 1}
    bind $g <Leave> {qc::gutHover %W 0}
}

# Proxy do widget de texto: detecta qualquer alteração do conteúdo e do
# cursor. O comando original vira ::qc::raw<caminho>; ::qc::_edw aponta
# sempre para o da aba ativa (ver activateTab).
proc qc::installProxy {w} {
    rename $w ::qc::raw$w
    interp alias {} $w {} ::qc::edProxy $w
}

proc qc::edProxy {w args} {
    if {[catch {::qc::raw$w {*}$args} r o]} {
        return -code error -errorcode [dict get $o -errorcode] $r
    }
    if {$w ne $::qc::ed} {return $r}
    switch -- [lindex $args 0] {
        insert - delete - replace {onChange}
        edit {
            if {[lindex $args 1] in {undo redo}} {onChange}
        }
        mark {
            if {[lindex $args 1] eq "set" && [lindex $args 2] eq "insert"} {onCursor}
        }
    }
    return $r
}

# ---------------------------------------------------------------------------
# Painel lateral: árvore de arquivos da pasta aberta
# ---------------------------------------------------------------------------
# Os itens da árvore têm como id o caminho completo; as subpastas são lidas
# só quando abertas (até lá têm um filho "\x01<caminho>" de marcação).

proc qc::buildSide {} {
    ttk::frame .side
    ttk::frame .side.head -style Head.TFrame
    ttk::label .side.head.l -textvariable ::qc::folderName -style Head.TLabel -anchor w
    ttk::button .side.head.r -text ⟳ -style Head.TButton -takefocus 0 \
        -command qc::refreshFolder
    ttk::button .side.head.x -text ✕ -style Head.TButton -takefocus 0 \
        -command qc::closeFolder
    pack .side.head.x .side.head.r -side right
    pack .side.head.l -side left -fill x -expand 1
    set t [ttk::treeview .side.t -show tree -selectmode browse \
        -yscrollcommand {.side.sy set}]
    ttk::scrollbar .side.sy -orient vertical -command [list $t yview]
    grid .side.head - -sticky ew
    grid $t .side.sy -sticky nsew
    grid columnconfigure .side 0 -weight 1
    grid rowconfigure .side 1 -weight 1
    $t tag configure dir -foreground $::qc::C(uifg)
    bind $t <<TreeviewOpen>> {qc::treeFill [.side.t focus]}
    bind $t <ButtonRelease-1> {qc::treeClick %x %y}
    bind $t <Return> {qc::treeActivate [.side.t focus]}
    bind $t <Button-3> {qc::treePopup %x %y %X %Y}
    bind $t <F2> {qc::treeRename [.side.t focus]}
    bind $t <Delete> {qc::treeDelete [.side.t focus]}
    menu .sidepop -tearoff 0
}

proc qc::treeFill {item} {
    set t .side.t
    if {$item eq "" || ![$t exists $item]} {return}
    set kids [$t children $item]
    if {[llength $kids] == 1 && [string index [lindex $kids 0] 0] eq "\x01"} {
        fillDir $item $item
    }
}

# Lista um diretório na árvore (pastas primeiro; arquivos ocultos de fora).
proc qc::fillDir {parent dir} {
    set t .side.t
    $t delete [$t children $parent]
    set dirs {}
    set files {}
    foreach p [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $p]} {lappend dirs $p} else {lappend files $p}
    }
    foreach p [lsort -dictionary $dirs] {
        $t insert $parent end -id $p -text [file tail $p] -tags dir
        $t insert $p end -id "\x01$p" -text ""
    }
    foreach p [lsort -dictionary $files] {
        $t insert $parent end -id $p -text [file tail $p] -tags file
    }
}

proc qc::treeClick {x y} {
    set t .side.t
    set item [$t identify item $x $y]
    if {$item eq "" || [string match *indicator* [$t identify element $x $y]]} {return}
    treeActivate $item
}

# Arquivo: abre no editor. Pasta: abre/fecha o nó.
proc qc::treeActivate {item} {
    set t .side.t
    if {$item eq "" || ![$t exists $item]} {return}
    if {[$t tag has dir $item]} {
        set open [expr {![$t item $item -open]}]
        if {$open} {treeFill $item}
        $t item $item -open $open
        return
    }
    if {$item ne $::qc::file} {openFile $item}
    focus $::qc::ed
}

# Menu de contexto da árvore. Clique numa pasta cria dentro dela; num
# arquivo, na pasta dele; no vazio, na raiz da pasta aberta.
proc qc::treePopup {x y X Y} {
    variable cfg
    set t .side.t
    if {$cfg(folder) eq ""} {return}
    set item [$t identify item $x $y]
    if {$item ne "" && [string index $item 0] eq "\x01"} {set item ""}
    if {$item ne ""} {
        $t selection set [list $item]
        $t focus $item
        set dir [expr {[$t tag has dir $item] ? $item : [file dirname $item]}]
    } else {
        set dir $cfg(folder)
    }
    set m .sidepop
    $m delete 0 end
    $m add command -label "Novo arquivo…" -command [list qc::treeNew file $dir]
    $m add command -label "Nova pasta…" -command [list qc::treeNew dir $dir]
    $m add separator
    set st [expr {$item eq "" ? "disabled" : "normal"}]
    $m add command -label "Renomear…" -accelerator F2 \
        -command [list qc::treeRename $item] -state $st
    $m add command -label "Mover…" -command [list qc::treeMove $item] -state $st
    $m add command -label "Excluir" -accelerator Del \
        -command [list qc::treeDelete $item] -state $st
    $m add separator
    $m add command -label "Atualizar" -command qc::refreshFolder
    tk_popup $m $X $Y
}

# Pede um nome num diálogo pequeno; devolve "" se cancelado. sel = quantos
# caracteres deixar selecionados (padrão: tudo).
proc qc::askName {title label {init ""} {sel end}} {
    set w .ask
    destroy $w
    toplevel $w -background $::qc::C(ui)
    wm title $w $title
    wm transient $w .
    wm resizable $w 0 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text $label
    ttk::entry $w.f.e -width 44
    ttk::frame $w.f.b
    ttk::button $w.f.b.ok -text OK -command {set ::qc::askDone 1}
    ttk::button $w.f.b.c -text Cancelar -command {set ::qc::askDone 0}
    pack $w.f -fill both -expand 1
    pack $w.f.l -anchor w
    pack $w.f.e -fill x -pady 6
    pack $w.f.b -anchor e
    pack $w.f.b.c $w.f.b.ok -side right -padx {6 0}
    bind $w <Return> {set ::qc::askDone 1}
    bind $w <Escape> {set ::qc::askDone 0}
    wm protocol $w WM_DELETE_WINDOW {set ::qc::askDone 0}
    $w.f.e insert 0 $init
    $w.f.e selection range 0 $sel
    $w.f.e icursor $sel
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    set ::qc::askDone 0
    focus $w.f.e
    catch {grab $w}
    tkwait variable ::qc::askDone
    set res [expr {$::qc::askDone ? [string trim [$w.f.e get]] : ""}]
    destroy $w
    return $res
}

# Nome válido para um item dentro de dir: sem barras, não vazio, inexistente.
proc qc::checkNewName {dir name} {
    if {$name in {"" . ..} || [string match */* $name]} {
        return "Nome inválido."
    }
    if {[file exists [file join $dir $name]]} {
        return "Já existe \"$name\" em [file tail $dir]."
    }
    return ""
}

proc qc::treeError {msg {detail ""}} {
    tk_messageBox -parent . -icon error -title qconsole -message $msg -detail $detail
}

# Cria um arquivo (e abre no editor) ou uma pasta dentro de dir.
proc qc::treeNew {kind dir} {
    set title [expr {$kind eq "file" ? "Novo arquivo" : "Nova pasta"}]
    set name [askName $title "Nome (em [file tail $dir]):"]
    if {$name eq ""} {return}
    set err [checkNewName $dir $name]
    if {$err ne ""} {treeError $err; return}
    set path [file join $dir $name]
    if {[catch {
        if {$kind eq "file"} {close [open $path {WRONLY CREAT EXCL}]} else {file mkdir $path}
    } err]} {
        treeError "Não foi possível criar \"$name\"." $err
        return
    }
    refreshFolder
    treeShow $path
    if {$kind eq "file"} {openFile $path; focus $::qc::ed}
}

# Abre as pastas acima de path na árvore e o seleciona.
proc qc::treeShow {path} {
    variable cfg
    set t .side.t
    set root [file normalize $cfg(folder)]
    if {[string first $root/ $path] != 0} {return}
    set p $root
    foreach part [lrange [file split [string range $path [string length $root]+1 end]] 0 end-1] {
        set p [file join $p $part]
        if {![$t exists $p]} {return}
        treeFill $p
        $t item $p -open 1
    }
    if {[$t exists $path]} {
        $t selection set [list $path]
        $t focus $path
        $t see $path
    }
}

# Um arquivo/pasta mudou de lugar: atualiza abas e arquivos recentes.
proc qc::pathMoved {old new} {
    variable TB
    variable cfg
    # abas abertas do arquivo (ou de arquivos dentro da pasta)
    foreach w $::qc::tabs {
        set f $TB($w,file)
        if {$f eq $old || [string first $old/ $f] == 0} {
            set TB($w,file) $new[string range $f [string length $old] end]
            if {$w eq $::qc::ed} {
                variable file $TB($w,file)
                set id [langForFile $file "" 1]
                if {$id ne "" && $id ne $::qc::lang} {setLang $id}
            }
        }
    }
    set l {}
    foreach f $cfg(recent) {
        if {$f eq $old || [string first $old/ $f] == 0} {
            set f $new[string range $f [string length $old] end]
        }
        lappend l $f
    }
    set cfg(recent) $l
    updateRecentMenu
    updateTitle
}

# F2 / menu: renomeia arquivo ou pasta, atualizando abas e recentes.
proc qc::treeRename {item} {
    set t .side.t
    if {![treeItemOk $item]} {return}
    set old $item
    set dir [file dirname $old]
    set tail [file tail $old]
    set ext [file extension $tail]
    set sel [expr {[file isfile $old] && $ext ne "" && $ext ne $tail
        ? [string length $tail] - [string length $ext] : "end"}]
    set name [askName Renomear "Novo nome:" $tail $sel]
    if {$name eq "" || $name eq $tail} {return}
    set err [checkNewName $dir $name]
    if {$err ne ""} {treeError $err; return}
    set new [file join $dir $name]
    set wasOpen [expr {[$t tag has dir $old] && [$t item $old -open]}]
    if {[catch {file rename $old $new} err]} {
        treeError "Não foi possível renomear \"$tail\"." $err
        return
    }
    pathMoved $old $new
    refreshFolder
    if {$wasOpen && [$t exists $new]} {treeFill $new; $t item $new -open 1}
    treeShow $new
    set ::qc::status "Renomeado: $tail → $name"
}

proc qc::treeItemOk {item} {
    expr {$item ne "" && [.side.t exists $item] && [string index $item 0] ne "\x01"}
}

# Move o arquivo/pasta para outra pasta (escolhida no seletor).
proc qc::treeMove {item} {
    if {![treeItemOk $item]} {return}
    set tail [file tail $item]
    set dest [chooseDir "Mover \"$tail\" para" [file dirname $item]]
    if {$dest eq "" || $dest eq [file dirname $item]} {return}
    if {$dest eq $item || [string first $item/ $dest] == 0} {
        treeError "Não dá para mover uma pasta para dentro dela mesma."
        return
    }
    set err [checkNewName $dest $tail]
    if {$err ne ""} {treeError $err; return}
    set new [file join $dest $tail]
    if {[catch {file rename $item $new} err]} {
        treeError "Não foi possível mover \"$tail\"." $err
        return
    }
    pathMoved $item $new
    refreshFolder
    treeShow $new
    set ::qc::status "Movido: $tail → $dest"
}

# Exclui (para a lixeira, se houver gio) o arquivo/pasta, depois de confirmar.
# Abas dos arquivos excluídos são fechadas; as com alterações ficam abertas.
proc qc::treeDelete {item} {
    variable TB
    variable cfg
    if {![treeItemOk $item]} {return}
    set tail [file tail $item]
    set isDir [file isdirectory $item]
    set trash [expr {[auto_execok gio] ne ""}]
    set what [expr {$isDir ? "a pasta \"$tail\" e tudo dentro dela" : "\"$tail\""}]
    set where [expr {$trash ? "para a lixeira" : "definitivamente"}]
    set r [tk_messageBox -parent . -icon warning -type okcancel -default cancel \
        -title Excluir -message "Excluir $what?" -detail "Será movido $where.\n$item"]
    if {$r ne "ok"} {return}
    if {$trash && [catch {exec gio trash -- $item} err]} {
        set r [tk_messageBox -parent . -icon warning -type okcancel -default cancel \
            -title Excluir -message "Não foi possível mover para a lixeira.\
                Excluir definitivamente?" -detail [string trim $err]]
        if {$r ne "ok"} {return}
        set trash 0
    }
    if {!$trash && [catch {file delete -force -- $item} err]} {
        treeError "Não foi possível excluir \"$tail\"." $err
        return
    }
    foreach w $::qc::tabs {
        set f $TB($w,file)
        if {($f eq $item || [string first $item/ $f] == 0) && ![$w edit modified]} {
            closeTab $w
        }
    }
    set l {}
    foreach f $cfg(recent) {
        if {$f ne $item && [string first $item/ $f] != 0} {lappend l $f}
    }
    set cfg(recent) $l
    updateRecentMenu
    refreshFolder
    set ::qc::status "Excluído: $tail"
}

# Seletor de pasta próprio: clique seleciona e "Abrir" abre a pasta
# selecionada (o diálogo do Tk abriria a pasta de cima); duplo clique entra.
proc qc::chooseDir {title {init ""}} {
    variable C
    variable CD
    set w .cdir
    destroy $w
    if {$init eq "" || ![file isdirectory $init]} {set init [pwd]}
    set CD(path) [file normalize $init]
    set CD(hidden) 0
    set CD(done) 0
    toplevel $w -background $C(ui)
    wm title $w $title
    wm transient $w .
    ttk::frame $w.f -padding 10
    ttk::frame $w.f.top
    ttk::button $w.f.top.up -text ↑ -width 3 -command qc::cdUp
    ttk::entry $w.f.top.e -textvariable ::qc::CD(path)
    pack $w.f.top.up -side left
    pack $w.f.top.e -side left -fill x -expand 1 -padx {6 0}
    listbox $w.f.l -font TkDefaultFont -background $C(field) -foreground $C(edfg) \
        -selectbackground $C(sel) -selectforeground #ffffff -bd 0 \
        -highlightthickness 0 -activestyle none -exportselection 0 \
        -yscrollcommand [list $w.f.sy set]
    ttk::scrollbar $w.f.sy -orient vertical -command [list $w.f.l yview]
    ttk::label $w.f.hint -foreground #8a8a8a \
        -text "Duplo clique entra na pasta · Abrir usa a selecionada (ou a atual)"
    ttk::frame $w.f.b
    ttk::checkbutton $w.f.b.h -text "Mostrar ocultas" -variable ::qc::CD(hidden) \
        -command {qc::cdGo $::qc::CD(path)}
    ttk::button $w.f.b.ok -text Abrir -command qc::cdOk
    ttk::button $w.f.b.c -text Cancelar -command {set ::qc::CD(done) 1}
    pack $w.f.b.h -side left
    pack $w.f.b.c $w.f.b.ok -side right -padx {6 0}
    grid $w.f.top - -sticky ew -pady {0 6}
    grid $w.f.l $w.f.sy -sticky nsew
    grid $w.f.hint - -sticky w -pady {4 0}
    grid $w.f.b - -sticky ew -pady {6 0}
    grid columnconfigure $w.f 0 -weight 1
    grid rowconfigure $w.f 1 -weight 1
    pack $w.f -fill both -expand 1
    bind $w.f.l <Double-1> {qc::cdEnter}
    bind $w.f.l <Right> {qc::cdEnter}
    bind $w.f.l <Left> {qc::cdUp}
    bind $w.f.l <BackSpace> {qc::cdUp}
    bind $w.f.l <Return> {qc::cdOk; break}
    bind $w.f.top.e <Return> {qc::cdGo $::qc::CD(path); break}
    bind $w <Escape> {set ::qc::CD(done) 1}
    wm protocol $w WM_DELETE_WINDOW {set ::qc::CD(done) 1}
    wm geometry $w 560x420+[expr {[winfo rootx .] + 120}]+[expr {[winfo rooty .] + 80}]
    cdGo $CD(path)
    focus $w.f.l
    catch {grab $w}
    set CD(result) ""
    tkwait variable ::qc::CD(done)
    destroy $w
    return $CD(result)
}

proc qc::cdGo {dir {select ""}} {
    variable CD
    set l .cdir.f.l
    set dir [file normalize $dir]
    if {![file isdirectory $dir]} {bell; return}
    set CD(path) $dir
    set names {}
    foreach p [glob -nocomplain -types d -directory $dir *] {lappend names [file tail $p]}
    if {$CD(hidden)} {
        foreach p [glob -nocomplain -types {d hidden} -directory $dir *] {
            set n [file tail $p]
            if {$n ni {. ..}} {lappend names $n}
        }
    }
    $l delete 0 end
    foreach n [lsort -dictionary $names] {$l insert end $n}
    # nada fica selecionado: "Abrir" logo após entrar abre a pasta atual
    set i [expr {$select eq "" ? -1 : [lsearch -exact [$l get 0 end] $select]}]
    if {$i < 0 && [$l size]} {set i 0}
    if {$i >= 0} {
        $l activate $i
        $l see $i
    }
}

proc qc::cdUp {} {
    variable CD
    cdGo [file dirname $CD(path)] [file tail $CD(path)]
}

proc qc::cdEnter {} {
    variable CD
    set l .cdir.f.l
    set i [lindex [$l curselection] 0]
    if {$i eq ""} {set i [$l index active]}
    if {$i eq "" || $i >= [$l size]} {return}
    cdGo [file join $CD(path) [$l get $i]]
}

proc qc::cdOk {} {
    variable CD
    set l .cdir.f.l
    set i [lindex [$l curselection] 0]
    set CD(result) [expr {$i eq "" ? $CD(path) : [file join $CD(path) [$l get $i]]}]
    set CD(done) 1
}

proc qc::openFolder {{dir ""}} {
    variable cfg
    if {$dir eq ""} {
        set opts {""}
        foreach d [list $cfg(folder) $cfg(lastdir)] {
            if {$d ne "" && [file isdirectory $d]} {lappend opts $d; break}
        }
        set dir [chooseDir "Abrir pasta" [lindex $opts end]]
        if {$dir eq ""} {
            if {$cfg(folder) eq ""} {set cfg(sidebar) 0}
            return
        }
    }
    if {![file isdirectory $dir]} {
        treeError "A pasta não existe mais." $dir
        set cfg(recentdirs) [lsearch -all -inline -not -exact $cfg(recentdirs) $dir]
        updateRecentMenu
        return
    }
    set cfg(folder) [file normalize $dir]
    set cfg(lastdir) $cfg(folder)
    set ::qc::folderName [file tail $cfg(folder)]
    addRecentDir $cfg(folder)
    fillDir {} $cfg(folder)
    showSide 1
    treeReveal
    if {$cfg(autocomp)} {projIndexStart}
}

proc qc::closeFolder {} {
    variable cfg
    set cfg(folder) ""
    projIndexClear
    .side.t delete [.side.t children {}]
    showSide 0
}

# Relê a pasta, mantendo abertas as subpastas que estavam abertas.
proc qc::refreshFolder {} {
    variable cfg
    if {$cfg(folder) eq "" || ![file isdirectory $cfg(folder)]} {return}
    set t .side.t
    set open {}
    set stack [$t children {}]
    while {[llength $stack]} {
        set stack [lassign $stack i]
        if {[$t item $i -open]} {
            lappend open $i
            lappend stack {*}[$t children $i]
        }
    }
    set sel [$t selection]
    set top [$t identify item 5 5]
    fillDir {} $cfg(folder)
    foreach i $open {
        if {[$t exists $i]} {fillDir $i $i; $t item $i -open 1}
    }
    set keep {}
    foreach i $sel {if {[$t exists $i]} {lappend keep $i}}
    $t selection set $keep
    if {$top ne "" && [$t exists $top]} {$t see $top}
    if {$cfg(autocomp) || $::qc::PS(root) ne ""} {projIndexStart}
}

# Seleciona na árvore o arquivo aberto no editor (abrindo as pastas dele).
proc qc::treeReveal {} {
    variable cfg
    variable file
    set t .side.t
    if {$file eq "" || $cfg(folder) eq "" || ".side" ni [.hp panes]} {return}
    set root [file normalize $cfg(folder)]
    if {[string first $root/ $file] != 0} {
        $t selection set {}
        return
    }
    set p $root
    foreach part [lrange [file split [string range $file [string length $root]+1 end]] 0 end-1] {
        set p [file join $p $part]
        if {![$t exists $p]} {return}
        treeFill $p
        $t item $p -open 1
    }
    if {[$t exists $file]} {
        $t selection set [list $file]
        $t focus $file
        $t see $file
    }
}

proc qc::showSide {on} {
    variable cfg
    set cfg(sidebar) $on
    set shown [expr {".side" in [.hp panes]}]
    if {$on && !$shown} {
        .hp insert 0 .side -weight 0
        update idletasks
        catch {.hp sashpos 0 $cfg(sidew)}
        # tclint-disable-next-line command-args
        after idle [list catch [list .hp sashpos 0 $cfg(sidew)]]
    } elseif {!$on && $shown} {
        catch {set cfg(sidew) [.hp sashpos 0]}
        .hp forget .side
    }
}

# Ctrl+B / Exibir > Painel de arquivos
proc qc::toggleSide {} {
    variable cfg
    set cfg(sidebar) [expr {!$cfg(sidebar)}]
    applySide
}

proc qc::applySide {} {
    variable cfg
    if {!$cfg(sidebar)} {
        showSide 0
    } elseif {$cfg(folder) eq "" || ![file isdirectory $cfg(folder)]} {
        openFolder
    } else {
        if {![llength [.side.t children {}]]} {openFolder $cfg(folder)}
        showSide 1
        treeReveal
    }
}

# ---------------------------------------------------------------------------
# Comandos do projeto (arquivo .qconsole)
# ---------------------------------------------------------------------------
# Um arquivo .qconsole na raiz do projeto define comandos (nome {comando}).
# Ctrl+Alt+R executa o primeiro; Ctrl+R continua executando o arquivo atual
# e Ctrl+Shift+R a seleção. O comando roda com "sh -c" na pasta do
# .qconsole; %F vira o arquivo aberto no editor e %R a raiz do projeto.

set qc::projName .qconsole

# Procura o .qconsole subindo a partir da pasta do arquivo atual e da pasta
# aberta no painel lateral.
proc qc::projectFile {} {
    variable file
    variable cfg
    set starts {}
    if {$file ne ""} {lappend starts [file dirname $file]}
    if {$cfg(folder) ne ""} {lappend starts $cfg(folder)}
    foreach d $starts {
        while 1 {
            set f [file join $d $::qc::projName]
            if {[file isfile $f]} {return $f}
            set up [file dirname $d]
            if {$up eq $d} {break}
            set d $up
        }
    }
    return ""
}

# Lê os comandos (dicionário nome -> comando); linhas com # são comentários.
proc qc::projectCmds {pf} {
    set lines {}
    foreach l [split [readFile $pf] \n] {
        if {![regexp {^\s*#} $l]} {lappend lines $l}
    }
    set d [join $lines \n]
    if {[catch {dict size $d}]} {
        error "formato inválido: use uma linha por comando, como  run {sbt run}"
    }
    return $d
}

# Ctrl+Alt+R: comando principal do projeto, ou o arquivo atual se não houver.
proc qc::runMain {} {
    set pf [projectFile]
    if {$pf eq ""} {
        run 0
        return
    }
    if {[catch {projectCmds $pf} cmds]} {
        clearConsole
        conAppend "$pf: $cmds\n" stderr
        return
    }
    if {![dict size $cmds]} {
        run 0
        return
    }
    runProject $pf [lindex [dict keys $cmds] 0]
}

proc qc::shQuote {s} {
    return '[string map {' '\''} $s]'
}

proc qc::runProject {pf name} {
    variable R
    variable cfg
    variable ed
    variable file
    if {[info exists R(fd)]} {
        set ::qc::status "Já existe uma execução em andamento (Ctrl+Break para interromper)"
        return
    }
    if {[catch {projectCmds $pf} cmds] || ![dict exists $cmds $name]} {
        conAppend "$pf: comando \"$name\" não encontrado\n" stderr
        return
    }
    # o build lê do disco: salva antes os arquivos abertos modificados
    foreach w $::qc::tabs {
        set f $::qc::TB($w,file)
        if {$f ne "" && [$w edit modified] && ![saveTo $f $w]} {return}
    }
    set root [file dirname [file normalize $pf]]
    set cmd [string map [list %F [shQuote $file] %R [shQuote $root]] [dict get $cmds $name]]
    if {$cfg(autoclear)} {clearConsole}
    ::qc::_edw tag remove errline 1.0 end
    ::qc::_edw tag remove warnline 1.0 end
    if {$::tcl_platform(platform) eq "windows"} {
        set argv [list cmd /c $cmd]
    } else {
        set argv [list sh -c $cmd]
    }
    lassign [chan pipe] er ew
    set old [pwd]
    catch {cd $root}
    set rc [catch {open |[list {*}$argv 2>@ $ew] r+} fd]
    cd $old
    if {$rc} {
        close $er; close $ew
        conAppend "Erro ao executar \"$cmd\": $fd\n" stderr
        return
    }
    close $ew
    catch {chan close $fd write}
    foreach c [list $fd $er] {
        fconfigure $c -blocking 0 -buffering none -translation auto
        setEncoding $c
    }
    array set R [list fd $fd er $er open 2 t0 [clock milliseconds] lang $::qc::lang \
        killed 0 pend "" sgr {} pid [lindex [pid $fd] 0] proj $root]
    chan event $fd readable [list qc::onStdout $fd]
    chan event $er readable [list qc::onStderr $er]
    conAppend "▶ [join [list "$name: [dict get $cmds $name]" [file tail $root] \
    [clock format [clock seconds] -format %H:%M:%S]] {  ·  }]\n" info
    set R(scan) [$::qc::con index end-1c]
    setRunning 1
    set ::qc::status "Executando $name…"
}

# Transforma em links as referências arquivo:linha[:coluna] das linhas
# completas da saída de um comando do projeto (ex.: erros do sbt/scalac).
proc qc::projScan {} {
    variable R
    variable con
    variable linkSeq
    set stop [$con index "end-1c linestart"]
    set i $R(scan)
    set re {((?:[A-Za-z]:)?[^\s:"'()\[\]<>]*[A-Za-z0-9_]\.[A-Za-z0-9]+):([0-9]+)(?::([0-9]+))?}
    while {[$con compare $i < $stop]} {
        set line [$con get $i "$i lineend"]
        set l [lindex [split $i .] 0]
        foreach {m f n c} [regexp -all -inline -indices -- $re $line] {
            set path [string range $line {*}$f]
            if {[file pathtype $path] ne "absolute"} {set path [file join $R(proj) $path]}
            if {![file isfile $path]} {continue}
            set path [file normalize $path]
            set ln [string range $line {*}$n]
            set col [expr {[lindex $c 0] >= 0 ? [string range $line {*}$c] - 1 : 0}]
            set lt link[incr linkSeq]
            $con tag add link $l.[lindex $m 0] $l.[expr {[lindex $m 1] + 1}]
            $con tag add $lt $l.[lindex $m 0] $l.[expr {[lindex $m 1] + 1}]
            $con tag bind $lt <1> [list qc::openAt $path $ln [expr {max($col, 0)}]]
        }
        set i [$con index "$i +1 line"]
    }
    set R(scan) $i
}

proc qc::openAt {path line col} {
    if {$path ne $::qc::file} {
        openFile $path
        if {$::qc::file ne $path} {return}
    }
    gotoLine $line $col
}

proc qc::updateProjMenu {} {
    set m .mb.script.proj
    $m delete 0 end
    set pf [projectFile]
    if {$pf eq ""} {
        $m add command -label "(nenhum $::qc::projName encontrado)" -state disabled
        return
    }
    if {[catch {projectCmds $pf} cmds]} {
        $m add command -label "($::qc::projName inválido)" -state disabled
        return
    }
    set first 1
    dict for {name cmd} $cmds {
        $m add command -label "$name — $cmd" -command [list qc::runProject $pf $name] \
            -accelerator [expr {$first ? "Ctrl+Alt+R" : ""}]
        set first 0
    }
}

# Abre o .qconsole do projeto; se não existir, cria um modelo na pasta aberta
# no painel (ou na pasta do arquivo atual).
proc qc::editProjectFile {} {
    variable cfg
    variable file
    set pf [projectFile]
    if {$pf eq ""} {
        if {$cfg(folder) ne ""} {
            set root $cfg(folder)
        } elseif {$file ne ""} {
            set root [file dirname $file]
        } else {
            set root [chooseDir "Pasta do projeto" $cfg(lastdir)]
            if {$root eq ""} {return}
        }
        set pf [file join $root $::qc::projName]
        if {[file exists [file join $root build.sbt]]} {
            set cmds "run   {sbt run}\ntest  {sbt test}\nbuild {sbt compile}"
        } elseif {[file exists [file join $root Makefile]]} {
            set cmds "run   {make run}\nbuild {make}\ntest  {make test}"
        } else {
            set cmds "run   {echo \"defina o comando em $::qc::projName\"}"
        }
        writeFile $pf "# Comandos do projeto para o qconsole: uma linha por comando, nome {comando}.
# Ctrl+Alt+R executa o primeiro; os demais ficam em Executar > Comandos do projeto.
# Ctrl+R continua executando o arquivo atual e Ctrl+Shift+R a seleção.
# Os comandos rodam com sh -c nesta pasta. %F = arquivo aberto no editor,
# %R = esta pasta. Referências arquivo:linha:coluna na saída viram links.
$cmds
"
        if {$cfg(folder) ne ""} {refreshFolder}
    }
    openFile $pf
}

# ---------------------------------------------------------------------------
# Troca de linguagem e destaque de sintaxe
# ---------------------------------------------------------------------------

proc qc::setLang {id} {
    variable lang
    variable langs
    variable inited
    variable cfg
    set id [langAlias $id]
    if {$id ni $langs} {return}
    if {$id ni $inited} {
        lappend inited $id
        set h [hook init $id]
        if {$h ne ""} {
            if {[catch {$h} err]} {conAppend "Erro no init de $id: $err\n" stderr}
        }
    }
    set lang $id
    set ::qc::TB($::qc::ed,lang) $id
    set ::qc::langSel $id
    set ::qc::langName [lget name]
    set cfg(lang) $id
    compileLang
    updateTabs
    updateTemplateMenu
    updateFmtSaveMenu
    highlight
    updateTitle
    detectVersion
    # índice de biblioteca da linguagem (dica/F12), em segundo plano
    if {$cfg(hoverdef)} {apiStart $id}
    mdApply
}

# Monta a regex única da linguagem: cada token vira um grupo; um token com
# grupo interno colore só esse grupo.
proc qc::compileLang {} {
    variable H
    variable S
    variable ed
    variable TB
    set d [ldict]
    if {[info exists TB($ed,hltags)]} {
        foreach t $TB($ed,hltags) {catch {::qc::_edw tag delete $t}}
    }
    array unset H
    set parts {}
    set specs {}
    set g 1
    set tags {}
    foreach {tag re} [dict get $d tokens] {
        if {[catch {regexp -about $re} ab]} {
            conAppend "Regex inválida em [lget name] ($tag): $ab\n" stderr
            continue
        }
        set n [lindex $ab 0]
        lappend parts "($re)"
        lappend specs [list $tag $g [expr {$n > 0}]]
        incr g [expr {$n + 1}]
        if {$tag ne "word"} {lappend tags $tag}
    }
    set H(re) "(?w)[join $parts |]"
    set H(specs) $specs
    set H(nfields) $g
    set wd [dict create]
    dict for {tag list} [dict get $d words] {
        foreach w $list {dict set wd $w $tag}
        lappend tags $tag
    }
    set H(words) $wd
    set H(defWords) [dict get $d defWords]
    set H(defTag) [dict get $d defTag]
    set H(capType) [dict get $d capType]
    set H(numRe) [dict get $d numberWord]
    set H(through) [dict get $d defThroughBrace]
    set H(pretty) [dict get $d pretty]
    set H(sub) [dict get $d sub]
    set H(wordHook) [hook wordTag]
    set H(rainbow) [expr {[dict get $d rainbow] ? [llength $::qc::rainbow] : 0}]
    set subtags {}
    dict for {t rules} $H(sub) {
        foreach {cond st sre} $rules {lappend subtags $st}
    }
    lappend tags $H(defTag) number
    if {$H(capType) ne ""} {lappend tags $H(capType)}
    set rbStyles {}
    for {set k 0} {$k < $H(rainbow)} {incr k} {
        lappend tags rb$k
        dict set rbStyles rb$k [list [lindex $::qc::rainbow $k] {}]
    }
    if {$H(rainbow)} {
        lappend tags rbbad
        dict set rbStyles rbbad [list $::qc::C(stderr) B]
    }
    set tags [lsort -unique [concat $tags $subtags]]
    set H(tags) $tags
    set TB($ed,hltags) $tags
    set H(subtags) [lsort -unique $subtags]

    set styles [dict merge $S $rbStyles [dict get $d styles]]
    foreach t $tags {
        set opts {}
        if {[dict exists $styles $t]} {
            lassign [dict get $styles $t] color st
            if {$color ne ""} {lappend opts -foreground $color}
            switch -- $st {
                B {lappend opts -font QcMonoB}
                I {lappend opts -font QcMonoI}
            }
        }
        ::qc::_edw tag configure $t {*}$opts
    }
    foreach t [concat $H(subtags) warnline errline found bmatch bbad sel] {::qc::_edw tag raise $t}
    ::qc::_edw tag lower curline
}

proc qc::schedHighlight {} {
    variable hlAfter
    after cancel $hlAfter
    set hlAfter [after 120 {qc::highlight}]
}

proc qc::highlight {} {
    variable ed
    variable H
    set txt [$ed get 1.0 end-1c]
    set starts {}
    set o 0
    foreach ln [split $txt \n] {
        lappend starts $o
        incr o [expr {[string length $ln] + 1}]
    }
    foreach t $H(tags) {set rng($t) {}}
    set nf $H(nfields)
    set defNext 0
    set open {} ;# rainbow: aberturas pendentes {fecho range}
    set pretty [expr {$::qc::cfg(pretty) && [dict size $H(pretty)]}]
    set pw {} ;# palavras exibidas como símbolo
    set pe {} ;# ...e o trecho oculto de cada uma
    set m [regexp -all -inline -indices -- $H(re) $txt]
    for {set i 0} {$i < [llength $m]} {incr i $nf} {
        set tag ""
        foreach spec $H(specs) {
            lassign $spec t g inner
            set r [lindex $m [expr {$i + $g}]]
            if {[lindex $r 0] < 0} {continue}
            set tag $t
            if {$inner} {
                set r2 [lindex $m [expr {$i + $g + 1}]]
                if {[lindex $r2 0] >= 0} {set r $r2}
            }
            break
        }
        if {$tag eq ""} {continue}
        lassign $r a z
        if {$tag eq "word"} {
            set word [string range $txt $a $z]
            if {$pretty && [dict exists $H(pretty) $word]} {
                lappend pw [off2idx $starts $a] [off2idx $starts [expr {$z + 1}]]
                lappend pe [off2idx $starts [expr {$a + 1}]] [off2idx $starts [expr {$z + 1}]]
            }
            set tag ""
            set fromTable 0
            if {$H(numRe) ne "" && [regexp -- $H(numRe) $word]} {
                set tag number
            } elseif {[dict exists $H(words) $word]} {
                set tag [dict get $H(words) $word]
                set fromTable 1
            }
            if {$H(wordHook) ne ""} {set tag [$H(wordHook) $word $tag $txt $a]}
            if {$tag ne ""} {
                set defNext [expr {$fromTable && $word in $H(defWords)}]
            } elseif {$defNext} {
                set tag $H(defTag)
                set defNext 0
            } elseif {$H(capType) ne "" && [string is upper [string index $word 0]]} {
                set tag $H(capType)
            } else {
                set defNext 0
                continue
            }
        } elseif {!($tag eq "brace" && $H(through))} {
            set defNext 0
        }
        if {$tag eq "brace" && $H(rainbow)} {
            # cor pelo nível de aninhamento; a abertura só é colorida quando
            # o fechamento correspondente aparece. Sem par (ou com o par
            # trocado, ex.: "(]"): rbbad
            set ch [string index $txt $a]
            set r [list [off2idx $starts $a] [off2idx $starts [expr {$a + 1}]]]
            set k [string first $ch "(\[\{"]
            if {$k >= 0} {
                lappend open [list [string index ")\]\}" $k] $r]
            } elseif {[llength $open] && [lindex $open end 0] eq $ch} {
                set rt rb[expr {([llength $open] - 1) % $H(rainbow)}]
                lappend rng($rt) {*}[lindex $open end 1] {*}$r
                set open [lrange $open 0 end-1]
            } else {
                lappend rng(rbbad) {*}$r
            }
            continue
        }
        lappend rng($tag) [off2idx $starts $a] [off2idx $starts [expr {$z + 1}]]
        # sub-destaques (ex.: interpolação em strings)
        if {[dict exists $H(sub) $tag]} {
            set str [string range $txt $a $z]
            foreach {cond st sre} [dict get $H(sub) $tag] {
                if {![regexp -- $cond $str]} {continue}
                foreach sr [regexp -all -inline -indices -- $sre $str] {
                    lassign $sr ia iz
                    lappend rng($st) [off2idx $starts [expr {$a + $ia}]] \
                        [off2idx $starts [expr {$a + $iz + 1}]]
                }
            }
        }
    }
    foreach o $open {lappend rng(rbbad) {*}[lindex $o 1]}
    foreach t $H(tags) {
        ::qc::_edw tag remove $t 1.0 end
        if {[llength $rng($t)]} {::qc::_edw tag add $t {*}$rng($t)}
    }
    ::qc::_edw tag remove pword 1.0 end
    ::qc::_edw tag remove pel 1.0 end
    if {[llength $pw]} {
        ::qc::_edw tag add pword {*}$pw
        ::qc::_edw tag add pel {*}$pe
    }
    unset -nocomplain ::qc::TB($ed,praw)
    computeFolds $txt
    prettyCursor
    schedGutter
    if {[winfo ismapped [fb]]} {markAll}
}

# offset de caractere -> índice do widget text
proc qc::off2idx {starts off} {
    set L [lsearch -bisect -integer $starts $off]
    return [expr {$L + 1}].[expr {$off - [lindex $starts $L]}]
}

# ---------------------------------------------------------------------------
# Números de linha, cursor, pares de chaves
# ---------------------------------------------------------------------------

proc qc::edYscroll {w args} {
    if {![edVisible $w]} {return}
    [winfo parent $w].sy set {*}$args
    if {$w ne $::qc::ed} {
        otherGutter $w
        mdSync [winfo parent $w]
        return
    }
    schedGutter
    mdSync
    if {[llength $::qc::mcur]} {after idle {qc::drawCarets}}
}

proc qc::edXscroll {w args} {
    if {![edVisible $w]} {return}
    [winfo parent $w].sx set {*}$args
    if {$w ne $::qc::ed} {otherGutter $w; return}
    schedGutter
    if {[llength $::qc::mcur]} {after idle {qc::drawCarets}}
}

# barras de rolagem -> editor exibido naquela janela
proc qc::hostScroll {host cmd args} {
    [hostEd $host] $cmd {*}$args
}

# Editor exibido numa janela (.pw.ed = principal; senão, janela desacoplada).
proc qc::hostEd {host} {
    if {$host eq ".pw.ed"} {return $::qc::dockCur}
    return $host.t
}

# O editor está à vista (aba da janela principal exibida ou desacoplada)?
proc qc::edVisible {w} {
    expr {[winfo parent $w] ne ".pw.ed" || $w eq $::qc::dockCur}
}

# Barra de busca da janela do editor ativo.
proc qc::fb {} {
    return [winfo parent $::qc::ed].find
}

# Números de linha de um editor visível que não é o ativo (ex.: rolado com
# a roda do mouse enquanto o foco está em outra janela).
proc qc::otherGutter {w} {
    if {![info exists ::qc::gutO($w)]} {
        set ::qc::gutO($w) 1
        # tclint-disable-next-line command-args
        after idle [list qc::drawGutter $w]
    }
}

proc qc::edConfigure {w} {
    if {$w eq $::qc::ed} {schedGutter} elseif {[winfo exists $w] && [edVisible $w]} {otherGutter $w}
}

proc qc::schedGutter {} {
    variable gutPending
    if {!$gutPending} {
        set gutPending 1
        after idle {qc::drawGutter}
    }
}

proc qc::drawGutter {{ed ""}} {
    variable C
    if {$ed eq ""} {
        variable gutPending 0
        set ed $::qc::ed
        set main 1
    } else {
        unset -nocomplain ::qc::gutO($ed)
        if {![winfo exists $ed] || ![edVisible $ed]} {return}
        if {$ed eq $::qc::ed} {schedGutter; return}
        set main 0
        # símbolos e cursores extras ficariam fora do lugar
        foreach l [winfo children $ed] {place forget $l}
    }
    set gut [winfo parent $ed].gut
    $gut delete all
    set last [lindex [split [$ed index end-1c] .] 0]
    set digits [expr {max(3, [string length $last])}]
    # números | coluna dos marcadores de recolher/expandir
    set w [expr {[font measure QcMono [string repeat 9 $digits]] + 30}]
    if {[$gut cget -width] != $w} {$gut configure -width $w}
    set cur [lindex [split [$ed index insert] .] 0]
    set folds [expr {[info exists ::qc::TB($ed,folds)] ? $::qc::TB($ed,folds) : {}}]
    set folded [foldedHeads $ed]
    set hover [expr {[info exists ::qc::gutHover($gut)] && $::qc::gutHover($gut)}]
    set k [expr {max(3, [font metrics QcMono -linespace] * 3 / 10)}] ;# meio triângulo
    set mx [expr {$w - 10}]
    set dim [blend $C(gutfg) $C(gutbg) 0.55]
    set nl 0 ;# "⋯" dos blocos recolhidos
    set i [$ed index "@0,0 linestart"]
    if {[$ed dlineinfo $i] eq ""} {set i [$ed index "$i +1 line"]}
    while {[$ed compare $i < end]} {
        # linhas de um bloco recolhido: pula para depois dele
        set e [foldEndAt $ed $i]
        if {$e ne "" && [$ed compare $e > $i]} {
            set i $e
            continue
        }
        set d [$ed dlineinfo $i]
        if {$d eq ""} {break}
        set n [lindex [split $i .] 0]
        $gut create text [expr {$w - 22}] [lindex $d 1] -anchor ne -text $n \
            -font QcMono -fill [expr {$n == $cur ? $C(gutcur) : $C(gutfg)}]
        set my [expr {[lindex $d 1] + [lindex $d 3] / 2}]
        if {[dict exists $folded $n]} {
            $gut create polygon [expr {$mx - $k / 2}] [expr {$my - $k}] \
                [expr {$mx + $k / 2 + 1}] $my [expr {$mx - $k / 2}] [expr {$my + $k}] \
                -fill $C(gutcur) -outline $C(gutcur)
            set bb [$ed bbox "$n.0 lineend"]
            if {$bb ne ""} {
                set l $ed.fd$nl
                if {![winfo exists $l]} {
                    label $l -text "⋯" -font QcMono -padx 4 -pady 0 -bd 0 \
                        -highlightthickness 0 -cursor hand2 \
                        -foreground $C(gutcur) -background $C(uiactive)
                    bindtags $l [list $l QcFoldMark QcPretty]
                }
                set ::qc::fdLine($l) $n
                place $l -x [expr {[lindex $bb 0] + 6}] -y [lindex $bb 1] \
                    -height [lindex $bb 3] -bordermode outside
                incr nl
            }
        } elseif {$hover && [dict exists $folds $n]} {
            $gut create polygon [expr {$mx - $k}] [expr {$my - $k / 2}] \
                [expr {$mx + $k}] [expr {$my - $k / 2}] $mx [expr {$my + $k / 2 + 1}] \
                -fill $dim -outline $dim
        }
        set i [$ed index "$i +1 line"]
    }
    while {[winfo exists $ed.fd$nl]} {
        place forget $ed.fd$nl
        incr nl
    }
    drawRulers $ed
    drawIndentGuides $ed
    if {$main} {drawPretty}
}

# --- guias de coluna (cfg(rulers)) -----------------------------------------
# Linhas verticais finas sobre o editor, redesenhadas junto com a margem
# (rolagem, zoom, redimensionamento). A posição vem do x da linha exibida no
# topo (negativo quando rolado na horizontal) + coluna * largura do caractere.
proc qc::drawRulers {ed} {
    variable cfg
    set i 0
    if {$cfg(rulerson) && [set d [$ed dlineinfo @0,0]] ne ""} {
        set x0 [lindex $d 0]
        set cw [font measure QcMono 0]
        set left [expr {[$ed cget -padx] + [$ed cget -bd]}]
        set wd [winfo width $ed]
        foreach c $cfg(rulers) {
            if {![string is integer -strict $c] || $c < 1} {continue}
            set x [expr {$x0 + $c * $cw}]
            if {$x < $left || $x >= $wd} {continue}
            set l $ed.rl$i
            if {![winfo exists $l]} {
                frame $l -width 1 -bd 0 -highlightthickness 0 -cursor xterm \
                    -background $::qc::C(ruler)
                bindtags $l [list $l QcRuler QcPretty]
            }
            place $l -x $x -y 0 -width 1 -relheight 1
            # abaixo dos símbolos, cursores extras e marcadores de bloco
            lower $l
            incr i
        }
    }
    while {[winfo exists $ed.rl$i]} {
        place forget $ed.rl$i
        incr i
    }
}

# --- guias de indentação (cfg(indentguides)) ------------------------------
# Uma linha vertical em cada nível de indentação (colunas 0, n, 2n... com n =
# "indent" da linguagem) nas linhas indentadas além dele. Linhas em branco
# valem como a menor indentação entre a linha não vazia anterior e a
# seguinte, para a guia não se partir no meio do bloco. Trechos seguidos do
# mesmo nível viram um só frame.
proc qc::lineIndent {s tw} {
    if {[string is space $s]} {return -1}
    set lead [string range $s 0 [expr {[string length $s] \
        - [string length [string trimleft $s " \t"]] - 1}]]
    if {[string first \t $lead] < 0} {return [string length $lead]}
    set ind 0
    foreach c [split $lead ""] {
        set ind [expr {$c eq "\t" ? ($ind / $tw + 1) * $tw : $ind + 1}]
    }
    return $ind
}

proc qc::drawIndentGuides {ed} {
    variable cfg
    set n 0
    if {$cfg(indentguides)} {
        set id [expr {[info exists ::qc::TB($ed,lang)] ? $::qc::TB($ed,lang) : ""}]
        # na abertura o editor pode ser desenhado antes de ter linguagem
        if {[catch {lget indent $id} tw] || ![string is integer -strict $tw] || $tw < 1} {
            set tw 4
        }
        # linhas visíveis: {indentação yTopo yBase}
        set rows {}
        set x0 ""
        set bot [$ed index "@0,[winfo height $ed]"]
        set i [$ed index "@0,0 linestart"]
        while {[$ed compare $i <= $bot]} {
            set e [foldEndAt $ed $i]
            if {$e ne "" && [$ed compare $e > $i]} {
                set i [$ed index "$e linestart"]
                if {[$ed compare $e != "$e linestart"]} {set i [$ed index "$i +1 line"]}
                continue
            }
            set d [$ed dlineinfo $i]
            if {$d eq "" && ![llength $rows]} {set d [$ed dlineinfo @0,0]}
            if {$d ne ""} {
                if {$x0 eq ""} {set x0 [lindex $d 0]}
                set y [lindex $d 1]
                set dl [$ed dlineinfo "$i lineend"]
                if {$dl eq ""} {set dl $d}
                set yb [expr {[lindex $dl 1] + [lindex $dl 3]}]
                set lastN [lindex [split $i .] 0]
                lappend rows [list [lineIndent [$ed get $i "$i lineend"] $tw] $y $yb $lastN]
            }
            set nx [$ed index "$i +1 line"]
            if {[$ed compare $nx == $i] || [$ed compare $nx >= end]} {break}
            set i $nx
        }
        if {[llength $rows] && $x0 ne ""} {
            # linhas em branco: menor indentação entre a anterior e a seguinte
            # (procurando fora da área visível, até 200 linhas)
            set first [lindex [split [$ed index "@0,0 linestart"] .] 0]
            set last [lindex [split [$ed index "end-1c"] .] 0]
            set prev 0
            for {set k [expr {$first - 1}]} {$k >= max(1, $first - 200)} {incr k -1} {
                set v [lineIndent [$ed get $k.0 "$k.0 lineend"] $tw]
                if {$v >= 0} {set prev $v; break}
            }
            set lastVis [expr {$lastN + 1}]
            set next 0
            for {set k $lastVis} {$k <= min($last, $lastVis + 200)} {incr k} {
                set v [lineIndent [$ed get $k.0 "$k.0 lineend"] $tw]
                if {$v >= 0} {set next $v; break}
            }
            set nr [llength $rows]
            set after [lrepeat $nr $next]
            for {set k [expr {$nr - 1}]} {$k >= 0} {incr k -1} {
                lset after $k $next
                set v [lindex $rows $k 0]
                if {$v >= 0} {set next $v}
            }
            set ind {}
            set maxi 0
            set k 0
            foreach r $rows {
                set v [lindex $r 0]
                if {$v < 0} {
                    set v [expr {min($prev, [lindex $after $k])}]
                } else {
                    set prev $v
                }
                lappend ind $v
                set maxi [expr {max($maxi, $v)}]
                incr k
            }
            lassign [activeIndentGuide $ed $tw $last] ac ba bb
            set cw [font measure QcMono 0]
            set left [expr {[$ed cget -padx] + [$ed cget -bd]}]
            set wd [winfo width $ed]
            for {set c 0} {$c < $maxi} {incr c $tw} {
                set x [expr {$x0 + $c * $cw}]
                if {$x < $left} {continue}
                if {$x >= $wd} {break}
                set y0 ""
                foreach r [concat $rows {{}}] v [concat $ind -1] {
                    if {$v > $c} {
                        if {$y0 eq ""} {
                            set y0 [lindex $r 1]
                            set la [lindex $r 3]
                        }
                        set y1 [lindex $r 2]
                        set lb [lindex $r 3]
                        continue
                    }
                    if {$y0 ne ""} {
                        set act [expr {$c == $ac && $la <= $bb && $lb >= $ba}]
                        indentGuide $ed $n $x $y0 $y1 $act
                        incr n
                        set y0 ""
                    }
                }
            }
        }
    }
    while {[winfo exists $ed.ig$n]} {
        place forget $ed.ig$n
        incr n
    }
}

# Guia do bloco onde está o cursor: {coluna primeira última}, com as linhas
# do corpo do bloco inteiro (também fora da área visível, para a guia
# continuar acesa ao rolar). Na linha que abre um bloco (a seguinte é mais
# indentada) é a guia do corpo dele; nas outras, a do nível mais interno
# que passa pela linha. Coluna -1: nenhuma.
proc qc::activeIndentGuide {ed tw last} {
    lassign [activeIndentCol $ed $tw $last] ac head cl
    if {$ac < 0} {return {-1 0 0}}
    # linhas não vazias com indentação <= ac delimitam o bloco
    set sp [expr {min($ac, 255)}]
    set nt [expr {min($ac / $tw, 255)}]
    set pat "^(?:\[ \]{0,$sp}|\t{0,$nt})\\S"
    if {$head} {
        set a [expr {$cl + 1}]
    } else {
        set h [$ed search -backwards -regexp -- $pat $cl.0 1.0]
        set a [expr {$h eq "" ? 1 : [lindex [split $h .] 0] + 1}]
    }
    set b $last
    if {$cl < $last} {
        set e [$ed search -regexp -- $pat [expr {$cl + 1}].0 end]
        if {$e ne "" && [$ed compare $e > $cl.0]} {set b [expr {[lindex [split $e .] 0] - 1}]}
    }
    return [list $ac $a $b]
}

# {coluna éCabeçalho linhaDoCursor} da guia ativa (coluna -1: nenhuma).
proc qc::activeIndentCol {ed tw last} {
    set cl [lindex [split [$ed index insert] .] 0]
    set ci [lineIndent [$ed get $cl.0 "$cl.0 lineend"] $tw]
    set ni -1
    set nl $cl
    for {set k [expr {$cl + 1}]} {$k <= min($last, $cl + 200)} {incr k} {
        set v [lineIndent [$ed get $k.0 "$k.0 lineend"] $tw]
        if {$v >= 0} {
            set ni $v
            set nl $k
            break
        }
    }
    if {$ci < 0} {
        # linha em branco: vale a menor entre a anterior e a seguinte
        set pi 0
        for {set k [expr {$cl - 1}]} {$k >= max(1, $cl - 200)} {incr k -1} {
            set v [lineIndent [$ed get $k.0 "$k.0 lineend"] $tw]
            if {$v >= 0} {set pi $v; break}
        }
        set ci [expr {min($pi, max($ni, 0))}]
    } elseif {$ni > $ci} {
        return [list [expr {$ci / $tw * $tw}] 1 $cl]
    }
    if {$ci <= 0} {return [list -1 0 $cl]}
    return [list [expr {($ci - 1) / $tw * $tw}] 0 $cl]
}

proc qc::indentGuide {ed n x y0 y1 {act 0}} {
    set l $ed.ig$n
    if {![winfo exists $l]} {
        frame $l -width 1 -bd 0 -highlightthickness 0 -cursor xterm
        bindtags $l [list $l QcRuler QcPretty]
    }
    $l configure -background $::qc::C([expr {$act ? "indguideact" : "indguide"}])
    place $l -x $x -y $y0 -width 1 -height [expr {max(1, $y1 - $y0)}]
    lower $l
}

# clique sobre a guia: cursor no ponto do editor logo abaixo
bind QcRuler <1> {
    set ed [winfo parent %W]
    $ed mark set insert @[expr {[winfo x %W] + %x}],[expr {[winfo y %W] + %y}]
    $ed tag remove sel 1.0 end
    focus $ed
    break
}

proc qc::applyRulers {} {
    foreach w $::qc::tabs {
        if {![winfo exists $w] || ![edVisible $w]} {continue}
        if {$w eq $::qc::ed} {schedGutter} else {otherGutter $w}
    }
}

proc qc::rulersDialog {} {
    set w .rulercfg
    if {[winfo exists $w]} {raise $w; focus $w.f.e; return}
    toplevel $w -background $::qc::C(ui)
    wm title $w "Guias de coluna"
    wm transient $w .
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text "Colunas (separadas por espaço; vazio = nenhuma):"
    ttk::entry $w.f.e -width 30 -textvariable ::qc::rulerTmp
    ttk::label $w.f.h -style Status.TLabel -text "ex.: 80 120"
    ttk::frame $w.f.b
    ttk::button $w.f.b.ok -text OK -command qc::rulersDialogApply
    ttk::button $w.f.b.no -text Cancelar -command [list destroy $w]
    pack $w.f.b.no $w.f.b.ok -side right -padx {6 0}
    pack $w.f -fill both -expand 1
    pack $w.f.l -anchor w
    pack $w.f.e -fill x -pady 4
    pack $w.f.h -anchor w
    pack $w.f.b -fill x -pady {8 0}
    bind $w <Return> qc::rulersDialogApply
    bind $w <Escape> [list destroy $w]
    set ::qc::rulerTmp $::qc::cfg(rulers)
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    focus $w.f.e
    $w.f.e selection range 0 end
}

proc qc::rulersDialogApply {} {
    variable cfg
    set cols {}
    foreach c [regexp -all -inline {[^\s,;]+} $::qc::rulerTmp] {
        if {![string is integer -strict $c] || $c < 1} {
            set ::qc::status "Coluna inválida: $c"
            bell
            return
        }
        lappend cols [expr {$c}]
    }
    destroy .rulercfg
    set cfg(rulers) [lsort -integer -unique $cols]
    if {[llength $cfg(rulers)]} {set cfg(rulerson) 1}
    applyRulers
}

proc qc::gutterClick {x y} {
    variable ed
    set i [$ed index "@0,$y linestart"]
    # coluna dos marcadores: recolhe/expande o bloco
    set g [winfo parent $ed].gut
    if {$x >= [winfo width $g] - 20} {
        set n [lindex [split $i .] 0]
        if {[dict exists [foldedHeads] $n] || ([info exists ::qc::TB($ed,folds)]
                && [dict exists $::qc::TB($ed,folds) $n])} {
            foldToggle $n
            focus $ed
            return
        }
    }
    $ed mark set insert $i
    $ed tag remove sel 1.0 end
    $ed tag add sel $i "$i +1 line"
    focus $ed
}

# --- recolher/expandir blocos --------------------------------------------
# Os blocos vêm da indentação: uma linha seguida de linhas mais indentadas
# (as em branco não contam) abre um bloco que vai até a última delas. Em
# Markdown, cada título também abre um, até o próximo de nível igual ou
# maior. TB(<editor>,folds) = dict linha do cabeçalho -> última linha.
# Um bloco recolhido é uma tag "fold:N" (-elide 1) do começo da linha
# seguinte ao cabeçalho ao começo da linha seguinte à última: o cabeçalho
# continua visível (com "⋯" no fim). Cada bloco tem a sua tag, então os
# internos continuam recolhidos quando o externo é expandido.

proc qc::computeFolds {txt} {
    variable ed
    set tw [lget indent]
    if {![string is integer -strict $tw] || $tw < 1} {set tw 4}
    set md [expr {$::qc::lang eq "markdown"}]
    set folds [dict create]
    set stack {} ;# {linha indentação} dos cabeçalhos abertos
    set heads {} ;# Markdown: {linha nível} dos títulos abertos
    set fence 0
    set last 0 ;# última linha não vazia
    set n 0
    foreach ln [split $txt \n] {
        incr n
        if {$md} {
            if {[regexp {^ {0,3}(```|~~~)} $ln]} {
                set fence [expr {!$fence}]
            } elseif {!$fence && [regexp {^ {0,3}(#{1,6})(?:[ \t]|$)} $ln -> h]} {
                set lv [string length $h]
                while {[llength $heads] && [lindex $heads end 1] >= $lv} {
                    set s [lindex $heads end 0]
                    if {$last > $s} {dict set folds $s $last}
                    set heads [lrange $heads 0 end-1]
                }
                lappend heads [list $n $lv]
            }
        }
        if {[string is space $ln]} {continue}
        set lead [string range $ln 0 [expr {[string length $ln] \
            - [string length [string trimleft $ln " \t"]] - 1}]]
        if {[string first \t $lead] < 0} {
            set ind [string length $lead]
        } else {
            set ind 0
            foreach c [split $lead ""] {
                set ind [expr {$c eq "\t" ? ($ind / $tw + 1) * $tw : $ind + 1}]
            }
        }
        while {[llength $stack] && [lindex $stack end 1] >= $ind} {
            set s [lindex $stack end 0]
            if {$last > $s && ![dict exists $folds $s]} {dict set folds $s $last}
            set stack [lrange $stack 0 end-1]
        }
        lappend stack [list $n $ind]
        set last $n
    }
    foreach e [concat $stack $heads] {
        set s [lindex $e 0]
        if {$last > $s && ![dict exists $folds $s]} {dict set folds $s $last}
    }
    set ::qc::TB($ed,folds) $folds
    # blocos recolhidos que a edição desmanchou (não começam/terminam mais
    # num começo de linha) voltam a aparecer
    foreach t [foldTags] {
        set r [::qc::_edw tag ranges $t]
        lassign $r a b
        if {[llength $r] != 2 || ![string match *.0 $a] || [::qc::_edw compare $a < 2.0]
            || (![string match *.0 $b] && [::qc::_edw compare $b < end-1c])} {
            ::qc::_edw tag delete $t
        }
    }
}

proc qc::foldTags {{w ::qc::_edw}} {
    lsearch -all -inline -glob [$w tag names] fold:*
}

# Cabeçalhos recolhidos: dict linha -> tags
proc qc::foldedHeads {{w ::qc::_edw}} {
    set d [dict create]
    foreach t [foldTags $w] {
        foreach {a b} [$w tag ranges $t] {
            dict lappend d [expr {[lindex [split $a .] 0] - 1}] $t
        }
    }
    return $d
}

# Fim (exclusive) do trecho recolhido que contém idx ("" se nenhum).
proc qc::foldEndAt {w idx} {
    set end ""
    foreach t [$w tag names $idx] {
        if {![string match fold:* $t]} {continue}
        set b [lindex [$w tag prevrange $t "$idx +1c"] 1]
        if {$b ne "" && ($end eq "" || [$w compare $b > $end])} {set end $b}
    }
    return $end
}

proc qc::foldLine {n} {
    variable ed
    if {![info exists ::qc::TB($ed,folds)] || ![dict exists $::qc::TB($ed,folds) $n]} {return 0}
    if {[dict exists [foldedHeads] $n]} {return 0}
    set e [dict get $::qc::TB($ed,folds) $n]
    set t fold:[incr ::qc::foldSeq]
    ::qc::_edw tag configure $t -elide 1
    ::qc::_edw tag add $t [expr {$n + 1}].0 [expr {$e + 1}].0
    return 1
}

proc qc::unfoldLine {n} {
    set d [foldedHeads]
    if {![dict exists $d $n]} {return 0}
    foreach t [dict get $d $n] {::qc::_edw tag delete $t}
    return 1
}

# Cursor escondido num bloco recolhido: vai para o fim do cabeçalho.
proc qc::foldFixCaret {} {
    variable ed
    while {[set e [foldEndAt ::qc::_edw insert]] ne ""} {
        set a ""
        foreach t [::qc::_edw tag names insert] {
            if {![string match fold:* $t]} {continue}
            set s [lindex [::qc::_edw tag prevrange $t "insert +1c"] 0]
            if {$a eq "" || [::qc::_edw compare $s < $a]} {set a $s}
        }
        $ed mark set insert "$a -1c"
    }
}

proc qc::foldToggle {n} {
    if {![unfoldLine $n] && [foldLine $n]} {foldFixCaret}
    schedGutter
}

# Ctrl+Shift+[: recolhe o bloco mais interno que contém o cursor.
proc qc::foldCursor {} {
    variable ed
    set c [lindex [split [$ed index insert] .] 0]
    if {![info exists ::qc::TB($ed,folds)]} {return}
    set done [foldedHeads]
    set best 0
    dict for {s e} $::qc::TB($ed,folds) {
        if {$s <= $c && $c <= $e && $s > $best && ![dict exists $done $s]} {set best $s}
    }
    if {$best && [foldLine $best]} {
        foldFixCaret
        $ed see insert
        schedGutter
    }
}

# Ctrl+Shift+]: expande o bloco recolhido na linha do cursor.
proc qc::unfoldCursor {} {
    variable ed
    if {[unfoldLine [lindex [split [$ed index insert] .] 0]]} {schedGutter}
}

proc qc::foldAll {} {
    variable ed
    if {![info exists ::qc::TB($ed,folds)]} {return}
    foreach s [dict keys $::qc::TB($ed,folds)] {foldLine $s}
    foldFixCaret
    $ed see insert
    schedGutter
}

proc qc::unfoldAll {} {
    foreach t [foldTags] {::qc::_edw tag delete $t}
    schedGutter
}

# Expande os blocos recolhidos que escondem idx (ex.: o cursor foi para
# dentro de um com Ir para linha ou Localizar).
proc qc::foldReveal {{idx insert}} {
    set hit 0
    foreach t [::qc::_edw tag names $idx] {
        if {[string match fold:* $t]} {
            ::qc::_edw tag delete $t
            set hit 1
        }
    }
    if {$hit} {schedGutter}
    return $hit
}

# Clique no "⋯" de um bloco recolhido: expande.
proc qc::foldMarkClick {l} {
    if {![info exists ::qc::fdLine($l)]} {return}
    set e [winfo parent $l]
    activateTab $e
    unfoldLine $::qc::fdLine($l)
    schedGutter
}

bind QcFoldMark <1> {qc::foldMarkClick %W; break}

# Mouse sobre a margem: mostra os marcadores dos blocos que podem ser
# recolhidos (os recolhidos aparecem sempre).
proc qc::gutHover {g on} {
    set ::qc::gutHover($g) $on
    set e [hostEd [winfo parent $g]]
    if {$e eq $::qc::ed} {schedGutter} elseif {$e ne "" && [winfo exists $e]} {otherGutter $e}
}

proc qc::onChange {} {
    ::qc::_edw tag remove errline 1.0 end
    ::qc::_edw tag remove warnline 1.0 end
    schedHighlight
    mdSched
    schedGutter
    onCursor
}

proc qc::onCursor {} {
    variable curPending
    if {!$curPending} {
        set curPending 1
        after idle {qc::updateCursor}
    }
}

proc qc::updateCursor {} {
    variable ed
    variable curPending 0
    # cursor dentro de um bloco recolhido (Ir para linha, Localizar…): expande
    if {[foldReveal]} {$ed see insert}
    lassign [split [$ed index insert] .] l c
    set ::qc::lncol "Ln $l, Col [expr {$c + 1}]"
    ::qc::_edw tag remove curline 1.0 end
    ::qc::_edw tag add curline "insert linestart" "insert lineend +1c"
    matchBrackets
    prettyCursor
    schedGutter
    drawCarets
}

# --- símbolos no lugar de palavras (chave "pretty" da linguagem) -----------
# A palavra continua no texto: o 1º caractere fica sob um label com o símbolo
# e o resto recebe a tag pel (oculta). A palavra sob o cursor aparece como é,
# para poder ser editada.
proc qc::prettyCursor {} {
    variable ed
    variable TB
    if {[info exists TB($ed,praw)]} {
        set s $TB($ed,praw)
        unset TB($ed,praw)
        set r [::qc::_edw tag nextrange pword $s]
        if {$r ne "" && [::qc::_edw compare [lindex $r 0] == $s]} {
            ::qc::_edw tag add pel "$s +1c" [lindex $r 1]
        }
    }
    set r [::qc::_edw tag prevrange pword "insert +1c"]
    if {$r ne "" && [::qc::_edw compare insert <= [lindex $r 1]]} {
        ::qc::_edw tag remove pel {*}$r
        set TB($ed,praw) [lindex $r 0]
    }
}

proc qc::drawPretty {} {
    variable ed
    variable H
    variable C
    set i 0
    if {[info exists H(pretty)] && [dict size $H(pretty)]} {
        set p [::qc::_edw index @0,0]
        set bot [::qc::_edw index "@0,[winfo height $ed] lineend"]
        while {[set r [::qc::_edw tag nextrange pword $p $bot]] ne ""} {
            lassign $r s e
            set p $e
            if {"pel" ni [::qc::_edw tag names "$s +1c"]} {continue}
            set word [::qc::_edw get $s $e]
            set bb [::qc::_edw bbox $s]
            if {$bb eq "" || ![dict exists $H(pretty) $word]} {continue}
            lassign $bb x y w h
            # cores e fonte das tags do caractere (em ordem de prioridade)
            set fg $C(edfg)
            set bg $C(edbg)
            set font QcMono
            foreach t [::qc::_edw tag names $s] {
                if {$t eq "sel"} {
                    set bg $C(sel)
                    continue
                }
                set v [::qc::_edw tag cget $t -foreground]
                if {$v ne ""} {set fg $v}
                set v [::qc::_edw tag cget $t -background]
                if {$v ne ""} {set bg $v}
                set v [::qc::_edw tag cget $t -font]
                if {$v ne ""} {set font $v}
            }
            set l $ed.pl$i
            if {![winfo exists $l]} {
                label $l -padx 0 -pady 0 -bd 0 -highlightthickness 0 -cursor xterm
                bindtags $l [list $l QcPretty]
            }
            $l configure -text [dict get $H(pretty) $word] -foreground $fg \
                -background $bg -font $font
            set ::qc::plIdx($l) $s
            place $l -x $x -y $y -width $w -height $h -bordermode outside
            incr i
        }
    }
    while {[winfo exists $ed.pl$i]} {
        place forget $ed.pl$i
        incr i
    }
}

# Clique no símbolo: cursor no começo da palavra (que então aparece).
proc qc::prettyClick {l} {
    set ed [winfo parent $l]
    if {![info exists ::qc::plIdx($l)]} {return}
    $ed mark set insert $::qc::plIdx($l)
    $ed tag remove sel 1.0 end
    focus $ed
}

# a roda do mouse sobre o símbolo rola o editor
bind QcPretty <1> {qc::prettyClick %W}
foreach ev {MouseWheel Shift-MouseWheel} {
    bind QcPretty <$ev> [string map [list EV $ev] {
        event generate [winfo parent %W] <EV> -delta %D \
            -x [expr {[winfo x %W] + %x}] -y [expr {[winfo y %W] + %y}]
    }]
}
foreach ev {Button-4 Button-5 Shift-Button-4 Shift-Button-5} {
    catch {
        bind QcPretty <$ev> [string map [list EV $ev] {
            event generate [winfo parent %W] <EV> \
                -x [expr {[winfo x %W] + %x}] -y [expr {[winfo y %W] + %y}]
        }]
    }
}

# Verdadeiro se a posição está dentro de string/comentário (pelo destaque).
proc qc::inLiteral {idx} {
    foreach t [::qc::_edw tag names $idx] {
        if {$t in {string comment directive}} {return 1}
    }
    return 0
}

proc qc::matchBrackets {} {
    variable ed
    ::qc::_edw tag remove bmatch 1.0 end
    ::qc::_edw tag remove bbad 1.0 end
    set pairs {\{ \} \[ \] ( )}
    set i ""
    foreach cand {"insert -1c" insert} {
        set ch [$ed get $cand]
        if {$ch in $pairs && [$ed compare $cand < end-1c]} {
            set i [$ed index $cand]
            break
        }
    }
    if {$i eq "" || [inLiteral $i]} {return}
    set k [lsearch -exact $pairs $ch]
    if {$k % 2 == 0} {
        set open $ch; set close [lindex $pairs $k+1]; set fwd 1
    } else {
        set open [lindex $pairs $k-1]; set close $ch; set fwd 0
    }
    set re "\[\\$open\\$close\]"
    set depth 1
    set pos $i
    for {set n 0} {$n < 20000} {incr n} {
        if {$fwd} {
            set pos [::qc::_edw search -forwards -regexp -- $re "$pos +1c" end]
        } else {
            set pos [::qc::_edw search -backwards -regexp -- $re $pos 1.0]
        }
        if {$pos eq ""} {break}
        if {[inLiteral $pos]} {continue}
        if {[$ed get $pos] eq $ch} {incr depth} else {incr depth -1}
        if {$depth == 0} {
            ::qc::_edw tag add bmatch $i "$i +1c" $pos "$pos +1c"
            return
        }
    }
    ::qc::_edw tag add bbad $i "$i +1c"
}

# Posição do "(" / "[" / "{" ainda aberto que envolve idx ("" se nenhum).
proc qc::enclosingOpen {idx} {
    set depth 0
    set pos [::qc::_edw index $idx]
    for {set n 0} {$n < 20000} {incr n} {
        set pos [::qc::_edw search -backwards -regexp -- {[][(){}]} $pos 1.0]
        if {$pos eq ""} {break}
        if {[inLiteral $pos]} {continue}
        if {[::qc::_edw get $pos] in {) \] \}}} {
            incr depth
        } elseif {$depth == 0} {
            return $pos
        } else {
            incr depth -1
        }
    }
    return ""
}

# ---------------------------------------------------------------------------
# Comandos de edição
# ---------------------------------------------------------------------------

# Executa várias alterações como um único passo de desfazer (aninhável).
proc qc::atomic {script} {
    variable atomicDepth
    set ed $::qc::ed
    if {[incr atomicDepth] == 1} {
        $ed edit separator
        $ed configure -autoseparators 0
    }
    try {
        uplevel 1 $script
    } finally {
        if {[incr atomicDepth -1] == 0} {
            $ed configure -autoseparators 1
            $ed edit separator
        }
    }
}

proc qc::editCmd {what} {
    catch {$::qc::ed edit $what}
    $::qc::ed see insert
}

proc qc::selectAll {w} {
    switch -- [winfo class $w] {
        Text {
            $w tag add sel 1.0 end-1c
            $w mark set insert end-1c
        }
        TEntry - Entry {
            $w selection range 0 end
            $w icursor end
        }
    }
}

proc qc::paste {w} {
    if {[catch {clipboard get} data]} {return}
    if {$w eq $::qc::ed && [llength $::qc::mcur] && !$::qc::mapplying} {
        multiApply [list qc::paste $w]
        return
    }
    atomic {
        catch {$w delete sel.first sel.last}
        $w insert insert $data
    }
    $w see insert
}

proc qc::selLines {} {
    variable ed
    if {[llength [$ed tag ranges sel]]} {
        set a [lindex [split [$ed index sel.first] .] 0]
        set z [$ed index sel.last]
        lassign [split $z .] zl zc
        if {$zc == 0 && $zl > $a} {incr zl -1}
        return [list $a $zl]
    }
    set l [lindex [split [$ed index insert] .] 0]
    return [list $l $l]
}

proc qc::indentStr {} {
    return [string repeat " " [lget indent]]
}

proc qc::indent {in} {
    variable ed
    set hasSel [llength [$ed tag ranges sel]]
    lassign [selLines] a z
    set ind [indentStr]
    set iw [lget indent]
    if {$in && (!$hasSel || $a == $z && [$ed get sel.first sel.last] ne [$ed get $a.0 "$a.0 lineend"])} {
        catch {$ed delete sel.first sel.last}
        $ed insert insert $ind
        $ed see insert
        return
    }
    atomic {
        for {set l $a} {$l <= $z} {incr l} {
            if {$in} {
                if {[$ed get $l.0 "$l.0 lineend"] ne ""} { $ed insert $l.0 $ind }
            } else {
                set lead [$ed get $l.0 $l.$iw]
                regexp "^( {1,$iw}|\t)?" $lead -> ws
                if {$ws ne ""} { $ed delete $l.0 "$l.0 +[string length $ws]c" }
            }
        }
    }
    if {$hasSel} {
        $ed tag remove sel 1.0 end
        $ed tag add sel $a.0 "$z.0 lineend +1c"
    }
}

# Enter com auto-indentação: hook newlineIndent da linguagem ou, por padrão,
# mais um nível quando a linha termina com algo que casa com indentAfter.
proc qc::newline {} {
    variable ed
    catch {$ed delete sel.first sel.last}
    # Enter no fim de um cabeçalho recolhido expande o bloco
    foldReveal "insert +1c"
    set h [hook newlineIndent]
    if {$h ne ""} {
        # o hook pode tratar o Enter sozinho (return -code break)
        if {[catch {$h} ind] == 3} {
            $ed see insert
            return
        }
        $ed insert insert "\n$ind"
        $ed see insert
        return
    }
    set before [$ed get "insert linestart" insert]
    regexp {^[ \t]*} $before ws
    set code $before
    if {[lget commentRe] ne ""} {set code [regsub -- [lget commentRe] $code ""]}
    set extra ""
    if {[regexp -- [lget indentAfter] $code]} {set extra [indentStr]}
    set open [string index [string trimright $code] end]
    set next [$ed get insert]
    if {$extra ne "" && "$open$next" in {\{\} () \[\]}} {
        $ed insert insert "\n$ws$extra"
        set m [$ed index insert]
        $ed insert insert "\n$ws"
        $ed mark set insert $m
    } else {
        $ed insert insert "\n$ws$extra"
    }
    $ed see insert
}

proc qc::closeChar {ch} {
    variable ed
    catch {$ed delete sel.first sel.last}
    set before [$ed get "insert linestart" insert]
    # linha só com espaços: desindenta um nível antes de fechar o bloco
    if {[string first $ch [lget dedentChars]] >= 0 && [regexp {^[ \t]+$} $before]} {
        set iw [lget indent]
        if {[string index $before end] eq "\t"} {
            set n 1
        } else {
            set n [expr {[string length $before] % $iw}]
            if {$n == 0} {set n $iw}
        }
        $ed delete "insert -${n}c" insert
    }
    $ed insert insert $ch
    $ed see insert
}

proc qc::duplicateLine {} {
    variable ed
    lassign [selLines] a z
    set chunk [$ed get $a.0 "$z.0 lineend"]
    $ed insert "$z.0 lineend" "\n$chunk"
    $ed mark set insert "insert +[expr {$z - $a + 1}] lines"
    $ed see insert
}

# Ctrl+Shift+↑/↓: move a linha atual (ou as da seleção) uma linha para
# cima/baixo, mantendo cursor e seleção; um único passo de desfazer.
proc qc::moveLines {d} {
    variable ed
    lassign [selLines] a z
    set last [lindex [split [$ed index end-1c] .] 0]
    if {($d < 0 && $a <= 1) || ($d > 0 && $z >= $last)} return
    set sel [$ed tag ranges sel]
    set ins [$ed index insert]
    atomic {
        if {$d < 0} {
            set o [expr {$a - 1}]
            set other [$ed get $o.0 "$o.0 lineend"]
            $ed delete $o.0 $a.0
            $ed insert "[expr {$z - 1}].0 lineend" "\n$other"
        } else {
            set o [expr {$z + 1}]
            set other [$ed get $o.0 "$o.0 lineend"]
            $ed delete "$z.0 lineend" "$o.0 lineend"
            $ed insert $a.0 "$other\n"
        }
    }
    set shift {{i d} {
        lassign [split $i .] l c
        return [expr {$l + $d}].$c
    }}
    $ed tag remove sel 1.0 end
    if {[llength $sel] == 2} {
        $ed tag add sel [apply $shift [lindex $sel 0] $d] [apply $shift [lindex $sel 1] $d]
    }
    $ed mark set insert [apply $shift $ins $d]
    $ed see insert
}

# ---------------------------------------------------------------------------
# Fechamento automático de pares
# ---------------------------------------------------------------------------

# Abre/fecha dos pares da linguagem corrente: {aberturas fechamentos}.
proc qc::pairLists {} {
    set o {}; set c {}
    foreach p [lget autoPairs] {
        lappend o [string index $p 0]
        lappend c [string index $p 1]
    }
    return [list $o $c]
}

# <KeyPress> do editor: trata os caracteres de pares; 1 = tratado.
proc qc::keyChar {ch state} {
    if {$state & 0x0C || [string length $ch] != 1} {return 0} ;# Ctrl / Alt
    lassign [pairLists] o c
    if {$ch ni $o && $ch ni $c && $ch ni {) ] \}}} {return 0}
    typeChar $ch
    return 1
}

# Digita um caractere no cursor, com a lógica de pares:
#  - abertura com seleção: envolve a seleção (que continua selecionada);
#  - abertura sem seleção: insere o par e deixa o cursor no meio, se o
#    próximo caractere for espaço, fim de linha ou fechamento;
#  - fechamento igual ao próximo caractere: só passa por cima dele.
proc qc::typeChar {ch} {
    variable ed
    lassign [pairLists] opens closes
    set hasSel [llength [::qc::_edw tag ranges sel]]
    set prev [expr {[$ed compare insert == 1.0] ? "" : [$ed get "insert -1c"]}]
    set next [$ed get insert]
    set k [lsearch -exact $opens $ch]
    if {$k >= 0} {
        set cl [lindex $closes $k]
        if {$hasSel} {
            set a [$ed index sel.first]
            set b [$ed index sel.last]
            atomic {
                $ed insert $b $cl
                $ed insert $a $ch
            }
            ::qc::_edw tag remove sel 1.0 end
            ::qc::_edw tag add sel "$a +1c" "$b +1c"
            $ed mark set insert "$b +1c"
            $ed see insert
            return
        }
        if {$ch eq $cl && $next eq $ch && $prev ne "\\"} {
            $ed mark set insert "insert +1c"
            return
        }
        set ok [expr {
            $next eq "" || [string is space $next] || $next in $closes
            || $next in {, ; : .}
        }]
        if {$ok && $ch eq $cl} {
            # aspas: não depois de letra/dígito (ex.: don't) nem de "\"
            set ok [expr {![regexp {[\w\\]} $prev] && $prev ne $ch}]
        }
        if {$ok} {
            $ed insert insert $ch$cl
            $ed mark set insert "insert -1c"
        } else {
            $ed insert insert $ch
        }
        $ed see insert
        return
    }
    if {!$hasSel && $next eq $ch && $ch in $closes} {
        $ed mark set insert "insert +1c"
        return
    }
    if {$ch in {) ] \}}} {
        closeChar $ch
        return
    }
    catch {$ed delete sel.first sel.last}
    $ed insert insert $ch
    $ed see insert
}

# Backspace: apaga a seleção, ou o caractere anterior; num par vazio
# ("(|)", "\"|\"") apaga os dois.
proc qc::backspace {} {
    variable ed
    if {[llength [::qc::_edw tag ranges sel]]} {
        $ed delete sel.first sel.last
    } elseif {[$ed compare insert > 1.0]} {
        foldReveal "insert -1c"
        if {[$ed get "insert -1c" "insert +1c"] in [lget autoPairs]} {
            $ed delete "insert -1c" "insert +1c"
        } else {
            $ed delete "insert -1c"
        }
    }
    $ed see insert
}

proc qc::deleteFwd {} {
    variable ed
    if {[llength [::qc::_edw tag ranges sel]]} {
        $ed delete sel.first sel.last
    } else {
        foldReveal "insert +1c"
        $ed delete insert
    }
}

# ---------------------------------------------------------------------------
# Autocompletar (Ctrl+Espaço, ou sozinho ao digitar 3 letras)
# ---------------------------------------------------------------------------
# Sugestões, nesta ordem: palavras do arquivo aberto, palavras-chave da
# linguagem e, com uma pasta aberta, palavras dos arquivos da pasta com as
# extensões da linguagem corrente. "Palavra" é o token "word" da linguagem.
# O índice da pasta é montado aos poucos em segundo plano (sem travar a
# interface), reaproveitando os arquivos que não mudaram (mtime), e é
# refeito ao abrir/recarregar a pasta e ao salvar.

namespace eval qc {
    variable AC ;# popup: on, start (índice do início da palavra)...
    array set AC {on 0 start "" items {} after "" buf {} kw {} proj {}}
    variable PX ;# PX(<arquivo>) = {mtime ext palavras}
    array set PX {}
    variable PW ;# PW(<ext>,<palavra>) = nº de arquivos com ela
    array set PW {}
    variable PL ;# PL(<ext>) = palavras de PW com essa extensão (cache)
    array set PL {}
    variable PS ;# varredura em andamento
    array set PS {root "" after "" dirs {} files {} seen {} n 0 done 0}
    variable acSkipDirs {node_modules target build dist out _build __pycache__ venv
        project/target}
    variable acMaxFiles 5000
    variable acMaxSize 1000000
}

proc qc::acWordRe {} {
    set tk [lget tokens]
    if {[dict exists $tk word]} {return [dict get $tk word]}
    return {[A-Za-z_][A-Za-z0-9_]*}
}

# Palavras distintas de um texto (3+ caracteres, com alguma letra, sem
# começar por dígito).
proc qc::acExtract {text {re ""}} {
    if {$re eq ""} {set re [acWordRe]}
    set n [expr {[lindex [regexp -about $re] 0] + 1}]
    set all [regexp -all -inline -- $re $text]
    set out {}
    for {set i 0} {$i < [llength $all]} {incr i $n} {
        set w [lindex $all $i]
        if {
            [string length $w] >= 3 && ![string is digit [string index $w 0]]
            && [regexp {[[:alpha:]]} $w]
        } {
            lappend out $w
        }
    }
    return [lsort -unique $out]
}

# Parte da palavra antes do cursor ("" se o cursor não está numa palavra).
proc qc::acPrefix {} {
    set before [$::qc::ed get "insert linestart" insert]
    if {[regexp -- "(?:[acWordRe])\$" $before m]} {return $m}
    return ""
}

# Junta as fontes de sugestão ao abrir o popup (o filtro reaproveita).
proc qc::acPool {} {
    variable AC
    variable ed
    variable H
    variable cfg
    variable PS
    set re [acWordRe]
    # o texto sem a palavra que está sendo digitada
    set text "[$ed get 1.0 $AC(start)]\n[$ed get insert end]"
    foreach w $::qc::tabs {
        if {$w ne $ed && $::qc::TB($w,lang) eq $::qc::lang} {
            append text \n [$w get 1.0 end-1c]
        }
    }
    set AC(buf) [acExtract $text $re]
    set AC(kw) [lsort [dict keys $H(words)]]
    set AC(proj) {}
    if {$cfg(folder) ne ""} {
        if {$PS(root) ne $cfg(folder)} {projIndexStart}
        foreach ext [lget ext] {lappend AC(proj) {*}[projWords $ext]}
    }
}

# Filtra pelo prefixo atual e mostra/atualiza o popup; 0 = nada a sugerir.
proc qc::acFilter {} {
    variable AC
    variable ed
    set p [acPrefix]
    if {[$ed index "insert -[string length $p]c"] ne $AC(start)} {
        acHide
        return 0
    }
    set g [string map {\\ \\\\ * \\* ? \\? [ \\[ ] \\]} $p]*
    set exact {}
    set rest {}
    foreach src {buf kw proj} {
        foreach w [lsearch -all -inline -glob -nocase $AC($src) $g] {
            if {$w eq $p || [info exists seen($w)]} {continue}
            set seen($w) 1
            if {[string match $g $w]} {lappend exact $w} else {lappend rest $w}
            if {[array size seen] >= 300} {break}
        }
    }
    set items [concat $exact $rest]
    if {![llength $items]} {
        acHide
        return 0
    }
    set AC(items) $items
    acPlace
    return 1
}

proc qc::acBuild {} {
    variable C
    set w .ac
    toplevel $w -background #555555 -bd 0
    wm withdraw $w
    wm overrideredirect $w 1
    catch {wm attributes $w -type popup_menu}
    listbox $w.l -font QcMono -background $C(gutbg) -foreground $C(edfg) \
        -selectbackground $C(sel) -selectforeground #ffffff -bd 0 \
        -highlightthickness 0 -activestyle none -exportselection 0 -takefocus 0
    pack $w.l -fill both -expand 1 -padx 1 -pady 1
    bind $w.l <ButtonPress-1> {qc::acAccept [%W nearest %y]; break}
    bind $w.l <MouseWheel> {%W yview scroll [expr {%D > 0 ? -3 : 3}] units; break}
    catch {bind $w.l <Button-4> {%W yview scroll -3 units; break}}
    catch {bind $w.l <Button-5> {%W yview scroll 3 units; break}}
}

proc qc::acPlace {} {
    variable AC
    variable ed
    set bb [$ed bbox $AC(start)]
    if {$bb eq ""} {set bb [$ed bbox insert]}
    if {$bb eq ""} {acHide; return}
    if {![winfo exists .ac]} {acBuild}
    set l .ac.l
    $l delete 0 end
    $l insert end {*}$AC(items)
    set wid 12
    foreach i $AC(items) {if {[string length $i] > $wid} {set wid [string length $i]}}
    $l configure -height [expr {min([llength $AC(items)], 10)}] -width [expr {min($wid + 1, 60)}]
    $l selection clear 0 end
    $l selection set 0
    $l activate 0
    $l see 0
    lassign $bb x y w h
    set rx [expr {[winfo rootx $ed] + $x - 3}]
    set ry [expr {[winfo rooty $ed] + $y + $h + 2}]
    update idletasks
    set ph [winfo reqheight .ac]
    set pw [winfo reqwidth .ac]
    if {$ry + $ph > [winfo vrootheight .]} {set ry [expr {$ry - $h - $ph - 4}]}
    if {$rx + $pw > [winfo vrootwidth .]} {set rx [expr {[winfo vrootwidth .] - $pw}]}
    wm geometry .ac +$rx+$ry
    if {!$AC(on)} {
        wm deiconify .ac
        raise .ac
        set AC(on) 1
    }
}

proc qc::acShow {manual} {
    variable AC
    variable ed
    if {[llength $::qc::mcur]} {return}
    set p [acPrefix]
    if {$p eq "" && !$manual} {return}
    set AC(start) [$ed index "insert -[string length $p]c"]
    acPool
    if {![acFilter] && $manual} {set ::qc::status "Nenhuma sugestão"}
}

proc qc::acHide {} {
    variable AC
    after cancel $AC(after)
    if {$AC(on)} {
        set AC(on) 0
        wm withdraw .ac
    }
}

proc qc::acMove {d} {
    set l .ac.l
    set n [$l size]
    set i [expr {[$l curselection] + $d}]
    if {abs($d) == 1} {
        set i [expr {($i + $n) % $n}] ;# setas dão a volta
    } else {
        set i [expr {max(0, min($n - 1, $i))}]
    }
    $l selection clear 0 end
    $l selection set $i
    $l activate $i
    $l see $i
}

proc qc::acAccept {{i ""}} {
    variable AC
    variable ed
    if {$i eq ""} {set i [.ac.l curselection]}
    set w [lindex $AC(items) $i]
    acHide
    focus $ed
    if {$w eq "" || [$ed compare insert < $AC(start)]} {return}
    atomic {
        $ed delete $AC(start) insert
        $ed insert insert $w
    }
    $ed see insert
}

# <KeyPress> do editor (bindtag QcComp, antes das demais).
proc qc::acKey {K A s} {
    variable AC
    if {$AC(on) && !($s & 0x0C)} {
        switch -- $K {
            Up {acMove -1; return -code break}
            Down {acMove 1; return -code break}
            Prior {acMove -9; return -code break}
            Next {acMove 9; return -code break}
            Return - KP_Enter - Tab {acAccept; return -code break}
            Escape {acHide; return -code break}
            Left - Right - Home - End {acHide}
        }
    } elseif {$AC(on) && ![regexp {_[LR]$} $K]} {
        acHide ;# Ctrl/Alt + tecla
    }
    # depois que a tecla for processada pelo editor: abre/atualiza o popup
    after cancel $AC(after)
    # tclint-disable-next-line command-args
    set AC(after) [after idle [list qc::acAfterKey $K $A $s]]
}

proc qc::acAfterKey {K A s} {
    variable AC
    variable cfg
    if {[llength $::qc::mcur]} {acHide; return}
    if {$s & 0x0C} {return}
    set typed [expr {$A ne "" && [string is print $A]}]
    if {$AC(on)} {
        if {$typed || $K in {BackSpace Delete}} {
            if {[acPrefix] eq ""} {acHide} else {acFilter}
        }
        return
    }
    if {!$cfg(autocomp) || !$typed} {return}
    set p [acPrefix]
    if {[string length $p] < 3 || [string index $p end] ne $A} {return}
    if {[inLiteral "insert -[string length $p]c"]} {return}
    acShow 0
}

# --- índice das palavras da pasta aberta -----------------------------------

proc qc::projIndexStart {} {
    variable PS
    variable cfg
    after cancel $PS(after)
    if {$cfg(folder) eq "" || ![file isdirectory $cfg(folder)]} {projIndexClear; return}
    if {$PS(root) ne $cfg(folder)} {projIndexClear}
    set PS(root) $cfg(folder)
    set PS(dirs) [list $cfg(folder)]
    set PS(files) {}
    set PS(seen) [dict create]
    set PS(n) 0
    set PS(done) 0
    set PS(after) [after 50 {qc::projIndexStep}]
}

proc qc::projIndexClear {} {
    variable PS
    variable PX
    variable PW
    variable PL
    after cancel $PS(after)
    array set PS {root "" dirs {} files {} seen {} n 0 done 0}
    array unset ::qc::DX
    array unset ::qc::DN
    array unset PX
    array unset PW
    array unset PL
}

# Um pedaço da varredura (~15 ms); reagenda a si mesmo até terminar.
proc qc::projIndexStep {} {
    variable PS
    variable PX
    variable acSkipDirs
    variable acMaxFiles
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 15} {
        if {[llength $PS(files)]} {
            set PS(files) [lassign $PS(files) f]
            dict set PS(seen) $f 1
            projIndexFile $f
        } elseif {[llength $PS(dirs)] && $PS(n) < $acMaxFiles} {
            set PS(dirs) [lassign $PS(dirs) d]
            foreach p [lsort [glob -nocomplain -directory $d -types d *]] {
                set rel [string range $p [string length $PS(root)]+1 end]
                if {[file tail $p] ni $acSkipDirs && $rel ni $acSkipDirs} {
                    lappend PS(dirs) $p
                }
            }
            foreach p [glob -nocomplain -directory $d -types f *] {
                if {$PS(n) >= $acMaxFiles} {break}
                if {[langForFileAny $p] ne ""} {
                    lappend PS(files) $p
                    incr PS(n)
                }
            }
        } else {
            # fim: esquece os arquivos que sumiram
            foreach f [array names PX] {
                if {![dict exists $PS(seen) $f]} {projForget $f}
            }
            set PS(seen) {}
            set PS(done) 1
            return
        }
    }
    set PS(after) [after 5 {qc::projIndexStep}]
}

proc qc::projIndexFile {f} {
    variable PX
    variable PW
    variable PL
    variable acMaxSize
    if {[catch {file mtime $f} mt] || [catch {file size $f} sz] || $sz > $acMaxSize} {
        projForget $f
        return
    }
    if {[info exists PX($f)] && [lindex $PX($f) 0] == $mt} {return}
    set id [langForFileAny $f]
    if {$id eq "" || [catch {readFile $f} data]} {projForget $f; return}
    set id [langForFile $f $data]
    projForget $f
    set ext [string tolower [file extension $f]]
    set tk [lget tokens $id]
    set re [expr {[dict exists $tk word] ? [dict get $tk word] : {[A-Za-z_][A-Za-z0-9_]*}}]
    set words [acExtract $data $re]
    set PX($f) [list $mt $ext $words]
    defIndexFile $f $id $data
    foreach w $words {incr PW($ext,$w)}
    unset -nocomplain PL($ext)
}

proc qc::projForget {f} {
    variable PX
    variable PW
    variable PL
    if {![info exists PX($f)]} {return}
    lassign $PX($f) - ext words
    foreach w $words {
        if {[incr PW($ext,$w) -1] <= 0} {unset PW($ext,$w)}
    }
    unset PX($f)
    defForget $f
    unset -nocomplain PL($ext)
}

proc qc::projWords {ext} {
    variable PW
    variable PL
    if {![info exists PL($ext)]} {
        set n [string length $ext]
        set PL($ext) [lsort [lmap k [array names PW $ext,*] {string range $k $n+1 end}]]
    }
    return $PL($ext)
}

# ---------------------------------------------------------------------------
# Ir para definição (F12) e dica ao passar o mouse
# ---------------------------------------------------------------------------
# Definições: palavras de defWords seguidas de um nome (ex.: "proc nome",
# "let rec nome", "(define (nome") e as regexes de defPatterns. Os arquivos
# da pasta entram no índice junto com a varredura do autocompletar
# (DX(<arquivo>) = definições, DN(<nome>) = arquivos que o definem); as abas
# abertas são lidas na hora, porque podem ter alterações não salvas.
# Cada definição: {nome linha coluna textoDaLinha comentáriosAcima}.

namespace eval qc {
    variable DX
    variable DN
    variable DR ;# DR(<lang>) = regexes de definição compiladas
    array set DX {}
    array set DN {}
    array set DR {}
    variable navStack {} ;# posições para o Alt+←
    variable tipAfter ""
    variable tipKey ""
    variable linkKey "" ;# palavra sublinhada com Ctrl: {palavra início}
}

proc qc::defRegexes {id} {
    variable DR
    if {[info exists DR($id)]} {return $DR($id)}
    set tk [lget tokens $id]
    set wre [expr {[dict exists $tk word] ? [dict get $tk word] : {[A-Za-z_][A-Za-z0-9_]*}}]
    set res {}
    set dw [lget defWords $id]
    if {[llength $dw]} {
        set alt [join [lmap w $dw {reQuote $w}] |]
        set custom [lget defWordsRe $id]
        if {$custom ne ""} {
            lappend res [string map [list %W $alt %N $wre] $custom]
        } else {
            # "let rec x", "module type S", "type 'a t", "(define (f"
            lappend res "(?:^|\[^\\w-\])(?:$alt)(?:\[ \\t\]+(?:$alt))*\\s+(?:'\\w+\[ \\t\]+)?\\(?($wre)"
        }
    }
    lappend res {*}[lget defPatterns $id]
    set out {}
    foreach re $res {
        if {[catch {regexp -about $re} ab] || [lindex $ab 0] < 1} {continue}
        lappend out $re [expr {[lindex $ab 0] + 1}]
    }
    # palavras-chave não são nomes de definição (builtins podem ser)
    set kw {}
    set wd [lget words $id]
    if {[dict exists $wd keyword]} {
        foreach w [dict get $wd keyword] {dict set kw $w 1}
    }
    set p [regsub {(.)\1+$} [lget comment $id] {\1}]
    set DR($id) [list $out $kw $p [lget commentEnd $id]]
    return $DR($id)
}

# Nome usado no índice: sem o qualificador (::ns::proc -> proc).
proc qc::defKey {name} {
    return [regsub {^.*::} $name {}]
}

# Lista de definições de um texto: {nome linha coluna assinatura comentários
# docstring qualificado}. Com qual=1 (índice de biblioteca) o hook defQual da
# linguagem dá o nome completo; "" descarta a definição (ex.: interna).
proc qc::defsIn {text id {qual 0}} {
    lassign [defRegexes $id] res kw cpre cend
    if {![llength $res]} {return {}}
    set qh [expr {$qual ? [hook defQual $id] : ""}]
    set dstr [lget docString $id]
    set lines [split $text \n]
    set starts {}
    set o 0
    foreach ln $lines {
        lappend starts $o
        incr o [expr {[string length $ln] + 1}]
    }
    set out {}
    set seen {}
    foreach {re step} $res {
        set m [regexp -all -inline -indices -line -- $re $text]
        for {set i 0} {$i < [llength $m]} {incr i $step} {
            lassign [lindex $m $i+1] a z
            if {$a < 0} {continue}
            set raw [string range $text $a $z]
            set key [defKey $raw]
            if {$key eq "" || [dict exists $kw $key] || [dict exists $seen $a]} {continue}
            dict set seen $a 1
            set L [lsearch -bisect -integer $starts $a]
            set col [expr {$a - [lindex $starts $L]}]
            set q ""
            if {$qual} {
                set q [expr {$qh ne "" ? [$qh $lines $L $raw] : $key}]
                if {$q eq ""} {continue}
            }
            lassign [defSig $lines $L $col] sig E
            set post [expr {$dstr ? [defDocString $lines $E] : {}}]
            lappend out [list $key [expr {$L + 1}] $col $sig \
                [defDoc $lines $L $cpre $cend] $post $q]
        }
    }
    return $out
}

# Assinatura: a linha da definição e, se os parênteses abertos a partir do
# nome continuarem abertos, as seguintes (até 8). Devolve {texto últimaLinha}.
proc qc::defSig {lines L col} {
    set line [lindex $lines $L]
    if {$col > 0 && [string index $line $col-1] eq "("} {incr col -1}
    set rest [string range $line $col end]
    set depth [expr {[regexp -all {\(} $rest] - [regexp -all {\)} $rest]}]
    set sig [list [string trim $line]]
    set E $L
    while {$depth > 0 && $E + 1 < [llength $lines]} {
        incr E
        set ln [lindex $lines $E]
        if {$E < $L + 8} {lappend sig "  [string trim $ln]"}
        incr depth [expr {[regexp -all {\(} $ln] - [regexp -all {\)} $ln]}]
        if {$E >= $L + 30} {break}
    }
    if {$E >= $L + 8} {lappend sig "  …"}
    return [list [join $sig \n] $E]
}

# Docstring (Scheme): string que começa na linha seguinte à assinatura.
proc qc::defDocString {lines E} {
    set t [string trim [lindex $lines [incr E]]]
    if {[string index $t 0] ne "\""} {return {}}
    set out {}
    set t [string range $t 1 end]
    while {[llength $out] < 12} {
        if {[regexp {^((?:[^"\\]|\\.)*)"} $t -> body]} {
            lappend out [string trim $body]
            break
        }
        lappend out [string trim $t]
        if {[incr E] >= [llength $lines]} {break}
        set t [lindex $lines $E]
    }
    return [lmap l $out {string map {\\" \" \\\\ \\} $l}]
}

# Comentários logo acima da linha L (índice 0; pode haver uma linha em
# branco entre eles): linhas com o prefixo de comentário ou um bloco
# terminado em */ ou commentEnd. Linhas só com o prefixo no começo e no fim
# do bloco são descartadas.
proc qc::defDoc {lines L cpre cend} {
    set doc {}
    set k [expr {$L - 1}]
    set t [string trim [lindex $lines $k]]
    # aceita uma linha em branco entre o comentário e a definição
    if {$t eq "" && $k > 0} {
        set t [string trim [lindex $lines [incr k -1]]]
    }
    set ends [list */]
    if {$cend ne ""} {lappend ends $cend}
    set block 0
    foreach e $ends {
        if {$t ne "" && [string match "*$e" $t]} {set block 1}
    }
    while {$k >= 0 && [llength $doc] < 60} {
        set t [string trim [lindex $lines $k]]
        if {$block} {
            set doc [linsert $doc 0 $t]
            if {[string match "/\\**" $t] || ($cend ne "" && [string first $cpre $t] == 0)} {break}
        } elseif {$cpre ne "" && [string first $cpre $t] == 0} {
            set doc [linsert $doc 0 $t]
        } else {
            break
        }
        incr k -1
    }
    if {$block || ![llength $doc]} {return [lrange $doc 0 9]}
    # parágrafos separados por linhas só com o prefixo; sem os de copyright
    # e licença
    set pr [regsub {(.)\1+$} $cpre {\1}]
    set paras {}
    set cur {}
    foreach t $doc {
        if {[string trim $t "$pr "] eq ""} {
            if {[llength $cur]} {lappend paras $cur; set cur {}}
        } else {
            lappend cur $t
        }
    }
    if {[llength $cur]} {lappend paras $cur}
    set out {}
    foreach p $paras {
        if {[regexp -nocase {copyright|license|warrant|\$Id|RCS:} [join $p]]} {continue}
        if {[llength $out]} {lappend out $pr}
        lappend out {*}$p
    }
    set out [lrange $out 0 9]
    while {[llength $out] && [lindex $out end] eq $pr} {set out [lrange $out 0 end-1]}
    return $out
}

proc qc::defIndexFile {f id data} {
    variable DX
    variable DN
    defForget $f
    set defs [defsIn $data $id]
    if {![llength $defs]} {return}
    set DX($f) $defs
    foreach d $defs {dict set DN([lindex $d 0]) $f 1}
}

proc qc::defForget {f} {
    variable DX
    variable DN
    if {![info exists DX($f)]} {return}
    foreach d $DX($f) {
        set k [lindex $d 0]
        if {[info exists DN($k)]} {
            dict unset DN($k) $f
            if {![dict size $DN($k)]} {unset DN($k)}
        }
    }
    unset DX($f)
}

# Definições de name: aba ativa, outras abas da mesma linguagem e arquivos
# da pasta. Cada item: {arquivo editor nome linha coluna texto doc}
# (editor = "" para arquivo que não está aberto).
proc qc::findDefs {name} {
    variable DX
    variable DN
    variable PS
    variable cfg
    variable TB
    set id $::qc::lang
    set key [defKey $name]
    set out {}
    set open {}
    set ws [list $::qc::ed]
    foreach w $::qc::tabs {if {$w ne $::qc::ed} {lappend ws $w}}
    foreach w $ws {
        if {$TB($w,file) ne ""} {dict set open $TB($w,file) 1}
        if {$TB($w,lang) ne $id} {continue}
        foreach d [defsIn [$w get 1.0 end-1c] $id] {
            if {[lindex $d 0] eq $key} {lappend out [list $TB($w,file) $w {*}$d]}
        }
    }
    if {$cfg(folder) ne "" && $PS(root) ne $cfg(folder)} {projIndexStart}
    if {[info exists DN($key)]} {
        set exts [lget ext]
        foreach f [lsort [dict keys $DN($key)]] {
            if {
                [dict exists $open $f]
                || [string tolower [file extension $f]] ni $exts
            } {continue}
            foreach d $DX($f) {
                if {[lindex $d 0] eq $key} {lappend out [list $f "" {*}$d]}
            }
        }
    }
    if {![llength $out]} {set out [apiDefs $id $name]}
    return $out
}

# --- índice de biblioteca ---------------------------------------------------
# Definições das bibliotecas instaladas da linguagem (hook apiSources: lista
# de arquivos e pastas). Indexadas em segundo plano na primeira consulta;
# AX(<lang>) = dicionário nome completo -> itens no formato de findDefs.
# Itens sem código-fonte (ex.: procedimentos do Guile escritos em C) têm
# linha 0. O hook apiParse lê formatos próprios (ex.: guile-procedures.txt).

namespace eval qc {
    variable AX
    variable AS ;# AS(<lang>,todo|dirs|done): varredura
    array set AX {}
    array set AS {}
}

proc qc::apiStart {id} {
    variable AS
    variable AX
    if {[info exists AS($id,done)]} {return}
    set AS($id,done) 0
    set AX($id) [dict create]
    set AS($id,todo) {}
    set AS($id,dirs) {}
    set AS($id,n) 0
    set h [hook apiSources $id]
    if {$h eq "" || [catch {$h} srcs]} {
        set AS($id,done) 1
        return
    }
    foreach p $srcs {
        if {[file isdirectory $p]} {
            lappend AS($id,dirs) $p
        } elseif {[file isfile $p]} {
            lappend AS($id,todo) $p
        }
    }
    # tclint-disable-next-line command-args
    after 200 [list qc::apiStep $id]
}

proc qc::apiStep {id} {
    variable AS
    variable acMaxSize
    set exts [lget ext $id]
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 15} {
        if {[llength $AS($id,todo)]} {
            set AS($id,todo) [lassign $AS($id,todo) f]
            catch {apiIndexFile $id $f}
        } elseif {[llength $AS($id,dirs)] && $AS($id,n) < 5000} {
            set AS($id,dirs) [lassign $AS($id,dirs) d]
            foreach p [lsort [glob -nocomplain -directory $d -types d *]] {
                lappend AS($id,dirs) $p
            }
            foreach p [lsort [glob -nocomplain -directory $d -types f *]] {
                if {
                    [string tolower [file extension $p]] in $exts
                    && ![catch {file size $p} sz] && $sz <= $acMaxSize
                } {
                    lappend AS($id,todo) $p
                    incr AS($id,n)
                }
            }
        } else {
            set AS($id,done) 1
            return
        }
    }
    # tclint-disable-next-line command-args
    after 5 [list qc::apiStep $id]
}

proc qc::apiIndexFile {id f} {
    variable AX
    set data [readFile $f]
    set h [hook apiParse $id]
    set items -
    if {$h ne ""} {set items [$h $f $data]}
    if {$items eq "-"} {
        set items {}
        foreach d [defsIn $data $id 1] {
            lappend items [list [lindex $d end] [list $f "" {*}$d]]
        }
    }
    foreach it $items {
        lassign $it q item
        dict lappend AX($id) $q $item
    }
}

# Nome completo procurado no índice (sem "::" no começo).
proc qc::apiDefs {id name} {
    variable AX
    apiStart $id
    set q [regsub {^::} $name {}]
    if {![info exists AX($id)] || ![dict exists $AX($id) $q]} {return {}}
    return [dict get $AX($id) $q]
}

# Palavra (pela regex "word" da linguagem) na posição idx do editor:
# {palavra início fim}. after=1 aceita o cursor logo depois da palavra.
proc qc::wordAt {idx {after 1}} {
    variable ed
    lassign [split [$ed index $idx] .] l c
    set line [$ed get $l.0 "$l.0 lineend"]
    foreach r [regexp -all -inline -indices -- [acWordRe] $line] {
        lassign $r a z
        if {$c >= $a && ($c <= $z || ($after && $c == $z + 1))} {
            return [list [string range $line $a $z] $l.$a $l.[expr {$z + 1}]]
        }
    }
    return {}
}

# Tira da lista a própria definição em que o cursor/mouse está.
proc qc::defsElsewhere {defs at} {
    lassign [split $at .] l c
    set out {}
    foreach d $defs {
        lassign $d f w - dl dc
        if {$w eq $::qc::ed && $dl == $l && $dc == $c} {continue}
        lappend out $d
    }
    return $out
}

proc qc::defLabel {d} {
    lassign $d f w name line
    if {$line == 0} {return "[file tail $f] (embutido, sem código-fonte)"}
    return "[expr {$f eq "" ? "Sem título" : [file tail $f]}]:$line"
}

# Só as definições que têm código-fonte para abrir.
proc qc::defsWithSource {defs} {
    lmap d $defs {if {[lindex $d 3] == 0} {continue}; set d}
}

# F12 (idx = insert) ou Ctrl+clique (idx = @x,y).
proc qc::goToDefinition {{idx insert}} {
    variable ed
    focus $ed
    set wd [wordAt $idx [expr {$idx eq "insert"}]]
    if {![llength $wd]} {
        set ::qc::status "Nenhum nome no cursor"
        return
    }
    lassign $wd name a
    set all [findDefs $name]
    set others [defsElsewhere $all $a]
    set defs [defsWithSource $others]
    if {![llength $defs]} {
        set ::qc::status [expr {
            [llength $others] ? "$name é embutido (sem código-fonte)"
            : [llength $all] ? "Já está na definição de $name"
            : "Definição de $name não encontrada"
        }]
        return
    }
    if {[llength $defs] == 1} {
        gotoDef [lindex $defs 0]
        return
    }
    # várias: menu para escolher, na posição do cursor
    set m .defpop
    destroy $m
    menu $m -tearoff 0
    foreach d $defs {
        set txt [lindex [split [lindex $d 5] \n] 0]
        if {[string length $txt] > 70} {set txt "[string range $txt 0 68]…"}
        $m add command -label "[defLabel $d]   $txt" -command [list qc::gotoDef $d]
    }
    set bb [$ed bbox $a]
    if {![llength $bb]} {set bb {0 0 0 0}}
    tk_popup $m [expr {[winfo rootx $ed] + [lindex $bb 0]}] \
        [expr {[winfo rooty $ed] + [lindex $bb 1] + [lindex $bb 3]}]
}

proc qc::gotoDef {d} {
    lassign $d f w name line col
    navPush
    if {$w ne "" && [winfo exists $w]} {
        activateTab $w
    } else {
        openFile $f
        if {$::qc::file ne $f} {return}
    }
    gotoLine $line $col
    set ::qc::status "$name — [defLabel $d]   (Alt+← volta)"
}

proc qc::navPush {} {
    variable navStack
    variable ed
    lappend navStack [list $::qc::file $ed [$ed index insert]]
    set navStack [lrange $navStack end-49 end]
}

# Alt+←: volta para onde estava antes do último F12.
proc qc::navBack {} {
    variable navStack
    if {![llength $navStack]} {
        set ::qc::status "Nada para voltar"
        return
    }
    lassign [lindex $navStack end] f w idx
    set navStack [lrange $navStack 0 end-1]
    set w [edResolve $w]
    if {[winfo exists $w] && $w in $::qc::tabs} {
        activateTab $w
    } elseif {$f ne ""} {
        openFile $f
        if {$::qc::file ne $f} {return}
    } else {
        return
    }
    $::qc::ed mark set insert $idx
    $::qc::ed tag remove sel 1.0 end
    $::qc::ed see insert
    focus $::qc::ed
}

# Botão direito: leva o cursor ao clique (se não for dentro da seleção).
proc qc::edPopup {w x y X Y} {
    focus $w
    set i [$w index @$x,$y]
    set sel [$w tag ranges sel]
    if {![llength $sel] || [$w compare $i < sel.first] || [$w compare $i > sel.last]} {
        $w tag remove sel 1.0 end
        $w mark set insert $i
    }
    tk_popup .edpop $X $Y
}

# --- dica -----------------------------------------------------------------

proc qc::tipHide {} {
    variable tipAfter
    variable tipKey ""
    after cancel $tipAfter
    catch {destroy .tip}
}

# Palavra sob o mouse ({} se o ponteiro não está sobre texto).
proc qc::wordUnderMouse {w x y} {
    if {$w ne $::qc::ed} {return {}}
    set wd [wordAt @$x,$y 0]
    if {![llength $wd]} {return {}}
    # fora do texto (depois do fim da linha) o índice "@x,y" cai no fim
    set bb [$w bbox [lindex $wd 1]]
    if {![llength $bb] || $y < [lindex $bb 1] || $y > [lindex $bb 1] + [lindex $bb 3]} {
        return {}
    }
    return $wd
}

# Definições de uma palavra do editor, fora a própria; {} para palavras-chave,
# variáveis, strings e comentários.
proc qc::defsForWord {wd} {
    lassign $wd name a
    if {[inLiteral $a]} {return {}}
    foreach t [$::qc::ed tag names $a] {if {$t in {keyword var}} {return {}}}
    return [defsElsewhere [findDefs $name] $a]
}

proc qc::hoverSched {w x y {state 0}} {
    variable tipAfter
    variable tipKey
    if {$state & 4} {linkUpdate $w $x $y} else {linkClear}
    if {!$::qc::cfg(hoverdef) || $w ne $::qc::ed} {return}
    after cancel $tipAfter
    set wd [wordUnderMouse $w $x $y]
    set key [lrange $wd 0 1]
    if {$key eq $tipKey && [winfo exists .tip]} {return}
    catch {destroy .tip}
    set tipKey ""
    if {![llength $wd]} {return}
    # tclint-disable-next-line command-args
    set tipAfter [after 450 [list qc::tipShow $w $wd $x $y]]
}

# --- Ctrl+clique ----------------------------------------------------------

proc qc::linkUpdate {w x y} {
    variable linkKey
    set wd [wordUnderMouse $w $x $y]
    set key [lrange $wd 0 1]
    if {$key eq $linkKey} {return}
    linkClear
    if {![llength $wd] || ![llength [defsWithSource [defsForWord $wd]]]} {return}
    set linkKey $key
    $w tag add deflink [lindex $wd 1] [lindex $wd 2]
    $w configure -cursor hand2
}

proc qc::linkClear {} {
    variable linkKey
    if {$linkKey eq ""} {return}
    set linkKey ""
    foreach w $::qc::tabs {
        $w tag remove deflink 1.0 end
        $w configure -cursor xterm
    }
}

# Ctrl apertado com o mouse já parado sobre o editor.
proc qc::linkAtPointer {w} {
    lassign [winfo pointerxy $w] px py
    if {[winfo containing $px $py] ne $w} {return}
    linkUpdate $w [expr {$px - [winfo rootx $w]}] [expr {$py - [winfo rooty $w]}]
}

proc qc::ctrlClick {w x y} {
    tipHide
    set wd [wordUnderMouse $w $x $y]
    if {[llength $wd] && [llength [defsWithSource [defsForWord $wd]]]} {
        linkClear
        goToDefinition @$x,$y
    } else {
        addCaretAt $x $y
    }
}

proc qc::tipShow {w wd x y} {
    variable C
    variable tipKey
    if {$w ne $::qc::ed || ![winfo exists $w]} {return}
    lassign $wd name a
    set defs [defsForWord $wd]
    if {![llength $defs]} {return}
    set tipKey [lrange $wd 0 1]

    set t .tip
    toplevel $t -background #555555
    wm withdraw $t
    wm overrideredirect $t 1
    catch {wm attributes $t -type tooltip}
    text $t.t -background $C(ui) -foreground $C(edfg) -font QcMono -bd 0 \
        -highlightthickness 0 -padx 8 -pady 6 -wrap none -cursor arrow
    pack $t.t -padx 1 -pady 1
    $t.t tag configure loc -foreground #8a8a8a -font TkDefaultFont
    $t.t tag configure doc -foreground [lindex [dict get $::qc::S comment] 0] -font QcMonoI
    $t.t tag configure sig -foreground $C(edfg)
    set n 0
    foreach d $defs {
        # até 3 definições, parando antes se a dica já estiver grande
        if {$n >= 3 || ($n > 0 && [$t.t count -lines 1.0 end] > 18)} {break}
        incr n
        lassign $d f - - line - sig doc post
        if {$n > 1} {$t.t insert end \n}
        $t.t insert end "[defLabel $d]\n" loc
        foreach dl $doc {$t.t insert end "$dl\n" doc}
        foreach sl [split $sig \n] {
            if {[string length $sl] > 120} {set sl "[string range $sl 0 118]…"}
            $t.t insert end "$sl\n" sig
        }
        foreach dl $post {$t.t insert end "$dl\n" doc}
    }
    if {[llength $defs] > $n} {
        $t.t insert end "+[expr {[llength $defs] - $n}] outras (F12 para escolher)\n" loc
    }
    $t.t delete end-1c
    set wmax 10
    foreach ln [split [$t.t get 1.0 end-1c] \n] {
        set wmax [expr {max($wmax, min(120, [string length $ln]))}]
    }
    $t.t configure -width $wmax -height [lindex [split [$t.t index end-1c] .] 0] \
        -state disabled
    # abaixo da linha do mouse; acima, se não couber na tela
    set bb [$w bbox $a]
    set rx [expr {[winfo rootx $w] + $x + 4}]
    set ry [expr {[winfo rooty $w] + [lindex $bb 1] + [lindex $bb 3] + 4}]
    update idletasks
    set tw [winfo reqwidth $t]
    set th [winfo reqheight $t]
    set sw [winfo screenwidth $t]
    set sh [winfo screenheight $t]
    if {$rx + $tw > $sw} {set rx [expr {max(0, $sw - $tw)}]}
    if {$ry + $th > $sh} {set ry [expr {[winfo rooty $w] + [lindex $bb 1] - $th - 4}]}
    wm geometry $t +$rx+$ry
    wm deiconify $t
    raise $t
}

# ---------------------------------------------------------------------------
# Vários cursores (Ctrl+D / Alt+F3 / Ctrl+clique)
# ---------------------------------------------------------------------------
# O cursor principal é o próprio insert/sel do Text. Cada cursor extra é um
# par de marcas qcm<id>a / qcm<id>b (início/fim da seleção dele). Uma edição
# é aplicada a cada cursor em sequência: o cursor vira temporariamente o
# insert/sel, o comando de edição normal roda e o resultado volta às marcas.

# Marca a = âncora da seleção, b = posição do cursor (b pode vir antes de a).
proc qc::regSave {id} {
    set i [::qc::_edw index insert]
    set anchor $i
    if {[llength [::qc::_edw tag ranges sel]]} {
        set f [::qc::_edw index sel.first]
        set anchor $f
        if {$i eq $f} {set anchor [::qc::_edw index sel.last]}
    }
    regSet $id $anchor $i
}

proc qc::regSet {id anchor caret} {
    ::qc::_edw mark set qcm${id}a $anchor
    ::qc::_edw mark set qcm${id}b $caret
    # seleção: o texto inserido nas bordas (por cursores vizinhos) fica fora
    if {[::qc::_edw compare $anchor == $caret]} {
        lassign {left left} ga gb
    } elseif {[::qc::_edw compare $anchor < $caret]} {
        lassign {right left} ga gb
    } else {
        lassign {left right} ga gb
    }
    ::qc::_edw mark gravity qcm${id}a $ga
    ::qc::_edw mark gravity qcm${id}b $gb
}

# Início e fim (em ordem) da seleção do cursor.
proc qc::regGet {id} {
    set a [::qc::_edw index qcm${id}a]
    set b [::qc::_edw index qcm${id}b]
    if {[::qc::_edw compare $a > $b]} {return [list $b $a]}
    return [list $a $b]
}

proc qc::regCaret {id} {
    return [::qc::_edw index qcm${id}b]
}

proc qc::regLoad {id} {
    lassign [regGet $id] a b
    ::qc::_edw tag remove sel 1.0 end
    if {[::qc::_edw compare $a < $b]} {::qc::_edw tag add sel $a $b}
    $::qc::ed mark set insert [regCaret $id]
}

proc qc::multiApply {script} {
    variable ed
    variable mcur
    variable mapplying
    regSave p
    set mapplying 1
    try {
        atomic {
            foreach id [concat $mcur p] {
                regLoad $id
                uplevel #0 $script
                regSave $id
            }
        }
    } finally {
        set mapplying 0
        regLoad p
        ::qc::_edw mark unset qcmpa qcmpb
    }
    # cursores que acabaram na mesma posição viram um só
    set seen [list [regKey [::qc::_edw index insert] [::qc::_edw index insert]]]
    if {[llength [::qc::_edw tag ranges sel]]} {
        lappend seen [regKey [::qc::_edw index sel.first] [::qc::_edw index sel.last]]
    }
    set keep {}
    foreach id $mcur {
        set key [regKey {*}[regGet $id]]
        if {$key in $seen} {
            ::qc::_edw mark unset qcm${id}a qcm${id}b
        } else {
            lappend seen $key
            lappend keep $id
        }
    }
    set mcur $keep
    multiRedraw
    $ed see insert
}

proc qc::regKey {a b} {return "$a $b"}

proc qc::multiRedraw {} {
    variable mcur
    ::qc::_edw tag remove msel 1.0 end
    foreach id $mcur {
        lassign [regGet $id] a b
        if {[::qc::_edw compare $a < $b]} {::qc::_edw tag add msel $a $b}
    }
    ::qc::_edw tag raise msel
    drawCarets
}

# Os cursores extras são frames finos posicionados sobre o Text.
proc qc::drawCarets {} {
    variable ed
    variable mcur
    variable C
    set i 0
    foreach id $mcur {
        set bb [::qc::_edw bbox qcm${id}b]
        if {$bb eq ""} {continue}
        lassign $bb x y - h
        set w $ed.mc$i
        if {![winfo exists $w]} {
            frame $w -background $C(caret) -width 2 -bd 0 -cursor xterm
        }
        # o Tk desenha o próprio cursor centrado na borda do caractere
        place $w -x [expr {$x - 1}] -y $y -width 2 -height $h -bordermode outside
        incr i
    }
    while {[winfo exists $ed.mc$i]} {
        place forget $ed.mc$i
        incr i
    }
}

proc qc::multiClear {} {
    variable mcur
    variable mlast ""
    if {![llength $mcur]} {return}
    foreach id $mcur {::qc::_edw mark unset qcm${id}a qcm${id}b}
    set mcur {}
    ::qc::_edw tag remove msel 1.0 end
    drawCarets
}

proc qc::multiAdd {a b} {
    variable mcur
    variable mseq
    set id [incr mseq]
    regSet $id $a $b
    lappend mcur $id
    return $id
}

# Tecla com vários cursores ativos (bindtag QcMulti, antes das demais).
proc qc::multiKey {K A s} {
    variable mcur
    if {![llength $mcur]} {return}
    if {
        [string match *_L $K] || [string match *_R $K]
        || $K in {Caps_Lock Num_Lock ISO_Level3_Shift Mode_switch Multi_key}
    } {return}
    if {($s & 0x0C) == 4 && $K in {Left Right}} {
        # Ctrl+←/→ (com Shift, seleciona): palavra a palavra, em cada cursor
        multiApply [list qc::moveCaret Word$K [expr {$s & 1}]]
        return -code break
    }
    if {$s & 0x0C} {
        # Ctrl+D continua adicionando, Ctrl+V cola em todos (via qc::paste),
        # Ctrl+S/R não mexem no texto; o resto volta a um cursor só
        if {
            !($s & 4 && [string tolower $K] in {d v s r})
            && !($s & 8 && $K in {Up Down})
        } {multiClear}
        return
    }
    set shift [expr {$s & 1}]
    switch -- $K {
        Escape {multiClear; return -code break}
        BackSpace {multiApply qc::backspace}
        Delete - KP_Delete {multiApply qc::deleteFwd}
        Return - KP_Enter {multiApply qc::newline}
        Tab {multiApply {qc::indent 1}}
        Left - Right - Home - End - Up - Down {
            multiApply [list qc::moveCaret $K $shift]
        }
        default {
            if {$A ne "" && [string is print $A]} {
                multiApply [list qc::typeChar $A]
            } else {
                # PageUp/PageDown voltam a um cursor; teclas mortas (acentos)
                # e outras sem caractere são ignoradas
                if {$K in {Prior Next}} {multiClear}
                return
            }
        }
    }
    return -code break
}

# Move o cursor; com shift, estende a seleção a partir da âncora.
proc qc::moveCaret {k {shift 0}} {
    variable ed
    set hasSel [llength [::qc::_edw tag ranges sel]]
    set ins [$ed index insert]
    if {$hasSel && !$shift && $k eq "Left"} {
        set to sel.first
    } elseif {$hasSel && !$shift && $k eq "Right"} {
        # linha(s) inteira(s) selecionada(s): fim da última linha, não o
        # começo da seguinte
        set to sel.last
        if {
            [$ed compare sel.last == "sel.last linestart"]
            && [$ed compare sel.first < sel.last]
        } {set to "sel.last -1c"}
    } elseif {$k eq "WordLeft"} {
        set to [tk::TextPrevPos $ed insert [prevWordFn]]
    } elseif {$k eq "WordRight"} {
        # como no Tk: com Shift, até o fim da palavra
        set to [expr {
            $shift && [info commands tk::TextSelectNextWord] ne ""
            ? [tk::TextSelectNextWord $ed insert] : [tk::TextNextWord $ed insert]
        }]
    } else {
        set to [dict get {
            Left "insert -1c" Right "insert +1c" Home "insert linestart"
            End "insert lineend" Up "insert -1 line" Down "insert +1 line"
        } $k]
        if {$k eq "Home"} {set to [smartHome]}
    }
    set to [$ed index $to]
    if {[$ed compare $to > end-1c]} {set to [$ed index end-1c]}
    # palavra a palavra (vários cursores): não sai da linha, para no
    # fim/início dela; assim cada cursor continua na sua linha
    if {$k in {WordLeft WordRight} && [$ed compare "$to linestart" != "$ins linestart"]} {
        set to [$ed index [expr {$k eq "WordRight" ? "$ins lineend" : "$ins linestart"}]]
    }
    set anchor $ins
    if {$hasSel} {
        set f [$ed index sel.first]
        set anchor $f
        if {$ins eq $f} {set anchor [$ed index sel.last]}
    }
    ::qc::_edw tag remove sel 1.0 end
    if {$shift && [$ed compare $anchor != $to]} {
        if {[$ed compare $anchor < $to]} {
            ::qc::_edw tag add sel $anchor $to
        } else {
            ::qc::_edw tag add sel $to $anchor
        }
    }
    $ed mark set insert $to
}

# Início da palavra anterior: tk::startOfPreviousWord (Tk 9) ou a do Tcl.
proc qc::prevWordFn {} {
    if {[info commands ::tk::startOfPreviousWord] ne ""} {return tk::startOfPreviousWord}
    return tcl_startOfPreviousWord
}

# Home "inteligente": vai ao primeiro caractere não branco da linha; se o
# cursor já estiver lá, vai ao início da linha.
proc qc::smartHome {} {
    variable ed
    set ls [$ed index "insert linestart"]
    set line [$ed get $ls "insert lineend"]
    regexp -indices {^[ \t]*} $line m
    set first [$ed index "$ls +[expr {[lindex $m 1] + 1}]c"]
    if {[$ed compare insert == $first]} {return $ls}
    return $first
}

# ←/→ sem Shift com texto selecionado: cursor no início/fim da seleção.
proc qc::selJump {k state} {
    if {$state & 0x0D || ![llength [::qc::_edw tag ranges sel]]} {return 0}
    moveCaret $k
    $::qc::ed see insert
    return 1
}

# Ctrl+D: sem seleção, seleciona a palavra no cursor; com seleção, adiciona
# um cursor na próxima ocorrência do texto selecionado (dando a volta no
# fim do arquivo). Devolve 1 se selecionou algo novo.
proc qc::selectNext {{redraw 1}} {
    variable ed
    variable mcur
    variable mlast
    variable mword
    if {![llength [::qc::_edw tag ranges sel]]} {
        if {[llength $mcur]} {
            # vários cursores sem seleção: seleciona a palavra em cada um
            multiApply qc::selectWord
            return 0
        }
        if {![selectWord]} {return 0}
        set mword [list [$ed index sel.first] [$ed index sel.last]]
        return 1
    }
    set sa [$ed index sel.first]
    set sb [$ed index sel.last]
    if {![llength $mcur]} {
        set mlast ""
        if {$mword ne [list $sa $sb]} {set mword ""}
    }
    set text [$ed get $sa $sb]
    set len [string length $text]
    # (não usar expr aqui: ele transformaria o índice "2.10" no número 2.1)
    set start $sb
    if {$mlast ne "" && $mlast in $mcur} {set start [lindex [regGet $mlast] 1]}
    set taken [list $sa]
    foreach id $mcur {lappend taken [lindex [regGet $id] 0]}
    for {set n 0} {$n < 100000} {incr n} {
        set pos [::qc::_edw search -exact -forwards -- $text $start]
        if {$pos eq ""} {return 0}
        set end [::qc::_edw index "$pos +${len}c"]
        if {$pos in $taken} {
            set ::qc::status "Todas as ocorrências já estão selecionadas ([expr {[llength $mcur] + 1}])"
            return 0
        }
        set start $end
        if {$mword ne ""} {
            set before [expr {[$ed compare $pos == 1.0] ? "" : [$ed get "$pos -1c"]}]
            if {[regexp {\w} $before] || [regexp {\w} [$ed get $end]]} {continue}
        }
        break
    }
    set mlast [multiAdd $pos $end]
    if {$redraw} {
        multiRedraw
        $ed see $pos
        set ::qc::status "[expr {[llength $mcur] + 1}] seleções"
    }
    return 1
}

# Seleciona a palavra no cursor (ou logo antes dele); 0 se não houver.
proc qc::selectWord {} {
    variable ed
    set i insert
    if {![regexp {\w} [$ed get insert]]} {
        if {[$ed compare insert == 1.0] || ![regexp {\w} [$ed get "insert -1c"]]} {return 0}
        set i "insert -1c"
    }
    set a [$ed index "$i wordstart"]
    set b [$ed index "$i wordend"]
    ::qc::_edw tag remove sel 1.0 end
    ::qc::_edw tag add sel $a $b
    $ed mark set insert $b
    return 1
}

# Alt+F3: seleciona todas as ocorrências de uma vez.
proc qc::selectAllOcc {} {
    variable ed
    if {![llength [::qc::_edw tag ranges sel]] && ![selectNext]} {return}
    while {[selectNext 0]} {}
    multiRedraw
    set ::qc::status "[expr {[llength $::qc::mcur] + 1}] seleções"
}

# Shift+Alt+↑/↓: adiciona um cursor na linha acima do cursor mais alto (ou
# abaixo do mais baixo), na coluna do cursor original.
proc qc::addCaretLine {dir} {
    variable ed
    variable mcur
    variable mcol
    if {![llength $mcur]} {set mcol [lindex [split [$ed index insert] .] 1]}
    set lines [list [lindex [split [$ed index insert] .] 0]]
    foreach id $mcur {lappend lines [lindex [split [regCaret $id] .] 0]}
    set l [expr {$dir < 0 ? [tcl::mathfunc::min {*}$lines] - 1 : [tcl::mathfunc::max {*}$lines] + 1}]
    set last [lindex [split [$ed index end-1c] .] 0]
    if {$l < 1 || $l > $last} {return}
    set len [lindex [split [$ed index "$l.0 lineend"] .] 1]
    set i $l.[expr {min($mcol, $len)}]
    multiAdd $i $i
    multiRedraw
    $ed see $i
    set ::qc::status "[expr {[llength $mcur] + 1}] cursores"
}

# Ctrl+clique (fora de um nome com definição) ou Alt+clique: adiciona um
# cursor (o principal continua onde estava).
proc qc::addCaretAt {x y} {
    variable ed
    focus $ed
    set i [$ed index @$x,$y]
    multiAdd $i $i
    multiRedraw
}

# Comenta com o prefixo da linguagem; se ela só tiver comentário de bloco
# (commentEnd, ex.: OCaml), cada linha vira "(* ... *)".
proc qc::toggleComment {} {
    variable ed
    set c [lget comment]
    set ce [lget commentEnd]
    set q [reQuote $c]
    set qe [expr {$ce eq "" ? "" : " ?[reQuote $ce]\\s*$"}]
    lassign [selLines] a z
    set all 1
    for {set l $a} {$l <= $z} {incr l} {
        set line [$ed get $l.0 "$l.0 lineend"]
        if {[string trim $line] ne "" && ![regexp "^\\s*$q.*$qe" $line]} {set all 0; break}
    }
    atomic {
        for {set l $a} {$l <= $z} {incr l} {
            set line [$ed get $l.0 "$l.0 lineend"]
            if {$all} {
                if {$ce ne "" && [regexp -indices $qe $line r]} {
                    $ed delete $l.[lindex $r 0] "$l.0 lineend"
                }
                if {[regexp -indices "^\\s*($q ?)" $line -> r]} {
                    $ed delete $l.[lindex $r 0] $l.[expr {[lindex $r 1] + 1}]
                }
            } elseif {[string trim $line] ne ""} {
                regexp {^\s*} $line ws
                if {$ce ne ""} { $ed insert "$l.0 lineend" " $ce" }
                $ed insert $l.[string length $ws] "$c "
            }
        }
    }
    if {$a == $z && ![llength [$ed tag ranges sel]]} {
        $ed mark set insert "insert +1 line"
    }
}

proc qc::zoom {d} {
    variable cfg
    if {$d == 0} {
        set cfg(fontsize) 11
    } else {
        set cfg(fontsize) [expr {max(6, min(48, $cfg(fontsize) + $d))}]
    }
    foreach f {QcMono QcMonoB QcMonoI} {font configure $f -size $cfg(fontsize)}
    mdZoom
    updateTabs
    schedGutter
    set ::qc::status "Fonte: $cfg(fontsize) pt"
}

proc qc::applyWrap {} {
    variable cfg
    foreach w $::qc::tabs {
        $w configure -wrap [expr {$cfg(wrap) ? "word" : "none"}]
    }
    foreach h [concat .pw.ed [floatTops]] {
        if {$cfg(wrap)} {
            grid remove $h.sx
        } else {
            grid $h.sx
        }
    }
    schedGutter
}

# ---------------------------------------------------------------------------
# Localizar / substituir / ir para linha
# ---------------------------------------------------------------------------

proc qc::showFind {replace} {
    variable ed
    variable find
    grid [fb]
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        if {[string first \n $s] < 0} {set find(pat) $s}
    }
    set e [fb].[expr {$replace ? "rep" : "pat"}]
    if {$replace && $find(pat) eq ""} {set e [fb].pat}
    focus $e
    $e selection range 0 end
    markAll
}

proc qc::hideFind {} {
    grid remove [fb]
    $::qc::ed tag remove found 1.0 end
    focus $::qc::ed
}

proc qc::searchOpts {} {
    variable find
    set o {}
    if {!$find(case)} {lappend o -nocase}
    if {$find(regex)} {lappend o -regexp}
    return $o
}

proc qc::markAll {} {
    variable ed
    variable find
    ::qc::_edw tag remove found 1.0 end
    [fb].pat configure -style TEntry
    set find(info) ""
    if {$find(pat) eq "" || ![winfo ismapped [fb]]} {return}
    set cnt {}
    if {[catch {::qc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} {
        set find(info) "regex inválida"
        [fb].pat configure -style NotFound.TEntry
        return
    }
    set r {}
    foreach h $hits n $cnt {
        if {$n > 0} {lappend r $h "$h +${n}c"}
    }
    if {[llength $r]} {::qc::_edw tag add found {*}$r}
    set find(info) "[llength $hits] ocorrência(s)"
    if {![llength $hits]} {[fb].pat configure -style NotFound.TEntry}
}

proc qc::findNext {fwd} {
    variable ed
    variable find
    if {$find(pat) eq ""} {showFind 0; return}
    if {$fwd} {
        set start [expr {[llength [$ed tag ranges sel]] ? "sel.last" : "insert"}]
        set dir -forwards
    } else {
        set start [expr {[llength [$ed tag ranges sel]] ? "sel.first" : "insert"}]
        set dir -backwards
    }
    if {[catch {::qc::_edw search $dir {*}[searchOpts] -count n -- $find(pat) $start} idx]} {return}
    if {$idx eq ""} {
        set ::qc::status "Não encontrado: $find(pat)"
        return
    }
    $ed tag remove sel 1.0 end
    $ed tag add sel $idx "$idx +${n}c"
    $ed mark set insert [expr {$fwd ? "$idx +${n}c" : $idx}]
    $ed see $idx
    set ::qc::status ""
}

proc qc::replaceText {matched} {
    variable find
    if {!$find(regex)} {return $find(rep)}
    set o {}
    if {!$find(case)} {lappend o -nocase}
    regsub {*}$o -- $find(pat) $matched $find(rep) out
    return $out
}

proc qc::replaceOne {} {
    variable ed
    variable find
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        set o [searchOpts]
        if {
            [catch {::qc::_edw search {*}$o -count n -- $find(pat) sel.first sel.last} idx] == 0
            && $idx ne "" && [$ed compare $idx == sel.first] && $n == [string length $s]
        } {
            set a [$ed index sel.first]
            atomic {
                $ed delete sel.first sel.last
                $ed insert $a [replaceText $s]
            }
        }
    }
    findNext 1
    markAll
}

proc qc::replaceAll {} {
    variable ed
    variable find
    if {$find(pat) eq ""} {return}
    set cnt {}
    if {[catch {::qc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} {return}
    atomic {
        set k 0
        foreach h [lreverse $hits] n [lreverse $cnt] {
            if {$n == 0} continue
            set s [$ed get $h "$h +${n}c"]
            $ed delete $h "$h +${n}c"
            $ed insert $h [replaceText $s]
            incr k
        }
    }
    set ::qc::status "$k substituição(ões)"
    markAll
}

proc qc::gotoDialog {} {
    set w .goto
    if {[winfo exists $w]} {raise $w; focus $w.e; return}
    toplevel $w -background $::qc::C(ui)
    wm title $w "Ir para linha"
    wm transient $w .
    wm resizable $w 0 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text "Linha:"
    ttk::entry $w.e -width 10 -textvariable ::qc::gotoLine
    ttk::button $w.f.ok -text OK -command qc::gotoApply
    pack $w.f -fill both
    pack $w.f.l -in $w.f -side left
    pack $w.e -in $w.f -side left -padx 6
    pack $w.f.ok -side left
    bind $w <Return> qc::gotoApply
    bind $w <Escape> [list destroy $w]
    set ::qc::gotoLine [lindex [split [$::qc::ed index insert] .] 0]
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    focus $w.e
    $w.e selection range 0 end
}

proc qc::gotoApply {} {
    if {[string is integer -strict $::qc::gotoLine]} {
        gotoLine $::qc::gotoLine
    }
    destroy .goto
}

proc qc::gotoLine {n {col 0}} {
    variable ed
    $ed mark set insert $n.$col
    $ed tag remove sel 1.0 end
    $ed see insert
    focus $ed
}

# ---------------------------------------------------------------------------
# Interpretadores (runners)
# ---------------------------------------------------------------------------

proc qc::runnerNames {{id ""}} {
    set out {}
    foreach r [lget runners $id] {lappend out [dict get $r name]}
    return $out
}

# Executável do runner: opção do usuário, variável QCONSOLE_<LANG>, hook
# findExe da linguagem ou busca no PATH pelos nomes em "exe".
proc qc::findExe {rn {id ""}} {
    if {$id eq ""} {set id $::qc::lang}
    set name [dict get $rn name]
    set user [lcfg exe.$name $id]
    if {$user ne ""} {return [list $user]}
    set ev QCONSOLE_[string toupper $id]
    if {[info exists ::env($ev)]} {return [list $::env($ev)]}
    set h [hook findExe $id]
    if {$h ne ""} {
        set p [$h $rn]
        if {$p ne ""} {return $p}
    }
    foreach n [dict get $rn exe] {
        set p [auto_execok $n]
        if {$p ne ""} {return $p}
    }
    return ""
}

# Runner corrente: o escolhido nas opções, se disponível, ou o primeiro
# encontrado. Retorna o dicionário da linguagem mesclado com o do runner.
proc qc::currentRunner {{id ""}} {
    if {$id eq ""} {set id $::qc::lang}
    set rs [lget runners $id]
    if {![llength $rs]} {return ""}
    set want [lcfg runner $id]
    foreach r $rs {
        if {[dict get $r name] eq $want && [findExe $r $id] ne ""} {return $r}
    }
    foreach r $rs {
        if {[findExe $r $id] ne ""} {return $r}
    }
    return [lindex $rs 0]
}

# Onde o executável é procurado (para mensagens).
proc qc::runnerSearched {rn} {
    if {[dict exists $rn searchHint]} {return [dict get $rn searchHint]}
    return [join [dict get $rn exe] {, }]
}

proc qc::runnerLabel {rn} {
    return [expr {[dict exists $rn label] ? [dict get $rn label] : [dict get $rn name]}]
}

# Versão do interpretador (em segundo plano: alguns launchers demoram).
proc qc::detectVersion {} {
    variable V
    variable lang
    set rn [currentRunner]
    if {$rn eq ""} {
        set ::qc::interp [expr {[hook run] ne "" ? "Ctrl+R: pré-visualizar" : "sem interpretador"}]
        return
    }
    set key $lang,[dict get $rn name]
    set exe [findExe $rn]
    if {$exe eq ""} {
        set ::qc::interp "[runnerLabel $rn] não encontrado"
        return
    }
    if {[info exists V($key)]} {showVersion; return}
    set ::qc::interp "[runnerLabel $rn] …"
    set stdin [expr {[dict exists $rn versionStdin] ? [dict get $rn versionStdin] : ""}]
    set vargs [expr {[dict exists $rn version] ? [dict get $rn version] : "--version"}]
    if {[catch {open |[list {*}$exe {*}$vargs << $stdin 2>@1] r} f]} {
        set V($key) ""
        showVersion
        return
    }
    fconfigure $f -blocking 0
    set ::qc::verBuf($f) ""
    chan event $f readable [list qc::onVersion $f $key $rn]
}

proc qc::onVersion {f key rn} {
    variable V
    append ::qc::verBuf($f) [read $f]
    if {![eof $f]} {return}
    catch {close $f}
    set out [stripAnsi $::qc::verBuf($f)]
    unset ::qc::verBuf($f)
    set re [expr {[dict exists $rn versionRe] ? [dict get $rn versionRe] : {([0-9]+\.[0-9][0-9.]*)}}]
    set V($key) [expr {[regexp -- $re $out -> v] ? $v : ""}]
    showVersion
}

proc qc::showVersion {} {
    variable V
    set rn [currentRunner]
    set key $::qc::lang,[dict get $rn name]
    set v [expr {[info exists V($key)] ? $V($key) : ""}]
    set ::qc::interp [string trim "[runnerLabel $rn] $v"]
}

proc qc::langVersion {} {
    variable V
    set rn [currentRunner]
    if {$rn eq ""} {return ""}
    set key $::qc::lang,[dict get $rn name]
    return [expr {[info exists V($key)] ? $V($key) : ""}]
}

# ---------------------------------------------------------------------------
# Opções de execução
# ---------------------------------------------------------------------------

proc qc::optionsDialog {} {
    variable cfg
    set w .opts
    if {[winfo exists $w]} {destroy $w}
    set names [runnerNames]
    set rn [currentRunner]
    set ::qc::optTmp(runner) [expr {$rn eq "" ? "" : [dict get $rn name]}]
    set ::qc::optTmp(opts) [lcfg opts]
    set ::qc::optTmp(args) [lcfg args]
    set ::qc::optTmp(exe) [lcfg exe.$::qc::optTmp(runner)]
    toplevel $w -background $::qc::C(ui)
    wm title $w "Opções de execução — [lget name]"
    wm transient $w .
    wm resizable $w 1 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.lr -text "Interpretador:"
    ttk::combobox $w.f.r -state readonly -values $names -textvariable ::qc::optTmp(runner) -width 20
    ttk::label $w.f.lx -text "Executável:"
    ttk::entry $w.f.x -width 60 -textvariable ::qc::optTmp(exe)
    ttk::label $w.f.hx -foreground #8a8a8a -text ""
    ttk::label $w.f.lo -text "Opções do interpretador:"
    ttk::entry $w.f.o -width 60 -textvariable ::qc::optTmp(opts)
    ttk::label $w.f.ho -foreground #8a8a8a -text ""
    ttk::label $w.f.la -text "Argumentos do programa:"
    ttk::entry $w.f.a -width 60 -textvariable ::qc::optTmp(args)
    ttk::frame $w.f.b
    ttk::button $w.f.b.ok -text OK -command qc::optionsApply
    ttk::button $w.f.b.cancel -text Cancelar -command [list destroy $w]
    pack $w.f.b.cancel $w.f.b.ok -side right -padx {6 0}
    grid $w.f.lr $w.f.r -sticky w -pady 3
    grid $w.f.lx $w.f.x -sticky w -pady 3
    grid x $w.f.hx -sticky w
    grid $w.f.lo $w.f.o -sticky w -pady {10 3}
    grid x $w.f.ho -sticky w
    grid $w.f.la $w.f.a -sticky w -pady {10 3}
    grid $w.f.b - -sticky e -pady {10 0}
    grid configure $w.f.x $w.f.o $w.f.a -sticky ew
    grid columnconfigure $w.f 1 -weight 1
    pack $w.f -fill both -expand 1
    bind $w.f.r <<ComboboxSelected>> qc::optionsRunnerChanged
    optionsHints
    bind $w <Return> qc::optionsApply
    bind $w <Escape> [list destroy $w]
    wm geometry $w +[expr {[winfo rootx .] + 120}]+[expr {[winfo rooty .] + 100}]
    focus $w.f.o
}

proc qc::optionsRunner {} {
    foreach r [lget runners] {
        if {[dict get $r name] eq $::qc::optTmp(runner)} {return $r}
    }
    return ""
}

proc qc::optionsRunnerChanged {} {
    set ::qc::optTmp(exe) [lcfg exe.$::qc::optTmp(runner)]
    optionsHints
}

proc qc::optionsHints {} {
    set w .opts.f
    set rn [optionsRunner]
    if {$rn eq ""} {return}
    set saved [lcfg exe.[dict get $rn name]]
    set ::qc::cfg(exe.[dict get $rn name].$::qc::lang) ""
    set found [findExe $rn]
    set ::qc::cfg(exe.[dict get $rn name].$::qc::lang) $saved
    $w.hx configure -text [expr {
        $found eq ""
        ? "não encontrado (procurados: [runnerSearched $rn])"
        : "vazio = [join $found]"
    }]
    $w.ho configure -text [expr {[dict exists $rn optsHint] ? "ex.: [dict get $rn optsHint]" : ""}]
}

proc qc::optionsApply {} {
    variable cfg
    variable lang
    set r $::qc::optTmp(runner)
    set cfg(runner.$lang) $r
    set cfg(opts.$lang) [string trim $::qc::optTmp(opts)]
    set cfg(args.$lang) [string trim $::qc::optTmp(args)]
    set cfg(exe.$r.$lang) [string trim $::qc::optTmp(exe)]
    catch {unset ::qc::V($lang,$r)}
    destroy .opts
    saveCfg
    detectVersion
    set ::qc::status "Opções de execução atualizadas"
}

# ---------------------------------------------------------------------------
# Abas
# ---------------------------------------------------------------------------
# Cada aba tem o próprio widget text (conteúdo, desfazer, cursor, rolagem,
# destaque). Só o da aba ativa fica na tela; ::qc::ed e ::qc::_edw apontam
# para ele, e ::qc::file é o arquivo dele.

proc qc::newEditor {} {
    variable tabs
    set w .pw.ed.t[incr ::qc::tabSeq]
    edCreate $w
    array set ::qc::TB [list $w,file "" $w,lang ""]
    # a nova aba entra logo depois da ativa
    set i [lsearch -exact $tabs $::qc::ed]
    set tabs [linsert $tabs [expr {$i + 1}] $w]
    return $w
}

# Cria o widget text de um editor. Com peer, ele é um "peer" de outro (mesmo
# conteúdo, tags, marcas e histórico de desfazer): é assim que uma aba muda
# de janela, já que o Tk não move widgets entre janelas.
proc qc::edCreate {w {peer ""}} {
    variable C
    variable cfg
    set opts [list -background $C(edbg) -foreground $C(edfg) \
        -insertbackground $C(caret) -insertwidth 2 -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -font QcMono -undo 1 -maxundo 0 -autoseparators 1 \
        -wrap [expr {$cfg(wrap) ? "word" : "none"}] \
        -bd 0 -highlightthickness 0 -padx 6 -pady 4 -tabstyle wordprocessor \
        -yscrollcommand [list qc::edYscroll $w] -xscrollcommand [list qc::edXscroll $w]]
    if {$peer eq ""} {
        text $w {*}$opts
        setupEdTags $w
    } else {
        set raw ::qc::raw$peer
        $raw peer create $w {*}$opts -tabs [$raw cget -tabs]
        # cursor e rolagem são de cada peer
        $w mark set insert [$raw index insert]
        set top [$raw index @0,0]
        # tclint-disable-next-line command-args
        after idle [list catch [list $w yview $top]]
    }
    installProxy $w
    bindtags $w [list $w QcHover QcComp QcMulti QcKeys QcEdit Text [winfo toplevel $w] all]
    bind $w <Configure> [list qc::edConfigure $w]
    bind $w <<Modified>> [list qc::onModified $w]
    bind $w <FocusIn> [list qc::edFocus $w]
    # tecla/clique num editor que não é o ativo (o foco do sistema pode estar
    # em outra janela): ele passa a ser o ativo antes de tratar o evento
    bind $w <KeyPress> {qc::edSync %W}
    bind $w <ButtonPress> {qc::edSync %W}
}

proc qc::edSync {w} {
    if {$w ne $::qc::ed && $w in $::qc::tabs} {activateTab $w}
}

# Clique/foco num editor de outra janela: ele passa a ser o ativo.
proc qc::edFocus {w} {
    # só se o foco ainda estiver nele (eventos atrasados não roubam o foco)
    if {$w ne $::qc::ed && $w in $::qc::tabs && [focus] eq $w} {activateTab $w}
}

proc qc::onModified {w} {
    if {$w eq $::qc::ed} {updateTitle} else {drawTabs; floatTitle $w}
}

proc qc::dockedTabs {} {
    lmap w $::qc::tabs {
        if {[winfo parent $w] ne ".pw.ed"} continue
        set w
    }
}

proc qc::floatTops {} {
    lmap w $::qc::tabs {
        if {[winfo parent $w] eq ".pw.ed"} continue
        winfo parent $w
    }
}

# Traz para a frente a janela do editor (se o foco estiver em outra).
proc qc::edRaise {w} {
    set top [winfo toplevel $w]
    set f [focus]
    if {$f eq "" || [winfo toplevel $f] ne $top} {
        if {[wm state $top] eq "iconic"} {wm deiconify $top}
        raise $top
        # outra janela: o foco do sistema precisa ir junto
        if {[winfo ismapped $top]} {
            # recém-colocado no grid: precisa estar mapeado para o Tk
            # lembrar dele como o foco da janela
            if {![winfo ismapped $w]} {update idletasks}
            catch {focus -force $w}
        }
    }
}

proc qc::activateTab {w} {
    variable ed
    variable TB
    variable lang
    variable dockCur
    if {$w eq $ed} {
        edRaise $w
        focus $w
        return
    }
    tipHide
    if {$ed ne "" && [winfo exists $ed]} {
        multiClear
        acHide
    }
    set ed $w
    interp alias {} ::qc::_edw {} ::qc::raw$w
    set host [winfo parent $w]
    # na janela principal só a aba exibida fica no grid
    if {$host eq ".pw.ed" && $dockCur ne $w} {
        if {$dockCur ne "" && [winfo exists $dockCur]} {grid remove $dockCur}
        grid $w -in .pw.ed -row 1 -column 1 -sticky nsew
        set dockCur $w
    }
    variable gut $host.gut
    variable file $TB($w,file)
    set want [expr {$TB($w,lang) ne "" ? $TB($w,lang) : $lang}]
    if {$want ne "" && ($want ne $lang || ![info exists TB($w,hltags)])} {
        setLang $want
    } elseif {$lang ne ""} {
        updateTitle
    }
    $host.sy set {*}[$w yview]
    $host.sx set {*}[$w xview]
    if {[winfo ismapped [fb]]} {markAll}
    treeReveal
    updateCursor
    mdApply
    edRaise $w
    focus $w
}

# --- abas desacopladas -----------------------------------------------------
# A aba vai para uma janela própria (.flN, com o editor em .flN.ed.t e a
# pré-visualização do Markdown em .flN.md) e sai da
# barra de abas, mas continua em ::qc::tabs. A janela principal sempre fica
# com pelo menos uma aba.

# O editor old foi trocado por new: atualiza tudo o que guarda o caminho.
proc qc::retarget {old new} {
    variable TB
    variable tabs
    variable R
    variable navStack
    foreach k [array names TB $old,*] {
        set TB($new,[string range $k [string length $old,] end]) $TB($k)
        unset TB($k)
    }
    set i [lsearch -exact $tabs $old]
    if {$i >= 0} {lset tabs $i $new}
    if {[info exists R(ed)] && $R(ed) eq $old} {set R(ed) $new}
    set navStack [lmap n $navStack {
        if {[lindex $n 1] eq $old} {lset n 1 $new}
        set n
    }]
    set ::qc::moved($old) $new
}

# Caminho atual de um editor que pode ter mudado de janela.
proc qc::edResolve {w} {
    while {![winfo exists $w] && [info exists ::qc::moved($w)]} {
        set w $::qc::moved($w)
    }
    return $w
}

# Tira o editor old de cena (antes de destruí-lo).
proc qc::edDrop {old} {
    if {$old eq $::qc::ed} {
        tipHide
        multiClear
        acHide
        set ::qc::ed ""
    }
    if {$old eq $::qc::dockCur} {set ::qc::dockCur ""}
    unset -nocomplain ::qc::gutO($old)
}

proc qc::undock {{w ""} {geom ""}} {
    variable C
    variable cfg
    variable dockCur
    if {$w eq ""} {set w $::qc::ed}
    if {![winfo exists $w] || [winfo parent $w] ne ".pw.ed"} {return}
    set docked [dockedTabs]
    set j [lsearch -exact $docked $w]
    set shown [expr {$w eq $dockCur}]

    set top .fl[incr ::qc::tabSeq]
    set h $top.ed
    toplevel $top -background $C(ui)
    wm withdraw $top
    if {$geom eq ""} {
        set gw [expr {max(500, [winfo width .pw.ed])}]
        # Markdown: espaço também para a pré-visualização
        if {$cfg(mdpreview) && $::qc::TB($w,lang) eq "markdown"} {
            set gw [expr {min($gw * 2, [winfo screenwidth .] * 9 / 10)}]
        }
        set gh [expr {max(350, [winfo height .pw.ed])}]
        set geom ${gw}x${gh}+[expr {[winfo rootx .pw.ed] + 40}]+[expr {[winfo rooty .pw.ed] + 40}]
    }
    wm geometry $top $geom
    wm minsize $top 300 200
    ttk::frame $top.head -style Head.TFrame
    ttk::label $top.head.l -style Head.TLabel -anchor w
    ttk::button $top.head.d -text "⇱ Acoplar" -style Head.TButton -takefocus 0 \
        -command [list qc::dock $h.t]
    pack $top.head.d -side right
    pack $top.head.l -side left -fill x -expand 1
    # editor | pré-visualização do Markdown (painel incluído só quando preciso)
    ttk::panedwindow $top.pw -orient horizontal
    ttk::frame $h
    canvas $h.gut -background $C(gutbg) -highlightthickness 0 -bd 0 \
        -width [$::qc::gut cget -width]
    ttk::scrollbar $h.sy -orient vertical -command [list qc::hostScroll $h yview]
    ttk::scrollbar $h.sx -orient horizontal -command [list qc::hostScroll $h xview]
    buildFindBar $h.find
    buildPreview $top.md $h

    edCreate $h.t $w
    retarget $w $h.t
    edDrop $w
    destroy $w
    catch {interp alias {} $w {}}

    grid $h.gut -row 0 -column 0 -sticky nsew
    grid $h.t -row 0 -column 1 -sticky nsew
    grid $h.sy -row 0 -column 2 -sticky ns
    grid $h.sx -row 1 -column 1 -sticky ew
    grid $h.find -row 2 -column 0 -columnspan 3 -sticky ew
    grid columnconfigure $h 1 -weight 1
    grid rowconfigure $h 0 -weight 1
    grid remove $h.find
    if {$cfg(wrap)} {grid remove $h.sx}
    $top.pw add $h -weight 1
    pack $top.head -side top -fill x
    pack $top.pw -side top -fill both -expand 1
    bindGutter $h.gut
    bind $h.gut <Configure> [list qc::edConfigure $h.t]
    foreach {seq cmd} $::qc::globalKeys {catch {bind $top $seq $cmd}}
    wm protocol $top WM_DELETE_WINDOW [list qc::dock $h.t]

    # a janela principal mostra a aba vizinha (ou uma nova, se não sobrou)
    if {$shown} {
        set docked [dockedTabs]
        if {![llength $docked]} {lappend docked [newEditor]}
        activateTab [lindex $docked [expr {min($j, [llength $docked] - 1)}]]
    }
    # quando aparecer, a janela nova recebe o foco
    bind $h.t <Map> {
        bind %W <Map> {}
        catch {focus -force %W}
    }
    # foco do sistema na janela (sem widget lembrado): vai para o editor
    bind $top <FocusIn> [list apply {{top e} {
        if {[focus] eq $top && [winfo exists $e]} {focus $e}
    }} $top $h.t]
    wm deiconify $top
    # espera a janela aparecer: antes disso o foco não chega nela, e um
    # comando logo em seguida (Ctrl+S, Ctrl+F4) iria para a aba principal
    waitMapped $h.t
    activateTab $h.t
    floatTitle $h.t
    drawTabs
    set ::qc::status "Aba desacoplada (Ctrl+Shift+T ou fechar a janela acopla de volta)"
    return $top
}

proc qc::waitMapped {w {ms 1000}} {
    set t0 [clock milliseconds]
    while {[winfo exists $w] && ![winfo ismapped $w] && [clock milliseconds] - $t0 < $ms} {
        after 10 {set ::qc::mapWait 1}
        vwait ::qc::mapWait
    }
}

proc qc::dock {{w ""}} {
    if {$w eq ""} {set w $::qc::ed}
    if {![winfo exists $w] || [winfo parent $w] eq ".pw.ed"} {return}
    set top [winfo toplevel $w]
    set n .pw.ed.t[incr ::qc::tabSeq]
    edCreate $n $w
    retarget $w $n
    edDrop $w
    # ativa antes de destruir a janela: senão o Tk devolve o foco ao último
    # editor que o teve na janela principal
    activateTab $n
    destroy $top
    catch {interp alias {} $w {}}
    drawTabs
    set ::qc::status "Aba acoplada"
}

# Ctrl+Shift+T
proc qc::toggleDock {} {
    if {[winfo parent $::qc::ed] eq ".pw.ed"} {undock} else {dock}
}

# Título da janela de uma aba desacoplada.
proc qc::floatTitle {w} {
    if {[winfo parent $w] eq ".pw.ed"} {return}
    set top [winfo toplevel $w]
    if {![winfo exists $top.head]} {return}
    set f $::qc::TB($w,file)
    set name [expr {$f eq "" ? "Sem título" : [file tail $f]}]
    set mod [expr {[$w edit modified] ? " •" : ""}]
    set dir [expr {$f eq "" ? "" : "  —  [file dirname $f]"}]
    wm title $top "$name$mod$dir  —  qconsole"
    $top.head.l configure -text "$name$mod"
}

# Aba para um arquivo novo: reaproveita a ativa se for "Sem título" e vazia.
proc qc::freshTab {} {
    variable ed
    if {
        $ed ne "" && $::qc::TB($ed,file) eq "" && ![$ed edit modified]
        && [$ed compare end-1c == 1.0]
    } {
        return $ed
    }
    set w [newEditor]
    activateTab $w
    return $w
}

proc qc::tabForFile {path} {
    foreach w $::qc::tabs {
        if {$path ne "" && $::qc::TB($w,file) eq $path} {return $w}
    }
    return ""
}

# Fecha a aba (perguntando se há alterações). A última aba não some: vira
# "Sem título".
proc qc::closeTab {w} {
    variable tabs
    variable TB
    if {![winfo exists $w]} {return 1}
    if {[$w edit modified]} {
        activateTab $w
        if {![confirmDiscard]} {return 0}
    }
    set host [winfo parent $w]
    set docked [dockedTabs]
    if {$host eq ".pw.ed" && [llength $docked] == 1} {
        activateTab $w
        variable file ""
        setContent ""
        set ::qc::status "Arquivo fechado"
        return 1
    }
    set i [lsearch -exact $tabs $w]
    set tabs [lreplace $tabs $i $i]
    if {$host eq ".pw.ed"} {
        if {$w eq $::qc::dockCur} {
            set j [lsearch -exact $docked $w]
            set docked [lreplace $docked $j $j]
            activateTab [lindex $docked [expr {min($j, [llength $docked] - 1)}]]
        }
        edDrop $w
        destroy $w
    } else {
        if {$w eq $::qc::ed} {activateTab $::qc::dockCur}
        edDrop $w
        destroy [winfo toplevel $w]
    }
    catch {interp alias {} $w {}}
    array unset TB $w,*
    drawTabs
    return 1
}

proc qc::closeOtherTabs {w} {
    foreach t $::qc::tabs {
        if {$t ne $w && ![closeTab $t]} {break}
    }
    if {[winfo exists $w]} {activateTab $w}
}

# Ctrl+Tab / Ctrl+Shift+Tab (e Ctrl+PgDn / Ctrl+PgUp)
proc qc::cycleTab {d} {
    set tabs [dockedTabs]
    set n [llength $tabs]
    if {$n < 2} {
        if {$n && $::qc::ed ne $::qc::dockCur} {activateTab $::qc::dockCur}
        return
    }
    set i [lsearch -exact $tabs $::qc::dockCur]
    activateTab [lindex $tabs [expr {($i + $d) % $n}]]
}

# Link da saída: volta para a aba onde o programa foi executado.
proc qc::gotoTabLine {w line col} {
    set w [edResolve $w]
    if {[winfo exists $w]} {activateTab $w}
    gotoLine $line $col
}

proc qc::buildTabBar {c} {
    variable C
    set h [expr {[font metrics TkDefaultFont -linespace] + 12}]
    canvas $c -height $h -background $C(trough) -highlightthickness 0 -bd 0 \
        -xscrollincrement 24
    # só redesenha se a largura mudou: drawTabs recria os itens, o que gera
    # <Enter> na aba sob o mouse e pode realimentar <Configure>
    bind $c <Configure> {
        if {%w != [set ::qc::tabBarW]} { set ::qc::tabBarW %w; qc::drawTabs }
    }
    bind $c <MouseWheel> {%W xview scroll [expr {%D > 0 ? -1 : 1}] units}
    catch {bind $c <Button-4> {%W xview scroll -1 units}}
    catch {bind $c <Button-5> {%W xview scroll 1 units}}
    catch {bind $c <Shift-Button-4> {%W xview scroll -1 units}}
    catch {bind $c <Shift-Button-5> {%W xview scroll 1 units}}
    # duplo clique no espaço vazio: novo arquivo
    bind $c <Double-1> {if {[%W find withtag current] eq ""} qc::newFile}

    set m [menu .tabpop -tearoff 0]
    $m add command -label "Fechar" -accelerator Ctrl+F4 \
        -command {qc::closeTab $::qc::tabMenuW}
    $m add command -label "Fechar as outras" \
        -command {qc::closeOtherTabs $::qc::tabMenuW}
    $m add command -label "Desacoplar em nova janela" -accelerator Ctrl+Shift+T \
        -command {qc::undock $::qc::tabMenuW}
    $m add separator
    $m add command -label "Copiar caminho" -command {
        set f $::qc::TB($::qc::tabMenuW,file)
        if {$f ne ""} { clipboard clear; clipboard append $f }
    }
}

proc qc::tabMenu {w X Y} {
    set ::qc::tabMenuW $w
    .tabpop entryconfigure "Copiar caminho" \
        -state [expr {$::qc::TB($w,file) eq "" ? "disabled" : "normal"}]
    tk_popup .tabpop $X $Y
}

set ::qc::tabBarW 0

# Só altera a barra de status se o texto mudou (evita relayout à toa).
proc qc::setStatus {msg} {
    if {$::qc::status ne $msg} {set ::qc::status $msg}
}

proc qc::drawTabs {} {
    variable tabs
    variable TB
    variable C
    set c .pw.ed.tabs
    if {![winfo exists $c]} {return}
    $c delete all
    set h [winfo reqheight $c]
    # nomes repetidos ganham o nome da pasta
    set tails {}
    foreach w $tabs {
        if {$TB($w,file) ne ""} {dict incr tails [file tail $TB($w,file)]}
    }
    set x 0
    set ax0 0
    set ax1 0
    set n 0
    foreach w [dockedTabs] {
        incr n
        set f $TB($w,file)
        set name [expr {$f eq "" ? "Sem título" : [file tail $f]}]
        if {$f ne "" && [dict get $tails [file tail $f]] > 1} {
            append name " — [file tail [file dirname $f]]"
        }
        set act [expr {$w eq $::qc::dockCur}]
        set bg [expr {$act ? $C(edbg) : $C(trough)}]
        set fg [expr {$act ? "#e0e0e0" : "#8a8a8a"}]
        set mod [$w edit modified]
        set cy [expr {$h / 2 + 1}]
        set tt [$c create text [expr {$x + 12}] $cy -anchor w -text $name \
            -fill $fg -font TkDefaultFont -tags [list tab$n]]
        set tx [lindex [$c bbox $tt] 2]
        # O botão de fechar recebe os eventos por uma área fixa; o glifo fica
        # "disabled" (fora da detecção do mouse). ● é mais largo que ×: se o
        # glifo fosse o alvo, com o mouse na borda <Enter> trocaria ● por ×,
        # o mouse ficaria fora, <Leave> voltaria ● e o ciclo não terminaria.
        $c create rectangle [expr {$tx + 5}] 4 [expr {$tx + 23}] [expr {$h - 4}] \
            -fill $bg -outline "" -tags [list cls$n]
        set xx [$c create text [expr {$tx + 14}] $cy -anchor center \
            -text [expr {$mod ? "●" : "×"}] -fill $fg -font TkDefaultFont \
            -state disabled]
        set x1 [expr {$tx + 26}]
        $c create rectangle $x 0 $x1 $h -fill $bg -outline "" -tags [list tab$n]
        $c create line $x1 4 $x1 [expr {$h - 4}] -fill $C(ui)
        if {$act} {
            $c create rectangle $x 0 $x1 2 -fill $C(accent) -outline "" -tags [list tab$n]
            set ax0 $x
            set ax1 $x1
        }
        $c lower tab$n
        $c raise $tt
        $c bind tab$n <1> [list qc::activateTab $w]
        $c bind tab$n <2> [list qc::closeTab $w]
        $c bind tab$n <3> [list qc::tabMenu $w %X %Y]
        $c bind tab$n <Enter> [list qc::setStatus $f]
        $c bind cls$n <1> [list qc::closeTab $w]
        $c bind cls$n <2> [list qc::closeTab $w]
        $c bind cls$n <Enter> [list $c itemconfigure $xx -text × -fill #ffffff]
        $c bind cls$n <Leave> [list $c itemconfigure $xx \
            -text [expr {$mod ? "●" : "×"}] -fill $fg]
        set x [expr {$x1 + 1}]
    }
    # mantém a aba ativa à vista
    set W [winfo width $c]
    $c configure -scrollregion [list 0 0 [expr {max($x, $W)}] $h]
    if {$x <= $W} {
        $c xview moveto 0
    } else {
        set left [expr {[lindex [$c xview] 0] * $x}]
        if {$ax0 < $left} {
            $c xview moveto [expr {double($ax0) / $x}]
        } elseif {$ax1 > $left + $W} {
            $c xview moveto [expr {double($ax1 - $W) / $x}]
        }
    }
}

# ---------------------------------------------------------------------------
# Arquivos
# ---------------------------------------------------------------------------

proc qc::updateTitle {} {
    variable file
    set ::qc::TB($::qc::ed,file) $file
    drawTabs
    if {[winfo parent $::qc::ed] ne ".pw.ed"} {
        floatTitle $::qc::ed
        return
    }
    set name [expr {$file eq "" ? "Sem título" : [file tail $file]}]
    set mod [expr {[$::qc::ed edit modified] ? " •" : ""}]
    set dir [expr {$file eq "" ? "" : "  —  [file dirname $file]"}]
    wm title . "$name$mod$dir  —  qconsole · [lget name]"
}

proc qc::confirmDiscard {} {
    if {![$::qc::ed edit modified]} {return 1}
    set r [tk_messageBox -parent [winfo toplevel $::qc::ed] -icon warning -type yesnocancel \
        -title qconsole -message "Salvar as alterações?" \
        -detail "O arquivo foi modificado."]
    switch -- $r {
        yes {return [save]}
        no {return 1}
        default {return 0}
    }
}

proc qc::setContent {data} {
    variable ed
    multiClear
    foreach t [foldTags] {::qc::_edw tag delete $t}
    $ed delete 1.0 end
    $ed insert 1.0 $data
    $ed edit reset
    $ed edit modified 0
    $ed mark set insert 1.0
    $ed see 1.0
    ::qc::_edw tag remove errline 1.0 end
    ::qc::_edw tag remove warnline 1.0 end
    highlight
    updateTitle
}

proc qc::newFile {} {
    freshTab
    variable file ""
    setContent ""
    set ::qc::status "Novo arquivo ([lget name])"
}

proc qc::newFromTemplate {label} {
    freshTab
    set ver [langVersion]
    variable file ""
    set text [dict get [lget templates] $label]
    if {$ver ne ""} {
        set text [string map [list @VERSION@ $ver] $text]
    } else {
        # versão desconhecida: tira as linhas que dependem dela
        set text [join [lsearch -all -inline -not [split $text \n] *@VERSION@*] \n]
    }
    setContent $text
    set ::qc::status "Modelo $label · Ctrl+R executa"
}

proc qc::closeFile {} {
    closeTab $::qc::ed
}

proc qc::fileTypes {} {
    variable langs
    variable lang
    set out [list [list [lget name] [lget ext]]]
    set seen [list [lget ext]]
    foreach id $langs {
        set ext [lget ext $id]
        if {[llength $ext] && $ext ni $seen} {
            lappend seen $ext
            set name [lget name $id]
            # "Scheme (Kawa)" -> "Scheme" quando outras usam as mesmas extensões
            regsub { \(.*\)$} $name {} name
            lappend out [list $name $ext]
        }
    }
    lappend out {"Todos os arquivos" *}
    return $out
}

# Linguagem de um arquivo pela extensão. Quando várias usam a mesma (as
# implementações de Scheme), decide o hook detect com o conteúdo (data, ou
# lido do arquivo); sem indicação, fica a linguagem atual (keep) ou a
# primeira com interpretador instalado.
proc qc::langForFile {path {data ""} {keep 0}} {
    variable langs
    set ext [string tolower [file extension $path]]
    set cands {}
    foreach id $langs {
        if {$ext in [lget ext $id]} {lappend cands $id}
    }
    if {[llength $cands] < 2} {return [lindex $cands 0]}
    if {$data eq "" && [file isfile $path]} {catch {set data [readFile $path]}}
    foreach id $cands {
        set h [hook detect $id]
        if {$h eq ""} {continue}
        if {![catch {$h $data $path} r] && $r in $cands} {return $r}
        break
    }
    if {$keep && $::qc::lang in $cands} {return $::qc::lang}
    return [firstInstalled $cands]
}

# Primeira das linguagens ids com interpretador encontrado (ou a primeira).
proc qc::firstInstalled {ids} {
    foreach id $ids {
        set rn [currentRunner $id]
        if {$rn ne "" && [findExe $rn $id] ne ""} {return $id}
    }
    return [lindex $ids 0]
}

# Nomes que não estão na lista de linguagens: "scheme" (de configurações
# antigas, -lang scheme, cercas ```scheme) vira a implementação padrão.
proc qc::langAlias {id} {
    if {$id eq "scheme" && $id ni $::qc::langs} {
        set ids [lsearch -all -inline -glob $::qc::langs scheme-*]
        if {[llength $ids]} {return [firstInstalled $ids]}
    }
    return $id
}

proc qc::openFile {{path ""}} {
    variable cfg
    if {$path eq ""} {
        set opts [list -parent . -title "Abrir" -filetypes [fileTypes]]
        if {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
            lappend opts -initialdir $cfg(lastdir)
        }
        set path [tk_getOpenFile {*}$opts]
        if {$path eq ""} {return}
    }
    # já aberto: só muda para a aba dele
    set w [tabForFile [file normalize $path]]
    if {$w ne ""} {
        activateTab $w
        return
    }
    if {[catch {readFile $path} data]} {
        tk_messageBox -parent . -icon error -title qconsole \
            -message "Não foi possível abrir o arquivo." -detail $data
        return
    }
    if {[string index $data end] eq "\n"} {set data [string range $data 0 end-1]}
    freshTab
    variable file [file normalize $path]
    set cfg(lastdir) [file dirname $file]
    set id [langForFile $file $data]
    if {$id ne "" && $id ne $::qc::lang} {setLang $id}
    setContent $data
    addRecent $file
    treeReveal
    set ::qc::status "Aberto: $file"
}

proc qc::save {} {
    variable file
    if {$file eq ""} {return [saveAs]}
    return [fmtAfterSave [saveTo $file]]
}

proc qc::saveAs {} {
    variable cfg
    variable file
    set h [hook defaultExt]
    set ext [expr {$h ne "" ? [$h [$::qc::ed get 1.0 end-1c]] : [lindex [lget ext] 0]}]
    set opts [list -parent . -title "Salvar como" -filetypes [fileTypes]]
    if {$ext ne ""} {lappend opts -defaultextension $ext}
    if {$file ne ""} {
        lappend opts -initialdir [file dirname $file] -initialfile [file tail $file]
    } elseif {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
        lappend opts -initialdir $cfg(lastdir)
    }
    set path [tk_getSaveFile {*}$opts]
    if {$path eq ""} {return 0}
    return [fmtAfterSave [saveTo [file normalize $path]]]
}

# Salva o editor w (padrão: a aba ativa) em path.
proc qc::saveTo {path {w ""}} {
    variable ed
    variable cfg
    variable TB
    if {$w eq ""} {set w $ed}
    set fmtErr [formatOnSave $w]
    set data [$w get 1.0 end-1c]
    if {$data ne "" && [string index $data end] ne "\n"} {append data \n}
    if {[catch {writeFile $path $data} err]} {
        tk_messageBox -parent . -icon error -title qconsole \
            -message "Não foi possível salvar o arquivo." -detail $err
        return 0
    }
    set TB($w,file) $path
    set cfg(lastdir) [file dirname $path]
    $w edit modified 0
    addRecent $path
    if {$w eq $ed} {
        variable file $path
        updateTitle
    } else {
        drawTabs
    }
    if {$cfg(folder) ne "" && [string first [file normalize $cfg(folder)]/ $path] == 0} {
        refreshFolder
    }
    set ::qc::status "Salvo: $path"
    if {$fmtErr ne ""} {append ::qc::status "  (não formatado: $fmtErr)"}
    return 1
}

# --- Formatar ao salvar (cfg(fmtsave.<lang>)) -------------------------------
# Formatador interno (hook reformat): roda antes de gravar, em saveTo.
# Ferramenta externa (tclfmt, scalafmt, ocamlformat…): roda em segundo plano
# depois de um Ctrl+S/Salvar como e, se mudar algo, salva de novo.

# O item do menu Editar segue a linguagem atual.
proc qc::updateFmtSaveMenu {} {
    set m .mb.edit
    set i [$m index "Formatar ao salvar"]
    set ok [expr {[llength [lget formatters]] || [hook reformat] ne ""}]
    $m entryconfigure $i -variable ::qc::cfg(fmtsave.$::qc::lang) \
        -state [expr {$ok ? "normal" : "disabled"}]
}

# Reformata o editor w com o formatador interno da linguagem dele, se a
# opção estiver ligada. Devolve a mensagem de erro do formatador, ou "" (o
# arquivo é salvo de qualquer jeito).
proc qc::formatOnSave {w} {
    set id [expr {[info exists ::qc::TB($w,lang)] ? $::qc::TB($w,lang) : $::qc::lang}]
    if {[lcfg fmtsave $id] ne "1"} {return ""}
    if {$w eq $::qc::ed && [currentTool formatters] ne ""} {return ""}
    set h [hook reformat $id]
    if {$h eq ""} {return ""}
    set old [$w get 1.0 end-1c]
    if {[catch {$h $old} new]} {return $new}
    if {$w eq $::qc::ed} {
        applyFormatted $w $old $new
    } elseif {[string trimright $new \n] ne [string trimright $old \n]} {
        $w replace 1.0 end-1c $new
    }
    return ""
}

# Depois de salvar a aba ativa (ok = resultado de saveTo): dispara a
# ferramenta externa de formatação, se a opção estiver ligada.
proc qc::fmtAfterSave {ok} {
    if {$ok && [lcfg fmtsave] eq "1" && [currentTool formatters] ne ""} {
        formatCode 1
    }
    return $ok
}

proc qc::addRecent {path} {
    variable cfg
    set l [lsearch -all -inline -not -exact $cfg(recent) $path]
    set cfg(recent) [lrange [linsert $l 0 $path] 0 9]
    updateRecentMenu
}

proc qc::addRecentDir {path} {
    variable cfg
    set l [lsearch -all -inline -not -exact $cfg(recentdirs) $path]
    set cfg(recentdirs) [lrange [linsert $l 0 $path] 0 9]
    updateRecentMenu
}

proc qc::updateRecentMenu {} {
    variable cfg
    foreach {m key cmd} {.mb.file.recent recent qc::openFile
                         .mb.file.recentdirs recentdirs qc::openFolder} {
        if {![winfo exists $m]} {continue}
        $m delete 0 end
        foreach p $cfg($key) {
            $m add command -label $p -command [list $cmd $p]
        }
        if {![llength $cfg($key)]} {
            $m add command -label "(vazio)" -state disabled
        } else {
            $m add separator
            $m add command -label "Limpar lista" \
                -command [list apply {k {set ::qc::cfg($k) {}; qc::updateRecentMenu}} $key]
        }
    }
}

proc qc::quit {} {
    variable TB
    variable cfg
    foreach w $::qc::tabs {
        if {[$w edit modified]} {
            activateTab $w
            if {![confirmDiscard]} {return}
        }
    }
    # abas reabertas na próxima vez
    set cfg(tabs) {}
    foreach w $::qc::tabs {
        if {$TB($w,file) ne ""} {lappend cfg(tabs) $TB($w,file)}
    }
    set cfg(tabcur) $TB($::qc::ed,file)
    set cfg(floats) {}
    foreach w $::qc::tabs {
        if {[winfo parent $w] ne ".pw.ed" && $TB($w,file) ne ""} {
            lappend cfg(floats) [list $TB($w,file) [wm geometry [winfo toplevel $w]]]
        }
    }
    stop
    termKill
    saveCfg
    catch {file delete -force [tmpDir]}
    exit
}

# ---------------------------------------------------------------------------
# Console e execução
# ---------------------------------------------------------------------------

proc qc::conAppend {text tag} {
    variable con
    $con configure -state normal
    # linhas enormes (saída sem quebra de linha) deixam o widget text muito
    # lento: quebra a cada 2000 caracteres
    set col [lindex [split [$con index end-1c] .] 1]
    $con insert end [wrapLong $text $col 2000] $tag
    # limita o tamanho do console
    set lines [lindex [split [$con index end] .] 0]
    if {$lines > 50000} {$con delete 1.0 [expr {$lines - 40000}].0}
    $con configure -state disabled
    # rolar a cada pedaço é caro quando a saída é contínua: uma vez por ciclo
    variable conSee
    if {![info exists conSee]} {
        set conSee 1
        after idle {unset ::qc::conSee; $::qc::con see end}
    }
}

# Quebra os trechos de text que passariam de max caracteres numa linha
# (col = caracteres já presentes na linha corrente).
proc qc::wrapLong {text col max} {
    if {$col + [string length $text] <= $max} {return $text}
    set out ""
    foreach seg [split $text \n] {
        while {$col + [string length $seg] > $max} {
            set k [expr {max(0, $max - $col)}]
            append out [string range $seg 0 $k-1] \n
            set seg [string range $seg $k end]
            set col 0
        }
        append out $seg \n
        set col 0
    }
    return [string range $out 0 end-1]
}

proc qc::clearConsole {} {
    variable con
    $con configure -state normal
    $con delete 1.0 end
    $con configure -state disabled
}

proc qc::setRunning {on} {
    # terminal no lugar da saída: volta para a saída ao executar
    if {$on && $::qc::cfg(terminal) && $::qc::cfg(termpos) eq "replace"} {showTerminal 0}
    set s [expr {$on ? "disabled" : "!disabled"}]
    set ns [expr {$on ? "!disabled" : "disabled"}]
    .tb.run state $s
    .tb.stop state $ns
    .mb.script entryconfigure 0 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 1 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 2 -state [expr {$on ? "normal" : "disabled"}]
}

# Nome do arquivo temporário (o do arquivo atual ou script.<ext>) e código
# a executar, com o hook prepare da linguagem. Retorna dict name code mode.
proc qc::prepareCode {code selOnly} {
    variable file
    set exts [lget ext]
    set ext [string tolower [file extension $file]]
    set name [expr {$file ne "" && $ext in $exts ? [file tail $file] : "script[lindex $exts 0]"}]
    set mode ""
    set h [hook prepare]
    if {$h ne ""} {
        set p [$h $code $selOnly $file $name]
        if {[dict exists $p name]} {set name [dict get $p name]}
        if {[dict exists $p code]} {set code [dict get $p code]}
        if {[dict exists $p mode]} {set mode [dict get $p mode]}
    }
    return [dict create name $name code $code mode $mode]
}

# errPatterns (%F = arquivo) -> lista regex nº-de-grupos para o linkify.
proc qc::errPats {patterns name} {
    set pats {}
    set fre "(?:\[^\\s:(\"'\]*\[/\\\\\])?[reQuote $name]"
    foreach p $patterns {
        set p [string map [list %F $fre] $p]
        if {![catch {regexp -about $p} ab]} {lappend pats $p [lindex $ab 0]}
    }
    return $pats
}

proc qc::run {selOnly} {
    variable ed
    variable R
    variable cfg
    variable file
    variable lang
    # linguagens sem execução própria (ex.: Markdown: pré-visualizar)
    set h [hook run]
    if {$h ne ""} {
        $h $selOnly
        return
    }
    if {[info exists R(fd)]} {
        set ::qc::status "Já existe uma execução em andamento (Ctrl+Break para interromper)"
        return
    }
    set lineoff 0
    if {$selOnly} {
        if {![llength [$ed tag ranges sel]]} {
            set ::qc::status "Nenhum texto selecionado"
            return
        }
        set code [$ed get sel.first sel.last]
        set lineoff [expr {[lindex [split [$ed index sel.first] .] 0] - 1}]
    } else {
        set code [$ed get 1.0 end-1c]
    }
    if {$cfg(autoclear)} {clearConsole}
    set rn [currentRunner]
    if {$rn eq ""} {
        conAppend "[lget name]: nenhum interpretador definido.\n" stderr
        return
    }
    set exe [findExe $rn]
    if {$exe eq ""} {
        conAppend "[runnerLabel $rn] não encontrado (procurados: [runnerSearched $rn]).\n" stderr
        conAppend "Indique o executável em Executar > Opções de execução (Ctrl+E).\n" stderr
        return
    }
    ::qc::_edw tag remove errline 1.0 end
    ::qc::_edw tag remove warnline 1.0 end

    set p [prepareCode $code $selOnly]
    set name [dict get $p name]
    set code [dict get $p code]
    set mode [dict get $p mode]
    set disp [expr {$file eq "" ? $name : [file tail $file]}]

    set dir [tmpDir]
    set script [file join $dir $name]
    if {$code ne "" && [string index $code end] ne "\n"} {append code \n}
    writeFile $script $code
    set wrapper ""
    if {[dict exists $rn wrapper]} {
        set wext [expr {[dict exists $rn wrapperExt] ? [dict get $rn wrapperExt] : ""}]
        set wrapper [file join $dir qconsole-wrapper$wext]
        writeFile $wrapper [dict get $rn wrapper]
    }
    set wd [expr {$file eq "" ? [pwd] : [file dirname $file]}]

    set opts [splitArgs [lcfg opts]]
    set pargs [splitArgs [lcfg args]]
    set cmd $exe
    foreach a [dict get $rn args] {
        switch -- $a {
            %F {lappend cmd $script}
            %W {lappend cmd $wrapper}
            %O {lappend cmd {*}$opts}
            %A {lappend cmd {*}$pargs}
            %--A {if {[llength $pargs]} {lappend cmd -- {*}$pargs}}
            default {lappend cmd $a}
        }
    }

    lassign [chan pipe] er ew
    set old [pwd]
    catch {cd $wd}
    set rc [catch {open |[list {*}$cmd 2>@ $ew] r+} fd]
    cd $old
    if {$rc} {
        close $er; close $ew
        conAppend "Erro ao iniciar [runnerLabel $rn]: $fd\n" stderr
        return
    }
    close $ew
    catch {chan close $fd write}
    foreach c [list $fd $er] {
        fconfigure $c -blocking 0 -buffering none -translation auto
        setEncoding $c
    }
    # parâmetros de saída da linguagem/runner (o runner pode sobrepor)
    set d [dict merge [ldict] $rn]
    set pats [errPats [dict get $d errPatterns] $name]
    set nlines [llength [split [string trimright $code \n] \n]]
    array set R [list fd $fd er $er open 2 t0 [clock milliseconds] lang $lang \
        lineoff $lineoff script $script name $name disp $disp nlines $nlines \
        pats $pats col0 [dict get $d col0] infoRe [dict get $d infoRe] \
        warnRe [dict get $d warnRe] grayInfo [dict get $d grayInfo] \
        killed 0 pend "" sgr {} pid [lindex [pid $fd] 0] proj "" \
        ed $ed]
    chan event $fd readable [list qc::onStdout $fd]
    chan event $er readable [list qc::onStderr $er]

    set what [expr {$selOnly ? "seleção de $disp (a partir da linha [expr {$lineoff + 1}])" : $disp}]
    set info [list $what [runnerLabel $rn]]
    if {$mode ne ""} {lappend info $mode}
    lappend info [clock format [clock seconds] -format %H:%M:%S]
    conAppend "▶ [join $info {  ·  }]\n" info
    setRunning 1
    set ::qc::status "Executando…"
}

proc qc::onStdout {fd} {
    # em blocos: com saída contínua a interface continua respondendo
    set data [read $fd 65536]
    if {$data ne ""} {
        conAnsi $data stdout
        if {$::qc::R(proj) ne ""} {projScan}
    }
    if {[eof $fd]} {
        chan event $fd readable {}
        streamClosed
    }
}

# Texto com sequências ANSI SGR (cores/negrito) -> tags do console.
proc qc::conAnsi {data base} {
    variable R
    set data $R(pend)$data
    set R(pend) ""
    # sequência incompleta no fim do bloco: guarda para o próximo
    if {[regexp -indices {\x1b(?:\[[0-9;?]*)?$} $data m]} {
        set R(pend) [string range $data [lindex $m 0] end]
        set data [string range $data 0 [lindex $m 0]-1]
    }
    set pos 0
    foreach {m p f} [regexp -all -inline -indices {\x1b\[([0-9;?]*)([A-Za-z])} $data] {
        if {[lindex $m 0] > $pos} {
            conAppend [string range $data $pos [lindex $m 0]-1] [list $base {*}$R(sgr)]
        }
        set pos [expr {[lindex $m 1] + 1}]
        if {[string range $data {*}$f] ne "m"} {continue}
        foreach c [split [string range $data {*}$p] ";"] {
            if {$c ne "" && ![string is integer -strict $c]} {continue}
            if {$c eq "" || $c == 0} {
                set R(sgr) {}
            } elseif {$c == 1} {
                lappend R(sgr) ansiB
            } elseif {$c == 22} {
                set R(sgr) [lsearch -all -inline -not -exact $R(sgr) ansiB]
            } elseif {($c >= 30 && $c <= 37) || ($c >= 90 && $c <= 97) || $c == 39} {
                set R(sgr) [lsearch -all -inline -not -glob $R(sgr) {ansi[0-9]*}]
                if {$c != 39} {lappend R(sgr) ansi$c}
            }
        }
    }
    if {$pos < [string length $data]} {
        conAppend [string range $data $pos end] [list $base {*}$R(sgr)]
    }
}

proc qc::onStderr {er} {
    # com tempo limitado: um programa que escreve sem parar no stderr
    # (ex.: recursão infinita com mensagens) não pode prender a interface
    # neste laço; o que sobrar no canal dispara o evento de novo
    set t0 [clock milliseconds]
    while {[clock milliseconds] - $t0 < 30 && [gets $er line] >= 0} {
        if {$::qc::R(proj) ne ""} {
            conAnsi $line\n stderr
            projScan
        } else {
            errLine $line
        }
    }
    if {[eof $er]} {
        chan event $er readable {}
        streamClosed
    }
}

# Uma linha do stderr: hook stderrLine da linguagem (que devolve pares
# tag/texto, ou "-" para o tratamento padrão) ou classificação por regex.
proc qc::errLine {raw} {
    variable R
    set h [hook stderrLine $R(lang)]
    if {$h ne ""} {
        set res [$h $raw]
        if {$res ne "-"} {
            foreach {tag text} $res {linkify $text $tag}
            return
        }
    }
    # barras de progresso: fica só com o último trecho após \r
    set k [string last \r $raw]
    if {$k >= 0} {set raw [string range $raw $k+1 end]}
    set gray [string match "*\x1b\\\[90m*" $raw]
    set line [string map [list [tmpDir]/ ""] [stripAnsi $raw]]
    if {$R(warnRe) ne "" && [regexp -- $R(warnRe) $line]} {
        set tag warn
    } elseif {($R(grayInfo) && $gray) || ($R(infoRe) ne "" && [regexp -- $R(infoRe) $line])} {
        set tag info
    } else {
        set tag stderr
    }
    linkify $line $tag
}

# Troca referências ao arquivo temporário (padrões errPatterns da linguagem)
# por links clicáveis para a linha correspondente no editor.
# ctx: array com o estado (o da execução, ou o da verificação/formatação).
# Retorna o número de referências encontradas.
proc qc::linkify {line tag {ctx ::qc::R}} {
    upvar #0 $ctx R
    variable con
    variable linkSeq
    set hits {}
    foreach {pat ng} $R(pats) {
        set m [regexp -all -inline -indices -- $pat $line]
        set step [expr {$ng + 1}]
        for {set i 0} {$i < [llength $m]} {incr i $step} {
            set whole [lindex $m $i]
            set lg [expr {$ng >= 1 ? [lindex $m $i+1] : {-1 -1}}]
            set cg [expr {$ng >= 2 ? [lindex $m $i+2] : {-1 -1}}]
            if {[lindex $lg 0] >= 0} {lappend hits [list {*}$whole {*}$lg {*}$cg]}
        }
    }
    set pos 0
    set nlinks 0
    foreach h [lsort -integer -index 0 $hits] {
        lassign $h ms me ls le cs ce
        if {$ms < $pos} {continue}
        set n [string range $line $ls $le]
        # linhas além do fim são de código gerado pelo interpretador/wrapper
        # (a linha seguinte à última é aceita: "fim inesperado do arquivo")
        if {$n < 1 || $n > $R(nlines) + 1} {continue}
        set target [expr {min($n, max($R(nlines), 1)) + $R(lineoff)}]
        set col 0
        if {$cs >= 0} {
            set col [string range $line $cs $ce]
            if {!$R(col0)} {incr col -1}
            if {$col < 0} {set col 0}
        }
        # troca o caminho do temporário pelo nome exibido e a linha pela real
        set segs [list [list $ls $le $target]]
        set k [string first $R(name) [string range $line $ms $me]]
        if {$k >= 0} {
            set ps [expr {$ms + $k}]
            set pe [expr {$ps + [string length $R(name)] - 1}]
            while {$ps > $ms && [string index $line $ps-1] ni {" " "\t" : ( \" '}} {incr ps -1}
            lappend segs [list $ps $pe $R(disp)]
        }
        set txt ""
        set p $ms
        foreach s [lsort -integer -index 0 $segs] {
            lassign $s a z rep
            append txt [string range $line $p $a-1] $rep
            set p [expr {$z + 1}]
        }
        append txt [string range $line $p $me]
        conAppend [string range $line $pos $ms-1] $tag
        set lt link[incr linkSeq]
        incr nlinks
        conAppend $txt [list $tag link $lt]
        $con tag bind $lt <1> [list qc::gotoTabLine $R(ed) $target $col]
        set pos [expr {$me + 1}]
        if {$tag eq "warn" && [winfo exists $R(ed)]} {
            $R(ed) tag add warnline $target.0 "$target.0 lineend +1c"
        }
        if {$tag eq "stderr" && [winfo exists $R(ed)]} {
            $R(ed) tag add errline $target.0 "$target.0 lineend +1c"
        }
    }
    conAppend [string range $line $pos end]\n $tag
    return $nlinks
}

proc qc::streamClosed {} {
    variable R
    if {[incr R(open) -1] > 0} {return}
    set fd $R(fd)
    fconfigure $fd -blocking 1
    set code 0
    if {[catch {close $fd} msg opts]} {
        set ec [dict get $opts -errorcode]
        switch -- [lindex $ec 0] {
            CHILDSTATUS {set code [lindex $ec 2]}
            CHILDKILLED {set code [lindex $ec 2]}
            default {set code "?"}
        }
    }
    catch {close $R(er)}
    if {$R(proj) ne ""} {
        if {[$::qc::con get end-2c] ne "\n"} {conAppend \n stdout}
        projScan
    }
    set secs [expr {([clock milliseconds] - $R(t0)) / 1000.0}]
    if {$R(killed)} {
        conAppend "■ Interrompido após [format %.3f $secs] s\n" stderr
        set ::qc::status "Interrompido"
    } else {
        set tag [expr {$code eq "0" ? "info" : "stderr"}]
        conAppend "■ Finalizado em [format %.3f $secs] s (código de saída $code)\n" $tag
        set ::qc::status "Finalizado em [format %.3f $secs] s"
    }
    array unset R
    setRunning 0
}

# Processos filhos (launchers como o do scala disparam outros processos).
proc qc::descendants {pid} {
    set out {}
    if {![catch {exec pgrep -P $pid} kids]} {
        foreach k $kids {lappend out $k {*}[descendants $k]}
    }
    return $out
}

proc qc::stop {} {
    variable R
    if {![info exists R(pid)]} {return}
    set R(killed) 1
    if {$::tcl_platform(platform) eq "windows"} {
        catch {exec {*}[auto_execok taskkill] /F /T /PID $R(pid)}
        return
    }
    set all [linsert [descendants $R(pid)] 0 $R(pid)]
    catch {exec kill {*}$all}
    # processos que demoram a sair (ex.: JVM): força após 3 s
    # tclint-disable-next-line command-args
    after 3000 [list apply {{all t0} {
        if {[info exists ::qc::R(t0)] && $::qc::R(t0) == $t0} {
            catch {exec kill -9 {*}$all}
        }
    }} $all $R(t0)]
}

# ---------------------------------------------------------------------------
# Verificação (linter) e formatação
# ---------------------------------------------------------------------------
# Chaves "linters" e "formatters" da linguagem: listas de dicionários
#   name label exe args       como nos runners; nos args: %F arquivo,
#                             %C opção de configuração, %O opções do runner,
#                             %S script auxiliar, %D pasta temporária,
#                             %R pasta do arquivo, %N caminho do arquivo
#                             original (ou <pasta>/<nome> se não salvo)
#   runner                    só vale com esse runner (ex.: guile, chez)
#   useRunner 1               usa o executável do runner corrente
#   nearRunner 1              procura exe primeiro na pasta do executável
#                             do runner (ex.: switch do opam), depois no PATH
#   script scriptExt          script auxiliar gravado na pasta temporária
#   config configArg          arquivos de configuração procurados da pasta
#                             do arquivo para cima; configArg com %P = caminho
#   noConfigArg               %C quando nenhum desses arquivos existe
#   optsKeep                  só estas opções do runner vão para %O
#                             (opção -> nº de valores)
#   output stdout|inplace     (formatador) resultado na saída ou no arquivo
#   errPatterns col0          como na linguagem (padrão: os dela)
#   warnRe errRe infoRe       classificação das linhas (aviso/erro/info);
#   tag                       linhas não classificadas: herdam a anterior,
#                             começando por "tag" (padrão stderr)
#   groupRe                   linha que inicia uma mensagem: todas as linhas
#                             dela recebem a classificação achada nela
#                             (quando o "Warning"/"Error" vem depois do local)
#   ignoreRe                  linhas descartadas
# Sem formatador externo, o hook "reformat" da linguagem (texto -> texto).

# Ferramenta corrente do tipo kind (linters/formatters): a primeira instalada
# ou, se nenhuma estiver, a primeira; "" se não houver.
proc qc::currentTool {kind} {
    set rn [currentRunner]
    set rname [expr {$rn eq "" ? "" : [dict get $rn name]}]
    set first ""
    foreach t [lget $kind] {
        if {[dict exists $t runner] && [dict get $t runner] ne $rname} {continue}
        if {[toolExe $t] ne ""} {return $t}
        if {$first eq ""} {set first $t}
    }
    return $first
}

proc qc::toolGet {t key {def ""}} {
    return [expr {[dict exists $t $key] ? [dict get $t $key] : $def}]
}

# Executável: opção exe.<nome> da configuração, o do runner (useRunner) ou
# busca no PATH.
proc qc::toolExe {t} {
    set user [lcfg exe.[dict get $t name]]
    if {$user ne ""} {return [list $user]}
    if {[toolGet $t useRunner 0]} {
        set rn [currentRunner]
        return [expr {$rn eq "" ? "" : [findExe $rn]}]
    }
    if {[toolGet $t nearRunner 0]} {
        set rn [currentRunner]
        set rexe [expr {$rn eq "" ? "" : [lindex [findExe $rn] 0]}]
        if {$rexe ne "" && [file pathtype $rexe] ne "relative"} {
            set dir [file dirname $rexe]
            foreach n [toolGet $t exe] {
                foreach c [list [file join $dir $n] [file join $dir $n.exe]] {
                    if {[file isfile $c] && [file executable $c]} {return [list $c]}
                }
            }
        }
    }
    foreach n [toolGet $t exe] {
        set p [auto_execok $n]
        if {$p ne ""} {return $p}
    }
    return ""
}

proc qc::toolMissing {t} {
    if {[toolGet $t useRunner 0]} {
        set rn [currentRunner]
        set what [expr {$rn eq "" ? "" : " (procurados: [runnerSearched $rn])"}]
    } else {
        set what " (procurados: [join [toolGet $t exe] {, }])"
    }
    conAppend "[runnerLabel $t] não encontrado$what.\n" stderr
    set ::qc::status "[runnerLabel $t] não encontrado"
}

# Primeiro dos arquivos names achado de dir para cima, ou "".
proc qc::findUp {dir names} {
    set dir [file normalize $dir]
    while 1 {
        foreach n $names {
            set p [file join $dir $n]
            if {[file isfile $p]} {return $p}
        }
        set up [file dirname $dir]
        if {$up eq $dir} {return ""}
        set dir $up
    }
}

# Linha de comando da ferramenta para o arquivo path (wd = pasta do original).
proc qc::toolCmd {t exe path wd} {
    set dir [file dirname $path]
    set orig [expr {$::qc::file ne "" ? $::qc::file : [file join $wd [file tail $path]]}]
    set map [list %D $dir %R $wd %N $orig]
    set conf [findUp $wd [toolGet $t config]]
    if {$conf ne ""} {
        set cargs [lmap a [toolGet $t configArg] {string map [list %P $conf {*}$map] $a}]
    } else {
        set cargs [lmap a [toolGet $t noConfigArg] {string map $map $a}]
    }
    set script ""
    if {[dict exists $t script]} {
        set script [file join $dir qconsole-[dict get $t name][toolGet $t scriptExt]]
        writeFile $script [dict get $t script]
    }
    set opts [splitArgs [lcfg opts]]
    if {[dict exists $t optsKeep]} {
        set keep [dict get $t optsKeep]
        set o {}
        for {set i 0} {$i < [llength $opts]} {incr i} {
            set a [lindex $opts $i]
            if {[dict exists $keep $a]} {
                set n [dict get $keep $a]
                lappend o {*}[lrange $opts $i [expr {$i + $n}]]
                incr i $n
            }
        }
        set opts $o
    }
    set cmd $exe
    foreach a [dict get $t args] {
        switch -- $a {
            %F {lappend cmd $path}
            %C {lappend cmd {*}$cargs}
            %O {lappend cmd {*}$opts}
            %S {lappend cmd $script}
            default {lappend cmd [string map $map $a]}
        }
    }
    return $cmd
}

# Grava o texto do editor em <tmp>/<sub>/<nome> e prepara o array ctx (o
# estado usado pelo linkify). Retorna o caminho gravado.
proc qc::toolSetup {ctx sub t code} {
    upvar #0 $ctx X
    variable file
    variable ed
    set name [dict get [prepareCode $code 0] name]
    set dir [file join [tmpDir] $sub]
    file mkdir $dir
    set path [file join $dir $name]
    if {$code ne "" && [string index $code end] ne "\n"} {append code \n}
    writeFile $path $code
    set pats [errPats [toolGet $t errPatterns [lget errPatterns]] $name]
    array unset X
    array set X [list ed $ed tool $t name $name dir $dir code $code lineoff 0 \
        disp [expr {$file eq "" ? $name : [file tail $file]}] \
        nlines [llength [split [string trimright $code \n] \n]] \
        pats $pats col0 [toolGet $t col0 [lget col0]] \
        t0 [clock milliseconds]]
    return $path
}

# Executa cmd em segundo plano (stdout e stderr separados) e, ao terminar,
# chama {*}$done código stdout stderr.
proc qc::toolExec {cmd wd done} {
    variable TX
    lassign [chan pipe] er ew
    set old [pwd]
    catch {cd $wd}
    set rc [catch {open |[list {*}$cmd 2>@ $ew] r+} fd]
    cd $old
    close $ew
    if {$rc} {
        close $er
        {*}$done -1 "" $fd
        return
    }
    catch {chan close $fd write}
    foreach c [list $fd $er] {
        fconfigure $c -blocking 0 -translation auto
        setEncoding $c
    }
    set id [incr ::qc::toolSeq]
    set TX($id) [dict create out "" err "" open 2 fd $fd er $er done $done]
    chan event $fd readable [list qc::toolRead $id $fd out]
    chan event $er readable [list qc::toolRead $id $er err]
}

proc qc::toolRead {id ch key} {
    variable TX
    dict append TX($id) $key [read $ch]
    if {![eof $ch]} {return}
    chan event $ch readable {}
    dict incr TX($id) open -1
    if {[dict get $TX($id) open] > 0} {return}
    set t $TX($id)
    unset TX($id)
    set fd [dict get $t fd]
    fconfigure $fd -blocking 1
    set code 0
    if {[catch {close $fd} msg opts]} {
        set ec [dict get $opts -errorcode]
        set code [expr {[lindex $ec 0] in {CHILDSTATUS CHILDKILLED} ? [lindex $ec 2] : "?"}]
    }
    catch {close [dict get $t er]}
    {*}[dict get $t done] $code [dict get $t out] [dict get $t err]
}

# Saída da ferramenta no console, com links para as linhas citadas.
# Retorna o número de referências (problemas) encontradas.
proc qc::toolOutput {ctx out err} {
    upvar #0 $ctx X
    set t $X(tool)
    set warnRe [toolGet $t warnRe]
    set errRe [toolGet $t errRe]
    set infoRe [toolGet $t infoRe]
    set ignoreRe [toolGet $t ignoreRe]
    set groupRe [toolGet $t groupRe]
    set cur [toolGet $t tag stderr]
    set n 0
    set lines {}
    foreach raw [concat [split [string trimright $out] \n] [split [string trimright $err] \n]] {
        set k [string last \r $raw]
        if {$k >= 0} {set raw [string range $raw $k+1 end]}
        set line [string map [list $X(dir)/ "" [tmpDir]/ ""] [stripAnsi $raw]]
        if {[string trim $line] eq ""} {continue}
        if {$ignoreRe ne "" && [regexp -- $ignoreRe $line]} {continue}
        lappend lines $line
    }
    if {$groupRe ne ""} {
        # mensagens em grupos: a classificação vale para o grupo inteiro
        set groups {}
        foreach line $lines {
            if {![llength $groups] || [regexp -- $groupRe $line]} {
                lappend groups [list $line]
            } else {
                lset groups end [list {*}[lindex $groups end] $line]
            }
        }
        foreach g $groups {
            set tag [toolGet $t tag stderr]
            foreach line $g {
                if {$warnRe ne "" && [regexp -- $warnRe $line]} {
                    set tag warn
                    break
                }
                if {$errRe ne "" && [regexp -- $errRe $line]} {
                    set tag stderr
                    break
                }
            }
            foreach line $g {incr n [linkify $line $tag $ctx]}
        }
        return $n
    }
    foreach line $lines {
        if {$warnRe ne "" && [regexp -- $warnRe $line]} {
            set tag [set cur warn]
        } elseif {$errRe ne "" && [regexp -- $errRe $line]} {
            set tag [set cur stderr]
        } elseif {$infoRe ne "" && [regexp -- $infoRe $line]} {
            set tag info
        } else {
            set tag $cur
        }
        incr n [linkify $line $tag $ctx]
    }
    return $n
}

proc qc::toolHeader {verb ctx} {
    upvar #0 $ctx X
    if {$::qc::cfg(autoclear) && ![info exists ::qc::R(fd)]} {clearConsole}
    set when [clock format [clock seconds] -format %H:%M:%S]
    conAppend "▶ $verb $X(disp)  ·  [runnerLabel $X(tool)]  ·  $when\n" info
}

proc qc::toolSecs {ctx} {
    upvar #0 $ctx X
    return [format %.3f [expr {([clock milliseconds] - $X(t0)) / 1000.0}]]
}

# --- verificação (linter) ---------------------------------------------------

proc qc::lint {} {
    variable ed
    variable LT
    variable file
    if {[info exists LT(ed)]} {
        set ::qc::status "Já existe uma verificação em andamento"
        return
    }
    set t [currentTool linters]
    if {$t eq ""} {
        set ::qc::status "[lget name]: nenhum verificador (linter) disponível"
        return
    }
    set exe [toolExe $t]
    if {$exe eq ""} {toolMissing $t; return}
    set path [toolSetup ::qc::LT lint $t [$ed get 1.0 end-1c]]
    set wd [expr {$file eq "" ? [pwd] : [file dirname $file]}]
    foreach tg {errline warnline} {$ed tag remove $tg 1.0 end}
    toolHeader Verificando ::qc::LT
    set ::qc::status "Verificando…"
    toolExec [toolCmd $t $exe $path $wd] $wd qc::lintDone
}

proc qc::lintDone {code out err} {
    variable LT
    set n [toolOutput ::qc::LT $out $err]
    set secs [toolSecs ::qc::LT]
    if {$n > 0} {
        set msg "$n problema(s) encontrado(s)"
        conAppend "■ $msg em $secs s\n" warn
    } elseif {$code eq "0"} {
        set msg "Nenhum problema encontrado"
        conAppend "■ $msg ($secs s)\n" info
    } else {
        set msg "[runnerLabel $LT(tool)] terminou com código de saída $code"
        conAppend "■ $msg\n" stderr
    }
    set ::qc::status $msg
    array unset LT
}

# --- formatação -------------------------------------------------------------

# onSave: chamado por "Formatar ao salvar" (sem mensagens na saída; salva de
# novo ao terminar).
proc qc::formatCode {{onSave 0}} {
    variable ed
    variable FT
    variable file
    if {[info exists FT(ed)]} {
        if {!$onSave} {set ::qc::status "Já existe uma formatação em andamento"}
        return
    }
    set code [$ed get 1.0 end-1c]
    set t [currentTool formatters]
    if {$t eq ""} {
        set h [hook reformat]
        if {$h eq ""} {
            set ::qc::status "[lget name]: nenhum formatador disponível"
            return
        }
        if {[catch {$h $code} new]} {
            set ::qc::status "Erro ao formatar: $new"
            return
        }
        applyFormatted $ed $code $new
        return
    }
    set exe [toolExe $t]
    if {$exe eq ""} {
        if {$onSave} {
            append ::qc::status "  ([runnerLabel $t] não encontrado: não formatado)"
        } else {
            toolMissing $t
        }
        return
    }
    set path [toolSetup ::qc::FT fmt $t $code]
    set FT(orig) $code
    set FT(path) $path
    set FT(save) $onSave
    set wd [expr {$file eq "" ? [pwd] : [file dirname $file]}]
    set ::qc::status "Formatando com [runnerLabel $t]…"
    toolExec [toolCmd $t $exe $path $wd] $wd qc::formatDone
}

proc qc::formatDone {code out err} {
    variable FT
    set ed $FT(ed)
    set orig $FT(orig)
    if {$FT(save)} {
        formatSaveDone $code $out
        array unset FT
        return
    }
    if {$code ne "0"} {
        toolHeader Formatando ::qc::FT
        toolOutput ::qc::FT $out $err
        conAppend "■ [runnerLabel $FT(tool)] terminou com código de saída $code\n" stderr
        set ::qc::status "Erro ao formatar (veja a saída)"
    } elseif {![winfo exists $ed] || $ed ne $::qc::ed} {
        set ::qc::status "Formatação descartada: a aba mudou"
    } elseif {[$ed get 1.0 end-1c] ne $orig} {
        set ::qc::status "Formatação descartada: o texto mudou durante a formatação"
    } else {
        set new [expr {[toolGet $FT(tool) output stdout] eq "stdout" ? $out : [readFile $FT(path)]}]
        applyFormatted $ed $orig $new
    }
    array unset FT
}

# Fim da formatação disparada por "Formatar ao salvar": aplica e salva de
# novo, só se a aba e o texto ainda forem os mesmos.
proc qc::formatSaveDone {code out} {
    variable FT
    set ed $FT(ed)
    set f [expr {[winfo exists $ed] ? $::qc::TB($ed,file) : ""}]
    if {$code ne "0"} {
        set ::qc::status "Salvo: $f  (não formatado: [runnerLabel $FT(tool)]\
            terminou com código $code; Ctrl+Shift+F mostra os erros)"
        return
    }
    if {$ed ne $::qc::ed || [$ed get 1.0 end-1c] ne $FT(orig) || $f eq ""} return
    set new [expr {[toolGet $FT(tool) output stdout] eq "stdout" ? $out : [readFile $FT(path)]}]
    applyFormatted $ed $FT(orig) $new
    if {[$ed edit modified]} {
        saveTo $f
        set ::qc::status "Salvo e formatado: $f"
    } else {
        set ::qc::status "Salvo: $f"
    }
}

# Troca o texto old pelo formatado new mexendo só no que mudou (um passo de
# desfazer) e mantém o cursor na mesma linha.
proc qc::applyFormatted {ed old new} {
    if {[string index $old end] eq "\n"} {
        set new [string trimright $new \n]\n
    } else {
        set new [string trimright $new \n]
    }
    if {$new eq $old} {
        set ::qc::status "O código já está formatado"
        return
    }
    multiClear
    set ol [split $old \n]
    set nl [split $new \n]
    lassign [split [$ed index insert] .] cl cc
    atomic {
        if {[llength $ol] == [llength $nl]} {
            # mesmas linhas (só indentação/espaços): troca linha a linha
            set i 0
            foreach a $ol b $nl {
                incr i
                if {$a eq $b} {continue}
                $ed replace $i.0 "$i.0 lineend" $b
                if {$i == $cl} {
                    regexp {^[ \t]*} $a ia
                    regexp {^[ \t]*} $b ib
                    set ia [string length $ia]
                    set ib [string length $ib]
                    set cc [expr {$cc <= $ia ? min($cc, $ib) : max($ib, $cc + $ib - $ia)}]
                }
            }
        } else {
            # troca só o trecho entre as linhas iguais do início e do fim
            set no [llength $ol]
            set nn [llength $nl]
            set lim [expr {min($no, $nn) - 1}]
            set p 0
            while {$p < $lim && [lindex $ol $p] eq [lindex $nl $p]} {incr p}
            set s 0
            while {$p + $s < $lim && [lindex $ol end-$s] eq [lindex $nl end-$s]} {incr s}
            set pre [string length [join [lrange $ol 0 $p-1] \n]]
            if {$p > 0} {incr pre}
            set suf 0
            if {$s > 0} {
                set suf [expr {[string length [join [lrange $ol end-[expr {$s - 1}] end] \n]] + 1}]
            }
            set mid [string range $new $pre end-$suf]
            $ed replace "1.0 + $pre chars" "1.0 + [expr {[string length $old] - $suf}] chars" $mid
            if {$cl > $no - $s} {
                incr cl [expr {$nn - $no}]
            } elseif {$cl > $p} {
                set cl [expr {min($cl, $nn - $s)}]
            }
        }
    }
    $ed mark set insert $cl.$cc
    $ed see insert
    set ::qc::status "Código formatado"
}

# ---------------------------------------------------------------------------
# Terminal embutido
# ---------------------------------------------------------------------------
# Um emulador de terminal (xterm por padrão) roda incorporado num frame
# contêiner (requer X11). Fica ao lado da saída ou no lugar dela
# (cfg(termpos) = side | replace). cfg(termcmd) troca o comando; nele
# %W é o id da janela contêiner e %D a pasta inicial. Ex.:
#   urxvt -embed %W -cd %D        st -w %W
# O xterm é aberto bem maior que o painel e o Tk o reduz ao tamanho do
# contêiner (uma janela embutida não cresce além do tamanho inicial).

proc qc::buildTerminal {} {
    variable C
    set f [ttk::frame .pw.term]
    ttk::frame $f.head -style Head.TFrame
    ttk::label $f.head.l -text "Terminal" -style Head.TLabel -anchor w
    ttk::button $f.head.o -text "Saída" -style Head.TButton -takefocus 0 \
        -command {qc::showTerminal 0}
    ttk::button $f.head.r -text ⟳ -style Head.TButton -takefocus 0 \
        -command qc::termRestart
    ttk::button $f.head.x -text ✕ -style Head.TButton -takefocus 0 \
        -command {qc::showTerminal 0}
    pack $f.head.x $f.head.r -side right
    pack $f.head.l -side left -fill x -expand 1
    grid $f.head -sticky ew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure $f 1 -weight 1
    termContainer
}

# O Tk destrói o contêiner quando a janela embutida some (ex.: "exit" no
# shell); por isso ele é recriado a cada novo terminal.
proc qc::termContainer {} {
    set c .pw.term.c
    if {[winfo exists $c]} {return $c}
    frame $c -container 1 -background $::qc::C(conbg) -bd 0 -highlightthickness 0
    grid $c -row 1 -column 0 -sticky nsew
    # o teclado vai para o terminal enquanto o ponteiro estiver sobre ele
    # (é assim que o X entrega as teclas a uma janela embutida)
    bind $c <Enter> {qc::termHover 1 %d}
    bind $c <Leave> {qc::termHover 0 %d}
    return $c
}

proc qc::termHover {in detail} {
    variable T
    if {$detail eq "NotifyInferior"} {return}
    set c .pw.term.c
    if {$in} {
        if {[focus] ne $c} {set T(prevfocus) [focus]}
        focus $c
    } elseif {[focus] eq $c} {
        set p [expr {[info exists T(prevfocus)] ? $T(prevfocus) : ""}]
        if {$p eq "" || ![winfo exists $p] || ![winfo ismapped $p]} {set p $::qc::ed}
        focus $p
    }
}

proc qc::showTerminal {on} {
    set ::qc::cfg(terminal) $on
    applyTerminal
}

# Ctrl+' / Exibir > Terminal
proc qc::toggleTerminal {} {
    showTerminal [expr {!$::qc::cfg(terminal)}]
}

proc qc::applyTerminal {} {
    variable cfg
    if {$cfg(termpos) ni {side replace}} {set cfg(termpos) side}
    set want .pw.co
    if {$cfg(terminal)} {
        set want [expr {$cfg(termpos) eq "replace" ? ".pw.term" : ".pw.co .pw.term"}]
    }
    if {[.pw.bot panes] ne $want} {
        foreach p [.pw.bot panes] {.pw.bot forget $p}
        foreach p $want {.pw.bot add $p -weight 1}
        if {[llength $want] > 1} {
            update idletasks
            catch {.pw.bot sashpos 0 [expr {[winfo width .pw] / 2}]}
        }
    }
    if {$cfg(terminal) && ![termStart]} {
        set cfg(terminal) 0
        applyTerminal
        return
    }
    if {$cfg(terminal)} {
        pack forget .pw.co.head.t
    } else {
        pack .pw.co.head.t -side right -before .pw.co.head.l
        if {[string match .pw.term* [focus]]} {focus $::qc::ed}
    }
    if {$cfg(termpos) eq "replace"} {
        pack .pw.term.head.o -side right -after .pw.term.head.r
    } else {
        pack forget .pw.term.head.o
    }
}

# Pasta inicial: a pasta aberta, a do arquivo atual ou a pasta pessoal.
proc qc::termDir {} {
    variable cfg
    if {$cfg(folder) ne "" && [file isdirectory $cfg(folder)]} {return $cfg(folder)}
    if {$::qc::file ne ""} {return [file dirname [file normalize $::qc::file]]}
    return [homeDir]
}

proc qc::termDefaultCmd {wid} {
    variable C
    variable cfg
    return [list xterm -into $wid +sb -geometry 400x150 -title qconsole \
        -bg $C(conbg) -fg $C(confg) -fa [font actual QcMono -family] -fs $cfg(fontsize) \
        -xrm "XTerm*cursorColor: $C(caret)" -xrm "XTerm*internalBorder: 4" \
        -xrm "XTerm*borderWidth: 0" -xrm "XTerm*metaSendsEscape: true" \
        -xrm "XTerm*selectToClipboard: true"]
}

proc qc::termStart {} {
    variable T
    variable cfg
    if {[info exists T(chan)]} {return 1}
    if {[tk windowingsystem] ne "x11"} {
        set ::qc::status "O terminal embutido requer X11"
        return 0
    }
    set c [termContainer]
    update idletasks
    set wid [winfo id $c]
    set dir [termDir]
    if {[string trim $cfg(termcmd)] ne ""} {
        set cmd [string map [list %W $wid %D [list $dir]] $cfg(termcmd)]
        if {[catch {llength $cmd}]} {
            set ::qc::status "Comando do terminal inválido: $cfg(termcmd)"
            return 0
        }
    } elseif {[auto_execok xterm] eq ""} {
        set ::qc::status "xterm não encontrado (Exibir > Comando do terminal…)"
        return 0
    } else {
        set cmd [termDefaultCmd $wid]
    }
    set old [pwd]
    catch {cd $dir}
    set rc [catch {open |[list {*}$cmd 2>@1] r} ch]
    cd $old
    if {$rc} {
        conAppend "Erro ao abrir o terminal: $ch\n" stderr
        return 0
    }
    fconfigure $ch -blocking 0
    chan event $ch readable [list qc::termRead $ch]
    set T(chan) $ch
    set T(pid) [pid $ch]
    return 1
}

# Mensagens do emulador vão para a saída; no fim (ex.: "exit" no shell)
# o painel do terminal é fechado.
proc qc::termRead {ch} {
    variable T
    set d [read $ch]
    if {[string trim $d] ne ""} {conAppend "terminal: $d" stderr}
    if {![eof $ch]} {return}
    catch {close $ch}
    if {[info exists T(chan)] && $T(chan) eq $ch} {
        unset T(chan) T(pid)
        showTerminal 0
    }
}

proc qc::termKill {} {
    variable T
    if {![info exists T(chan)]} {return}
    set ch $T(chan)
    set pids $T(pid)
    unset T(chan) T(pid)
    chan event $ch readable {}
    catch {exec kill {*}$pids}
    catch {close $ch}
    if {[string match .pw.term* [focus]]} {focus $::qc::ed}
    catch {destroy .pw.term.c}
}

proc qc::termRestart {} {
    termKill
    if {$::qc::cfg(terminal)} {
        applyTerminal
    } else {
        showTerminal 1
    }
}

proc qc::termDialog {} {
    set w .termcfg
    if {[winfo exists $w]} {raise $w; focus $w.f.e; return}
    toplevel $w -background $::qc::C(ui)
    wm title $w "Comando do terminal"
    wm transient $w .
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text "Comando (vazio = xterm com as cores do editor):"
    ttk::entry $w.f.e -width 60 -textvariable ::qc::termTmp
    ttk::label $w.f.h -style Status.TLabel -justify left -text \
        "%W = id da janela onde o terminal é embutido, %D = pasta inicial\nex.: urxvt -embed %W -cd %D    ·    st -w %W"
    ttk::frame $w.f.b
    ttk::button $w.f.b.ok -text OK -command qc::termDialogApply
    ttk::button $w.f.b.no -text Cancelar -command [list destroy $w]
    pack $w.f.b.no $w.f.b.ok -side right -padx {6 0}
    pack $w.f -fill both -expand 1
    pack $w.f.l -anchor w
    pack $w.f.e -fill x -pady 4
    pack $w.f.h -anchor w
    pack $w.f.b -fill x -pady {8 0}
    bind $w <Return> qc::termDialogApply
    bind $w <Escape> [list destroy $w]
    set ::qc::termTmp $::qc::cfg(termcmd)
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    focus $w.f.e
}

proc qc::termDialogApply {} {
    variable cfg
    set new [string trim $::qc::termTmp]
    destroy .termcfg
    if {$new eq $cfg(termcmd)} {return}
    set cfg(termcmd) $new
    if {[info exists ::qc::T(chan)]} {termRestart}
}

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

proc qc::showShortcuts {} {
    tk_messageBox -parent . -title "Atalhos" -message "Atalhos de teclado" -detail [join {
        "Ctrl+R / Ctrl+Enter   Executar arquivo"
        "Ctrl+Shift+R          Executar seleção"
        "Ctrl+Alt+R            Executar comando do projeto (.qconsole)"
        "Ctrl+Break            Interromper execução"
        "Ctrl+W                Limpar saída"
        "Ctrl+E                Opções de execução"
        ""
        "Ctrl+N / O / S        Novo / Abrir / Salvar"
        "Ctrl+Shift+S          Salvar como"
        "Ctrl+Shift+O          Abrir pasta"
        "Ctrl+B                Painel de arquivos"
        "F2 / Del (no painel)  Renomear / excluir arquivo ou pasta"
        "Ctrl+Shift+M          Pré-visualização do Markdown"
        "Ctrl+Shift+E          Exportar Markdown para HTML"
        "Ctrl+' / Ctrl+`       Terminal"
        "Ctrl+F4               Fechar aba"
        "Ctrl+Tab / Ctrl+PgDn  Próxima aba"
        "Ctrl+Shift+Tab / PgUp Aba anterior"
        "Ctrl+Shift+T          Desacoplar / acoplar aba"
        "Ctrl+Q                Sair"
        ""
        "Ctrl+Z / Ctrl+Y       Desfazer / Refazer"
        "Ctrl+F / Ctrl+H       Localizar / Substituir"
        "F3 / Shift+F3         Próximo / Anterior"
        "Ctrl+L                Ir para linha"
        "F12 / Alt+←           Ir para definição / Voltar"
        "Ctrl+D                Selecionar próxima ocorrência"
        "Alt+F3                Selecionar todas as ocorrências"
        "Ctrl+Clique           Ir para definição (nome sublinhado)"
        "                      ou adicionar cursor"
        "Alt+Clique            Adicionar cursor"
        "Shift+Alt+↑ / ↓       Adicionar cursor acima / abaixo"
        "Esc                   Voltar a um cursor"
        "Ctrl+Shift+D          Duplicar linha"
        "Ctrl+Shift+↑ / ↓      Mover linha para cima / baixo"
        "Ctrl+Shift+\[ / \]      Recolher / expandir bloco"
        "Ctrl+/                Comentar linhas"
        "Ctrl+Shift+F          Formatar código"
        "F8                    Verificar código (linter)"
        "Ctrl+Espaço           Completar palavra"
        "Tab / Shift+Tab       Indentar / Desindentar"
        "Ctrl+ + / - / 0       Tamanho da fonte"
    } \n]
}

proc qc::about {} {
    variable langs
    set ls {}
    foreach id $langs {lappend ls [lget name $id]}
    set rn [currentRunner]
    set exe [expr {$rn eq "" ? "" : [join [findExe $rn]]}]
    set detail "Editor simples para avaliação rápida de código.\n\n"
    append detail "Linguagens: [join $ls {, }]\nAtual: [lget name] · $::qc::interp\nComando: $exe\n\n"
    append detail "Tcl [info patchlevel] · Tk [package present Tk]"
    if {[llength $::qc::loadErrors]} {
        append detail "\n\nErros ao carregar linguagens:\n[join $::qc::loadErrors \n]"
    }
    tk_messageBox -parent . -title "Sobre" -message "qconsole $::qc::version" -detail $detail
}

# ---------------------------------------------------------------------------
# Markdown: leitura (parser), pré-visualização e exportação para HTML
# ---------------------------------------------------------------------------
# qc::md::parse converte o texto em uma lista de blocos; a mesma árvore é
# desenhada no painel de pré-visualização (qc::mdRender, widget text) e
# convertida em HTML (qc::md::toHtml). Cobre o CommonMark usual e as
# extensões do GitHub mais comuns: tabelas, ~~riscado~~, listas de tarefas
# e links automáticos.
#
# Blocos: {h linha nível inlines slug}  {p linha inlines}
#         {code linha linguagem texto}  {quote linha blocos}
#         {list linha ordenada início compacta itens}  (item: {tarefa blocos},
#          tarefa = "" | 0 | 1)
#         {hr linha}  {table linha alinhamentos cabeçalho linhas}
#         {html linha texto}
# Inlines: {t texto} {code texto} {em ...} {strong ...} {del ...}
#          {link href título inlines} {img src alt título} {br} {html texto}
# "linha" é a linha do fonte (1 = primeira), usada para sincronizar a
# rolagem do editor com a pré-visualização.

namespace eval qc::md {
    variable refs {} ;# definições [id]: url "título"
    variable slugs {} ;# ids dos títulos já usados (para âncoras únicas)
    variable punct {!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~}
    # tags que começam um bloco HTML
    variable blockTags [join {
        address article aside blockquote center details dialog dd div dl dt
        fieldset figcaption figure footer form h[1-6] header hr iframe li main
        nav ol p pre section summary table tbody td tfoot th thead tr ul video
        audio picture script style
    } |]
}

proc qc::md::parse {text} {
    variable refs
    variable slugs
    set refs [dict create]
    set slugs [dict create]
    set lines [split [string map [list \r\n \n \r \n \t "    "] $text] \n]
    set defRe {^ {0,3}\[([^\]]+)\]:[ \t]*<?([^\s>]+)>?}
    append defRe {(?:[ \t]+(?:"([^"]*)"|'([^']*)'|\(([^)]*)\)))?[ \t]*$}
    # pré-passo: definições de referência (fora de blocos de código); a
    # linha vira branca para manter a numeração
    set fence ""
    set out {}
    foreach ln $lines {
        if {$fence ne ""} {
            if {[regexp -- $fence $ln]} {set fence ""}
        } elseif {[regexp {^ {0,3}(`{3,}|~{3,})} $ln -> f]} {
            set fence "^ {0,3}[string repeat [string index $f 0] [string length $f]]"
        } elseif {[regexp $defRe $ln -> id href t1 t2 t3]} {
            set key [norm $id]
            if {![dict exists $refs $key]} {
                dict set refs $key [list [unescape $href] "$t1$t2$t3"]
            }
            set ln ""
        }
        lappend out $ln
    }
    return [blocks $out 1]
}

proc qc::md::norm {label} {
    return [string tolower [regsub -all {\s+} [string trim $label] " "]]
}

proc qc::md::unescape {s} {
    return [regsub -all {\\([[:punct:]])} $s {\1}]
}

proc qc::md::blank {ln} {
    return [expr {[string trim $ln] eq ""}]
}

# Marcador de lista: {recuo marcador espaços resto} ou "".
proc qc::md::listMarker {ln} {
    if {[regexp {^( {0,3})([-*+]|[0-9]{1,9}[.)])(?:([ ]+)(.*))?$} $ln -> ind mk sp rest]} {
        return [list $ind $mk $sp $rest]
    }
    return ""
}

# Mesmo tipo de lista: mesmo marcador (-, *, +) ou mesmo delimitador (. ou )).
proc qc::md::sameList {a b} {
    set oa [string is digit [string index $a 0]]
    set ob [string is digit [string index $b 0]]
    if {$oa != $ob} {return 0}
    return [expr {[string index $a end] eq [string index $b end]}]
}

# A linha começa um bloco que interrompe um parágrafo?
proc qc::md::startsBlock {ln} {
    variable blockTags
    if {[regexp {^ {0,3}(?:`{3,}|~{3,}|#{1,6}(?:[ \t]|$)|>)} $ln]} {return 1}
    if {[regexp {^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$} $ln]} {return 1}
    set m [listMarker $ln]
    if {$m ne "" && [string trim [lindex $m 3]] ne ""} {return 1}
    if {[regexp -nocase "^ {0,3}<(?:/?(?:$blockTags)(?:\[\\s/>\]|\$)|!--)" $ln]} {return 1}
    return 0
}

proc qc::md::isHr {ln} {
    return [regexp {^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$} $ln]
}

proc qc::md::slug {inl} {
    variable slugs
    set s [string tolower [plain $inl]]
    set s [regsub -all {[^[:alnum:] _-]} $s ""]
    set s [regsub -all { } [string trim $s] -]
    if {$s eq ""} {set s secao}
    set base $s
    set k 0
    while {[dict exists $slugs $s]} {set s $base-[incr k]}
    dict set slugs $s 1
    return $s
}

# Linhas -> blocos. base = número (no fonte) da primeira linha.
proc qc::md::blocks {lines base} {
    variable blockTags
    set out {}
    set n [llength $lines]
    set i 0
    while {$i < $n} {
        set ln [lindex $lines $i]
        set L [expr {$base + $i}]
        if {[blank $ln]} {incr i; continue}

        # bloco cercado ``` / ~~~
        if {[regexp {^( {0,3})(`{3,}|~{3,})([^`]*)$} $ln -> ind f info]} {
            set close "^ {0,3}[string repeat [string index $f 0] [string length $f]]\[[string index $f 0]\]*\[ \t\]*\$"
            set body {}
            set strip [string length $ind]
            incr i
            while {$i < $n && ![regexp -- $close [lindex $lines $i]]} {
                set l [lindex $lines $i]
                if {$strip} {regsub "^ {0,$strip}" $l "" l}
                lappend body $l
                incr i
            }
            incr i
            lappend out [list code $L [lindex [regexp -inline {\S+} $info] 0] [join $body \n]]
            continue
        }

        # código indentado (4 espaços)
        if {[string match "    *" $ln]} {
            set body {}
            while {$i < $n} {
                set l [lindex $lines $i]
                if {[string match "    *" $l]} {
                    lappend body [string range $l 4 end]
                } elseif {[blank $l]} {
                    lappend body ""
                } else {
                    break
                }
                incr i
            }
            while {[llength $body] && [blank [lindex $body end]]} {set body [lrange $body 0 end-1]}
            lappend out [list code $L "" [join $body \n]]
            continue
        }

        # título # ... ######
        if {[regexp {^ {0,3}(#{1,6})(?:[ \t]+(.*))?$} $ln -> h t]} {
            set t [string trim [regsub {(?:^|[ \t]+)#+[ \t]*$} $t ""]]
            set inl [inl $t]
            lappend out [list h $L [string length $h] $inl [slug $inl]]
            incr i
            continue
        }

        # linha horizontal
        if {[isHr $ln]} {
            lappend out [list hr $L]
            incr i
            continue
        }

        # tabela (cabeçalho | ... seguido de |---|:---:|)
        if {
            [string first | $ln] >= 0 && $i + 1 < $n
            && [string first | [lindex $lines $i+1]] >= 0
            && [regexp {^ {0,3}\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$} [lindex $lines $i+1]]
        } {
            set head [splitRow $ln]
            set aligns {}
            foreach c [splitRow [lindex $lines $i+1]] {
                set c [string trim $c]
                set l [string match :* $c]
                set r [string match *: $c]
                lappend aligns [expr {$l && $r ? "center" : ($r ? "right" : ($l ? "left" : ""))}]
            }
            if {[llength $aligns] == [llength $head]} {
                set nc [llength $head]
                set rows {}
                incr i 2
                while {$i < $n} {
                    set l [lindex $lines $i]
                    if {[blank $l] || [string first | $l] < 0 || [startsBlock $l]} {break}
                    set cells [lrange [concat [splitRow $l] [lrepeat $nc ""]] 0 $nc-1]
                    lappend rows [lmap c $cells {inl [string trim $c]}]
                    incr i
                }
                lappend out [list table $L $aligns [lmap c $head {inl [string trim $c]}] $rows]
                continue
            }
        }

        # citação
        if {[regexp {^ {0,3}>} $ln]} {
            set sub {}
            while {$i < $n} {
                set l [lindex $lines $i]
                if {[regexp {^ {0,3}> ?(.*)$} $l -> r]} {
                    lappend sub $r
                } elseif {
                    ![blank $l] && [llength $sub] && ![blank [lindex $sub end]]
                    && ![startsBlock $l] && ![isHr $l]
                } {
                    lappend sub $l ;# continuação "preguiçosa"
                } else {
                    break
                }
                incr i
            }
            lappend out [list quote $L [blocks $sub $L]]
            continue
        }

        # lista
        set m [listMarker $ln]
        if {$m ne ""} {
            lassign $m - mk0
            set ordered [string is digit [string index $mk0 0]]
            set start [expr {$ordered ? [scan [string range $mk0 0 end-1] %d] : 1}]
            set items {}
            set tight 1
            while {$i < $n} {
                set m [listMarker [lindex $lines $i]]
                if {$m eq "" || ![sameList $mk0 [lindex $m 1]]} {break}
                lassign $m ind mk sp rest
                set Li [expr {$base + $i}]
                set W [expr {[string length $ind] + [string length $mk] + 1}]
                if {$rest ne "" && [string length $sp] <= 4} {
                    incr W [expr {[string length $sp] - 1}]
                } elseif {$rest ne ""} {
                    set rest "[string repeat " " [expr {[string length $sp] - 1}]]$rest"
                }
                set task ""
                if {[regexp {^\[([ xX])\](?:[ ]+(.*))?$} $rest -> x r2]} {
                    set task [expr {$x ne " "}]
                    set rest $r2
                }
                set sub [list $rest]
                incr i
                while {$i < $n} {
                    set l [lindex $lines $i]
                    if {[blank $l]} {
                        lappend sub ""
                    } elseif {[regexp {^ *} $l sp2] && [string length $sp2] >= $W} {
                        lappend sub [string range $l $W end]
                    } elseif {
                        ![blank [lindex $sub end]] && ![startsBlock $l] && ![isHr $l]
                        && [listMarker $l] eq ""
                    } {
                        lappend sub [string trimleft $l] ;# continuação "preguiçosa"
                    } else {
                        break
                    }
                    incr i
                }
                set trail 0
                while {[llength $sub] > 1 && [blank [lindex $sub end]]} {
                    set sub [lrange $sub 0 end-1]
                    incr trail
                }
                # linha em branco entre blocos do próprio item: lista "solta"
                for {set k 1} {$k < [llength $sub] - 1} {incr k} {
                    if {[blank [lindex $sub $k]] && ![string match " *" [lindex $sub $k+1]]} {
                        set tight 0
                    }
                }
                lappend items [list $task [blocks $sub $Li]]
                if {$trail && $i < $n} {
                    set m2 [listMarker [lindex $lines $i]]
                    if {$m2 ne "" && [sameList $mk0 [lindex $m2 1]]} {set tight 0}
                }
            }
            lappend out [list list $L $ordered $start $tight $items]
            continue
        }

        # bloco HTML: até a próxima linha em branco
        if {[regexp -nocase "^ {0,3}<(?:/?(?:$blockTags)(?:\[\\s/>\]|\$)|!--)" $ln]} {
            set body {}
            while {$i < $n && ![blank [lindex $lines $i]]} {
                lappend body [lindex $lines $i]
                incr i
            }
            lappend out [list html $L [join $body \n]]
            continue
        }

        # parágrafo (ou título sublinhado com === / ---)
        set para [list [string trimleft $ln]]
        set level 0
        incr i
        while {$i < $n} {
            set l [lindex $lines $i]
            if {[blank $l]} {break}
            if {[regexp {^ {0,3}(=+|-+)[ \t]*$} $l -> u]} {
                set level [expr {[string index $u 0] eq "=" ? 1 : 2}]
                incr i
                break
            }
            if {[startsBlock $l] || [isHr $l]} {break}
            lappend para [string trimleft $l]
            incr i
        }
        set text [join $para \n]
        if {$level} {
            set inl [inl [string trim $text]]
            lappend out [list h $L $level $inl [slug $inl]]
        } else {
            lappend out [list p $L [inl [string trimright $text]]]
        }
    }
    return $out
}

# Células de uma linha de tabela (| a | b |); \| é um | literal.
proc qc::md::splitRow {ln} {
    set ln [string trim $ln]
    if {[string index $ln 0] eq "|"} {set ln [string range $ln 1 end]}
    if {[string index $ln end] eq "|" && [string index $ln end-1] ne "\\"} {
        set ln [string range $ln 0 end-1]
    }
    set cells {}
    set cur ""
    set tick 0
    set n [string length $ln]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $ln $i]
        if {$c eq "\\" && [string index $ln $i+1] eq "|"} {
            append cur |
            incr i
        } elseif {$c eq "`"} {
            set tick [expr {!$tick}]
            append cur $c
        } elseif {$c eq "|" && !$tick} {
            lappend cells $cur
            set cur ""
        } else {
            append cur $c
        }
    }
    lappend cells $cur
    return $cells
}

# --- inlines ---------------------------------------------------------------

proc qc::md::inl {s} {
    variable punct
    set out {}
    set buf ""
    set n [string length $s]
    set i 0
    while {$i < $n} {
        if {![regexp -start $i -indices {[\\`*_~\[!<\nh&]} $s r]} {
            append buf [string range $s $i end]
            break
        }
        set j [lindex $r 0]
        append buf [string range $s $i $j-1]
        set i $j
        set c [string index $s $i]
        switch -- $c {
            "\\" {
                set d [string index $s $i+1]
                if {$d eq "\n"} {
                    emit out buf
                    lappend out br
                    incr i 2
                } elseif {$d ne "" && [string first $d $punct] >= 0} {
                    append buf $d
                    incr i 2
                } else {
                    append buf "\\"
                    incr i
                }
            }
            "\n" {
                if {[regexp {  +$} $buf]} {
                    set buf [string trimright $buf " "]
                    emit out buf
                    lappend out br
                } else {
                    set buf "[string trimright $buf " "]\n"
                }
                incr i
                while {[string index $s $i] eq " "} {incr i}
            }
            "`" {
                set k $i
                while {[string index $s $k] eq "`"} {incr k}
                set run [expr {$k - $i}]
                set tick [string repeat ` $run]
                set p $k
                set found -1
                while {[set q [string first $tick $s $p]] >= 0} {
                    set e $q
                    while {[string index $s $e] eq "`"} {incr e}
                    if {$e - $q == $run} {set found $q; break}
                    set p $e
                }
                if {$found < 0} {
                    append buf $tick
                    set i $k
                    continue
                }
                set code [string map {\n " "} [string range $s $k $found-1]]
                if {[regexp {^ .*[^ ].* $} $code]} {set code [string range $code 1 end-1]}
                emit out buf
                lappend out [list code $code]
                set i [expr {$found + $run}]
            }
            "*" - "_" - "~" {
                set k $i
                while {[string index $s $k] eq $c} {incr k}
                set run [expr {$k - $i}]
                set prev [string index $s $i-1]
                set next [string index $s $k]
                set ok [expr {$next ne "" && ![string is space $next]}]
                if {$c eq "_" && $prev ne "" && [string is alnum $prev]} {set ok 0}
                if {$c eq "~" && $run != 2} {set ok 0}
                set done 0
                if {$ok} {
                    if {$c eq "~"} {
                        set tries {2}
                    } elseif {$run >= 3} {
                        set tries {3 2 1}
                    } elseif {$run == 2} {
                        set tries {2 1}
                    } else {
                        set tries {1}
                    }
                    foreach len $tries {
                        set from [expr {$k}]
                        set q [findClose $s $from $c $len 0]
                        if {$q < 0} {continue}
                        set inner [inl [string range $s $from $q-1]]
                        append buf [string range $s $i [expr {$k - $len - 1}]]
                        emit out buf
                        switch -- $len {
                            3 {lappend out [list strong [list em {*}$inner]]}
                            2 {lappend out [list [expr {$c eq "~" ? "del" : "strong"}] {*}$inner]}
                            1 {lappend out [list em {*}$inner]}
                        }
                        set i [expr {$q + $len}]
                        set done 1
                        break
                    }
                }
                if {!$done} {
                    append buf [string range $s $i $k-1]
                    set i $k
                }
            }
            "!" - "\[" {
                set img [expr {$c eq "!"}]
                if {$img && [string index $s $i+1] ne "\["} {
                    append buf !
                    incr i
                    continue
                }
                set lk [linkAt $s [expr {$i + $img}]]
                if {$lk eq ""} {
                    append buf $c
                    incr i
                    continue
                }
                lassign $lk end text href title
                emit out buf
                if {$img} {
                    lappend out [list img $href [plain [inl $text]] $title]
                } else {
                    lappend out [list link $href $title {*}[inl $text]]
                }
                set i $end
            }
            "<" {
                set rest [string range $s $i end]
                if {[regexp {^<((?:https?|ftp|mailto|file):[^\s<>]*)>} $rest all u]} {
                    emit out buf
                    lappend out [list link $u "" [list t $u]]
                    incr i [string length $all]
                } elseif {[regexp {^<([^\s<>@]+@[^\s<>@]+\.[^\s<>@]+)>} $rest all u]} {
                    emit out buf
                    lappend out [list link mailto:$u "" [list t $u]]
                    incr i [string length $all]
                } elseif {[regexp {^<(?:/?[A-Za-z][A-Za-z0-9-]*(?:\s+[^<>]*)?/?|!--(?:[^-]|-[^-])*--)>} $rest all]} {
                    emit out buf
                    lappend out [list html $all]
                    incr i [string length $all]
                } else {
                    append buf <
                    incr i
                }
            }
            "h" {
                set prev [string index $s $i-1]
                if {
                    ($prev eq "" || ![string is alnum $prev])
                    && [regexp {^https?://[^\s<>]+} [string range $s $i end] u]
                } {
                    set u [regsub {[.,;:!?'"*_~]+$} $u ""]
                    while {
                        [string index $u end] eq ")"
                        && [regexp -all {\)} $u] > [regexp -all {\(} $u]
                    } {
                        set u [string range $u 0 end-1]
                    }
                    emit out buf
                    lappend out [list link $u "" [list t $u]]
                    incr i [string length $u]
                } else {
                    append buf h
                    incr i
                }
            }
            "&" {
                if {[regexp {^&(?:[A-Za-z][A-Za-z0-9]*|#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6});} \
                        [string range $s $i end] ent]} {
                    append buf [entity $ent]
                    incr i [string length $ent]
                } else {
                    append buf &
                    incr i
                }
            }
        }
    }
    emit out buf
    return $out
}

proc qc::md::emit {outVar bufVar} {
    upvar 1 $outVar out $bufVar buf
    if {$buf ne ""} {
        lappend out [list t $buf]
        set buf ""
    }
}

# Entidade HTML -> caractere (as desconhecidas ficam como estão).
proc qc::md::entity {e} {
    set map {
        &amp; & &lt; < &gt; > &quot; \" &apos; ' &nbsp;   &copy; ©
        &reg; ® &trade; ™ &mdash; — &ndash; – &hellip; …
        &laquo; « &raquo; » &larr; ← &rarr; → &uarr; ↑
        &darr; ↓ &times; × &deg; ° &middot; · &bull; •
        &euro; € &check; ✓
    }
    if {[dict exists $map $e]} {return [dict get $map $e]}
    if {[regexp {^&#[xX]([0-9a-fA-F]+);$} $e -> h]} {
        scan $h %x v
    } elseif {![regexp {^&#([0-9]+);$} $e -> v]} {
        return $e
    }
    set v [scan $v %d]
    if {$v <= 0 || $v > 0x10FFFF} {return �}
    return [format %c $v]
}

# Fecho de uma ênfase com "len" caracteres c, a partir de "from". Aberturas
# no meio (ex.: o ** de "*a **b** c*") são puladas junto com o fecho delas.
proc qc::md::findClose {s from c len depth} {
    if {$depth > 20} {return -1}
    set p $from
    set n [string length $s]
    while {$p < $n} {
        set q [string first $c $s $p]
        if {$q < 0} {return -1}
        # pula código inline e escapes
        set k [string first ` $s $p]
        if {$k >= 0 && $k < $q} {
            set e $k
            while {[string index $s $e] eq "`"} {incr e}
            set q2 [string first [string range $s $k $e-1] $s $e]
            set p [expr {$q2 >= 0 ? $q2 + ($e - $k) : $e}]
            continue
        }
        if {[string index $s $q-1] eq "\\"} {
            set p [expr {$q + 1}]
            continue
        }
        set e $q
        while {[string index $s $e] eq $c} {incr e}
        set run [expr {$e - $q}]
        set before [string index $s $q-1]
        set after [string index $s $e]
        set canClose [expr {$q > $from && ![string is space $before]}]
        if {$c eq "_" && $after ne "" && [string is alnum $after]} {set canClose 0}
        if {$canClose && ($run == $len || ($run == 3 && $c ne "~"))} {return $q}
        set canOpen [expr {$after ne "" && ![string is space $after]}]
        if {$c eq "_" && [string is alnum $before]} {set canOpen 0}
        if {$canOpen && !$canClose && $c ne "~" || $canOpen && $c eq "~" && $run == 2 && !$canClose} {
            # abertura interna: pula até o fecho dela
            set q2 [findClose $s $e $c [expr {min($run, 2)}] [expr {$depth + 1}]]
            if {$q2 >= 0} {
                set p [expr {$q2 + min($run, 2)}]
                continue
            }
        }
        set p $e
    }
    return -1
}

# [texto](destino "título"), [texto][ref], [texto][] ou [texto] em s[i].
# Retorna {fim texto href título} ou "".
proc qc::md::linkAt {s i} {
    variable refs
    set n [string length $s]
    set depth 0
    for {set j $i} {$j < $n} {incr j} {
        set ch [string index $s $j]
        if {$ch eq "\\"} {
            incr j
        } elseif {$ch eq "`"} {
            set e $j
            while {[string index $s $e] eq "`"} {incr e}
            set q [string first [string range $s $j $e-1] $s $e]
            if {$q >= 0} {set j [expr {$q + ($e - $j) - 1}]}
        } elseif {$ch eq "\["} {
            incr depth
        } elseif {$ch eq "\]"} {
            incr depth -1
            if {$depth == 0} {break}
        }
    }
    if {$j >= $n} {return ""}
    set text [string range $s $i+1 $j-1]
    set k [expr {$j + 1}]
    if {[string index $s $k] eq "("} {
        set d 0
        for {set m $k} {$m < $n} {incr m} {
            set ch [string index $s $m]
            if {$ch eq "\\"} {
                incr m
            } elseif {$ch eq "("} {
                incr d
            } elseif {$ch eq ")"} {
                incr d -1
                if {$d == 0} {break}
            }
        }
        if {$m < $n} {
            set inside [string trim [string range $s $k+1 $m-1]]
            if {
                [regexp {^<([^>]*)>(?:\s+(.*))?$} $inside -> href rest]
                || [regexp {^(\S*)(?:\s+(.*))?$} $inside -> href rest]
            } {
                set title ""
                regexp {^["'(](.*)["')]$} [string trim $rest] -> title
                return [list [expr {$m + 1}] $text [unescape $href] $title]
            }
        }
    }
    set key $text
    set end $k
    if {[regexp {^\[([^\]]*)\]} [string range $s $k end] all id]} {
        if {$id ne ""} {set key $id}
        set end [expr {$k + [string length $all]}]
    }
    set key [norm $key]
    if {$key ne "" && [dict exists $refs $key]} {
        lassign [dict get $refs $key] href title
        return [list $end $text $href $title]
    }
    return ""
}

# Texto puro de uma lista de inlines.
proc qc::md::plain {nodes} {
    set out ""
    foreach nd $nodes {
        switch -- [lindex $nd 0] {
            t - code {append out [lindex $nd 1]}
            br {append out " "}
            em - strong - del {append out [plain [lrange $nd 1 end]]}
            link {append out [plain [lrange $nd 3 end]]}
            img {append out [lindex $nd 2]}
        }
    }
    return $out
}

# --- destaque de sintaxe em blocos de código ---------------------------------
# Usa os tokens da linguagem do tcode indicada na cerca (```tcl, ```scheme,
# ```sh...). Retorna {tag início fim} (deslocamentos de caractere, fim
# exclusivo) e o dicionário de estilos.

proc qc::md::langId {info} {
    set info [string tolower $info]
    if {$info eq ""} {return ""}
    if {$info in $::qc::langs} {return $info}
    set alias {console shell shell shell bash shell zsh shell scheme scheme
               guile scheme-guile chez scheme-chez kawa scheme-kawa
               racket scheme lisp scheme ml ocaml tk tcl sc scala}
    if {[dict exists $alias $info]} {
        set id [::qc::langAlias [dict get $alias $info]]
        if {$id in $::qc::langs} {return $id}
    }
    foreach id $::qc::langs {
        if {".$info" in [::qc::lget ext $id]} {return $id}
    }
    return ""
}

proc qc::md::hlSpec {id} {
    variable HS
    if {[info exists HS($id)]} {return $HS($id)}
    if {$id ni $::qc::inited} {
        lappend ::qc::inited $id
        set h [::qc::hook init $id]
        if {$h ne ""} {catch {$h}}
    }
    set d [::qc::ldict $id]
    set parts {}
    set specs {}
    set g 1
    foreach {tag re} [dict get $d tokens] {
        if {[catch {regexp -about $re} ab]} {continue}
        set n [lindex $ab 0]
        lappend parts "($re)"
        lappend specs [list $tag $g [expr {$n > 0}]]
        incr g [expr {$n + 1}]
    }
    set words [dict create]
    dict for {tag list} [dict get $d words] {
        foreach w $list {dict set words $w $tag}
    }
    set HS($id) [dict create re "(?w)[join $parts |]" specs $specs nf $g \
        words $words defWords [dict get $d defWords] defTag [dict get $d defTag] \
        capType [dict get $d capType] numRe [dict get $d numberWord] \
        styles [dict merge $::qc::S [dict get $d styles]]]
    return $HS($id)
}

proc qc::md::hlCode {id text} {
    if {$id eq "" || $id eq "markdown"} {return {}}
    set H [hlSpec $id]
    if {[dict get $H specs] eq ""} {return {}}
    set nf [dict get $H nf]
    set words [dict get $H words]
    set out {}
    set defNext 0
    set m [regexp -all -inline -indices -- [dict get $H re] $text]
    for {set i 0} {$i < [llength $m]} {incr i $nf} {
        set tag ""
        foreach spec [dict get $H specs] {
            lassign $spec t g inner
            set r [lindex $m [expr {$i + $g}]]
            if {[lindex $r 0] < 0} {continue}
            set tag $t
            if {$inner} {
                set r2 [lindex $m [expr {$i + $g + 1}]]
                if {[lindex $r2 0] >= 0} {set r $r2}
            }
            break
        }
        if {$tag eq ""} {continue}
        lassign $r a z
        if {$tag eq "word"} {
            set w [string range $text $a $z]
            if {[dict get $H numRe] ne "" && [regexp -- [dict get $H numRe] $w]} {
                set tag number
            } elseif {[dict exists $words $w]} {
                set tag [dict get $words $w]
                set defNext [expr {$w in [dict get $H defWords]}]
            } elseif {$defNext} {
                set tag [dict get $H defTag]
                set defNext 0
            } elseif {[dict get $H capType] ne "" && [string is upper [string index $w 0]]} {
                set tag [dict get $H capType]
            } else {
                continue
            }
        } elseif {$tag eq "brace"} {
            continue
        } else {
            set defNext 0
        }
        lappend out [list $tag $a [expr {$z + 1}]]
    }
    return $out
}

# --- HTML ------------------------------------------------------------------

proc qc::md::esc {s} {
    return [string map {& &amp; < &lt; > &gt; \" &quot;} $s]
}

proc qc::md::htmlInl {nodes} {
    set out ""
    foreach nd $nodes {
        switch -- [lindex $nd 0] {
            t {append out [esc [lindex $nd 1]]}
            code {append out "<code>[esc [lindex $nd 1]]</code>"}
            br {append out "<br>\n"}
            html {append out [lindex $nd 1]}
            em - strong - del {
                set t [lindex $nd 0]
                append out "<$t>[htmlInl [lrange $nd 1 end]]</$t>"
            }
            link {
                lassign $nd - href title
                set a "<a href=\"[esc $href]\""
                if {$title ne ""} {append a " title=\"[esc $title]\""}
                append out "$a>[htmlInl [lrange $nd 3 end]]</a>"
            }
            img {
                lassign $nd - src alt title
                set a "<img src=\"[esc $src]\" alt=\"[esc $alt]\""
                if {$title ne ""} {append a " title=\"[esc $title]\""}
                append out "$a>"
            }
        }
    }
    return $out
}

proc qc::md::htmlCode {lang text} {
    set id [langId $lang]
    set cls [expr {$lang ne "" ? " class=\"language-[esc $lang]\"" : ""}]
    set out "<pre><code$cls>"
    set p 0
    if {$id ne ""} {
        set styles [dict get [hlSpec $id] styles]
        foreach r [hlCode $id $text] {
            lassign $r tag a z
            append out [esc [string range $text $p $a-1]]
            set css ""
            if {[dict exists $styles $tag]} {
                lassign [dict get $styles $tag] color st
                if {$color ne ""} {append css "color:$color;"}
                if {$st eq "B"} {append css "font-weight:bold;"}
                if {$st eq "I"} {append css "font-style:italic;"}
            }
            set chunk [esc [string range $text $a $z-1]]
            append out [expr {$css ne "" ? "<span style=\"$css\">$chunk</span>" : $chunk}]
            set p $z
        }
    }
    append out [esc [string range $text $p end]] "</code></pre>\n"
    return $out
}

proc qc::md::htmlBlocks {blocks {tight 0}} {
    set out ""
    foreach b $blocks {
        switch -- [lindex $b 0] {
            h {
                lassign $b - - lv inl id
                append out "<h$lv id=\"[esc $id]\">[htmlInl $inl]</h$lv>\n"
            }
            p {
                set c [htmlInl [lindex $b 2]]
                append out [expr {$tight ? "$c\n" : "<p>$c</p>\n"}]
            }
            code {append out [htmlCode [lindex $b 2] [lindex $b 3]]}
            quote {append out "<blockquote>\n[htmlBlocks [lindex $b 2]]</blockquote>\n"}
            hr {append out "<hr>\n"}
            html {append out [lindex $b 2] \n}
            list {
                lassign $b - - ordered start tgt items
                set tasks 0
                foreach it $items {if {[lindex $it 0] ne ""} {set tasks 1}}
                set cls [expr {$tasks ? " class=\"task-list\"" : ""}]
                if {$ordered} {
                    set st [expr {$start != 1 ? " start=\"$start\"" : ""}]
                    append out "<ol$st$cls>\n"
                } else {
                    append out "<ul$cls>\n"
                }
                foreach it $items {
                    lassign $it task sub
                    append out "<li>"
                    if {$task ne ""} {
                        append out "<input type=\"checkbox\" disabled[expr {$task ? " checked" : ""}]> "
                    }
                    set inner [htmlBlocks $sub $tgt]
                    append out [expr {$tgt ? [string trimright $inner \n] : "\n$inner"}] "</li>\n"
                }
                append out [expr {$ordered ? "</ol>\n" : "</ul>\n"}]
            }
            table {
                lassign $b - - aligns head rows
                append out "<table>\n<thead>\n<tr>"
                foreach c $head a $aligns {
                    set st [expr {$a ne "" ? " style=\"text-align:$a\"" : ""}]
                    append out "<th$st>[htmlInl $c]</th>"
                }
                append out "</tr>\n</thead>\n<tbody>\n"
                foreach r $rows {
                    append out "<tr>"
                    foreach c $r a $aligns {
                        set st [expr {$a ne "" ? " style=\"text-align:$a\"" : ""}]
                        append out "<td$st>[htmlInl $c]</td>"
                    }
                    append out "</tr>\n"
                }
                append out "</tbody>\n</table>\n"
            }
        }
    }
    return $out
}

# Documento HTML completo. base: pasta para resolver caminhos relativos
# (usada na cópia temporária aberta no navegador).
proc qc::md::toHtml {text {title ""} {base ""}} {
    set blocks [parse $text]
    if {$title eq ""} {
        foreach b $blocks {
            if {[lindex $b 0] eq "h"} {set title [plain [lindex $b 3]]; break}
        }
    }
    set head "<meta charset=\"utf-8\">\n"
    append head "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
    append head "<meta name=\"generator\" content=\"qconsole $::qc::version\">\n"
    if {$base ne ""} {
        set u [string map {% %25 " " %20 # %23 ? %3F} [file normalize $base]]
        append head "<base href=\"file://$u/\">\n"
    }
    append head "<title>[esc $title]</title>\n"
    set body [htmlBlocks $blocks]
    append out "<!DOCTYPE html>\n<html>\n<head>\n$head<style>\n[css]</style>\n</head>\n" \
        "<body>\n<main class=\"markdown-body\">\n$body</main>\n</body>\n</html>\n"
    return $out
}

proc qc::md::css {} {
    return {:root {
  --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --border: #d1d9e0;
  --code-bg: #eff1f3; --link: #0969da; --row: #f6f8fa; --pre-bg: #2b2b2b; --pre-fg: #a9b7c6;
}
@media (prefers-color-scheme: dark) {
  :root {
    --fg: #e6edf3; --muted: #9198a1; --bg: #0d1117; --border: #3d444d;
    --code-bg: #262c36; --link: #4493f8; --row: #151b23; --pre-bg: #1e1f22;
  }
}
html { background: var(--bg); color: var(--fg); }
body {
  margin: 0; padding: 32px 16px;
  font: 16px/1.6 -apple-system, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
}
.markdown-body { max-width: 860px; margin: 0 auto; overflow-wrap: break-word; }
h1, h2, h3, h4, h5, h6 { margin: 1.5em 0 .6em; line-height: 1.25; font-weight: 600; }
h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
h3 { font-size: 1.25em; } h4 { font-size: 1em; }
h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
.markdown-body > :first-child { margin-top: 0; }
p, ul, ol, blockquote, pre, table { margin: 0 0 16px; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
code, pre {
  font-family: "JetBrains Mono", "Fira Code", "DejaVu Sans Mono", Menlo, Consolas, monospace;
  font-size: 85%;
}
code { background: var(--code-bg); padding: .2em .4em; border-radius: 6px; }
pre {
  background: var(--pre-bg); color: var(--pre-fg); padding: 16px;
  border-radius: 6px; overflow: auto; line-height: 1.45;
}
pre code { background: none; padding: 0; font-size: 100%; color: inherit; }
blockquote { margin-left: 0; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
ul, ol { padding-left: 2em; }
li + li { margin-top: .25em; }
ul.task-list { list-style: none; padding-left: 1.2em; }
ul.task-list input { margin: 0 .3em 0 -1.2em; vertical-align: middle; }
hr { height: 2px; border: 0; background: var(--border); margin: 24px 0; }
table { border-collapse: collapse; display: block; max-width: 100%; overflow: auto; }
th, td { border: 1px solid var(--border); padding: 6px 13px; }
th { font-weight: 600; }
tr:nth-child(2n) td { background: var(--row); }
img { max-width: 100%; }
del { color: var(--muted); }
}
}

# --- painel de pré-visualização ----------------------------------------------
# Fica à direita do editor/saída (painel .md de .hp) quando a aba ativa é
# Markdown e Exibir > Pré-visualização do Markdown está ligado. É redesenhado
# ao editar (com atraso) e acompanha a rolagem do editor; duplo clique leva
# o editor à linha correspondente.

namespace eval qc {
    variable MD
    array set MD {after "" sync 0 lines {} fonts {} links 0 shown 0}
    # cores da pré-visualização
    array set C {
        mdfg #c9d1d9 mdhead #e6e6e6 mdmuted #8b949e mdlink #589df6
        mdcode #e0a96d mdcodebg #3a3d41 mdprebg #1e1f22 mdrule #4a4d50
        mdquotebg #303235 mdthbg #35383b
    }
}

# Painel de pré-visualização f (com o texto em f.t) da janela cujo editor
# fica em host (.pw.ed na principal).
proc qc::buildPreview {f host} {
    variable C
    variable MD
    ttk::frame $f
    ttk::frame $f.head -style Head.TFrame
    ttk::label $f.head.l -text "Pré-visualização" -style Head.TLabel -anchor w
    ttk::button $f.head.x -text ✕ -style Head.TButton -takefocus 0 \
        -command {set ::qc::cfg(mdpreview) 0; qc::mdApply}
    ttk::button $f.head.b -text "Navegador" -style Head.TButton -takefocus 0 \
        -command [list qc::mdAct $host qc::mdBrowser]
    ttk::button $f.head.e -text "Exportar HTML…" -style Head.TButton -takefocus 0 \
        -command [list qc::mdAct $host qc::mdExport]
    pack $f.head.x $f.head.b $f.head.e -side right
    pack $f.head.l -side left -fill x -expand 1
    set w [text $f.t -background $C(edbg) -foreground $C(mdfg) -wrap word \
        -font [mdFont body] -bd 0 -highlightthickness 0 -padx 18 -pady 12 \
        -cursor arrow -insertwidth 0 -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -spacing1 1 -spacing3 1 -yscrollcommand [list $f.sy set]]
    ttk::scrollbar $f.sy -orient vertical -command [list $w yview]
    grid $f.head - -sticky ew
    grid $w $f.sy -sticky nsew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure $f 1 -weight 1
    set MD(H,$w) $host
    set MD(L,$w) {}
    set MD(R,$w) {}
    set MD(D,$w) [pwd]
    bind $w <Destroy> [list array unset ::qc::MD *,$w]
    # só leitura, mas com seleção e cópia
    bindtags $w [list $w QcKeys QcMdView Text [winfo toplevel $w] all]
    bind QcMdView <KeyPress> {
        if {%K ni {Up Down Left Right Prior Next Home End}} break
    }
    foreach ev {<<Cut>> <<Paste>> <<Clear>> <<Undo>> <<Redo>> <BackSpace> <Delete> <Return>} {
        bind QcMdView $ev break
    }
    bind $w <Double-1> {qc::mdGotoSource %W %x %y; break}
    bind $w <Configure> [list qc::mdRules $w]
    bind $w <Control-MouseWheel> {qc::zoom [expr {%D > 0 ? 1 : -1}]; break}

    $w tag configure p -spacing3 10
    $w tag configure tight -spacing3 3
    $w tag configure head -foreground $C(mdhead) -spacing1 14 -spacing3 8
    $w tag configure quote -foreground $C(mdmuted) -background $C(mdquotebg)
    $w tag configure icode -foreground $C(mdcode) -background $C(mdcodebg)
    $w tag configure pre -background $C(mdprebg) -foreground $C(edfg) \
        -font [mdFont mono] -wrap char -spacing1 0 -spacing3 0 -lmargin1 12 -lmargin2 12 -rmargin 12
    $w tag configure prepad -background $C(mdprebg) -font [list [mdFamily] 4] \
        -spacing1 0 -spacing3 0
    $w tag configure del -overstrike 1 -foreground $C(mdmuted)
    $w tag configure link -foreground $C(mdlink) -underline 1
    $w tag configure muted -foreground $C(mdmuted)
    $w tag configure htmlblk -foreground $C(mdmuted) -font [mdFont mono]
    $w tag configure th -background $C(mdthbg)
    $w tag configure bullet -foreground $C(mdmuted)
    $w tag configure gap -spacing3 6
    $w tag configure sgap -font [list [mdFamily] 5] -spacing1 0 -spacing3 0
    $w tag bind link <Enter> [list $w configure -cursor hand2]
    $w tag bind link <Leave> [list $w configure -cursor arrow]
    foreach t {keyword defname type string comment number var interp option
               annot brace directive builtin constant symbol} {
        lassign [dict get $::qc::S $t] color st
        set opts [list -foreground $color]
        switch -- $st {
            B {lappend opts -font [mdFont mono 1 0]}
            I {lappend opts -font [mdFont mono 0 1]}
        }
        $w tag configure syn_$t {*}$opts
    }
    $w tag raise sel
}

# Fonte da pré-visualização: kind = body | h1..h6 | mono; b/i = negrito/itálico.
proc qc::mdFont {kind {b 0} {i 0}} {
    variable MD
    set name QcMd_${kind}_$b$i
    if {$name ni [font names]} {
        if {$kind eq "mono"} {
            set fam [font actual QcMono -family]
        } else {
            set fam [mdFamily]
        }
        font create $name -family $fam
        dict set MD(fonts) $name [list $kind $b $i]
        mdFontSize $name
    }
    return $name
}

proc qc::mdFamily {} {
    variable MD
    if {[info exists MD(family)]} {return $MD(family)}
    set fams [font families]
    foreach f {"Noto Sans" "Inter" "Segoe UI" "Ubuntu" "Cantarell" "DejaVu Sans"
               "Liberation Sans" "Helvetica" "Arial"} {
        if {[lsearch -nocase -exact $fams $f] >= 0} {return [set MD(family) $f]}
    }
    return [set MD(family) [font actual TkDefaultFont -family]]
}

proc qc::mdFontSize {name} {
    variable MD
    lassign [dict get $MD(fonts) $name] kind b i
    set base [expr {$::qc::cfg(fontsize) + 1}]
    set scale [dict get {body 1.0 mono 0.92 h1 1.9 h2 1.55 h3 1.3 h4 1.12 h5 1.0 h6 0.92} $kind]
    if {$kind in {h1 h2 h3 h4 h5 h6}} {set b 1}
    font configure $name -size [expr {max(6, round($base * $scale))}] \
        -weight [expr {$b ? "bold" : "normal"}] -slant [expr {$i ? "italic" : "roman"}]
}

proc qc::mdZoom {} {
    variable MD
    foreach name [dict keys $MD(fonts)] {mdFontSize $name}
    foreach host [mdHosts] {
        if {[mdShown $host]} {mdRender $host}
    }
}

# Janelas com editor: a principal e as desacopladas.
proc qc::mdHosts {} {
    return [concat .pw.ed [floatTops]]
}

# Painel de pré-visualização da janela do editor host.
proc qc::mdPv {host} {
    if {$host eq ".pw.ed"} {return .md}
    return [winfo toplevel $host].md
}

proc qc::mdShown {host} {
    set f [mdPv $host]
    if {$host eq ".pw.ed"} {return [expr {$f in [.hp panes]}]}
    return [expr {[winfo exists $f] && $f in [[winfo toplevel $host].pw panes]}]
}

proc qc::edLang {e} {
    if {$e eq $::qc::ed} {return $::qc::lang}
    return $::qc::TB($e,lang)
}

# A janela host deve mostrar a pré-visualização (a aba dela é Markdown)?
proc qc::mdWant {host} {
    set e [hostEd $host]
    expr {$::qc::cfg(mdpreview) && $e ne "" && [winfo exists $e] && [edLang $e] eq "markdown"}
}

# Pré-visualização da aba ativa está à vista?
proc qc::mdVisible {} {
    if {$::qc::ed eq "" || ![winfo exists $::qc::ed]} {return 0}
    return [mdWant [winfo parent $::qc::ed]]
}

# Botões do painel: agem sobre a aba daquela janela.
proc qc::mdAct {host cmd} {
    set e [hostEd $host]
    if {$e ne "" && [winfo exists $e]} {activateTab $e}
    $cmd
}

# Divisor editor | pré-visualização.
proc qc::mdSash {host} {
    variable cfg
    if {$host eq ".pw.ed"} {
        set pw .hp
    } else {
        set pw [winfo toplevel $host].pw
    }
    set k [expr {[llength [$pw panes]] - 2}]
    if {$k < 0} {return}
    set wd [winfo width $pw]
    if {$host eq ".pw.ed"} {
        set w [expr {$cfg(mdw) > 100 ? $cfg(mdw) : $wd * 45 / 100}]
    } else {
        set w [expr {$wd / 2}]
    }
    catch {$pw sashpos $k [expr {max(200, $wd - $w)}]}
}

# Inclui/remove o painel da janela host; 1 se acabou de ser incluído.
proc qc::mdPane {host want} {
    variable cfg
    set f [mdPv $host]
    set shown [mdShown $host]
    if {$host eq ".pw.ed"} {
        set pw .hp
    } else {
        set pw [winfo toplevel $host].pw
    }
    if {$want && !$shown} {
        $pw add $f -weight 1
        update idletasks
        if {[winfo ismapped $pw] && [winfo width $pw] > 1} {
            mdSash $host
        } else {
            # janela ainda sem tamanho (recém-criada): posiciona ao aparecer
            bind $pw <Configure> [list apply {{pw host} {
                if {[winfo width $pw] > 1} {
                    bind $pw <Configure> {}
                    qc::mdSash $host
                }
            }} $pw $host]
        }
        return 1
    } elseif {!$want && $shown} {
        if {$host eq ".pw.ed"} {set cfg(mdw) [winfo width $f]}
        $pw forget $f
    }
    return 0
}

# Mostra/esconde os painéis conforme a aba de cada janela e a opção.
proc qc::mdApply {} {
    variable MD
    if {![winfo exists .md]} {return}
    set act [expr {$::qc::ed ne "" && [winfo exists $::qc::ed] ? [winfo parent $::qc::ed] : ""}]
    foreach host [mdHosts] {
        set want [mdWant $host]
        if {[mdPane $host $want] && $host ne $act} {
            # tclint-disable-next-line command-args
            after idle [list qc::mdRender $host]
        }
    }
    set MD(shown) [mdVisible]
    if {$MD(shown)} {
        after cancel $MD(after)
        set MD(after) [after idle qc::mdRender]
    }
    catch {
        set m .mb.file
        set st [expr {$::qc::lang eq "markdown" ? "normal" : "disabled"}]
        $m entryconfigure "Exportar para HTML…" -state $st
        $m entryconfigure "Abrir no navegador" -state $st
    }
}

# Ctrl+Shift+M / Exibir > Pré-visualização do Markdown
proc qc::mdToggle {} {
    variable cfg
    if {$::qc::lang ne "markdown"} {
        set ::qc::status "A pré-visualização é para arquivos Markdown"
        return
    }
    set cfg(mdpreview) [expr {!$cfg(mdpreview)}]
    mdApply
}

proc qc::mdSched {} {
    variable MD
    if {!$MD(shown)} {return}
    after cancel $MD(after)
    set MD(after) [after 250 qc::mdRender]
}

proc qc::mdRender {{host ""}} {
    variable MD
    if {$host eq ""} {
        if {$::qc::ed eq "" || ![winfo exists $::qc::ed]} {return}
        set host [winfo parent $::qc::ed]
    }
    if {![winfo exists $host] || ![mdWant $host]} {return}
    set ed [hostEd $host]
    set w [mdPv $host].t
    if {![winfo exists $w]} {return}
    set f [expr {$ed eq $::qc::ed ? $::qc::file : $::qc::TB($ed,file)}]
    set MD(lines) {}
    set MD(rules) {}
    set MD(dir) [expr {$f ne "" ? [file dirname $f] : [pwd]}]
    $w configure -state normal
    $w delete 1.0 end
    foreach m [$w mark names] {
        if {[string match {src[0-9]*} $m] || [string match anchor:* $m]} {$w mark unset $m}
    }
    foreach t [$w tag names] {
        if {[regexp {^(?:lnk|mg|tb)[0-9]} $t]} {$w tag delete $t}
    }
    foreach c [winfo children $w] {destroy $c}
    set MD(links) 0
    if {[catch {
        set blocks [md::parse [$ed get 1.0 end-1c]]
        mdBlocks $w $blocks [dict create ind 0 tight 0 quote 0 bullet "" level 0]
    } err]} {
        $w insert end "Erro ao interpretar o Markdown:\n$::errorInfo" muted
    }
    # sem linha em branco sobrando no fim
    while {[$w get "end-2c"] eq "\n" && [$w compare end-2c > 1.0]} {$w delete end-2c}
    $w configure -state disabled
    set MD(L,$w) $MD(lines)
    set MD(R,$w) $MD(rules)
    set MD(D,$w) $MD(dir)
    mdRules $w
    mdSyncNow $host
}

# Tag de margens (criada sob demanda).
proc qc::mdMargin {w l1 l2} {
    set t mg$l1,$l2
    if {$t ni [$w tag names]} {
        $w tag configure $t -lmargin1 $l1 -lmargin2 $l2
        $w tag lower $t
    }
    return $t
}

# Marca a linha do fonte no ponto atual (sincronização da rolagem).
proc qc::mdMark {w line} {
    variable MD
    if {[llength $MD(lines)] && [lindex $MD(lines) end] >= $line} {return}
    $w mark set src$line end-1c
    $w mark gravity src$line left
    lappend MD(lines) $line
}

proc qc::mdBlocks {w blocks ctx} {
    set step 24
    foreach b $blocks {
        set ind [dict get $ctx ind]
        set tight [dict get $ctx tight]
        set bullet [dict get $ctx bullet]
        dict set ctx bullet ""
        mdMark $w [lindex $b 1]
        set s [$w index end-1c]
        set extra {}
        if {[dict get $ctx quote]} {lappend extra quote}
        # marcador de item de lista: na primeira linha do primeiro bloco
        set l1 $ind
        if {$bullet ne ""} {
            set l1 [expr {$ind - $step}]
            if {[lindex $b 0] in {p h}} {
                $w insert end $bullet [list bullet {*}$extra]
            } else {
                $w insert end "$bullet\n" [list bullet {*}$extra]
                $w tag add [mdMargin $w $l1 $ind] $s end-1c
                set s [$w index end-1c]
                set l1 $ind
            }
        }
        set mg [mdMargin $w $l1 $ind]
        switch -- [lindex $b 0] {
            h {
                lassign $b - - lv inl id
                $w mark set anchor:$id end-1c
                $w mark gravity anchor:$id left
                mdInl $w $inl [dict create kind h$lv b 1 i 0 tags [list head {*}$extra]]
                $w insert end \n $extra
                $w tag add $mg $s end-1c
                if {$lv <= 2} {mdRule $w $ind}
            }
            p {
                mdInl $w [lindex $b 2] [dict create kind body b 0 i 0 tags $extra]
                $w insert end \n $extra
                $w tag add $mg $s end-1c
                $w tag add [expr {$tight ? "tight" : "p"}] $s end-1c
            }
            code {
                lassign $b - - lang text
                set id [md::langId $lang]
                set c0 [$w index end-1c]
                $w insert end " \n" prepad
                set cs [$w index end-1c]
                $w insert end $text\n [list pre {*}$extra]
                foreach r [md::hlCode $id $text] {
                    lassign $r tag a z
                    $w tag add syn_$tag "$cs +$a chars" "$cs +$z chars"
                }
                $w insert end " \n" prepad
                set t pre$ind
                if {$t ni [$w tag names]} {
                    $w tag configure $t -lmargin1 [expr {$ind + 12}] -lmargin2 [expr {$ind + 12}]
                }
                $w tag add $t $c0 end-1c
                $w tag add $mg $c0 end-1c
                $w insert end \n gap
            }
            quote {
                set sub $ctx
                dict set sub ind [expr {$ind + 16}]
                dict incr sub quote
                dict set sub tight 0
                mdBlocks $w [lindex $b 2] $sub
                $w insert end \n sgap
            }
            hr {
                mdRule $w $ind
            }
            html {
                $w insert end [lindex $b 2]\n [list htmlblk {*}$extra]
                $w tag add $mg $s end-1c
                $w insert end \n gap
            }
            list {
                lassign $b - - ordered start tgt items
                set lvl [dict get $ctx level]
                set n $start
                foreach it $items {
                    lassign $it task sub
                    if {$task ne ""} {
                        set mk [expr {$task ? "☑" : "☐"}]
                    } elseif {$ordered} {
                        set mk "$n."
                    } else {
                        set mk [lindex {• ◦ ▪} [expr {$lvl % 3}]]
                    }
                    incr n
                    set c $ctx
                    dict set c ind [expr {$ind + $step}]
                    dict set c tight $tgt
                    dict set c level [expr {$lvl + 1}]
                    dict set c bullet "$mk\t"
                    set tb tb[expr {$ind + $step}]
                    if {$tb ni [$w tag names]} {
                        $w tag configure $tb -tabs [list [expr {$ind + $step}]]
                    }
                    set s2 [$w index end-1c]
                    if {![llength $sub]} {
                        $w insert end "$mk\n" bullet
                        $w tag add [mdMargin $w $ind $ind] $s2 end-1c
                    } else {
                        mdBlocks $w $sub $c
                    }
                    $w tag add $tb $s2 end-1c
                }
                if {$tgt && $lvl == 0} {$w insert end \n gap}
            }
            table {
                mdTable $w $b $ind $extra
            }
        }
    }
}

# Linha horizontal: um frame embutido que acompanha a largura do texto.
proc qc::mdRule {w ind} {
    variable MD
    variable C
    set f $w.r[llength $MD(rules)]
    frame $f -height 1 -background $C(mdrule) -bd 0 -highlightthickness 0
    set s [$w index end-1c]
    $w window create end -window $f -align center
    $w insert end \n
    $w tag add [mdMargin $w $ind $ind] $s end-1c
    $w tag add gap $s end-1c
    lappend MD(rules) [list $f $ind]
}

proc qc::mdRules {w} {
    variable MD
    if {![winfo exists $w] || ![info exists MD(R,$w)]} {return}
    set full [expr {[winfo width $w] - 2 * [$w cget -padx] - 6}]
    foreach r $MD(R,$w) {
        lassign $r f ind
        if {[winfo exists $f]} {$f configure -width [expr {max(10, $full - $ind)}]}
    }
}

# Tabela: colunas alinhadas com paradas de tabulação.
proc qc::mdTable {w b ind extra} {
    lassign $b - - aligns head rows
    set nc [llength $head]
    set fb [mdFont body]
    set fh [mdFont body 1]
    set gap 22
    for {set c 0} {$c < $nc} {incr c} {
        set wd [font measure $fh [md::plain [lindex $head $c]]]
        foreach r $rows {
            set wd [expr {max($wd, [font measure $fb [md::plain [lindex $r $c]]])}]
        }
        lappend widths [expr {$wd + $gap}]
    }
    set tabs {}
    set x [expr {$ind + 8}]
    foreach wd $widths a $aligns {
        switch -- $a {
            center {lappend tabs [expr {$x + $wd / 2}] center}
            right {lappend tabs [expr {$x + $wd - $gap}] right}
            default {lappend tabs $x left}
        }
        incr x $wd
    }
    set t tb[incr ::qc::MD(links)]x
    $w tag configure $t -tabs $tabs -lmargin1 $ind -lmargin2 $ind -spacing1 3 -spacing3 3
    set s [$w index end-1c]
    foreach cell $head {
        $w insert end \t $extra
        mdInl $w $cell [dict create kind body b 1 i 0 tags $extra]
    }
    $w insert end \n
    $w tag add th $s end-1c
    foreach r $rows {
        foreach cell $r {
            $w insert end \t $extra
            mdInl $w $cell [dict create kind body b 0 i 0 tags $extra]
        }
        $w insert end \n
    }
    $w tag add $t $s end-1c
    $w insert end \n gap
}

# Inlines; st: kind (fonte), b, i, tags (tags extras).
proc qc::mdInl {w nodes st} {
    variable MD
    variable C
    foreach nd $nodes {
        set kind [dict get $st kind]
        set font [mdFont $kind [dict get $st b] [dict get $st i]]
        set tags [list $font {*}[dict get $st tags]]
        if {$font ni [$w tag names]} {$w tag configure $font -font $font}
        switch -- [lindex $nd 0] {
            t {$w insert end [string map {\n " "} [lindex $nd 1]] $tags}
            br {$w insert end \n $tags}
            code {
                set mf [mdFont mono [dict get $st b] [dict get $st i]]
                if {$mf ni [$w tag names]} {$w tag configure $mf -font $mf}
                $w insert end [lindex $nd 1] [list $mf icode {*}[dict get $st tags]]
            }
            em {mdInl $w [lrange $nd 1 end] [dict replace $st i 1]}
            strong {mdInl $w [lrange $nd 1 end] [dict replace $st b 1]}
            del {mdInl $w [lrange $nd 1 end] [dict replace $st tags [list del {*}[dict get $st tags]]]}
            html {$w insert end [lindex $nd 1] [list {*}$tags muted]}
            link {
                lassign $nd - href title
                set lt lnk[incr MD(links)]
                $w tag bind $lt <1> [list qc::mdOpenLink $href $w]
                $w tag bind $lt <Enter> [list set ::qc::status $href]
                set inner [lrange $nd 3 end]
                if {![llength $inner]} {set inner [list [list t $href]]}
                mdInl $w $inner [dict replace $st tags [list link $lt {*}[dict get $st tags]]]
            }
            img {
                lassign $nd - src alt
                set img [mdImage $src]
                if {$img ne ""} {
                    $w image create end -image $img -padx 2 -pady 4
                } else {
                    $w insert end "\[🖼 [expr {$alt ne "" ? $alt : [file tail $src]}]\]" [list {*}$tags muted]
                }
            }
        }
    }
}

# Imagem local (PNG/GIF/SVG...) reduzida para caber; "" se não der.
proc qc::mdImage {src} {
    variable MD
    if {[regexp {^[a-z]+://} $src] && ![string match file://* $src]} {return ""}
    set p [regsub {^file://} $src ""]
    set p [regsub {[?#].*$} $p ""]
    if {[file pathtype $p] ne "absolute"} {set p [file join $MD(dir) $p]}
    if {![file isfile $p]} {return ""}
    set key img,[file normalize $p]
    set mt [file mtime $p]
    if {[info exists MD($key)] && [lindex $MD($key) 0] == $mt} {return [lindex $MD($key) 1]}
    if {[catch {image create photo -file $p} img]} {return ""}
    set maxw 700
    set wd [image width $img]
    if {$wd > $maxw} {
        set k [expr {int(ceil($wd / double($maxw)))}]
        set small [image create photo]
        $small copy $img -subsample $k $k
        image delete $img
        set img $small
    }
    if {[info exists MD($key)]} {catch {image delete [lindex $MD($key) 1]}}
    set MD($key) [list $mt $img]
    return $img
}

proc qc::mdOpenLink {href {w .md.t}} {
    variable MD
    if {[string match #* $href]} {
        set id [string range $href 1 end]
        if {"anchor:$id" in [$w mark names]} {$w yview anchor:$id}
        return
    }
    if {[regexp {^(?:https?|ftp|mailto|file):} $href]} {
        mdOpenExternal $href
        return
    }
    set p [regsub {#.*$} $href ""]
    if {[file pathtype $p] ne "absolute"} {set p [file join $MD(D,$w) $p]}
    if {![file exists $p]} {
        set ::qc::status "Não encontrado: $p"
        return
    }
    set ext [string tolower [file extension $p]]
    if {[file isfile $p] && ([langForFileAny $p] ne "" || $ext in {.txt ""})} {
        openFile $p
    } else {
        mdOpenExternal $p
    }
}

proc qc::mdOpenExternal {target} {
    switch -- $::tcl_platform(os) {
        Darwin {set cmd [list open $target]}
        default {
            if {$::tcl_platform(platform) eq "windows"} {
                set cmd [list cmd /c start "" $target]
            } else {
                set cmd [list xdg-open $target]
            }
        }
    }
    if {[catch {exec {*}$cmd >/dev/null 2>@1 &} err]} {
        set ::qc::status "Não foi possível abrir: $err"
    } else {
        set ::qc::status "Abrindo: $target"
    }
}

# Rolagem do editor -> pré-visualização (interpola entre os blocos).
proc qc::mdSync {{host ""}} {
    variable MD
    if {$host eq ""} {set host [winfo parent $::qc::ed]}
    if {[info exists MD(sync,$host)] || ![mdShown $host]} {return}
    set MD(sync,$host) 1
    # tclint-disable-next-line command-args
    after idle [list qc::mdSyncNow $host]
}

proc qc::mdSyncNow {{host ""}} {
    variable MD
    if {$host eq ""} {set host [winfo parent $::qc::ed]}
    unset -nocomplain MD(sync,$host)
    if {![winfo exists $host] || ![mdShown $host]} {return}
    set ed [hostEd $host]
    set w [mdPv $host].t
    if {![winfo exists $ed] || ![llength $MD(L,$w)]} {return}
    set lines $MD(L,$w)
    lassign [$ed yview] top bot
    if {$top <= 0} {$w yview moveto 0; return}
    if {$bot >= 1} {$w yview moveto 1; return}
    set T [lindex [split [$ed index @0,0] .] 0]
    set k [lsearch -bisect -integer $lines $T]
    if {$k < 0} {$w yview moveto 0; return}
    set l0 [lindex $lines $k]
    if {[catch {
        set y0 [$w count -ypixels 1.0 src$l0]
        if {$k + 1 < [llength $lines]} {
            set l1 [lindex $lines $k+1]
            set y1 [$w count -ypixels 1.0 src$l1]
        } else {
            set l1 [lindex [split [$ed index end] .] 0]
            set y1 [$w count -ypixels 1.0 end]
        }
        set f [expr {$l1 > $l0 ? ($T - $l0) / double($l1 - $l0) : 0}]
        set y [expr {$y0 + $f * ($y1 - $y0)}]
        set total [$w count -ypixels 1.0 end]
        if {$total > 0} {$w yview moveto [expr {$y / double($total)}]}
    }]} {
        catch {$w yview src$l0}
    }
}

# Duplo clique na pré-visualização: leva o editor à linha do bloco.
proc qc::mdGotoSource {w x y} {
    set e [hostEd $::qc::MD(H,$w)]
    if {$e eq "" || ![winfo exists $e]} {return}
    activateTab $e
    set idx [$w index @$x,$y]
    set m [$w mark previous "$idx +1c"]
    while {$m ne "" && ![regexp {^src([0-9]+)$} $m -> line]} {
        set m [$w mark previous $m]
    }
    if {$m eq ""} {set line 1}
    gotoLine $line
    focus $::qc::ed
}

# --- exportação ------------------------------------------------------------

proc qc::mdHtmlTitle {} {
    variable file
    return [expr {$file ne "" ? [file rootname [file tail $file]] : ""}]
}

proc qc::mdExport {} {
    variable file
    variable cfg
    if {$::qc::lang ne "markdown"} {
        set ::qc::status "Exportar para HTML é para arquivos Markdown"
        return
    }
    set opts [list -parent . -title "Exportar para HTML" -defaultextension .html \
        -filetypes {{HTML {.html .htm}} {"Todos os arquivos" *}}]
    if {$file ne ""} {
        lappend opts -initialdir [file dirname $file] \
            -initialfile [file rootname [file tail $file]].html
    } elseif {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
        lappend opts -initialdir $cfg(lastdir)
    }
    set path [tk_getSaveFile {*}$opts]
    if {$path eq ""} {return}
    # caminhos relativos (imagens, links) continuam valendo se o HTML for
    # gravado em outra pasta
    set base ""
    if {$file ne "" && [file normalize [file dirname $path]] ne [file dirname $file]} {
        set base [file dirname $file]
    }
    set html [md::toHtml [$::qc::ed get 1.0 end-1c] "" $base]
    if {[catch {writeFile $path $html} err]} {
        tk_messageBox -parent . -icon error -title qconsole \
            -message "Não foi possível exportar." -detail $err
        return
    }
    set ::qc::status "Exportado: $path"
}

# Abre o documento no navegador (HTML temporário).
proc qc::mdBrowser {} {
    variable file
    if {$::qc::lang ne "markdown"} {
        set ::qc::status "Abrir no navegador é para arquivos Markdown"
        return
    }
    set base [expr {$file ne "" ? [file dirname $file] : [pwd]}]
    set name [expr {$file ne "" ? [file rootname [file tail $file]] : "sem-titulo"}]
    set path [file join [tmpDir] $name.html]
    if {[catch {
        writeFile $path [md::toHtml [$::qc::ed get 1.0 end-1c] "" $base]
    } err]} {
        set ::qc::status "Não foi possível gerar o HTML: $err"
        return
    }
    mdOpenExternal $path
}

# ===========================================================================
# Linguagens embutidas
# ===========================================================================

# --- Tcl -------------------------------------------------------------------

qc::language tcl {
    name     Tcl/Tk
    ext      {.tcl .tk .tm .test}
    comment  #
    indent   4
    indentAfter {[\{\[]\s*$}
    dedentChars "\}"
    autoPairs {() [] \{\} \"\"}
    rainbow  1
    tokens {
        comment {(?:^|;)[ \t]*(#[^\n]*)}
        escape  {\\.}
        string  {"(?:[^"\\]|\\.)*"?}
        var     {\$(?:\{[^\}\n]*\}|(?:::)?[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*(?:\([^)\n]*\))?)}
        number  {\m(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)\M}
        option  {[ \t](-[A-Za-z][-A-Za-z0-9_]*)}
        word    {(?:::)?[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*}
        brace   {[][{}]}
    }
    defWords {proc method}
    styles   { builtin {#ffc66d {}} }
    runners {
        {name tclsh label tclsh exe {tclsh9.0 tclsh8.6 tclsh} args {%O %W %F %A}
         wrapperExt .tcl versionStdin {puts [info patchlevel]}
         versionRe {([0-9]+\.[0-9]+[.0-9a-z]*)} optsHint "(opções do tclsh)"}
    }
    errPatterns {{\(file "%F" line ([0-9]+)\)}}
    linters {
        {name tclint label tclint exe {tclint} args {%C %F}
         config {tclint.toml .tclint} configArg {-c %P}
         errPatterns {{%F:([0-9]+):([0-9]+):}} tag warn errRe {syntax error}}
    }
    formatters {
        {name tclfmt label tclfmt exe {tclfmt} args {%C %F} output stdout
         config {tclint.toml .tclint} configArg {-c %P}
         errPatterns {{%F:([0-9]+):([0-9]+):}}}
    }
}

# Wrapper: executa o script, devolve o resultado e o errorInfo por um
# protocolo simples no stderr (\x01R / \x01E) e mantém janelas Tk abertas.
dict set qc::L(tcl) runners [list [dict replace [lindex [qc::lget runners tcl] 0] wrapper {
    set ::__qc_file [lindex $argv 0]
    set argv [lrange $argv 1 end]
    set argc [llength $argv]
    set argv0 $::__qc_file
    fconfigure stdout -buffering none -encoding utf-8
    fconfigure stderr -encoding utf-8
    set ::__qc_code [catch {uplevel #0 [list source -encoding utf-8 $::__qc_file]} ::__qc_res ::__qc_opts]
    if {$::__qc_code == 1} {
        set ei [dict get $::__qc_opts -errorinfo]
        set k [string last "(file \"$::__qc_file\" line" $ei]
        if {$k >= 0} {
            set e [string first "\n" $ei $k]
            if {$e > 0} { set ei [string range $ei 0 $e-1] }
        }
        puts stderr "\x01E[string map {\n \x02} $ei]"
        exit 1
    }
    if {$::__qc_res ne ""} {
        puts stderr "\x01R[string map {\n \x02} $::__qc_res]"
    }
    if {[info commands ::tk] ne "" && [winfo exists .]} { tkwait window . }
    exit 0
}]]

proc qc::lang::tcl::init {} {
    set i [interp create]
    set cmds [$i eval {info commands}]
    interp delete $i
    lappend cmds oo::class oo::define oo::objdefine oo::object oo::copy self next \
        my method constructor destructor msgcat::mc else elseif then finally on trap
    set tk {
        button canvas checkbutton entry frame label labelframe listbox menu
        menubutton message panedwindow radiobutton scale scrollbar spinbox text
        toplevel bind bindtags bell clipboard destroy event focus font grab grid
        image lower option pack place raise selection send tk tkwait winfo wm
        tk_messageBox tk_getOpenFile tk_getSaveFile tk_chooseColor
        tk_chooseDirectory tk_popup tk_setPalette tk_dialog ttk::button
        ttk::checkbutton ttk::combobox ttk::entry ttk::frame ttk::label
        ttk::labelframe ttk::menubutton ttk::notebook ttk::panedwindow
        ttk::progressbar ttk::radiobutton ttk::scale ttk::scrollbar
        ttk::separator ttk::sizegrip ttk::spinbox ttk::treeview ttk::style
    }
    dict set ::qc::L(tcl) words [dict create keyword $cmds builtin $tk]
}

# Comandos só são destacados em posição de comando.
# Bibliotecas: pastas de "info library", do Tk e do auto_path.
proc qc::lang::tcl::apiSources {} {
    set out {}
    set cands [list [info library]]
    if {[info exists ::tk_library]} {lappend cands $::tk_library}
    lappend cands {*}$::auto_path
    foreach d $cands {
        set d [file normalize $d]
        if {[file isdirectory $d] && $d ni $out} {lappend out $d}
    }
    # pastas dentro de outras da lista seriam lidas duas vezes
    lmap d $out {
        foreach o $out {
            if {$o ne $d && [string first $o/ $d] == 0} {set d ""; break}
        }
        if {$d eq ""} {continue}
        set d
    }
}

# Nome completo de um proc de biblioteca: o qualificado como escrito ou,
# se indentado, prefixado pelo "namespace eval" que o envolve. "" = proc
# dentro de outra construção (descartado).
proc qc::lang::tcl::defQual {lines L name} {
    set name [regsub {^::} $name {}]
    if {[string first :: $name] >= 0} {return $name}
    regexp {^[ \t]*} [lindex $lines $L] ind
    set n [string length $ind]
    if {$n == 0} {return $name}
    for {set k [expr {$L - 1}]} {$k >= 0} {incr k -1} {
        set l [lindex $lines $k]
        if {
            [regexp {^([ \t]*)namespace[ \t]+eval[ \t]+([^ \t\{]+)} $l -> i2 ns]
            && [string length $i2] < $n
        } {
            set ns [regsub {^::} $ns {}]
            return [expr {$ns eq "" ? $name : "${ns}::$name"}]
        }
        if {[regexp {^[^ \t#\}]} $l]} {return ""}
    }
    return ""
}

proc qc::lang::tcl::wordTag {word tag txt a} {
    if {$tag eq ""} {return ""}
    if {$word in {else elseif then finally on trap}} {return keyword}
    set p [expr {$a - 1}]
    while {$p >= 0 && [string index $txt $p] in {" " "\t"}} {incr p -1}
    if {$p >= 0 && [string index $txt $p] ni [list \n \; \[ \{]} {return ""}
    return $tag
}

proc qc::lang::tcl::stderrLine {line} {
    switch -glob -- $line {
        "\x01R*" {return [list result "Resultado: [string map {\x02 \n} [string range $line 2 end]]"]}
        "\x01E*" {
            set out {}
            foreach l [split [string range $line 2 end] \x02] {lappend out stderr $l}
            return $out
        }
    }
    return -
}

# tclsh da mesma instalação do wish, se houver.
proc qc::lang::tcl::findExe {rn} {
    set exe [info nameofexecutable]
    if {[string match -nocase tclsh* [file tail $exe]]} {return [list $exe]}
    set dir [file dirname $exe]
    set v [info tclversion]
    foreach n [list tclsh$v tclsh[string map {. ""} $v] tclsh] {
        foreach c [list [file join $dir $n] [file join $dir $n.exe]] {
            if {[file isfile $c] && [file executable $c]} {return [list $c]}
        }
    }
    return ""
}

# --- Scala 3 ---------------------------------------------------------------

qc::language scala {
    name     "Scala 3"
    ext      {.sc .scala}
    comment  //
    commentRe {\s*//.*$}
    indent   2
    indentAfter {(?:[\{\[\(]|=>?|:|<-|->|\m(?:then|else|do|yield|try|catch|finally|match|with))\s*$}
    tokens {
        directive {//>[^\n]*}
        comment   {//(?!>)[^\n]*|/\*(?:[^*]|\*(?!/))*(?:\*/)?}
        string    {(?:[[:alpha:]_][[:alnum:]_]*)?(?:"""(?:[^"]|"(?!""))*(?:"""+)?|"(?:[^"\\\n]|\\.)*"?)}
        string    {'(?:\\u[0-9a-fA-F]{4}|\\.|[^'\\\n])'}
        number    {\m(?:0[xX][0-9a-fA-F_]+[lL]?|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][-+]?[0-9]+)?[lLfFdD]?)\M}
        annot     {@[[:alpha:]_][[:alnum:]_]*}
        word      {[[:alpha:]_][[:alnum:]_]*}
        brace     {[][{}()]}
    }
    words {
        keyword {
            abstract case catch class def do else enum export extends false final
            finally for given if implicit import lazy match new null object
            override package private protected return sealed super then this throw
            trait true try type val var while with yield
            as derives end extension infix inline opaque open transparent using
        }
    }
    defWords {def val var class object trait enum type given}
    capType  type
    sub      { string {{^[[:alpha:]_]} interp {\$\{[^\}\n]*\}?|\$[[:alpha:]_][[:alnum:]_]*}} }
    runners {
        {name scala label Scala exe {scala} args {run %O %F %--A}
         versionRe {Scala version[^:]*:\s*(\S+)}
         optsHint "-S 3.3.4   --dep com.lihaoyi::os-lib:0.11.8   -J -Xmx2g   -q"}
        {name scala-cli label "Scala CLI" exe {scala-cli} args {run %O %F %--A}
         versionRe {Scala version[^:]*:\s*(\S+)}
         optsHint "-S 3.3.4   --dep com.lihaoyi::os-lib:0.11.8   -J -Xmx2g   -q"}
    }
    errPatterns {{%F:([0-9]+)(?::([0-9]+))?}}
    infoRe   {^\[info\]}
    warnRe   {^\[warn\]}
    grayInfo 1
    linters {
        {name scala-compile label "scala compile" useRunner 1
         args {compile %O -O -Wunused:imports,privates,locals -O -deprecation -O -feature %F}
         warnRe {Warning|^\[warn\]} errRe {Error|^\[error\]}
         infoRe {^(?:\[info\]|Compiling|Compiled|Compilation failed|Download|[0-9]+ (?:errors?|warnings?) found)}}
    }
    formatters {
        {name scalafmt label scalafmt useRunner 1 args {fmt %C %F} output inplace
         config {.scalafmt.conf} configArg {--scalafmt-conf %P}}
    }
}

# "scala" (fonte com @main/main/App) ou "sc" (script com instruções soltas).
proc qc::lang::scala::kind {code} {
    if {[regexp {(?n)^\s*@main\M|\mdef\s+main\s*[\[(]|\mextends\s+App\M} $code]} {
        return scala
    }
    return sc
}

proc qc::lang::scala::defaultExt {code} {
    return .[kind $code]
}

proc qc::lang::scala::prepare {code selOnly file name} {
    set ext [string tolower [file extension $file]]
    if {!$selOnly && $ext in {.sc .scala}} {
        set k [string range $ext 1 end]
    } else {
        set k [kind $code]
    }
    if {$k eq "sc"} {
        # o nome do script vira nome de objeto: precisa ser um identificador
        set base [expr {$file eq "" ? "script" : [file rootname [file tail $file]]}]
        set base [regsub -all {[^A-Za-z0-9_]} $base _]
        if {![regexp {^[A-Za-z_]} $base]} {set base "s$base"}
        return [list name $base.sc mode script]
    }
    return [list name [expr {$ext eq ".scala" ? [file tail $file] : "Main.scala"}] mode "fonte .scala"]
}

qc::template scala JVM {// Modelo JVM -- configuração por diretivas "//> using" do scala-cli.
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/reference/directives

// versão do Scala e do Java (a JVM é baixada automaticamente se necessário)
//> using scala @VERSION@
//> using jvm 25
// //> using jvm temurin:21

// opções da JVM e propriedades do sistema (System.getProperty)
//> using javaOpt -Xmx1g -Dfile.encoding=UTF-8 --sun-misc-unsafe-memory-access=allow
//> using javaProp app.env=dev

// opções do compilador, incluindo recursos experimentais
//> using options -deprecation -feature -unchecked -Wunused:all
//> using options -experimental
// //> using options -language:experimental.captureChecking
// //> using options -Yexplicit-nulls

// dependências ("::" = biblioteca Scala, ":" = biblioteca Java)
//> using dep com.lihaoyi::os-lib:0.11.8
//> using dep com.lihaoyi::upickle:4.4.3
//> using dep com.lihaoyi::pprint:0.9.6
// //> using dep org.postgresql:postgresql:42.7.4
// //> using toolkit default
//> using test.dep org.scalameta::munit:1.3.6

// outras configurações
// //> using repository sonatype:snapshots
// //> using resourceDir ./resources
// //> using mainClass principal

import upickle.default.*

case class Pessoa(nome: String, idade: Int) derives ReadWriter

@main def principal(args: String*): Unit =
  println(s"Java ${System.getProperty("java.version")} · app.env=${sys.props("app.env")}")
  println(s"Argumentos: ${args.mkString(", ")}")

  val pessoas = Seq(Pessoa("Ana", 31), Pessoa("Bruno", 27))
  val json = write(pessoas, indent = 2)
  println(json)
  pprint.pprintln(read[Seq[Pessoa]](json))

  println(s"Diretório atual: ${os.pwd}")
  os.list(os.pwd).take(5).foreach(p => println(s"  ${p.last}"))
}

qc::template scala Scala.js {// Modelo Scala.js -- configuração por diretivas "//> using" do scala-cli.
// Executa no Node.js (precisa do "node" no PATH).
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/guides/advanced/scala-js

//> using scala @VERSION@
//> using platform scala-js
//> using jsVersion 1.22.0

// módulos: es (ECMAScript) | commonjs | nomodule
//> using jsModuleKind es
// modo do linker: dev (rápido) | release (otimizado)
//> using jsMode dev
// //> using jsEmitSourceMaps true
// //> using jsDom true

// opções do compilador, incluindo recursos experimentais
//> using options -deprecation -feature -experimental

// dependências multiplataforma usam "::" também antes da versão
//> using dep com.lihaoyi::upickle::4.4.3
//> using dep com.lihaoyi::pprint::0.9.6
// //> using dep org.scala-js::scalajs-dom::2.8.1
//> using test.dep org.scalameta::munit::1.3.6

import scala.scalajs.js
import scala.scalajs.js.annotation.*
import upickle.default.*

case class Pessoa(nome: String, idade: Int) derives ReadWriter

// função JavaScript nativa exposta ao Scala
@js.native
@JSGlobal("Math")
object JSMath extends js.Object:
  def random(): Double = js.native

@main def principal(): Unit =
  val proc = js.Dynamic.global.process
  println(s"Node ${proc.version} · plataforma ${proc.platform}")

  val json = write(Seq(Pessoa("Ana", 31), Pessoa("Bruno", 27)))
  println(json)
  pprint.pprintln(read[Seq[Pessoa]](json))

  val obj = js.Dictionary[js.Any]("sorteio" -> JSMath.random(), "ok" -> true)
  println(js.JSON.stringify(obj))
}

qc::template scala "Scala Native" {// Modelo Scala Native -- configuração por diretivas "//> using" do scala-cli.
// Gera um executável nativo (precisa do clang/LLVM). A 1ª compilação é lenta.
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/guides/advanced/scala-native

//> using scala @VERSION@
//> using platform scala-native
//> using nativeVersion 0.5.12

// modo: debug | release-fast | release-size | release-full
//> using nativeMode debug
// coletor de lixo: immix | commix | boehm | none
//> using nativeGc immix
// otimização no link: none | thin | full
// //> using nativeLto thin

// opções do compilador, incluindo recursos experimentais
//> using options -deprecation -feature -experimental

// dependências multiplataforma usam "::" também antes da versão
//> using dep com.lihaoyi::upickle::4.4.3
//> using dep com.lihaoyi::os-lib::0.11.8
//> using test.dep org.scalameta::munit::1.3.6

import scala.scalanative.unsafe.*
import scala.scalanative.libc.{stdio, stdlib}
import upickle.default.*

case class Pessoa(nome: String, idade: Int) derives ReadWriter

@main def principal(): Unit =
  println(write(Seq(Pessoa("Ana", 31), Pessoa("Bruno", 27))))
  println(s"Diretório atual: ${os.pwd}")

  // chamando a libc diretamente
  Zone:
    stdio.printf(c"Olá do C: %s (HOME=%s)\n", toCString("Scala Native"), stdlib.getenv(c"HOME"))
  stdio.fflush(null)
}

# --- Groovy ------------------------------------------------------------------
# defWordsRe: "def nome", mas não o tipo de "def String s" / "val List<T> xs".
# Scripts rodam com "groovy" (Groovy 2.4 a 6). O log do Java (JUL) sai sem o
# cabeçalho de data/classe que o Groovy 6 põe antes de "Caught:".

# tclint-disable line-length
qc::language groovy {
    name     Groovy
    ext      {.groovy .gvy .gy .gsh .gradle}
    comment  //
    commentRe {\s*//.*$}
    indent   4
    indentAfter {(?:[\{\[\(]|->)\s*$}
    tokens {
        directive {^#![^\n]*}
        comment   {//[^\n]*|/\*(?:[^*]|\*(?!/))*(?:\*/)?}
        string    {"""(?:[^"\\]|\\.|"(?!""))*(?:""")?|'''(?:[^'\\]|\\.|'(?!''))*(?:''')?|"(?:[^"\\\n]|\\.)*"?|'(?:[^'\\\n]|\\.)*'?}
        string    {\$/(?:[^/$]|\$[/$]|\$(?![/$])|/(?!\$))*(?:/\$)?}
        string    {[=~][ \t]*(/(?:[^/*\\\n]|\\.)(?:[^/\\\n]|\\.)*/)}
        number    {\m(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][-+]?[0-9]+)?)[lLiIgGdDfF]?\M}
        annot     {@[[:alpha:]_][[:alnum:]_.]*}
        word      {[[:alpha:]_][[:alnum:]_]*}
        brace     {[][{}()]}
    }
    words {
        keyword {
            abstract as assert async await break case catch class const continue
            def default defer do else enum extends false final finally for goto if
            implements import in instanceof interface module native new non null
            package permits private protected public record return sealed static
            strictfp super switch synchronized this threadsafe throw throws trait
            transient true try val var volatile while yield
        }
        type {boolean byte char double float int long short void}
        builtin {
            println print printf sprintf it delegate owner evaluate sleep use with
            tap each eachWithIndex collect findAll find inject every any grep
        }
    }
    defWords {def val var class interface trait enum record}
    defWordsRe {(?:^|[^\w-])(?:%W)(?:[ \t]+(?:%W))*[ \t]+(%N)(?![ \t]*(?:<[^\n()=]*>)?(?:\[\])*[ \t]+[[:alpha:]_][[:alnum:]_]*[ \t]*(?:[=;,)(]|$))}
    defPatterns {
        {\m(?:val|var|def|final)[ \t]+(?:[A-Z][[:alnum:]_.]*(?:<[^\n()=]*>)?|boolean|byte|char|double|float|int|long|short)(?:\[\])*[ \t]+([[:alpha:]_][[:alnum:]_]*)}
        {^[ \t]*(?:(?:public|private|protected|static|final|abstract|synchronized|default|def)[ \t]+)*(?:[A-Z][[:alnum:]_.]*(?:<[^\n()=]*>)?|void|boolean|byte|char|double|float|int|long|short)(?:\[\])*[ \t]+([[:alpha:]_][[:alnum:]_]*)[ \t]*\(}
    }
    capType  type
    sub      { string {{^(?:"|\$/|/)} interp {\$\{[^\}\n]*\}?|\$[[:alpha:]_][[:alnum:]_]*(?:\.[[:alpha:]_][[:alnum:]_]*)*}} }
    runners {
        {name groovy label Groovy exe {groovy}
         args {-Djava.util.logging.SimpleFormatter.format=%5$s%6$s%n %O %F %A}
         version {--version} versionRe {Groovy Version: (\S+)}
         searchHint "groovy (PATH, GROOVY_HOME ou SDKMAN)"
         optsHint "-cp lib/*   --compile-static   -Dchave=valor   -Dgroovy.grape.report.downloads=true"}
    }
    errPatterns {{%F: ([0-9]+): .*@ line [0-9]+, column ([0-9]+)} {%F: ([0-9]+):} {\(%F:([0-9]+)\)}}
    warnRe   {^WARNING:|^\s*module not found:}
    infoRe   {^\s+at (?:groovy\.|org\.(?:codehaus|apache)\.groovy\.|java\.|jdk\.|sun\.)|^\s+\.\.\. [0-9]+ more|^\s*(?::{2,}|====|file:|https?://|-- artifact|/\S+\.(?:xml|pom|jar)$|tried$)|^(?:Preparing to download|Downloaded )|^\s+\[(?:SUCCESSFUL|NOT REQUIRED|FAILED)}
    linters {
        {name groovyc label groovyc exe {groovyc} nearRunner 1
         args {-d %D/classes %O %F}
         optsKeep {-cp 1 -classpath 1 --classpath 1 --compile-static 0 --type-checked 0 -indy 0}
         groupRe {: [0-9]+: } errRe {.}
         ignoreRe {startup failed:$|^[0-9]+ errors?$}}
        {name npm-groovy-lint label npm-groovy-lint exe {npm-groovy-lint}
         args {--output txt --loglevel warning --failon error %C %F}
         config {.groovylintrc.json .groovylintrc.js .groovylintrc} configArg {--config %P}
         errPatterns {{^\s*([0-9]+)\s+(?:error|warning|info)\M}}
         warnRe {^\s*[0-9]+\s+warning\M} errRe {^\s*[0-9]+\s+error\M}
         ignoreRe {^[│├┌└]|npm-groovy-lint results|^Failure:|^ *[0-9]+ (?:warning|info)\(s\)|\.groovy$|\.gradle$}}
    }
    formatters {
        {name npm-groovy-lint label "npm-groovy-lint --format" exe {npm-groovy-lint}
         args {--format %C %F} output inplace
         config {.groovylintrc.json .groovylintrc.js .groovylintrc} configArg {--config %P}
         errPatterns {{^\s*([0-9]+)\s+(?:error|warning|info)\M}}
         errRe {^\s*[0-9]+\s+error\M}
         ignoreRe {^[│├┌└]|npm-groovy-lint results|^Failure:|^ *[0-9]+ (?:warning|info)\(s\)|\.groovy$|\.gradle$}}
    }
}
# tclint-enable line-length

# Desestruturação ("def (a, b) = ...", com tipo, "x: a" ou "*resto"): um
# padrão de F12 por posição na lista (o regexp -all não acha sobrepostos).
apply {{} {
    set type {(?:[A-Z][[:alnum:]_.]*(?:<[^\n()=]*>)?|boolean|byte|char|double|float|int|long|short)(?:\[\])*}
    set pre {(?:\*|[[:alpha:]_][[:alnum:]_]*[ \t]*:[ \t]*|TYPE[ \t]+)?}
    set pre [string map [list TYPE $type] $pre]
    for {set k 0} {$k < 8} {incr k} {
        dict lappend ::qc::L(groovy) defPatterns [string cat \
            {\m(?:def|var|val|final)[ \t]*\((?:[^,()\n]*,)} "{$k}" {[ \t]*} $pre \
            {([[:alpha:]_][[:alnum:]_]*)[ \t]*(?=(?:,[^()\n]*)?\)[ \t]*=(?![=~]))}]
    }
}}

# Exceção não tratada no Groovy 6: o log do Java traz "Caught: {0}" e a
# pilha completa (até uma linha em branco); depois vem a pilha já limpa, sem
# os quadros internos do Groovy. Só a segunda é mostrada.
namespace eval qc::lang::groovy {
    variable skip 0
}

proc qc::lang::groovy::stderrLine {line} {
    variable skip
    # @Grab que não resolveu: a mensagem não diz a linha; aponta para o
    # @Grab da dependência no editor
    if {[regexp {unresolved dependency: ([^#\s]+)#([^;\s]+);([^:\]\s]+)} $line -> g a v]} {
        if {[string match "java.lang.RuntimeException:*" $line]} {return {}}
        set n [grabLine $g $a]
        set msg "Dependência não encontrada: $g:$a:$v"
        if {$n > 0} {append msg "  ($::qc::R(name):$n)"}
        return [list stderr $msg]
    }
    if {[string trim $line] eq "Caught: {0}"} {
        set skip 1
        return {}
    }
    if {$skip} {
        if {[string trim $line] eq ""} {
            set skip 0
            return {}
        }
        # 1ª linha: a exceção; depois, quadros "at", "... n more", "Caused by"
        if {$skip == 1 || [regexp {^\s|^Caused by:} $line]} {
            set skip 2
            return {}
        }
        set skip 0
    }
    return -
}

# Linha (do script executado) do @Grab de grupo:artefato, ou 0.
proc qc::lang::groovy::grabLine {g a} {
    upvar #0 ::qc::R R
    if {![info exists R(ed)] || ![winfo exists $R(ed)]} {return 0}
    set q {['"]}
    set ga [::qc::reQuote $g:$a]
    set ma "group\\s*\[:=\]\\s*$q[::qc::reQuote $g]$q.*module\\s*\[:=\]\\s*$q[::qc::reQuote $a]$q"
    set L 0
    foreach ln [split [$R(ed) get 1.0 end-1c] \n] {
        incr L
        if {[string match *@Grab* $ln] && ([regexp -- $ga $ln] || [regexp -- $ma $ln])} {
            set n [expr {$L - $R(lineoff)}]
            return [expr {$n > 0 && $n <= $R(nlines) ? $n : 0}]
        }
    }
    return 0
}

# Palavras-chave contextuais do Groovy (as do Groovy 6 inclusive): também
# valem como nomes ("def val = 5", "record.a", "[async, await]"), então só são
# destacadas em posição de palavra-chave.
namespace eval qc::lang::groovy {
    variable soft {val var record async await defer module trait yield permits sealed non}
    variable mods {(?:(?:public|private|protected|static|final|abstract|synchronized|default)[ \t]+)*}
    variable type {(?:[A-Z][[:alnum:]_.]*(?:<[^\n()=]*>)?|void|boolean|byte|char|double|float|int|long|short)(?:\[\])*}
}

# Também: nome de método declarado com tipo ("String nome(", "static void
# main(") e de variável declarada com tipo ("val String s", "final int n")
# recebem a tag de definição; o tipo nesse caso fica como tipo.
proc qc::lang::groovy::wordTag {word tag txt a} {
    variable soft
    variable mods
    variable type
    set e [expr {$a + [string length $word]}]
    set ls [expr {[string last \n $txt $a] + 1}]
    set before [string range $txt $ls [expr {$a - 1}]]
    set nl [string first \n $txt $e]
    set after [string trimleft [string range $txt $e [expr {$nl < 0 ? "end" : $nl - 1}]] " \t"]
    if {$tag eq "keyword" && $word in $soft} {
        if {$word eq "non"} {
            return [expr {[string match -sealed* [string range $txt $e end]] ? "keyword" : ""}]
        }
        # nome: depois de "." ou "def", antes de atribuição, separador ou fim
        if {[regexp {(?:\.|\mdef[ \t]+)$} $before]} {return ""}
        if {$after eq "" || [regexp {^(?:=(?![=~])|[,;:.)\]\}]|\?\.)} $after]} {return ""}
        if {[string index $after 0] eq "("} {
            # "val (a, b) = ...": desestruturação; fora isso, chamada val(x)
            if {$word in {val var} && [regexp {^\([^()\n]*\)[ \t]*=(?![=~])} $after]} {
                return keyword
            }
            if {$word ne "await"} {return ""}
        }
        return keyword
    }
    if {$tag ne ""} {return $tag}
    # desestruturação: "def (a, b) = ...", "val (int a, String b) = ...",
    # "def (x: a, y: b) = ...", "def (a, *resto) = ..." (o nome é o último
    # termo de cada item)
    if {[regexp {\m(?:def|var|val|final)[ \t]*\([^()\n]*$} $before]
        && [regexp {^(?:,[^()\n]*)?\)[ \t]*=(?![=~])} $after]} {
        return defname
    }
    # "val String s": o tipo continua tipo (não é o nome definido)
    if {[string is upper [string index $word 0]]
        && [regexp {\m(?:val|var|def|final)[ \t]+$} $before]
        && [regexp {^(?:<[^\n()=]*>)?(?:\[\])*[ \t]*[[:alpha:]_]} $after]} {
        return type
    }
    if {[regexp "\\m(?:val|var|def|final)\[ \t\]+$type\[ \t\]+\$" $before]} {return defname}
    if {[string index $after 0] ne "("} {return ""}
    if {[regexp "^\[ \t\]*$mods$type\[ \t\]+\$" $before]} {return defname}
    return ""
}

# Fora do PATH (ex.: aberto pelo menu do sistema): GROOVY_HOME ou SDKMAN.
proc qc::lang::groovy::findExe {rn} {
    set p [auto_execok groovy]
    if {$p ne ""} {return $p}
    set cands {}
    if {[info exists ::env(GROOVY_HOME)]} {lappend cands [file join $::env(GROOVY_HOME) bin groovy]}
    set sdk [expr {[info exists ::env(SDKMAN_DIR)] ? $::env(SDKMAN_DIR) : [file join [::qc::homeDir] .sdkman]}]
    lappend cands [file join $sdk candidates groovy current bin groovy]
    foreach c $cands {
        if {[file executable $c]} {
            # o script groovy precisa do java: o do SDKMAN, se não houver outro
            set java [file join $sdk candidates java current]
            if {![info exists ::env(JAVA_HOME)] && [auto_execok java] eq "" && [file isdirectory $java]} {
                set ::env(JAVA_HOME) $java
            }
            return [list $c]
        }
    }
    return ""
}

qc::template groovy Script {// Script Groovy -- Ctrl+R executa; argumentos em Executar > Opções (Ctrl+E).
// Dependências: @Grab('org.apache.commons:commons-lang3:3.17.0')

String saudacao(String nome) { "Olá, ${nome}!" }

println saudacao('mundo')

def quadrados = (1..5).collect { it * it }
println "Quadrados: $quadrados (soma ${quadrados.sum()})"

def pessoas = [[nome: 'Ana', idade: 31], [nome: 'Bruno', idade: 25]]
pessoas.sort { it.idade }.each { p ->
    println "${p.nome.padRight(6)} ${p.idade}"
}

args.eachWithIndex { a, i -> println "args[$i] = $a" }
}

qc::template groovy "Script com @Grab" {// Dependências do Maven Central com @Grab (Grape). Na 1ª execução elas são
// baixadas para ~/.groovy/grapes, o que demora um pouco; depois vêm do cache.
// Para ver o download: Executar > Opções (Ctrl+E) > -Dgroovy.grape.report.downloads=true
//
// Outras anotações úteis:
//   @GrabResolver(name = 'meu-repo', root = 'https://repo.exemplo.com/maven2/')
//   @GrabExclude('commons-io:commons-io')        // tira uma dependência transitiva
//   @GrabConfig(systemClassLoader = true)        // drivers JDBC (DriverManager)
@Grapes([
    @Grab('org.apache.commons:commons-csv:1.14.0'),
    @Grab(group = 'org.apache.commons', module = 'commons-lang3', version = '3.17.0'),
])
import org.apache.commons.csv.CSVFormat
import org.apache.commons.lang3.StringUtils

def csv = '''
nome,cidade,idade
ana souza,recife,31
bruno lima,porto alegre,25
carla dias,belém,42
'''.trim()

def formato = CSVFormat.DEFAULT.builder()
    .setHeader()
    .setSkipHeaderRecord(true)
    .get()

def registros = formato.parse(new StringReader(csv)).toList()
registros.sort { it.get('idade') as int }.each { r ->
    def nome = StringUtils.capitalize(r.get('nome'))
    def cidade = StringUtils.abbreviate(r.get('cidade'), 10)
    println "${nome.padRight(12)} ${cidade.padRight(10)} ${r.get('idade')}"
}
println "Média de idade: ${registros*.get('idade')*.toInteger().average()}"
}

qc::template groovy "Classe com main" {// Groovy @VERSION@
import groovy.transform.CompileStatic

@CompileStatic
class Main {
    static void main(String[] args) {
        List<Integer> xs = [3, 1, 2]
        println "Ordenado: ${xs.sort()}"
    }
}
}

# --- Scheme (Guile, Chez) --------------------------------------------------

qc::language scheme {
    name     Scheme
    ext      {.scm .ss .sls .sps .sld}
    comment  ;;
    indent   2
    dedentChars ""
    autoPairs {() [] \{\} \"\"}
    rainbow  1
    tokens {
        comment  {;[^\n]*|#\|(?:[^|]|\|(?!#))*(?:\|#)?|#;}
        string   {"(?:[^"\\]|\\.)*"?}
        string   {#\\(?:x[0-9a-fA-F]+|[[:alpha:]]+|[^[:space:]])}
        constant {#(?:true|false|t|f)\M}
        number   {#[xXbBoOdDeEiI][-+0-9a-fA-F./]+}
        symbol   {'[^][\s(){}"';`,|#][^][\s(){}"';`,|]*}
        word     {[^][\s(){}"';`,|#][^][\s(){}"';`,|]*}
        brace    {[][(){}]}
    }
    numberWord {^[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$|^[-+]?[0-9]+/[0-9]+$}
    words {
        keyword {
            define define* define-syntax define-record-type define-values
            define-library lambda lambda* case-lambda named-lambda
            let let* letrec letrec* let-values let*-values let-syntax
            letrec-syntax if cond case else when unless begin do set! quote
            quasiquote unquote unquote-splicing and or syntax-rules syntax-case
            with-syntax identifier-syntax import library export guard
            parameterize delay delay-force force call/cc
            call-with-current-continuation dynamic-wind receive assert
            module fluid-let include cond-expand =>
        }
        builtin {
            car cdr cons list cadr cddr caar cdar caddr cdddr append reverse length
            list-ref list-tail list-copy memq memv member assq assv assoc map
            for-each filter reduce fold fold-left fold-right apply iota vector
            make-vector vector-ref vector-set! vector-length vector->list
            list->vector vector-map vector-for-each string make-string
            string-length string-ref string-append substring string-copy
            string->symbol symbol->string string->number number->string
            string->list list->string string-upcase string-downcase string=?
            string<? char=? char<? eq? eqv? equal? not null? pair? list? zero?
            positive? negative? odd? even? number? integer? rational? real?
            symbol? string? char? vector? procedure? boolean? + - * / = < > <=
            >= abs min max quotient remainder modulo gcd lcm expt exp log sqrt
            exact inexact exact->inexact inexact->exact floor ceiling round
            truncate display write newline read read-line error raise
            with-exception-handler values call-with-values format void exit
            make-parameter make-hash-table hash-ref hash-set! hashtable-ref
            hashtable-set! make-eq-hashtable make-equal-hashtable
        }
    }
    defWords {define define* define-syntax define-record-type define-values}
    defThroughBrace 1
    docString 1
    pretty   {define λ lambda λ}
    runners {
        {name guile label Guile exe {guile guile3.0} args {--no-auto-compile %O %W %F %A}
         wrapperExt .scm versionRe {Guile\)? ([0-9][0-9.]*)}
         optsHint "-L ./lib   --r7rs   --r6rs"
         errPatterns {{%F:([0-9]+):([0-9]+)}} col0 1
         infoRe {^;;;} warnRe {warning:}
         wrapper {
(setvbuf (current-output-port) 'line)
(use-modules (system base compile))
(let* ((args (cdr (command-line)))
       (file (car args)))
  (set-program-arguments args)
  (load-compiled
   (compile-file file #:output-file (string-append file ".go")
                 #:opts %auto-compilation-options)))
         }}
        {name chez label "Chez Scheme" exe {scheme chez chezscheme petite}
         args {%O --script %F %A} versionRe {([0-9]+\.[0-9][0-9.]*)}
         optsHint "--libdirs ./lib   --optimize-level 2"
         errPatterns {{line ([0-9]+), char ([0-9]+) of %F}} col0 0}
        {name kawa label Kawa exe {kawa} args {%O %F %A}
         versionRe {Kawa ([0-9][0-9.]*)}
         searchHint "kawa (PATH)"
         optsHint "--r7rs   --full-tailcalls   -Dkawa.import.path=./lib/*.scm"
         errPatterns {{%F:([0-9]+):([0-9]+):} {\(%F:([0-9]+)\)}} col0 0
         warnRe {^\S+:[0-9]+:[0-9]+: warning - }
         infoRe {^\s+at (?:gnu\.|kawa\.|java\.|jdk\.|sun\.)|^\s+\.\.\. [0-9]+ more|^Picked up JAVA_TOOL_OPTIONS:|^;; }}
    }
    linters {
        {name guild label "guild compile" runner guile exe {guild guild3.0}
         args {compile -Wunused-variable -Wunbound-variable -Warity-mismatch
               -Wmacro-use-before-definition -Wduplicate-case-datum
               -Wbad-case-datum -Wformat %O -o %D/lint.go %F}
         optsKeep {-L 1 -x 1 --r6rs 0 --r7rs 0}
         errPatterns {{%F:([0-9]+):([0-9]+)}} col0 1 warnRe {warning:} errRe {.}
         ignoreRe {^wrote `|^ice-9/boot-9\.scm:}}
        {name chez-lint label "Chez Scheme (compile)" runner chez useRunner 1
         args {-q %O --script %S %F} scriptExt .ss
         errPatterns {{line ([0-9]+), char ([0-9]+) of %F}} col0 0
         warnRe {^Warning} errRe {^Exception|^Error}
         script {
(let* ([file (cadr (command-line))]
       [sfd (call-with-port (open-file-input-port file)
              (lambda (p) (make-source-file-descriptor file p #t)))]
       [ip (transcoded-port (open-file-input-port file) (native-transcoder))])
  (define (strip x) (if (annotation? x) (annotation-stripped x) x))
  (define (head x) (let ([s (strip x)]) (and (pair? s) (car s))))
  (define (report c)
    (display-condition c (current-error-port))
    (newline (current-error-port)))
  (define (unbound? c)
    (and (message-condition? c)
         (let ([m (condition-message c)])
           (and (>= (string-length m) 23)
                (string=? (substring m 0 23) "attempt to reference un")))))
  ;; compila sem executar; avisos: show? -> mostra e continua; erros: err
  (define (check forms show? err)
    (call/cc
      (lambda (k)
        (with-exception-handler
          (lambda (c)
            (cond
              [(warning? c) (when show? (report c))]
              [else (err c) (k #f)]))
          (lambda ()
            (let-values ([(op get) (open-bytevector-output-port)])
              (compile-to-port forms op)))))))
  (define forms
    (guard (c [#t (report c) (exit 1)])
      (let loop ([acc '()] [bfp 0])
        (let-values ([(x nbfp) (get-datum/annotations ip sfd bfp)])
          (if (eof-object? x) (reverse acc) (loop (cons x acc) nbfp))))))
  ;; 1) como no --script: sintaxe, macros e número de argumentos
  (check forms #t (lambda (c) (report c) (exit 1)))
  ;; 2) como programa, só para achar identificadores não definidos
  (unless (or (null? forms) (memq (head (car forms)) '(library top-level-program)))
    (check (list (if (eq? (head (car forms)) 'import)
                     `(top-level-program ,@forms)
                     `(top-level-program (import (chezscheme)) ,@forms)))
           #f
           (lambda (c) (when (unbound? c) (report c) (exit 1))))))
         }}
        {name kawa-lint label "Kawa (compile)" runner kawa useRunner 1
         args {--warn-undefined-variable --warn-unreachable --warn-void-used
               --warn-uninitialized %O -d %D/classes -C %F}
         optsKeep {--r7rs 0 --scheme 0 --full-tailcalls 0 --no-full-tailcalls 0}
         errPatterns {{%F:([0-9]+):([0-9]+):}} col0 0
         warnRe {: warning - } errRe {.} ignoreRe {^\(compiling }}
    }
}

# Bibliotecas do Guile: guile-procedures.txt (procedimentos em C) e os
# módulos .scm, achados a partir do executável (<prefixo>/share/guile/<versão>).
proc qc::lang::scheme::apiSources {} {
    set rn ""
    foreach r [::qc::lget runners guile] {
        if {[dict get $r name] eq "guile"} {set rn $r}
    }
    if {$rn eq ""} {return {}}
    set exe [lindex [::qc::findExe $rn guile] 0]
    if {$exe eq ""} {return {}}
    for {set i 0} {$i < 10 && [file type $exe] eq "link"} {incr i} {
        set exe [file normalize [file join [file dirname $exe] [file readlink $exe]]]
    }
    set share [file join [file dirname [file dirname $exe]] share guile]
    set vers [lsort -dictionary [glob -nocomplain -directory $share -types d {[0-9]*}]]
    if {![llength $vers]} {return {}}
    set d [lindex $vers end]
    set out {}
    set txt [file join $d guile-procedures.txt]
    if {[file isfile $txt]} {lappend out $txt}
    lappend out $d
    set site [file join $share site [file tail $d]]
    if {[file isdirectory $site]} {lappend out $site}
    return $out
}

# Só os define de nível superior (linha começando por "(").
proc qc::lang::scheme::defQual {lines L name} {
    if {[string index [lindex $lines $L] 0] ne "("} {return ""}
    return $name
}

# guile-procedures.txt: blocos separados por form feed, cada um com uma ou
# mais linhas "- Scheme Procedure: nome args" e o texto indentado.
proc qc::lang::scheme::apiParse {f data} {
    if {[file tail $f] ne "guile-procedures.txt"} {return -}
    set out {}
    foreach blk [lrange [split $data \f] 1 end] {
        set lines [split $blk \n]
        set name [string trim [lindex $lines 0]]
        if {$name eq ""} {continue}
        set sigs {}
        set doc {}
        foreach l [lrange $lines 1 end] {
            if {[regexp {^- Scheme Procedure: (.*)$} $l -> s]} {
                lappend sigs "([string trim $s])"
            } elseif {
                [llength $sigs] && [llength $doc] < 14
                && ([string trim $l] ne "" || [llength $doc])
            } {
                lappend doc [string trimright $l]
            }
        }
        if {![llength $sigs]} {continue}
        # tira a indentação comum e as linhas vazias do fim
        while {[llength $doc] && [string trim [lindex $doc end]] eq ""} {
            set doc [lrange $doc 0 end-1]
        }
        set doc [lmap l $doc {regsub {^     } $l {}}]
        lappend out [list $name [list $f "" $name 0 0 [join $sigs \n] {} $doc $name]]
    }
    return $out
}

# Indentação estilo Lisp: um nível além do "(" que envolve o cursor.
proc qc::lang::scheme::newlineIndent {} {
    set p [::qc::enclosingOpen insert]
    if {$p eq ""} {return ""}
    set col [lindex [split $p .] 1]
    return [string repeat " " [expr {$col + [::qc::lget indent]}]]
}

# --- formatação (reindentação no estilo Lisp) --------------------------------
# Regras do scheme-mode do Emacs: formas especiais têm N argumentos
# "distinguidos" (4 colunas além do "(" quando vão para outra linha) e o
# corpo (2 colunas); define* e def*: só corpo. Chamadas com argumento na
# linha da cabeça alinham com ele; senão, e em listas de dados ('(...),
# #(...), ((...) ...)), 1 coluna além do "(".
# Linhas dentro de strings e de #| |# não mudam; ";;;" fica na coluna 0.

namespace eval qc::lang::scheme {
    # forma -> nº de argumentos distinguidos
    variable specForms {
        begin 0 case 1 delay 0 delay-force 0 do 2 lambda 1 lambda* 1 λ 1
        named-lambda 2 let 1 let/named 2 let* 1
        letrec 1 letrec* 1 let-values 1 let*-values 1 let-syntax 1
        letrec-syntax 1 let-optional 2 let-optional* 2 let-keywords 3
        let-keywords* 3 syntax-rules 1 syntax-case 2 with-syntax 1
        call-with-input-file 1 call-with-output-file 1 call-with-port 1
        call-with-values 1 with-input-from-file 1 with-output-to-file 1
        with-input-from-port 1 with-output-to-port 1 with-fluids 1
        with-mutex 1 dynamic-wind 3 when 1 unless 1 library 1 module 1
        parameterize 1 guard 1 receive 2 fluid-let 1 match 1 match-lambda 0
        match-lambda* 0 match-let 1 match-let* 1 eval-when 1 while 1
        unwind-protect 1 try-catch 1 try-finally 1 synchronized 1
        object 1 reset 0 shift 1 async 0 trace-lambda 1 trace-let 1
    }
}

# Nº de argumentos distinguidos da forma h, ou -1 (chamada comum).
proc qc::lang::scheme::specN {h} {
    variable specForms
    if {[dict exists $specForms $h]} {return [dict get $specForms $h]}
    if {[string match def* $h]} {return 0}
    return -1
}

# Pilha: um item por "(" aberto -- coluna, dados?, cabeça, linha da cabeça,
# coluna do 1º argumento na linha da cabeça (-1 = nenhum), nº de elementos.
proc qc::lang::scheme::indentFor {stack ind} {
    if {![llength $stack]} {return 0}
    lassign [lindex $stack end] col data head - argCol count
    if {$data || $head eq ""} {return [expr {$col + 1}]}
    set n [specN $head]
    if {$n >= 0} {
        # o elemento desta linha é o de índice count (0 = cabeça)
        return [expr {$col + ($count >= 1 && $count <= $n ? 2 * $ind : $ind)}]
    }
    if {$argCol >= 0} {return $argCol}
    return [expr {$col + 1}]
}

# Registra um elemento (átomo, string ou lista) na lista aberta.
proc qc::lang::scheme::element {stackVar col sym ln} {
    upvar 1 $stackVar stack
    if {![llength $stack]} {return}
    lassign [lindex $stack end] c data head hl argCol count
    if {$count == 0} {
        set head [expr {[string is double -strict $sym] ? "" : $sym}]
        set hl $ln
    } elseif {$count == 1} {
        if {$hl == $ln} {set argCol $col}
        # let nomeado: (let loop ((...)) ...)
        if {$head eq "let" && $sym ne ""} {set head let/named}
    }
    incr count
    lset stack end [list $c $data $head $hl $argCol $count]
}

proc qc::lang::scheme::reformat {text} {
    set ind [::qc::lget indent scheme]
    set stack {}
    set inStr 0
    set bc 0
    set out {}
    set ln 0
    set delims [list " " \t ( ) \[ \] \" ";"]
    foreach line [split $text \n] {
        incr ln
        if {$inStr || $bc} {
            set new $line
        } else {
            set new [string trimleft $line " \t"]
            if {$new eq ""} {
                lappend out ""
                continue
            }
            if {![string match ";;;*" $new]} {
                set new [string repeat " " [indentFor $stack $ind]]$new
            }
        }
        set chars [split $new ""]
        set n [llength $chars]
        set pend -1
        set pdata 0
        set i 0
        while {$i < $n} {
            set c [lindex $chars $i]
            set d [lindex $chars $i+1]
            if {$inStr} {
                if {$c eq "\\"} {
                    incr i 2
                    continue
                }
                if {$c eq "\""} {set inStr 0}
                incr i
                continue
            }
            if {$bc} {
                if {$c eq "|" && $d eq "#"} {
                    incr bc -1
                    incr i 2
                } elseif {$c eq "#" && $d eq "|"} {
                    incr bc
                    incr i 2
                } else {
                    incr i
                }
                continue
            }
            switch -- $c {
                " " - "\t" {
                    incr i
                    continue
                }
                ";" {break}
                "\"" {
                    element stack [expr {$pend >= 0 ? $pend : $i}] "" $ln
                    set pend -1
                    set pdata 0
                    set inStr 1
                    incr i
                    continue
                }
                "(" - "[" {
                    element stack [expr {$pend >= 0 ? $pend : $i}] "" $ln
                    lappend stack [list $i $pdata "" 0 -1 0]
                    set pend -1
                    set pdata 0
                    incr i
                    continue
                }
                ")" - "]" {
                    if {[llength $stack]} {set stack [lrange $stack 0 end-1]}
                    set pend -1
                    set pdata 0
                    incr i
                    continue
                }
                "'" - "`" - "," {
                    if {$pend < 0} {set pend $i}
                    set pdata [expr {$c eq "'"}]
                    incr i [expr {$c eq "," && $d eq "@" ? 2 : 1}]
                    continue
                }
                "#" {
                    if {$d eq "|"} {
                        incr bc
                        incr i 2
                        continue
                    }
                    if {$d eq ";"} {
                        incr i 2
                        continue
                    }
                    if {$d eq "("} {
                        if {$pend < 0} {set pend $i}
                        set pdata 1
                        incr i
                        continue
                    }
                    if {$d in {' ` ,}} {
                        # #' #` #, #,@ (sintaxe: modelos são código)
                        if {$pend < 0} {set pend $i}
                        set pdata 0
                        incr i [expr {$d eq "," && [lindex $chars $i+2] eq "@" ? 3 : 2}]
                        continue
                    }
                    if {$d eq "\\"} {
                        # caractere: #\( #\; #\space ...
                        element stack [expr {$pend >= 0 ? $pend : $i}] "" $ln
                        set pend -1
                        set pdata 0
                        incr i 3
                        while {$i < $n && [lindex $chars $i] ni $delims} {incr i}
                        continue
                    }
                }
            }
            # átomo
            set j $i
            while {$j < $n && [lindex $chars $j] ni $delims} {
                if {[lindex $chars $j] eq "|"} {
                    incr j
                    while {$j < $n && [lindex $chars $j] ne "|"} {incr j}
                }
                incr j
            }
            set tok [join [lrange $chars $i $j-1] ""]
            if {[string index $tok 0] eq "#" && [lindex $chars $j] eq "("} {
                # #u8( #vu8( ...: prefixo de vetor
                if {$pend < 0} {set pend $i}
                set pdata 1
            } else {
                element stack [expr {$pend >= 0 ? $pend : $i}] $tok $ln
                set pend -1
                set pdata 0
            }
            set i $j
        }
        if {!$inStr} {set new [string trimright $new " \t"]}
        lappend out $new
    }
    return [join $out \n]
}

# --- Implementações de Scheme -------------------------------------------------
# Chez, Guile e Kawa usam as mesmas extensões: cada uma é uma linguagem
# própria no combo (scheme-chez, scheme-guile, scheme-kawa), derivada da
# "scheme" acima (que não aparece na lista), com só o seu runner, o seu
# linter e as suas palavras. Ao abrir um arquivo, a implementação vem do
# hook detect (cabeçalho do Emacs/Geiser, shebang ou o próprio código); sem
# indicação, fica a primeira instalada, nesta ordem.

namespace eval qc::lang::scheme {
    # id -> rótulo runner palavras-extras defWords-extras
    variable dialects {
        scheme-chez {
            name "Scheme (Chez)" runner chez
            words {
                keyword {
                    define-ftype foreign-procedure foreign-callable
                    trace-define trace-lambda trace-let trace untrace time
                    record-case define-property meta
                }
                builtin {
                    load-shared-object printf fprintf pretty-print
                    ftype-ref ftype-set! ftype-pointer-address
                    make-ftype-pointer foreign-alloc foreign-free foreign-ref
                    foreign-set! foreign-sizeof
                }
            }
            defWords {define-ftype trace-define define-property}
        }
        scheme-guile {
            name "Scheme (Guile)" runner guile
            words {
                keyword {
                    define-module use-modules define-public define-syntax-rule
                    eval-when with-fluids define-once
                }
                builtin {}
            }
            defWords {define-public define-syntax-rule define-once}
        }
        scheme-kawa {
            name "Scheme (Kawa)" runner kawa
            words {
                keyword {
                    define-simple-class define-class define-alias
                    define-constant define-private define-variable define-enum
                    define-macro defmacro define-early-constant
                    define-namespace define-private-alias module-name
                    module-export module-static module-compile-options require
                    try-catch try-finally synchronized object this future lazy
                    include-relative include-ci
                    reset shift async
                    define-foreign-procedure define-foreign-struct
                    trace untrace time
                }
                builtin {
                    invoke invoke-static invoke-special field static-field
                    slot-ref instance? as make primitive-throw runnable eager
                    force* make-promise promise-set-value!
                    promise-set-exception! promise-set-alias!
                    promise-set-thunk!
                    call-with-reset call-with-shift make-coroutine-generator
                    generator->list with-effect-handler perform await
                    foreign-library foreign-procedure foreign-callback
                    foreign-alloc foreign-ref foreign-set! foreign-sizeof
                    foreign-struct foreign-struct-ref foreign-struct-set!
                    string->pointer pointer->string foreign-null?
                    disassemble
                }
                constant {foreign-null}
            }
            defWords {
                define-simple-class define-class define-alias define-constant
                define-private define-variable define-enum define-macro
                defmacro define-early-constant define-private-alias
                define-foreign-procedure define-foreign-struct
            }
            tokens {
                constant {#!(?:optional|rest|key|eof|void|null|default|fold-case|no-fold-case)\M}
            }
        }
    }
    # nome usado no cabeçalho/shebang -> id
    variable dialectNames {
        chez scheme-chez chezscheme scheme-chez petite scheme-chez
        scheme scheme-chez scheme-script scheme-chez
        guile scheme-guile kawa scheme-kawa
    }
}

# Implementação indicada no arquivo, ou "":
#   ;; -*- mode: scheme; geiser-scheme: kawa -*-    (1ª ou 2ª linha, Emacs)
#   ;; Local Variables: ... geiser-scheme: guile ... ;; End:   (no fim)
#   #!/usr/bin/env guile  |  #!/usr/bin/scheme --script  |  #!/usr/bin/env kawa
# ou, sem isso, pistas no código: (use-modules ...)/(ice-9 ...) = Guile,
# (chezscheme) = Chez, (kawa ...), define-simple-class, module-name = Kawa.
proc qc::lang::scheme::detect {data path} {
    variable dialectNames
    set lines [split [string range $data 0 2000] \n]
    foreach l [lrange $lines 0 1] {
        if {[regexp -nocase -- {-\*-.*\mgeiser-scheme:\s*([-\w]+)} $l -> v]} {
            return [dialectOf $v]
        }
    }
    set tail [string range $data end-3000 end]
    if {[regexp -nocase {Local Variables:.*\mgeiser-scheme:\s*([-\w]+)} $tail -> v]} {
        return [dialectOf $v]
    }
    if {[regexp {^#!\s*(\S+)(?:[ \t]+(?:-S[ \t]+)?(\S+))?} [lindex $lines 0] -> p1 p2]} {
        set prog [file tail $p1]
        if {$prog eq "env"} {set prog [file tail $p2]}
        regsub {[0-9.]+$} $prog {} prog
        set id [dialectOf $prog]
        if {$id ne ""} {return $id}
    }
    set code [string range $data 0 20000]
    if {[regexp {\((?:use-modules|define-module)\M|\(ice-9 } $code]} {return scheme-guile}
    if {[regexp {\(chezscheme\)} $code]} {return scheme-chez}
    if {[regexp {\(kawa [-\w]+\)|\((?:define-simple-class|module-name|define-alias)\M} $code]} {
        return scheme-kawa
    }
    return ""
}

proc qc::lang::scheme::dialectOf {name} {
    variable dialectNames
    set name [string tolower $name]
    if {[dict exists $dialectNames $name]} {return [dict get $dialectNames $name]}
    if {$name in $::qc::langs} {return $name}
    return ""
}

# Linguagem > Indicar implementação no arquivo: grava (ou atualiza) o
# cabeçalho -*- geiser-scheme: ... -*- na 1ª linha (2ª, após um shebang).
proc qc::lang::scheme::writeHeader {} {
    variable dialects
    set id $::qc::lang
    if {![dict exists $dialects $id]} {
        set ::qc::status "A linguagem atual não é uma implementação de Scheme"
        return
    }
    set r [dict get $dialects $id runner]
    set w $::qc::ed
    set ln 1
    if {[$w get 1.0 1.2] eq "#!"} {set ln 2}
    set l [$w get $ln.0 "$ln.0 lineend"]
    if {[regexp -indices -nocase {(\mgeiser-scheme:\s*)([-\w]+)} $l -> - v]} {
        lassign $v a b
        $w replace $ln.$a $ln.[incr b] $r
    } elseif {[regexp -indices -- {-\*-(.*?)-\*-} $l -> body]} {
        lassign $body a b
        set vars [string trimright [string trim [string range $l $a $b]] ";"]
        if {$vars ne ""} {append vars ";"}
        $w replace $ln.$a $ln.[incr b] " [string trimleft "$vars geiser-scheme: $r"] "
    } else {
        $w insert $ln.0 ";; -*- mode: scheme; geiser-scheme: $r -*-\n"
    }
    ::qc::highlight
    set ::qc::status "Cabeçalho gravado: geiser-scheme: $r"
}

# Configurações antigas de "scheme" passam para cada implementação.
proc qc::lang::scheme::migrateCfg {} {
    variable dialects
    upvar #0 ::qc::cfg cfg
    set old [expr {[info exists cfg(runner.scheme)] ? $cfg(runner.scheme) : ""}]
    foreach {id spec} $dialects {
        set r [dict get $spec runner]
        foreach k [list fmtsave exe.$r opts args] {
            if {$k in {opts args} && $old ne $r} {continue}
            if {[info exists cfg($k.scheme)] && ![info exists cfg($k.$id)]} {
                set cfg($k.$id) $cfg($k.scheme)
            }
        }
    }
    if {[info exists cfg(lang)] && $cfg(lang) eq "scheme"} {
        set cfg(lang) [::qc::langAlias scheme]
    }
}

# Registra as implementações (depois de todos os hooks da "scheme").
apply {{} {
    upvar #0 ::qc::lang::scheme::dialects dialects
    set base $::qc::L(scheme)
    foreach {id spec} $dialects {
        set d $base
        set r [dict get $spec runner]
        dict set d name [dict get $spec name]
        dict set d runners [lmap x [dict get $base runners] {
            if {[dict get $x name] ne $r} continue
            set x
        }]
        dict set d linters [lmap x [dict get $base linters] {
            if {[dict exists $x runner] && [dict get $x runner] ne $r} continue
            set x
        }]
        set words [dict get $base words]
        dict for {tag list} [dict get $spec words] {
            dict lappend words $tag {*}$list
        }
        dict set d words $words
        dict lappend d defWords {*}[dict get $spec defWords]
        if {[dict exists $spec tokens]} {
            # antes dos números (tokens é lista: chaves repetidas)
            set tk [dict get $base tokens]
            set i [lsearch -exact -start 0 [lmap {k v} $tk {set k}] number]
            dict set d tokens [linsert $tk [expr {2 * $i}] {*}[dict get $spec tokens]]
        }
        ::qc::language $id $d
        foreach p [info procs ::qc::lang::scheme::*] {
            set n [namespace tail $p]
            if {$n eq "apiSources" && $r ne "guile"} {continue}
            interp alias {} ::qc::lang::${id}::$n {} $p
        }
    }
    # "scheme" fica só como base (e apelido: ver qc::langAlias)
    set ::qc::langs [lsearch -all -inline -not -exact $::qc::langs scheme]
}}

# --- OCaml / OxCaml ----------------------------------------------------------

# tclint-disable line-length
qc::language ocaml {
    name       "OCaml"
    ext        {.ml .mli .mlx}
    comment    "(*"
    commentEnd "*)"
    indent     2
    autoPairs  {() [] \{\} \"\"}
    indentAfter {(?:=|->|\m(?:then|else|do|begin|struct|sig|object|in|with|try|fun|function)|[\{\[\(])\s*$}
    rainbow  1
    tokens {
        comment   {\(\*(?:[^*]|\*(?!\)))*(?:\*\))?}
        directive {^[ \t]*(#[a-z_]+)}
        string    {"(?:[^"\\]|\\.)*"?}
        string    {\{\|(?:[^|]|\|(?!\}))*(?:\|\})?}
        string    {'(?:\\(?:[\\'"ntbr ]|[0-9]{3}|x[0-9a-fA-F]{2}|o[0-7]{3})|[^\\'\n])'}
        type      {'[a-z_][A-Za-z0-9_]*}
        number    {\m(?:0[xX][0-9a-fA-F_]+|0[oO][0-7_]+|0[bB][01_]+|[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][-+]?[0-9]+)?)[lLn]?\M}
        annot     {\[@@?@?[A-Za-z_.]+|\[%%?[A-Za-z_.]+}
        word      {[A-Za-z_][A-Za-z0-9_']*}
        brace     {[][(){}]}
    }
    words {
        keyword {
            and as assert begin class constraint do done downto else end exception
            external false for fun function functor if in include inherit
            initializer lazy let match method module mutable new nonrec object of
            open or private rec sig struct then to true try type val virtual when
            while with lsl lsr asr land lor lxor mod
            local_ stack_ exclave_ global_ unique_ once_ many_ portable_ kind_abbrev_
        }
        builtin {
            print_endline print_string print_int print_float print_char
            print_newline prerr_endline string_of_int int_of_string
            string_of_float float_of_string failwith invalid_arg raise ignore fst
            snd not ref incr decr
        }
    }
    defWords {let rec and type module val external method}
    capType  type
    runners {
        {name ocaml label OCaml exe {ocaml} args {%O %F %A} version {-version}
         versionRe {version (\S+)} optsHint "-I +unix unix.cma   -w +a   -rectypes"}
        {name oxcaml label OxCaml exe {} args {%O %F %A} version {-version}
         searchHint "switch opam ~/.opam/*ox*/bin/ocaml ou OPAM_SWITCH_PREFIX"
         versionRe {version (\S+)} optsHint "-extension-universe beta   -w +a"}
    }
    errPatterns {{File "%F", lines? ([0-9]+)(?:-[0-9]+)?, characters ([0-9]+)}
                 {File "%F", lines? ([0-9]+)}}
    col0     1
    warnRe   {^(?:Warning|Alert)\M}
    linters {
        {name ocamlc label "ocamlc -c" exe {ocamlc.opt ocamlc} nearRunner 1
         args {-c -w +a-4-29-40-41-42-44-45-48-58-59-60-66-70 -I %R %O %F}
         optsKeep {-I 1 -w 1 -alert 1 -open 1 -ppx 1 -rectypes 0 -principal 0
                   -strict-sequence 0 -nolabels 0 -extension 1 -extension-universe 1}
         groupRe {^File "} warnRe {^(?:Warning|Alert)\M|^Error \((?:warning|alert)}
         errRe {^Error\M}}
    }
    formatters {
        {name ocamlformat label ocamlformat exe {ocamlformat} nearRunner 1
         args {%C %F} output stdout config {.ocamlformat} configArg {--name %N}
         noConfigArg {--enable-outside-detected-project}
         groupRe {^File "|^ocamlformat:} warnRe {^Warning\M} errRe {^Error\M}}
        {name ocp-indent label ocp-indent exe {ocp-indent} nearRunner 1
         args {%F} output stdout}
    }
}
# tclint-enable line-length

# OxCaml é o compilador da Jane Street instalado como switch do opam (ex.:
# 5.2.0+ox): procura o toplevel no switch ativo ou em ~/.opam/*ox*.
proc qc::lang::ocaml::findExe {rn} {
    set opam [file join [::qc::homeDir] .opam]
    set pfx [expr {[info exists ::env(OPAM_SWITCH_PREFIX)] ? $::env(OPAM_SWITCH_PREFIX) : ""}]
    if {[dict get $rn name] eq "oxcaml"} {
        set cands [glob -nocomplain -directory $opam *ox*/bin/ocaml]
        if {[string match *ox* [file tail $pfx]]} {set cands [linsert $cands 0 $pfx/bin/ocaml]}
    } else {
        set p [auto_execok ocaml]
        if {$p ne ""} {return $p}
        set cands {}
        if {$pfx ne ""} {lappend cands $pfx/bin/ocaml}
        lappend cands $opam/default/bin/ocaml {*}[glob -nocomplain -directory $opam */bin/ocaml]
    }
    foreach c $cands {
        if {[file executable $c]} {return [list $c]}
    }
    return ""
}

# --- Shell -------------------------------------------------------------------

qc::language shell {
    name     Shell
    ext      {.sh .bash .zsh .ksh}
    comment  #
    indent   2
    indentAfter {(?:\m(?:then|do|else|in)|[\{\(]|\|\||&&|\||\\)\s*$}
    dedentChars "\}"
    tokens {
        comment {(?:^|[ \t;])(#[^\n]*)}
        string  {"(?:[^"\\]|\\.)*"?}
        string  {\$?'(?:[^'\\]|\\.)*'?}
        var     {\$(?:\{[^\}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9#?$!@*-])}
        defname {^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)}
        number  {\m[0-9]+\M}
        option  {[ \t](--?[A-Za-z][-A-Za-z0-9_]*)}
        word    {[A-Za-z_][A-Za-z0-9_]*}
        brace   {[][(){}]}
    }
    words {
        keyword {
            if then else elif fi case esac for select while until do done in
            function time coproc return break continue exit local export
            readonly declare typeset unset shift source alias set trap eval exec
        }
        builtin {
            echo printf read cd pwd pushd popd test true false let mapfile
            readarray getopts wait kill jobs command type hash umask ulimit
        }
    }
    defWords {function}
    defPatterns {{^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(\)}}
    sub      { string {{^"} var {\$(?:\{[^\}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9#?$!@*-])}} }
    runners {
        {name bash label bash exe {bash} args {%O %F %A} optsHint "-x   -e   -u   -o pipefail"}
        {name sh   label sh   exe {sh}   args {%O %F %A} optsHint "-x   -e"}
        {name zsh  label zsh  exe {zsh}  args {%O %F %A} optsHint "-x   -e"}
        {name dash label dash exe {dash} args {%O %F %A}}
    }
    errPatterns {{%F: line ([0-9]+):} {%F:([0-9]+):} {%F: ([0-9]+):}}
}

# --- Markdown --------------------------------------------------------------
# Sem interpretador: Ctrl+R mostra a pré-visualização (hook run) e
# Arquivo > Exportar para HTML gera a página (ver "Markdown" acima).

qc::language markdown {
    name     Markdown
    ext      {.md .markdown .mkd .mdown}
    comment  <!--
    commentEnd -->
    indent   2
    dedentChars ""
    autoPairs {() []}
    tokens {
        comment  {<!--(?:[^-]|-(?!->))*(?:-->)?}
        mdcode   {^ {0,3}```[^\n]*(?:\n(?! {0,3}```)[^\n]*)*(?:\n {0,3}```[^\n]*)?}
        mdcode   {^ {0,3}~~~[^\n]*(?:\n(?! {0,3}~~~)[^\n]*)*(?:\n {0,3}~~~[^\n]*)?}
        mdhead   {^ {0,3}#{1,6}(?:[ \t][^\n]*)?$}
        mdhead   {^ {0,3}(?:=+|-+)[ \t]*$}
        mdhr     {^ {0,3}(?:[*_][ \t]*){3,}$}
        mdmark   {^[ \t]*((?:>[ \t]?)+)}
        mdmark   {^[ \t]*((?:[-*+]|[0-9]+[.)])(?:[ \t]+\[[ xX]\])?)(?=[ \t])}
        mdcode   {``(?:[^`\n]|`(?!`))+``}
        mdcode   {`[^`\n]+`}
        mdstrong {\*\*(?![ \t])(?:[^*\n]|\*(?!\*))+\*\*}
        mdstrong {\m__(?![ \t])[^_\n]+__\M}
        mdem     {\*(?![ \t*])[^*\n]*[^*\s]\*|\*[^*\s]\*}
        mdem     {\m_(?![ \t_])[^_\n]*_\M}
        mddel    {~~[^~\n]+~~}
        mdlink   {!?\[[^\]\n]*\]\([^)\n]*\)}
        mdlink   {!?\[[^\]\n]*\]\[[^\]\n]*\]}
        mdlink   {^ {0,3}\[[^\]\n]+\]:[^\n]*}
        mdlink   {<(?:https?|mailto|ftp):[^>\s]*>}
        mdlink   {https?://[^\s<>()]+}
        mdhtml   {</?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>\n]*)?/?>}
        escape   {\\[^\n]}
        brace    {\|}
    }
    styles {
        mdhead   {#cc7832 B}
        mdhr     {#808080 {}}
        mdmark   {#cc7832 {}}
        mdcode   {#6a8759 {}}
        mdstrong {#d4d4d4 B}
        mdem     {#a9b7c6 I}
        mddel    {#808080 {}}
        mdlink   {#589df6 {}}
        mdhtml   {#e8bf6a {}}
        brace    {#808080 {}}
    }
}

# Enter continua listas ("- ", "1. " -> "2. ", "- [ ] ") e citações ("> ");
# num item vazio, encerra a lista (apaga o marcador e não abre outra linha).
proc qc::lang::markdown::newlineIndent {} {
    set ed $::qc::ed
    set before [$ed get "insert linestart" insert]
    set after [string trim [$ed get insert "insert lineend"]]
    if {[regexp {^([ \t]*)(?:([-*+])|([0-9]+)([.)]))([ \t]+)(\[[ xX]\][ \t]+)?(.*)$} \
            $before -> ws bul num delim sp box rest]} {
        if {[string trim $rest] eq "" && $after eq ""} {
            $ed delete "insert linestart" insert
            return -code break
        }
        set mk [expr {$bul ne "" ? $bul : "[expr {[scan $num %d] + 1}]$delim"}]
        if {$box ne ""} {set box "\[ \] "}
        return "$ws$mk$sp$box"
    }
    if {[regexp {^([ \t]*(?:>[ \t]?)+)(.*)$} $before -> q rest]} {
        if {[string trim $rest] eq "" && $after eq ""} {
            $ed delete "insert linestart" insert
            return -code break
        }
        return $q
    }
    regexp {^[ \t]*} $before ws
    return $ws
}

# Ctrl+R: mostra (e atualiza) a pré-visualização.
proc qc::lang::markdown::run {selOnly} {
    set ::qc::cfg(mdpreview) 1
    ::qc::mdApply
    set ::qc::status "Pré-visualização atualizada (Arquivo > Exportar para HTML… gera a página)"
}

qc::template markdown "Documento" {# Título

Um parágrafo com **negrito**, *itálico*, `código` e um [link](https://example.com).

## Lista

- item
- [ ] tarefa
- [x] tarefa feita

1. primeiro
2. segundo

> Citação.

```tcl
proc soma {a b} { expr {$a + $b} }
```

| Coluna | Valor |
|--------|------:|
| a      |     1 |
| b      |     2 |
}

# ---------------------------------------------------------------------------

proc qc::main {argv} {
    variable langs
    variable cfg
    loadLanguageFiles
    loadCfg
    if {[info commands ::qc::lang::scheme::migrateCfg] ne ""} {
        catch {::qc::lang::scheme::migrateCfg}
    }
    set id ""
    set path ""
    for {set i 0} {$i < [llength $argv]} {incr i} {
        set a [lindex $argv $i]
        if {$a eq "-lang"} {
            set id [lindex $argv [incr i]]
        } else {
            set path $a
        }
    }
    setupTheme
    buildUI
    set names {}
    foreach l $langs {lappend names [lget name $l]}
    .tb.lang configure -values $names
    if {$id eq "" && $path ne "" && [file isfile $path]} {set id [langForFile $path]}
    if {$id ne ""} {set id [langAlias $id]}
    if {$id eq "" || $id ni $langs} {set id [langAlias $cfg(lang)]}
    if {$id eq "" || $id ni $langs} {set id [lindex $langs 0]}
    setLang $id
    if {$path ne "" && [file isdirectory $path]} {
        set cfg(folder) [file normalize $path]
        set cfg(sidebar) 1
        set path ""
    }
    if {$cfg(sidebar) && $cfg(folder) ne "" && [file isdirectory $cfg(folder)]} {
        openFolder $cfg(folder)
    } else {
        set cfg(sidebar) 0
    }
    if {$path ne ""} {
        openFile $path
    } else {
        # reabre as abas da última sessão
        set cur $cfg(tabcur)
        foreach f $cfg(tabs) {
            if {[file isfile $f]} {openFile $f}
        }
        # abas que estavam desacopladas
        foreach fl $cfg(floats) {
            lassign $fl f geom
            set w [tabForFile $f]
            if {$w ne ""} {catch {undock $w $geom}}
        }
        set w [tabForFile $cur]
        if {$w ne ""} {activateTab $w}
        set ::qc::status ""
    }
    applyTerminal
    foreach e $::qc::loadErrors {conAppend "Erro ao carregar linguagem: $e\n" stderr}
    focus $::qc::ed
    updateCursor
}

proc qc::langForFileAny {path} {
    set ext [string tolower [file extension $path]]
    foreach id $::qc::langs {
        if {$ext in [lget ext $id]} {return $id}
    }
    return ""
}

if {![info exists ::qc_nomain]} {
    qc::main $argv
}
