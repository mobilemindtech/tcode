#!/usr/bin/env wish
# qconsole.tcl -- editor/console para avaliação rápida de código em várias
# linguagens (Tcl, Scala 3, Scheme...). Não é uma IDE: é um arquivo só, sem
# dependências além de Tcl/Tk 8.6 ou 9.x.
#
# Inspirado no groovyConsole: editor em cima, saída da execução embaixo. O
# código roda em um processo separado (a interface não trava e a execução
# pode ser interrompida).
#
# Uso: wish qconsole.tcl ?-lang tcl|scala|scheme|...? ?arquivo?
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
# defThroughBrace, col0, infoRe, warnRe, grayInfo (ver langDefaults).
# Hooks opcionais: procs em ::qc::lang::<id>:: -- init, wordTag, prepare,
# defaultExt, newlineIndent, stderrLine, findExe (ver as embutidas).
# Tags de cor disponíveis: veja qc::S; "styles" define novas.

package require Tk 8.6-

namespace eval qc {
    variable version 2.0
    variable scriptPath [file normalize [info script]]
    variable ed  ""          ;# editor
    variable con ""          ;# console de saída
    variable gut ""          ;# canvas com números de linha
    variable file ""         ;# arquivo atual ("" = sem nome)
    variable status ""
    variable lncol ""
    variable interp ""
    variable hlAfter ""
    variable gutPending 0
    variable curPending 0
    variable linkSeq 0
    variable langs {}         ;# ids das linguagens, em ordem de registro
    variable L                ;# L(<id>) = dicionário da linguagem
    array set L {}
    variable lang ""          ;# linguagem corrente
    variable langName ""
    variable H                ;# dados compilados da linguagem corrente
    array set H {tags {}}
    variable inited {}
    variable V                ;# versões detectadas: V(<lang>,<runner>)
    array set V {}
    variable loadErrors {}
    variable R                ;# estado da execução corrente
    array set R {}
    variable find
    array set find {pat "" rep "" case 0 regex 0}
    variable cfg
    array set cfg {
        fontsize 12 wrap 0 autoclear 1 recent {} geometry 1100x800
        lastdir "" sash 0.65 lang ""
    }
    # Paleta escura (inspirada no Darcula)
    variable C
    array set C {
        ui       #3c3f41   uifg     #bbbbbb   uiactive #4c5052
        field    #2b2b2b   border   #2b2b2b   trough   #313335
        accent   #4b6eaf   sel      #214283   thumb    #5a5d5f
        edbg     #2b2b2b   edfg     #a9b7c6   caret    #e0e0e0
        gutbg    #313335   gutfg    #606366   gutcur   #a4a3a3
        curline  #323438   found    #32593d   bmatch   #3b514d
        bbad     #7a2e2e   errline  #52302f
        conbg    #1e1f22   confg    #c8c8c8
        stderr   #ff6b68   warn     #e0c46c   info     #6f7f8f
        result   #8fbf6a
    }
    # Tags de destaque de sintaxe: cor e estilo (B negrito, I itálico)
    variable S {
        keyword   {#cc7832 B}   defname   {#ffc66d B}   type      {#6fafbd {}}
        string    {#6a8759 {}}  comment   {#808080 I}   number    {#6897bb {}}
        var       {#9876aa {}}  interp    {#9876aa {}}  option    {#bbb529 {}}
        annot     {#bbb529 {}}  brace     {#d0a86a {}}  directive {#629755 I}
        builtin   {#ffc66d {}}  constant  {#6897bb B}   symbol    {#9876aa {}}
    }
    variable langDefaults {
        name ? ext {} comment "#" commentEnd "" commentRe "" indent 4 tokens {} words {}
        defWords {} defTag defname defThroughBrace 0 capType "" numberWord ""
        sub {} styles {} indentAfter {[\{\[\(]\s*$} dedentChars "\}\)\]"
        runners {} errPatterns {} col0 0 infoRe "" warnRe "" grayInfo 0
        templates {}
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
    if {$id ni $langs} { lappend langs $id }
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
    if {$id eq ""} { set id $::qc::lang }
    return $::qc::L($id)
}

proc qc::lget {key {id ""}} {
    return [dict get [ldict $id] $key]
}

proc qc::hook {name {id ""}} {
    if {$id eq ""} { set id $::qc::lang }
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
    if {![catch {file home} h]} { return $h }
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)]} { return $::env($v) }
    }
    return [pwd]
}

proc qc::tmpDir {} {
    variable tmpdir
    if {[info exists tmpdir] && [file isdirectory $tmpdir]} { return $tmpdir }
    if {![catch {file tempdir} d]} { return [set tmpdir $d] }
    set base /tmp
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)]} { set base $::env($v); break }
    }
    set tmpdir [file join $base qconsole-[pid]-[clock clicks]]
    file mkdir $tmpdir
    return $tmpdir
}

proc qc::setEncoding {chan} {
    fconfigure $chan -encoding utf-8
    catch {fconfigure $chan -profile replace}   ;# Tcl 9
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
    if {[catch {llength $s}]} { return [regexp -all -inline {\S+} $s] }
    return $s
}

proc qc::stripAnsi {s} {
    return [regsub -all {\x1b\[[0-9;?]*[A-Za-z]} $s ""]
}

proc qc::pickFont {} {
    set fams [font families]
    foreach f {"JetBrains Mono" "Fira Code" "Source Code Pro" "Cascadia Code"
               "Hack" "DejaVu Sans Mono" "Liberation Mono" "Consolas" "Menlo"
               "Monaco" "Courier New"} {
        if {[lsearch -nocase -exact $fams $f] >= 0} { return $f }
    }
    return [font actual TkFixedFont -family]
}

# Configurações por linguagem ficam em cfg(<chave>.<lang>).
proc qc::lcfg {key {id ""}} {
    variable cfg
    if {$id eq ""} { set id $::qc::lang }
    return [expr {[info exists cfg($key.$id)] ? $cfg($key.$id) : ""}]
}

proc qc::loadCfg {} {
    variable cfg
    set rc [file join [homeDir] .qconsolerc]
    if {[file readable $rc]} {
        catch {
            dict for {k v} [readFile $rc] { set cfg($k) $v }
        }
    }
    if {![string is integer -strict $cfg(fontsize)]} { set cfg(fontsize) 12 }
}

proc qc::saveCfg {} {
    variable cfg
    catch {
        set cfg(geometry) [wm geometry .]
        set h [winfo height .pw]
        if {$h > 50} { set cfg(sash) [format %.3f [expr {double([.pw sashpos 0]) / $h}]] }
    }
    set out ""
    foreach k [lsort [array names cfg]] { append out [list $k $cfg($k)] \n }
    catch { writeFile [file join [homeDir] .qconsolerc] $out }
}

# ---------------------------------------------------------------------------
# Tema
# ---------------------------------------------------------------------------

proc qc::setupTheme {} {
    variable C
    variable cfg
    set fam [pickFont]
    font create QcMono  -family $fam -size $cfg(fontsize)
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
    ttk::style configure TScrollbar -background $C(thumb) -troughcolor $C(trough) \
        -bordercolor $C(trough) -lightcolor $C(thumb) -darkcolor $C(thumb) \
        -arrowcolor $C(uifg) -gripcount 0
    ttk::style map TScrollbar -background [list active #6e7173]
    ttk::style configure Sash -sashthickness 6 -gripcount 0 -background $C(ui)
    ttk::style configure Status.TLabel -padding {6 2} -foreground #9a9a9a
    ttk::style configure Head.TLabel -padding {6 2} -foreground #8a8a8a \
        -background $C(trough)
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
    ttk::combobox .tb.lang -state readonly -width 14 -takefocus 0 \
        -textvariable ::qc::langName
    bind .tb.lang <<ComboboxSelected>> {
        qc::setLang [lindex $::qc::langs [.tb.lang current]]
        focus $::qc::ed
    }
    pack .tb.lang -side right -padx 4

    # Painéis editor / console
    ttk::panedwindow .pw -orient vertical

    set f [ttk::frame .pw.ed]
    set gut [canvas $f.gut -background $C(gutbg) -highlightthickness 0 -bd 0 -width 40]
    set ed [text $f.t -background $C(edbg) -foreground $C(edfg) \
        -insertbackground $C(caret) -insertwidth 2 -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -font QcMono -undo 1 -maxundo 0 -autoseparators 1 \
        -wrap [expr {$cfg(wrap) ? "word" : "none"}] \
        -bd 0 -highlightthickness 0 -padx 6 -pady 4 -tabstyle wordprocessor \
        -yscrollcommand qc::edYscroll -xscrollcommand [list $f.sx set]]
    ttk::scrollbar $f.sy -orient vertical -command [list $ed yview]
    ttk::scrollbar $f.sx -orient horizontal -command [list $ed xview]
    buildFindBar $f.find
    grid $gut $ed $f.sy -sticky nsew
    grid x $f.sx -sticky ew
    grid $f.find -columnspan 3 -sticky ew
    grid columnconfigure $f 1 -weight 1
    grid rowconfigure $f 0 -weight 1
    grid remove $f.find
    if {$cfg(wrap)} { grid remove $f.sx }

    set f [ttk::frame .pw.co]
    ttk::label $f.head -text "Saída" -style Head.TLabel -anchor w
    set con [text $f.t -background $C(conbg) -foreground $C(confg) \
        -insertbackground $C(caret) -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -font QcMono -wrap char -bd 0 -highlightthickness 0 -padx 6 -pady 4 \
        -state disabled -cursor xterm -yscrollcommand [list $f.sy set]]
    ttk::scrollbar $f.sy -orient vertical -command [list $con yview]
    grid $f.head - -sticky ew
    grid $con $f.sy -sticky nsew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure $f 1 -weight 1

    .pw add .pw.ed -weight 3
    .pw add .pw.co -weight 1

    # Barra de status
    ttk::frame .sb
    ttk::label .sb.msg -textvariable ::qc::status -style Status.TLabel -anchor w
    ttk::label .sb.pos -textvariable ::qc::lncol -style Status.TLabel -width 16
    ttk::label .sb.run -textvariable ::qc::interp -style Status.TLabel
    pack .sb.run .sb.pos -side right
    pack .sb.msg -side left -fill x -expand 1

    pack .tb -side top -fill x
    pack .sb -side bottom -fill x
    pack .pw -side top -fill both -expand 1

    setupTags
    installProxy $ed
    setupBindings

    bind $gut <Configure> qc::schedGutter
    bind $ed <Configure> qc::schedGutter
    bind $ed <<Modified>> qc::updateTitle
    wm protocol . WM_DELETE_WINDOW qc::quit

    # posição inicial do divisor
    after idle {
        update idletasks
        set h [winfo height .pw]
        if {$h > 50} { catch {.pw sashpos 0 [expr {int($h * $::qc::cfg(sash))}]} }
    }
}

proc qc::buildMenus {} {
    variable cfg
    variable langs
    menu .mb -tearoff 0
    . configure -menu .mb

    set m [menu .mb.file -tearoff 0]
    .mb add cascade -label Arquivo -menu $m
    $m add command -label "Novo"               -accelerator Ctrl+N       -command qc::newFile
    $m add cascade -label "Novo a partir de modelo" -menu [menu $m.tpl -tearoff 0]
    $m add command -label "Abrir…"             -accelerator Ctrl+O       -command qc::openFile
    $m add cascade -label "Recentes"           -menu [menu $m.recent -tearoff 0]
    $m add separator
    $m add command -label "Salvar"             -accelerator Ctrl+S       -command qc::save
    $m add command -label "Salvar como…"       -accelerator Ctrl+Shift+S -command qc::saveAs
    $m add command -label "Fechar arquivo"     -accelerator Ctrl+F4      -command qc::closeFile
    $m add separator
    $m add command -label "Sair"               -accelerator Ctrl+Q       -command qc::quit
    updateRecentMenu

    set m [menu .mb.edit -tearoff 0]
    .mb add cascade -label Editar -menu $m
    $m add command -label "Desfazer"           -accelerator Ctrl+Z       -command {qc::editCmd undo}
    $m add command -label "Refazer"            -accelerator Ctrl+Y       -command {qc::editCmd redo}
    $m add separator
    $m add command -label "Recortar"           -accelerator Ctrl+X       -command {event generate $::qc::ed <<Cut>>}
    $m add command -label "Copiar"             -accelerator Ctrl+C       -command {event generate [focus] <<Copy>>}
    $m add command -label "Colar"              -accelerator Ctrl+V       -command {qc::paste $::qc::ed}
    $m add command -label "Selecionar tudo"    -accelerator Ctrl+A       -command {qc::selectAll $::qc::ed}
    $m add separator
    $m add command -label "Duplicar linha"     -accelerator Ctrl+D       -command qc::duplicateLine
    $m add command -label "Comentar/descomentar" -accelerator Ctrl+/     -command qc::toggleComment
    $m add separator
    $m add command -label "Localizar…"         -accelerator Ctrl+F       -command {qc::showFind 0}
    $m add command -label "Substituir…"        -accelerator Ctrl+H       -command {qc::showFind 1}
    $m add command -label "Localizar próximo"  -accelerator F3           -command {qc::findNext 1}
    $m add command -label "Localizar anterior" -accelerator Shift+F3     -command {qc::findNext 0}
    $m add command -label "Ir para linha…"     -accelerator Ctrl+L       -command qc::gotoDialog

    set m [menu .mb.lang -tearoff 0]
    .mb add cascade -label Linguagem -menu $m
    foreach id $langs {
        $m add radiobutton -label [lget name $id] -value $id -variable ::qc::langSel \
            -command [list qc::setLang $id]
    }

    set m [menu .mb.script -tearoff 0]
    .mb add cascade -label Executar -menu $m
    $m add command -label "Executar"           -accelerator Ctrl+R       -command {qc::run 0}
    $m add command -label "Executar seleção"   -accelerator Ctrl+Shift+R -command {qc::run 1}
    $m add command -label "Interromper"        -accelerator Ctrl+Break   -command qc::stop -state disabled
    $m add separator
    $m add command -label "Limpar saída"       -accelerator Ctrl+W       -command qc::clearConsole
    $m add checkbutton -label "Limpar saída antes de executar" -variable ::qc::cfg(autoclear)
    $m add separator
    $m add command -label "Opções de execução…" -accelerator Ctrl+E      -command qc::optionsDialog

    set m [menu .mb.view -tearoff 0]
    .mb add cascade -label Exibir -menu $m
    $m add command -label "Aumentar fonte"     -accelerator Ctrl++       -command {qc::zoom 1}
    $m add command -label "Diminuir fonte"     -accelerator Ctrl+-       -command {qc::zoom -1}
    $m add command -label "Fonte padrão"       -accelerator Ctrl+0       -command {qc::zoom 0}
    $m add separator
    $m add checkbutton -label "Quebra de linha" -variable ::qc::cfg(wrap) -command qc::applyWrap

    set m [menu .mb.help -tearoff 0]
    .mb add cascade -label Ajuda -menu $m
    $m add command -label "Atalhos"  -command qc::showShortcuts
    $m add command -label "Sobre"    -command qc::about

    # menus de contexto
    set m [menu .edpop -tearoff 0]
    $m add command -label "Recortar"         -command {event generate $::qc::ed <<Cut>>}
    $m add command -label "Copiar"           -command {event generate $::qc::ed <<Copy>>}
    $m add command -label "Colar"            -command {qc::paste $::qc::ed}
    $m add separator
    $m add command -label "Selecionar tudo"  -command {qc::selectAll $::qc::ed}
    $m add command -label "Executar seleção" -command {qc::run 1}

    set m [menu .conpop -tearoff 0]
    $m add command -label "Copiar"           -command {event generate $::qc::con <<Copy>>}
    $m add command -label "Selecionar tudo"  -command {$::qc::con tag add sel 1.0 end}
    $m add separator
    $m add command -label "Limpar saída"     -command qc::clearConsole
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
    ttk::checkbutton $w.re   -text ".*" -variable ::qc::find(regex) -command qc::markAll -takefocus 0
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

    trace add variable ::qc::find(pat) write {apply {args {after idle qc::markAll}}}
    foreach e [list $w.pat $w.rep] {
        bind $e <Return>       {qc::findNext 1; break}
        bind $e <Shift-Return> {qc::findNext 0; break}
        bind $e <Escape>       {qc::hideFind; break}
    }
}

# Tags fixas do editor e do console (as de sintaxe vêm da linguagem).
proc qc::setupTags {} {
    variable ed
    variable con
    variable C
    $ed tag configure curline   -background $C(curline)
    $ed tag configure errline   -background $C(errline)
    $ed tag configure found     -background $C(found)
    $ed tag configure bmatch    -background $C(bmatch) -font QcMonoB
    $ed tag configure bbad      -background $C(bbad)
    $ed tag lower curline

    $con tag configure stdout -foreground $C(confg)
    $con tag configure stderr -foreground $C(stderr)
    $con tag configure warn   -foreground $C(warn)
    $con tag configure result -foreground $C(result)
    $con tag configure info   -foreground $C(info) -font QcMonoI
    $con tag configure link   -underline 1
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
    set keys {
        <Control-n>         qc::newFile
        <Control-o>         qc::openFile
        <Control-s>         qc::save
        <Control-S>         qc::saveAs
        <Control-F4>        qc::closeFile
        <Control-q>         qc::quit
        <Control-r>         {qc::run 0}
        <Control-Return>    {qc::run 0}
        <Control-R>         {qc::run 1}
        <Control-Break>     qc::stop
        <Control-Pause>     qc::stop
        <Control-w>         qc::clearConsole
        <Control-e>         qc::optionsDialog
        <Control-f>         {qc::showFind 0}
        <Control-h>         {qc::showFind 1}
        <F3>                {qc::findNext 1}
        <Shift-F3>          {qc::findNext 0}
        <Control-l>         qc::gotoDialog
        <Control-plus>      {qc::zoom 1}
        <Control-equal>     {qc::zoom 1}
        <Control-KP_Add>    {qc::zoom 1}
        <Control-minus>     {qc::zoom -1}
        <Control-KP_Subtract> {qc::zoom -1}
        <Control-0>         {qc::zoom 0}
        <Control-a>         {qc::selectAll %W}
    }
    foreach {seq cmd} $keys {
        catch {bind QcKeys $seq "$cmd; break"}
        catch {bind . $seq $cmd}
    }
    event add <<Redo>> <Control-y>

    # teclas específicas do editor
    bind QcEdit <Tab>           {qc::indent 1; break}
    bind QcEdit <Shift-Tab>     {qc::indent 0; break}
    catch {bind QcEdit <ISO_Left_Tab> {qc::indent 0; break}}
    bind QcEdit <Return>        {qc::newline; break}
    bind QcEdit <KP_Enter>      {qc::newline; break}
    bind QcEdit <braceright>    {qc::closeChar "\}"; break}
    bind QcEdit <parenright>    {qc::closeChar ")"; break}
    bind QcEdit <bracketright>  {qc::closeChar "\]"; break}
    bind QcEdit <Control-d>     {qc::duplicateLine; break}
    bind QcEdit <Control-slash> {qc::toggleComment; break}
    bind QcEdit <<Paste>>       {qc::paste %W; break}
    bind QcEdit <Control-MouseWheel> {qc::zoom [expr {%D > 0 ? 1 : -1}]; break}
    bind QcEdit <Button-3>      {focus %W; tk_popup .edpop %X %Y; break}
    bind QcEdit <<Undo>>        {qc::editCmd undo; break}
    bind QcEdit <<Redo>>        {qc::editCmd redo; break}

    bindtags $ed [list $ed QcKeys QcEdit Text . all]
    bindtags $con [list $con QcKeys Text . all]
    foreach e {.pw.ed.find.pat .pw.ed.find.rep} {
        bindtags $e [list $e QcKeys TEntry . all]
    }
    bind $con <Button-3> {tk_popup .conpop %X %Y}
    bind $con <1> {focus %W}

    set gut $::qc::gut
    bind $gut <MouseWheel> {qc::wheel %D}
    catch {bind $gut <Button-4> {$::qc::ed yview scroll -3 units}}
    catch {bind $gut <Button-5> {$::qc::ed yview scroll 3 units}}
    bind $gut <1> {qc::gutterClick %y}
}

proc qc::wheel {d} {
    $::qc::ed yview scroll [expr {$d > 0 ? -3 : 3}] units
}

# Proxy do widget de texto: detecta qualquer alteração do conteúdo e do cursor.
proc qc::installProxy {w} {
    rename $w ::qc::_edw
    interp alias {} $w {} ::qc::edProxy
}

proc qc::edProxy {args} {
    if {[catch {::qc::_edw {*}$args} r o]} {
        return -code error -errorcode [dict get $o -errorcode] $r
    }
    switch -- [lindex $args 0] {
        insert - delete - replace { onChange }
        edit {
            if {[lindex $args 1] in {undo redo}} { onChange }
        }
        mark {
            if {[lindex $args 1] eq "set" && [lindex $args 2] eq "insert"} { onCursor }
        }
    }
    return $r
}

# ---------------------------------------------------------------------------
# Troca de linguagem e destaque de sintaxe
# ---------------------------------------------------------------------------

proc qc::setLang {id} {
    variable lang
    variable langs
    variable inited
    variable cfg
    if {$id ni $langs} return
    if {$id ni $inited} {
        lappend inited $id
        set h [hook init $id]
        if {$h ne ""} {
            if {[catch {$h} err]} { conAppend "Erro no init de $id: $err\n" stderr }
        }
    }
    set lang $id
    set ::qc::langSel $id
    set ::qc::langName [lget name]
    set cfg(lang) $id
    compileLang
    updateTabs
    updateTemplateMenu
    highlight
    updateTitle
    detectVersion
}

# Monta a regex única da linguagem: cada token vira um grupo; um token com
# grupo interno colore só esse grupo.
proc qc::compileLang {} {
    variable H
    variable S
    variable ed
    set d [ldict]
    foreach t $H(tags) { catch {::qc::_edw tag delete $t} }
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
        if {$tag ne "word"} { lappend tags $tag }
    }
    set H(re) "(?w)[join $parts |]"
    set H(specs) $specs
    set H(nfields) $g
    set wd [dict create]
    dict for {tag list} [dict get $d words] {
        foreach w $list { dict set wd $w $tag }
        lappend tags $tag
    }
    set H(words) $wd
    set H(defWords) [dict get $d defWords]
    set H(defTag) [dict get $d defTag]
    set H(capType) [dict get $d capType]
    set H(numRe) [dict get $d numberWord]
    set H(through) [dict get $d defThroughBrace]
    set H(sub) [dict get $d sub]
    set H(wordHook) [hook wordTag]
    set subtags {}
    dict for {t rules} $H(sub) {
        foreach {cond st sre} $rules { lappend subtags $st }
    }
    lappend tags $H(defTag) number
    if {$H(capType) ne ""} { lappend tags $H(capType) }
    set tags [lsort -unique [concat $tags $subtags]]
    set H(tags) $tags
    set H(subtags) [lsort -unique $subtags]

    set styles [dict merge $S [dict get $d styles]]
    foreach t $tags {
        set opts {}
        if {[dict exists $styles $t]} {
            lassign [dict get $styles $t] color st
            if {$color ne ""} { lappend opts -foreground $color }
            switch -- $st {
                B { lappend opts -font QcMonoB }
                I { lappend opts -font QcMonoI }
            }
        }
        ::qc::_edw tag configure $t {*}$opts
    }
    foreach t [concat $H(subtags) errline found bmatch bbad sel] { ::qc::_edw tag raise $t }
    ::qc::_edw tag lower curline
}

proc qc::schedHighlight {} {
    variable hlAfter
    after cancel $hlAfter
    set hlAfter [after 120 qc::highlight]
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
    foreach t $H(tags) { set rng($t) {} }
    set nf $H(nfields)
    set defNext 0
    set m [regexp -all -inline -indices -- $H(re) $txt]
    for {set i 0} {$i < [llength $m]} {incr i $nf} {
        set tag ""
        foreach spec $H(specs) {
            lassign $spec t g inner
            set r [lindex $m [expr {$i + $g}]]
            if {[lindex $r 0] < 0} continue
            set tag $t
            if {$inner} {
                set r2 [lindex $m [expr {$i + $g + 1}]]
                if {[lindex $r2 0] >= 0} { set r $r2 }
            }
            break
        }
        if {$tag eq ""} continue
        lassign $r a z
        if {$tag eq "word"} {
            set word [string range $txt $a $z]
            set tag ""
            set fromTable 0
            if {$H(numRe) ne "" && [regexp -- $H(numRe) $word]} {
                set tag number
            } elseif {[dict exists $H(words) $word]} {
                set tag [dict get $H(words) $word]
                set fromTable 1
            }
            if {$H(wordHook) ne ""} { set tag [$H(wordHook) $word $tag $txt $a] }
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
        lappend rng($tag) [off2idx $starts $a] [off2idx $starts [expr {$z + 1}]]
        # sub-destaques (ex.: interpolação em strings)
        if {[dict exists $H(sub) $tag]} {
            set str [string range $txt $a $z]
            foreach {cond st sre} [dict get $H(sub) $tag] {
                if {![regexp -- $cond $str]} continue
                foreach sr [regexp -all -inline -indices -- $sre $str] {
                    lassign $sr ia iz
                    lappend rng($st) [off2idx $starts [expr {$a + $ia}]] \
                                     [off2idx $starts [expr {$a + $iz + 1}]]
                }
            }
        }
    }
    foreach t $H(tags) {
        ::qc::_edw tag remove $t 1.0 end
        if {[llength $rng($t)]} { ::qc::_edw tag add $t {*}$rng($t) }
    }
    if {[winfo ismapped .pw.ed.find]} { markAll }
}

# offset de caractere -> índice do widget text
proc qc::off2idx {starts off} {
    set L [lsearch -bisect -integer $starts $off]
    return [expr {$L + 1}].[expr {$off - [lindex $starts $L]}]
}

# ---------------------------------------------------------------------------
# Números de linha, cursor, pares de chaves
# ---------------------------------------------------------------------------

proc qc::edYscroll {args} {
    .pw.ed.sy set {*}$args
    schedGutter
}

proc qc::schedGutter {} {
    variable gutPending
    if {!$gutPending} {
        set gutPending 1
        after idle qc::drawGutter
    }
}

proc qc::drawGutter {} {
    variable ed
    variable gut
    variable C
    variable gutPending 0
    $gut delete all
    set last [lindex [split [$ed index end-1c] .] 0]
    set digits [expr {max(3, [string length $last])}]
    set w [expr {[font measure QcMono [string repeat 9 $digits]] + 18}]
    if {[$gut cget -width] != $w} { $gut configure -width $w }
    set cur [lindex [split [$ed index insert] .] 0]
    set i [$ed index "@0,0 linestart"]
    if {[$ed dlineinfo $i] eq ""} { set i [$ed index "$i +1 line"] }
    while {[$ed compare $i < end]} {
        set d [$ed dlineinfo $i]
        if {$d eq ""} break
        set n [lindex [split $i .] 0]
        $gut create text [expr {$w - 10}] [lindex $d 1] -anchor ne -text $n \
            -font QcMono -fill [expr {$n == $cur ? $C(gutcur) : $C(gutfg)}]
        set i [$ed index "$i +1 line"]
    }
}

proc qc::gutterClick {y} {
    variable ed
    set i [$ed index "@0,$y linestart"]
    $ed mark set insert $i
    $ed tag remove sel 1.0 end
    $ed tag add sel $i "$i +1 line"
    focus $ed
}

proc qc::onChange {} {
    ::qc::_edw tag remove errline 1.0 end
    schedHighlight
    schedGutter
    onCursor
}

proc qc::onCursor {} {
    variable curPending
    if {!$curPending} {
        set curPending 1
        after idle qc::updateCursor
    }
}

proc qc::updateCursor {} {
    variable ed
    variable curPending 0
    lassign [split [$ed index insert] .] l c
    set ::qc::lncol "Ln $l, Col [expr {$c + 1}]"
    ::qc::_edw tag remove curline 1.0 end
    ::qc::_edw tag add curline "insert linestart" "insert lineend +1c"
    matchBrackets
    schedGutter
}

# Verdadeiro se a posição está dentro de string/comentário (pelo destaque).
proc qc::inLiteral {idx} {
    foreach t [::qc::_edw tag names $idx] {
        if {$t in {string comment directive}} { return 1 }
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
    if {$i eq "" || [inLiteral $i]} return
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
        if {$pos eq ""} break
        if {[inLiteral $pos]} continue
        if {[$ed get $pos] eq $ch} { incr depth } else { incr depth -1 }
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
        if {$pos eq ""} break
        if {[inLiteral $pos]} continue
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

# Executa várias alterações como um único passo de desfazer.
proc qc::atomic {script} {
    set ed $::qc::ed
    $ed edit separator
    $ed configure -autoseparators 0
    try {
        uplevel 1 $script
    } finally {
        $ed configure -autoseparators 1
        $ed edit separator
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
    if {[catch {clipboard get} data]} return
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
        if {$zc == 0 && $zl > $a} { incr zl -1 }
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
    set h [hook newlineIndent]
    if {$h ne ""} {
        $ed insert insert "\n[$h]"
        $ed see insert
        return
    }
    set before [$ed get "insert linestart" insert]
    regexp {^[ \t]*} $before ws
    set code $before
    if {[lget commentRe] ne ""} { set code [regsub -- [lget commentRe] $code ""] }
    set extra ""
    if {[regexp -- [lget indentAfter] $code]} { set extra [indentStr] }
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
            if {$n == 0} { set n $iw }
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
        if {[string trim $line] ne "" && ![regexp "^\\s*$q.*$qe" $line]} { set all 0; break }
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
        set cfg(fontsize) 12
    } else {
        set cfg(fontsize) [expr {max(6, min(48, $cfg(fontsize) + $d))}]
    }
    foreach f {QcMono QcMonoB QcMonoI} { font configure $f -size $cfg(fontsize) }
    updateTabs
    schedGutter
    set ::qc::status "Fonte: $cfg(fontsize) pt"
}

proc qc::applyWrap {} {
    variable cfg
    variable ed
    if {$cfg(wrap)} {
        $ed configure -wrap word
        grid remove .pw.ed.sx
    } else {
        $ed configure -wrap none
        grid .pw.ed.sx
    }
    schedGutter
}

# ---------------------------------------------------------------------------
# Localizar / substituir / ir para linha
# ---------------------------------------------------------------------------

proc qc::showFind {replace} {
    variable ed
    variable find
    grid .pw.ed.find
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        if {[string first \n $s] < 0} { set find(pat) $s }
    }
    set e [expr {$replace ? ".pw.ed.find.rep" : ".pw.ed.find.pat"}]
    if {$replace && $find(pat) eq ""} { set e .pw.ed.find.pat }
    focus $e
    $e selection range 0 end
    markAll
}

proc qc::hideFind {} {
    grid remove .pw.ed.find
    $::qc::ed tag remove found 1.0 end
    focus $::qc::ed
}

proc qc::searchOpts {} {
    variable find
    set o {}
    if {!$find(case)}  { lappend o -nocase }
    if {$find(regex)}  { lappend o -regexp }
    return $o
}

proc qc::markAll {} {
    variable ed
    variable find
    ::qc::_edw tag remove found 1.0 end
    .pw.ed.find.pat configure -style TEntry
    set find(info) ""
    if {$find(pat) eq "" || ![winfo ismapped .pw.ed.find]} return
    set cnt {}
    if {[catch {::qc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} {
        set find(info) "regex inválida"
        .pw.ed.find.pat configure -style NotFound.TEntry
        return
    }
    set r {}
    foreach h $hits n $cnt {
        if {$n > 0} { lappend r $h "$h +${n}c" }
    }
    if {[llength $r]} { ::qc::_edw tag add found {*}$r }
    set find(info) "[llength $hits] ocorrência(s)"
    if {![llength $hits]} { .pw.ed.find.pat configure -style NotFound.TEntry }
}

proc qc::findNext {fwd} {
    variable ed
    variable find
    if {$find(pat) eq ""} { showFind 0; return }
    if {$fwd} {
        set start [expr {[llength [$ed tag ranges sel]] ? "sel.last" : "insert"}]
        set dir -forwards
    } else {
        set start [expr {[llength [$ed tag ranges sel]] ? "sel.first" : "insert"}]
        set dir -backwards
    }
    if {[catch {::qc::_edw search $dir {*}[searchOpts] -count n -- $find(pat) $start} idx]} return
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
    if {!$find(regex)} { return $find(rep) }
    set o {}
    if {!$find(case)} { lappend o -nocase }
    regsub {*}$o -- $find(pat) $matched $find(rep) out
    return $out
}

proc qc::replaceOne {} {
    variable ed
    variable find
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        set o [searchOpts]
        if {[catch {::qc::_edw search {*}$o -count n -- $find(pat) sel.first sel.last} idx] == 0
                && $idx ne "" && [$ed compare $idx == sel.first] && $n == [string length $s]} {
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
    if {$find(pat) eq ""} return
    set cnt {}
    if {[catch {::qc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} return
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
    if {[winfo exists $w]} { raise $w; focus $w.e; return }
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
    foreach r [lget runners $id] { lappend out [dict get $r name] }
    return $out
}

# Executável do runner: opção do usuário, variável QCONSOLE_<LANG>, hook
# findExe da linguagem ou busca no PATH pelos nomes em "exe".
proc qc::findExe {rn {id ""}} {
    if {$id eq ""} { set id $::qc::lang }
    set name [dict get $rn name]
    set user [lcfg exe.$name $id]
    if {$user ne ""} { return [list $user] }
    set ev QCONSOLE_[string toupper $id]
    if {[info exists ::env($ev)]} { return [list $::env($ev)] }
    set h [hook findExe $id]
    if {$h ne ""} {
        set p [$h $rn]
        if {$p ne ""} { return $p }
    }
    foreach n [dict get $rn exe] {
        set p [auto_execok $n]
        if {$p ne ""} { return $p }
    }
    return ""
}

# Runner corrente: o escolhido nas opções, se disponível, ou o primeiro
# encontrado. Retorna o dicionário da linguagem mesclado com o do runner.
proc qc::currentRunner {{id ""}} {
    if {$id eq ""} { set id $::qc::lang }
    set rs [lget runners $id]
    if {![llength $rs]} { return "" }
    set want [lcfg runner $id]
    foreach r $rs {
        if {[dict get $r name] eq $want && [findExe $r $id] ne ""} { return $r }
    }
    foreach r $rs {
        if {[findExe $r $id] ne ""} { return $r }
    }
    return [lindex $rs 0]
}

# Onde o executável é procurado (para mensagens).
proc qc::runnerSearched {rn} {
    if {[dict exists $rn searchHint]} { return [dict get $rn searchHint] }
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
    if {$rn eq ""} { set ::qc::interp "sem interpretador"; return }
    set key $lang,[dict get $rn name]
    set exe [findExe $rn]
    if {$exe eq ""} {
        set ::qc::interp "[runnerLabel $rn] não encontrado"
        return
    }
    if {[info exists V($key)]} { showVersion; return }
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
    fileevent $f readable [list qc::onVersion $f $key $rn]
}

proc qc::onVersion {f key rn} {
    variable V
    append ::qc::verBuf($f) [read $f]
    if {![eof $f]} return
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
    if {$rn eq ""} { return "" }
    set key $::qc::lang,[dict get $rn name]
    return [expr {[info exists V($key)] ? $V($key) : ""}]
}

# ---------------------------------------------------------------------------
# Opções de execução
# ---------------------------------------------------------------------------

proc qc::optionsDialog {} {
    variable cfg
    set w .opts
    if {[winfo exists $w]} { destroy $w }
    set names [runnerNames]
    set rn [currentRunner]
    set ::qc::optTmp(runner) [expr {$rn eq "" ? "" : [dict get $rn name]}]
    set ::qc::optTmp(opts)   [lcfg opts]
    set ::qc::optTmp(args)   [lcfg args]
    set ::qc::optTmp(exe)    [lcfg exe.$::qc::optTmp(runner)]
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
        if {[dict get $r name] eq $::qc::optTmp(runner)} { return $r }
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
    if {$rn eq ""} return
    set saved [lcfg exe.[dict get $rn name]]
    set ::qc::cfg(exe.[dict get $rn name].$::qc::lang) ""
    set found [findExe $rn]
    set ::qc::cfg(exe.[dict get $rn name].$::qc::lang) $saved
    $w.hx configure -text [expr {$found eq ""
        ? "não encontrado (procurados: [runnerSearched $rn])"
        : "vazio = [join $found]"}]
    $w.ho configure -text [expr {[dict exists $rn optsHint] ? "ex.: [dict get $rn optsHint]" : ""}]
}

proc qc::optionsApply {} {
    variable cfg
    variable lang
    set r $::qc::optTmp(runner)
    set cfg(runner.$lang) $r
    set cfg(opts.$lang)   [string trim $::qc::optTmp(opts)]
    set cfg(args.$lang)   [string trim $::qc::optTmp(args)]
    set cfg(exe.$r.$lang) [string trim $::qc::optTmp(exe)]
    catch {unset ::qc::V($lang,$r)}
    destroy .opts
    saveCfg
    detectVersion
    set ::qc::status "Opções de execução atualizadas"
}

# ---------------------------------------------------------------------------
# Arquivos
# ---------------------------------------------------------------------------

proc qc::updateTitle {} {
    variable file
    set name [expr {$file eq "" ? "Sem título" : [file tail $file]}]
    set mod [expr {[$::qc::ed edit modified] ? " •" : ""}]
    set dir [expr {$file eq "" ? "" : "  —  [file dirname $file]"}]
    wm title . "$name$mod$dir  —  qconsole · [lget name]"
}

proc qc::confirmDiscard {} {
    if {![$::qc::ed edit modified]} { return 1 }
    set r [tk_messageBox -parent . -icon warning -type yesnocancel \
        -title qconsole -message "Salvar as alterações?" \
        -detail "O arquivo foi modificado."]
    switch -- $r {
        yes     { return [save] }
        no      { return 1 }
        default { return 0 }
    }
}

proc qc::setContent {data} {
    variable ed
    $ed delete 1.0 end
    $ed insert 1.0 $data
    $ed edit reset
    $ed edit modified 0
    $ed mark set insert 1.0
    $ed see 1.0
    ::qc::_edw tag remove errline 1.0 end
    highlight
    updateTitle
}

proc qc::newFile {{force 0}} {
    if {!$force && ![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::qc::status "Novo arquivo ([lget name])"
}

proc qc::newFromTemplate {label} {
    if {![confirmDiscard]} return
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
    if {![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::qc::status "Arquivo fechado"
}

proc qc::fileTypes {} {
    variable langs
    variable lang
    set out [list [list [lget name] [lget ext]]]
    foreach id $langs {
        if {$id ne $lang && [llength [lget ext $id]]} {
            lappend out [list [lget name $id] [lget ext $id]]
        }
    }
    lappend out {"Todos os arquivos" *}
    return $out
}

proc qc::langForFile {path} {
    variable langs
    set ext [string tolower [file extension $path]]
    if {$ext in [lget ext]} { return $::qc::lang }
    foreach id $langs {
        if {$ext in [lget ext $id]} { return $id }
    }
    return ""
}

proc qc::openFile {{path ""}} {
    variable cfg
    if {![confirmDiscard]} return
    if {$path eq ""} {
        set opts [list -parent . -title "Abrir" -filetypes [fileTypes]]
        if {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
            lappend opts -initialdir $cfg(lastdir)
        }
        set path [tk_getOpenFile {*}$opts]
        if {$path eq ""} return
    }
    if {[catch {readFile $path} data]} {
        tk_messageBox -parent . -icon error -title qconsole \
            -message "Não foi possível abrir o arquivo." -detail $data
        return
    }
    if {[string index $data end] eq "\n"} { set data [string range $data 0 end-1] }
    variable file [file normalize $path]
    set cfg(lastdir) [file dirname $file]
    set id [langForFile $file]
    if {$id ne "" && $id ne $::qc::lang} { setLang $id }
    setContent $data
    addRecent $file
    set ::qc::status "Aberto: $file"
}

proc qc::save {} {
    variable file
    if {$file eq ""} { return [saveAs] }
    return [saveTo $file]
}

proc qc::saveAs {} {
    variable cfg
    variable file
    set h [hook defaultExt]
    set ext [expr {$h ne "" ? [$h [$::qc::ed get 1.0 end-1c]] : [lindex [lget ext] 0]}]
    set opts [list -parent . -title "Salvar como" -filetypes [fileTypes]]
    if {$ext ne ""} { lappend opts -defaultextension $ext }
    if {$file ne ""} {
        lappend opts -initialdir [file dirname $file] -initialfile [file tail $file]
    } elseif {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
        lappend opts -initialdir $cfg(lastdir)
    }
    set path [tk_getSaveFile {*}$opts]
    if {$path eq ""} { return 0 }
    return [saveTo [file normalize $path]]
}

proc qc::saveTo {path} {
    variable ed
    variable cfg
    set data [$ed get 1.0 end-1c]
    if {$data ne "" && [string index $data end] ne "\n"} { append data \n }
    if {[catch {writeFile $path $data} err]} {
        tk_messageBox -parent . -icon error -title qconsole \
            -message "Não foi possível salvar o arquivo." -detail $err
        return 0
    }
    variable file $path
    set cfg(lastdir) [file dirname $path]
    $ed edit modified 0
    addRecent $path
    updateTitle
    set ::qc::status "Salvo: $path"
    return 1
}

proc qc::addRecent {path} {
    variable cfg
    set l [lsearch -all -inline -not -exact $cfg(recent) $path]
    set cfg(recent) [lrange [linsert $l 0 $path] 0 9]
    updateRecentMenu
}

proc qc::updateRecentMenu {} {
    variable cfg
    set m .mb.file.recent
    $m delete 0 end
    foreach p $cfg(recent) {
        $m add command -label $p -command [list qc::openFile $p]
    }
    if {![llength $cfg(recent)]} {
        $m add command -label "(vazio)" -state disabled
    } else {
        $m add separator
        $m add command -label "Limpar lista" -command {set ::qc::cfg(recent) {}; qc::updateRecentMenu}
    }
}

proc qc::quit {} {
    if {![confirmDiscard]} return
    stop
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
    $con insert end $text $tag
    # limita o tamanho do console
    set lines [lindex [split [$con index end] .] 0]
    if {$lines > 50000} { $con delete 1.0 [expr {$lines - 40000}].0 }
    $con configure -state disabled
    $con see end
}

proc qc::clearConsole {} {
    variable con
    $con configure -state normal
    $con delete 1.0 end
    $con configure -state disabled
}

proc qc::setRunning {on} {
    set s [expr {$on ? "disabled" : "!disabled"}]
    set ns [expr {$on ? "!disabled" : "disabled"}]
    .tb.run state $s
    .tb.stop state $ns
    .mb.script entryconfigure 0 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 1 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 2 -state [expr {$on ? "normal" : "disabled"}]
}

proc qc::run {selOnly} {
    variable ed
    variable R
    variable cfg
    variable file
    variable lang
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
    if {$cfg(autoclear)} { clearConsole }
    set rn [currentRunner]
    if {$rn eq ""} {
        conAppend "[lget name]: nenhum interpretador definido.\n" stderr
        return
    }
    set exe [findExe $rn]
    if {$exe eq ""} {
        conAppend "[runnerLabel $rn] não encontrado (procurados: [runnerSearched $rn]).\nIndique o executável em Executar > Opções de execução (Ctrl+E).\n" stderr
        return
    }
    ::qc::_edw tag remove errline 1.0 end

    # nome do arquivo temporário: o do arquivo atual ou script.<ext>
    set exts [lget ext]
    set ext [string tolower [file extension $file]]
    set name [expr {$file ne "" && $ext in $exts ? [file tail $file] : "script[lindex $exts 0]"}]
    set mode ""
    set h [hook prepare]
    if {$h ne ""} {
        set p [$h $code $selOnly $file $name]
        if {[dict exists $p name]} { set name [dict get $p name] }
        if {[dict exists $p code]} { set code [dict get $p code] }
        if {[dict exists $p mode]} { set mode [dict get $p mode] }
    }
    set disp [expr {$file eq "" ? $name : [file tail $file]}]

    set dir [tmpDir]
    set script [file join $dir $name]
    if {$code ne "" && [string index $code end] ne "\n"} { append code \n }
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
            %F   { lappend cmd $script }
            %W   { lappend cmd $wrapper }
            %O   { lappend cmd {*}$opts }
            %A   { lappend cmd {*}$pargs }
            %--A { if {[llength $pargs]} { lappend cmd -- {*}$pargs } }
            default { lappend cmd $a }
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
    set pats {}
    set fre "(?:\[^\\s:(\"'\]*\[/\\\\\])?[reQuote $name]"
    foreach p [dict get $d errPatterns] {
        set p [string map [list %F $fre] $p]
        if {![catch {regexp -about $p} ab]} { lappend pats $p [lindex $ab 0] }
    }
    set nlines [llength [split [string trimright $code \n] \n]]
    array set R [list fd $fd er $er open 2 t0 [clock milliseconds] lang $lang \
        lineoff $lineoff script $script name $name disp $disp nlines $nlines \
        pats $pats col0 [dict get $d col0] infoRe [dict get $d infoRe] \
        warnRe [dict get $d warnRe] grayInfo [dict get $d grayInfo] \
        killed 0 jumped 0 pend "" sgr {} pid [lindex [pid $fd] 0]]
    fileevent $fd readable [list qc::onStdout $fd]
    fileevent $er readable [list qc::onStderr $er]

    set what [expr {$selOnly ? "seleção de $disp (a partir da linha [expr {$lineoff + 1}])" : $disp}]
    set info [list $what [runnerLabel $rn]]
    if {$mode ne ""} { lappend info $mode }
    lappend info [clock format [clock seconds] -format %H:%M:%S]
    conAppend "▶ [join $info {  ·  }]\n" info
    setRunning 1
    set ::qc::status "Executando…"
}

proc qc::onStdout {fd} {
    set data [read $fd]
    if {$data ne ""} { conAnsi $data stdout }
    if {[eof $fd]} {
        fileevent $fd readable {}
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
        if {[string range $data {*}$f] ne "m"} continue
        foreach c [split [string range $data {*}$p] ";"] {
            if {$c ne "" && ![string is integer -strict $c]} continue
            if {$c eq "" || $c == 0} {
                set R(sgr) {}
            } elseif {$c == 1} {
                lappend R(sgr) ansiB
            } elseif {$c == 22} {
                set R(sgr) [lsearch -all -inline -not -exact $R(sgr) ansiB]
            } elseif {($c >= 30 && $c <= 37) || ($c >= 90 && $c <= 97) || $c == 39} {
                set R(sgr) [lsearch -all -inline -not -glob $R(sgr) {ansi[0-9]*}]
                if {$c != 39} { lappend R(sgr) ansi$c }
            }
        }
    }
    if {$pos < [string length $data]} {
        conAppend [string range $data $pos end] [list $base {*}$R(sgr)]
    }
}

proc qc::onStderr {er} {
    while {[gets $er line] >= 0} { errLine $line }
    if {[eof $er]} {
        fileevent $er readable {}
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
            foreach {tag text} $res { linkify $text $tag }
            return
        }
    }
    # barras de progresso: fica só com o último trecho após \r
    set k [string last \r $raw]
    if {$k >= 0} { set raw [string range $raw $k+1 end] }
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
proc qc::linkify {line tag} {
    variable R
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
            if {[lindex $lg 0] >= 0} { lappend hits [list {*}$whole {*}$lg {*}$cg] }
        }
    }
    set pos 0
    foreach h [lsort -integer -index 0 $hits] {
        lassign $h ms me ls le cs ce
        if {$ms < $pos} continue
        set n [string range $line $ls $le]
        # linhas além do fim são de código gerado pelo interpretador/wrapper
        # (a linha seguinte à última é aceita: "fim inesperado do arquivo")
        if {$n < 1 || $n > $R(nlines) + 1} continue
        set target [expr {min($n, max($R(nlines), 1)) + $R(lineoff)}]
        set col 0
        if {$cs >= 0} {
            set col [string range $line $cs $ce]
            if {!$R(col0)} { incr col -1 }
            if {$col < 0} { set col 0 }
        }
        # troca o caminho do temporário pelo nome exibido e a linha pela real
        set segs [list [list $ls $le $target]]
        set k [string first $R(name) [string range $line $ms $me]]
        if {$k >= 0} {
            set ps [expr {$ms + $k}]
            set pe [expr {$ps + [string length $R(name)] - 1}]
            while {$ps > $ms && [string index $line $ps-1] ni {" " "\t" : ( \" '}} { incr ps -1 }
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
        conAppend $txt [list $tag link $lt]
        $con tag bind $lt <1> [list qc::gotoLine $target $col]
        set pos [expr {$me + 1}]
        if {$tag eq "stderr"} {
            ::qc::_edw tag add errline $target.0 "$target.0 lineend +1c"
            if {!$R(jumped)} {
                set R(jumped) 1
                $::qc::ed see $target.0
            }
        }
    }
    conAppend [string range $line $pos end]\n $tag
}

proc qc::streamClosed {} {
    variable R
    if {[incr R(open) -1] > 0} return
    set fd $R(fd)
    fconfigure $fd -blocking 1
    set code 0
    if {[catch {close $fd} msg opts]} {
        set ec [dict get $opts -errorcode]
        switch -- [lindex $ec 0] {
            CHILDSTATUS { set code [lindex $ec 2] }
            CHILDKILLED { set code [lindex $ec 2] }
            default     { set code "?" }
        }
    }
    catch {close $R(er)}
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
        foreach k $kids { lappend out $k {*}[descendants $k] }
    }
    return $out
}

proc qc::stop {} {
    variable R
    if {![info exists R(pid)]} return
    set R(killed) 1
    if {$::tcl_platform(platform) eq "windows"} {
        catch {exec {*}[auto_execok taskkill] /F /T /PID $R(pid)}
        return
    }
    set all [linsert [descendants $R(pid)] 0 $R(pid)]
    catch {exec kill {*}$all}
    # processos que demoram a sair (ex.: JVM): força após 3 s
    after 3000 [list apply {{all t0} {
        if {[info exists ::qc::R(t0)] && $::qc::R(t0) == $t0} {
            catch {exec kill -9 {*}$all}
        }
    }} $all $R(t0)]
}

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

proc qc::showShortcuts {} {
    tk_messageBox -parent . -title "Atalhos" -message "Atalhos de teclado" -detail [join {
        "Ctrl+R / Ctrl+Enter   Executar"
        "Ctrl+Shift+R          Executar seleção"
        "Ctrl+Break            Interromper execução"
        "Ctrl+W                Limpar saída"
        "Ctrl+E                Opções de execução"
        ""
        "Ctrl+N / O / S        Novo / Abrir / Salvar"
        "Ctrl+Shift+S          Salvar como"
        "Ctrl+F4               Fechar arquivo"
        "Ctrl+Q                Sair"
        ""
        "Ctrl+Z / Ctrl+Y       Desfazer / Refazer"
        "Ctrl+F / Ctrl+H       Localizar / Substituir"
        "F3 / Shift+F3         Próximo / Anterior"
        "Ctrl+L                Ir para linha"
        "Ctrl+D                Duplicar linha"
        "Ctrl+/                Comentar linhas"
        "Tab / Shift+Tab       Indentar / Desindentar"
        "Ctrl+ + / - / 0       Tamanho da fonte"
    } \n]
}

proc qc::about {} {
    variable langs
    set ls {}
    foreach id $langs { lappend ls [lget name $id] }
    set rn [currentRunner]
    set exe [expr {$rn eq "" ? "" : [join [findExe $rn]]}]
    set extra [expr {[llength $::qc::loadErrors] ? "\n\nErros ao carregar linguagens:\n[join $::qc::loadErrors \n]" : ""}]
    tk_messageBox -parent . -title "Sobre" -message "qconsole $::qc::version" \
        -detail "Editor simples para avaliação rápida de código.\n\nLinguagens: [join $ls {, }]\nAtual: [lget name] · $::qc::interp\nComando: $exe\n\nTcl [info patchlevel] · Tk [package present Tk]$extra"
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
    tokens {
        comment {(?:^|;)[ \t]*(#[^\n]*)}
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
proc qc::lang::tcl::wordTag {word tag txt a} {
    if {$tag eq ""} { return "" }
    if {$word in {else elseif then finally on trap}} { return keyword }
    set p [expr {$a - 1}]
    while {$p >= 0 && [string index $txt $p] in {" " "\t"}} { incr p -1 }
    if {$p >= 0 && [string index $txt $p] ni [list \n \; \[ \{]} { return "" }
    return $tag
}

proc qc::lang::tcl::stderrLine {line} {
    switch -glob -- $line {
        "\x01R*" { return [list result "Resultado: [string map {\x02 \n} [string range $line 2 end]]"] }
        "\x01E*" {
            set out {}
            foreach l [split [string range $line 2 end] \x02] { lappend out stderr $l }
            return $out
        }
    }
    return -
}

# tclsh da mesma instalação do wish, se houver.
proc qc::lang::tcl::findExe {rn} {
    set exe [info nameofexecutable]
    if {[string match -nocase tclsh* [file tail $exe]]} { return [list $exe] }
    set dir [file dirname $exe]
    set v [info tclversion]
    foreach n [list tclsh$v tclsh[string map {. ""} $v] tclsh] {
        foreach c [list [file join $dir $n] [file join $dir $n.exe]] {
            if {[file isfile $c] && [file executable $c]} { return [list $c] }
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
        if {![regexp {^[A-Za-z_]} $base]} { set base "s$base" }
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

# --- Scheme (Guile, Chez) --------------------------------------------------

qc::language scheme {
    name     Scheme
    ext      {.scm .ss .sls .sps .sld}
    comment  ;;
    indent   2
    dedentChars ""
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
            define-module define-library lambda lambda* case-lambda named-lambda
            let let* letrec letrec* let-values let*-values let-syntax
            letrec-syntax if cond case else when unless begin do set! quote
            quasiquote unquote unquote-splicing and or syntax-rules syntax-case
            with-syntax identifier-syntax import library export guard
            parameterize delay delay-force force call/cc
            call-with-current-continuation dynamic-wind receive assert
            use-modules module fluid-let include cond-expand =>
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
    }
}

# Indentação estilo Lisp: um nível além do "(" que envolve o cursor.
proc qc::lang::scheme::newlineIndent {} {
    set p [::qc::enclosingOpen insert]
    if {$p eq ""} { return "" }
    set col [lindex [split $p .] 1]
    return [string repeat " " [expr {$col + [::qc::lget indent]}]]
}

# --- OCaml / OxCaml ----------------------------------------------------------

qc::language ocaml {
    name       "OCaml"
    ext        {.ml .mli .mlx}
    comment    "(*"
    commentEnd "*)"
    indent     2
    indentAfter {(?:=|->|\m(?:then|else|do|begin|struct|sig|object|in|with|try|fun|function)|[\{\[\(])\s*$}
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
}

# OxCaml é o compilador da Jane Street instalado como switch do opam (ex.:
# 5.2.0+ox): procura o toplevel no switch ativo ou em ~/.opam/*ox*.
proc qc::lang::ocaml::findExe {rn} {
    set opam [file join [::qc::homeDir] .opam]
    set pfx [expr {[info exists ::env(OPAM_SWITCH_PREFIX)] ? $::env(OPAM_SWITCH_PREFIX) : ""}]
    if {[dict get $rn name] eq "oxcaml"} {
        set cands [glob -nocomplain -directory $opam *ox*/bin/ocaml]
        if {[string match *ox* [file tail $pfx]]} { set cands [linsert $cands 0 $pfx/bin/ocaml] }
    } else {
        set p [auto_execok ocaml]
        if {$p ne ""} { return $p }
        set cands {}
        if {$pfx ne ""} { lappend cands $pfx/bin/ocaml }
        lappend cands $opam/default/bin/ocaml {*}[glob -nocomplain -directory $opam */bin/ocaml]
    }
    foreach c $cands {
        if {[file executable $c]} { return [list $c] }
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
    sub      { string {{^"} var {\$(?:\{[^\}\n]*\}|[A-Za-z_][A-Za-z0-9_]*|[0-9#?$!@*-])}} }
    runners {
        {name bash label bash exe {bash} args {%O %F %A} optsHint "-x   -e   -u   -o pipefail"}
        {name sh   label sh   exe {sh}   args {%O %F %A} optsHint "-x   -e"}
        {name zsh  label zsh  exe {zsh}  args {%O %F %A} optsHint "-x   -e"}
        {name dash label dash exe {dash} args {%O %F %A}}
    }
    errPatterns {{%F: line ([0-9]+):} {%F:([0-9]+):} {%F: ([0-9]+):}}
}

# ---------------------------------------------------------------------------

proc qc::main {argv} {
    variable langs
    variable cfg
    loadLanguageFiles
    loadCfg
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
    foreach l $langs { lappend names [lget name $l] }
    .tb.lang configure -values $names
    if {$id eq "" && $path ne ""} { set id [langForFileAny $path] }
    if {$id eq "" || $id ni $langs} { set id $cfg(lang) }
    if {$id eq "" || $id ni $langs} { set id [lindex $langs 0] }
    setLang $id
    if {$path ne ""} {
        openFile $path
    } else {
        newFile 1
    }
    foreach e $::qc::loadErrors { conAppend "Erro ao carregar linguagem: $e\n" stderr }
    focus $::qc::ed
    updateCursor
}

proc qc::langForFileAny {path} {
    set ext [string tolower [file extension $path]]
    foreach id $::qc::langs {
        if {$ext in [lget ext $id]} { return $id }
    }
    return ""
}

if {![info exists ::qc_nomain]} {
    qc::main $argv
}
