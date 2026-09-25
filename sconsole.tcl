#!/usr/bin/env wish
# sconsole.tcl -- editor/console simples para testes rápidos em Scala 3.
#
# Irmão do tconsole.tcl (inspirado no groovyConsole): editor em cima, saída
# da execução embaixo. O código é executado pelo comando `scala` (Scala 3.5+,
# baseado no scala-cli) ou pelo `scala-cli`, em um processo separado (a
# interface não trava e a execução pode ser interrompida). Requer Tcl/Tk 8.6
# ou 9.x.
#
# O código é executado como script (.sc: instruções no nível superior) ou,
# se tiver @main / def main / extends App, como fonte .scala. Diretivas
# "//> using ..." funcionam normalmente (dependências, versão do Scala etc).
#
# Uso: wish sconsole.tcl ?arquivo.sc|arquivo.scala?
#
# Variável de ambiente opcional: SCONSOLE_SCALA=/caminho/do/scala

package require Tk 8.6-

namespace eval sc {
    variable version 1.0
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
    variable kw [dict create]
    variable R                ;# estado da execução corrente
    array set R {}
    variable find
    array set find {pat "" rep "" case 0 regex 0}
    variable cfg
    array set cfg {
        fontsize 12 wrap 0 autoclear 1 recent {} geometry 1100x800
        lastdir "" sash 0.65 indent 2 scalaopts "" args ""
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
        keyword  #cc7832   defname  #ffc66d   type     #6fafbd
        string   #6a8759   comment  #808080   number   #6897bb
        interp   #9876aa   annot    #bbb529   brace    #d0a86a
        directive #629755
        stderr   #ff6b68   warn     #e0c46c   info     #6f7f8f
    }
}

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------

proc sc::homeDir {} {
    if {![catch {file home} h]} { return $h }
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)]} { return $::env($v) }
    }
    return [pwd]
}

proc sc::tmpDir {} {
    variable tmpdir
    if {[info exists tmpdir] && [file isdirectory $tmpdir]} { return $tmpdir }
    if {![catch {file tempdir} d]} { return [set tmpdir $d] }
    set base /tmp
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)]} { set base $::env($v); break }
    }
    set tmpdir [file join $base sconsole-[pid]-[clock clicks]]
    file mkdir $tmpdir
    return $tmpdir
}

proc sc::setEncoding {chan} {
    fconfigure $chan -encoding utf-8
    catch {fconfigure $chan -profile replace}   ;# Tcl 9
}

proc sc::readFile {path} {
    set f [open $path r]
    setEncoding $f
    set data [read $f]
    close $f
    return $data
}

proc sc::writeFile {path data} {
    set f [open $path w]
    setEncoding $f
    puts -nonewline $f $data
    close $f
}

proc sc::findScala {} {
    if {[info exists ::env(SCONSOLE_SCALA)]} { return [list $::env(SCONSOLE_SCALA)] }
    foreach n {scala scala-cli} {
        set p [auto_execok $n]
        if {$p ne ""} { return $p }
    }
    return ""
}

# Converte uma string de opções em lista (aceita sintaxe de lista Tcl para
# argumentos com espaços; senão divide nos espaços).
proc sc::splitArgs {s} {
    if {[catch {llength $s}]} { return [regexp -all -inline {\S+} $s] }
    return $s
}

proc sc::pickFont {} {
    set fams [font families]
    foreach f {"JetBrains Mono" "Fira Code" "Source Code Pro" "Cascadia Code"
               "Hack" "DejaVu Sans Mono" "Liberation Mono" "Consolas" "Menlo"
               "Monaco" "Courier New"} {
        if {[lsearch -nocase -exact $fams $f] >= 0} { return $f }
    }
    return [font actual TkFixedFont -family]
}

proc sc::loadCfg {} {
    variable cfg
    set rc [file join [homeDir] .sconsolerc]
    if {[file readable $rc]} {
        catch {
            set d [readFile $rc]
            foreach k [array names cfg] {
                if {[dict exists $d $k]} { set cfg($k) [dict get $d $k] }
            }
        }
    }
    if {![string is integer -strict $cfg(fontsize)]} { set cfg(fontsize) 12 }
    if {![string is integer -strict $cfg(indent)] || $cfg(indent) < 1} { set cfg(indent) 2 }
}

proc sc::saveCfg {} {
    variable cfg
    catch {
        set cfg(geometry) [wm geometry .]
        set h [winfo height .pw]
        if {$h > 50} { set cfg(sash) [format %.3f [expr {double([.pw sashpos 0]) / $h}]] }
    }
    set out ""
    foreach k [lsort [array names cfg]] { append out [list $k $cfg($k)] \n }
    catch { writeFile [file join [homeDir] .sconsolerc] $out }
}

# ---------------------------------------------------------------------------
# Tema
# ---------------------------------------------------------------------------

proc sc::setupTheme {} {
    variable C
    variable cfg
    set fam [pickFont]
    font create ScMono  -family $fam -size $cfg(fontsize)
    font create ScMonoB -family $fam -size $cfg(fontsize) -weight bold
    font create ScMonoI -family $fam -size $cfg(fontsize) -slant italic

    tk_setPalette background $C(ui) foreground $C(uifg) \
        activeBackground $C(accent) activeForeground #ffffff \
        selectBackground $C(sel) selectForeground #ffffff \
        highlightColor $C(accent) highlightBackground $C(ui) \
        insertBackground $C(caret) disabledForeground #6d6d6d \
        troughColor $C(trough) selectColor $C(field)
    option add *Menu.relief flat
    option add *Menu.activeBorderWidth 0
    option add *Menu.borderWidth 1

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

proc sc::buildUI {} {
    variable C
    variable cfg
    variable ed
    variable con
    variable gut

    wm title . sconsole
    wm geometry . $cfg(geometry)
    wm minsize . 500 350
    . configure -background $C(ui)

    buildMenus

    # Barra de ferramentas
    ttk::frame .tb -padding {4 3}
    set i 0
    foreach {name label cmd} {
        new   "Novo"         sc::newFile
        open  "Abrir…"       sc::openFile
        save  "Salvar"       sc::save
        -     -              -
        undo  "↶"            {sc::editCmd undo}
        redo  "↷"            {sc::editCmd redo}
        -     -              -
        run   "▶ Executar"   {sc::run 0}
        stop  "■ Parar"      sc::stop
        clear "⌫ Limpar"     sc::clearConsole
        opts  "Opções…"      sc::optionsDialog
        -     -              -
        find  "Localizar"    {sc::showFind 0}
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

    # Painéis editor / console
    ttk::panedwindow .pw -orient vertical

    set f [ttk::frame .pw.ed]
    set gut [canvas $f.gut -background $C(gutbg) -highlightthickness 0 -bd 0 -width 40]
    set ed [text $f.t -background $C(edbg) -foreground $C(edfg) \
        -insertbackground $C(caret) -insertwidth 2 -selectbackground $C(sel) \
        -selectforeground {} -inactiveselectbackground $C(sel) \
        -font ScMono -undo 1 -maxundo 0 -autoseparators 1 \
        -wrap [expr {$cfg(wrap) ? "word" : "none"}] \
        -bd 0 -highlightthickness 0 -padx 6 -pady 4 -tabstyle wordprocessor \
        -yscrollcommand sc::edYscroll -xscrollcommand [list $f.sx set]]
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
        -font ScMono -wrap char -bd 0 -highlightthickness 0 -padx 6 -pady 4 \
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
    ttk::label .sb.msg -textvariable ::sc::status -style Status.TLabel -anchor w
    ttk::label .sb.pos -textvariable ::sc::lncol -style Status.TLabel -width 16
    ttk::label .sb.scala -textvariable ::sc::interp -style Status.TLabel
    pack .sb.scala .sb.pos -side right
    pack .sb.msg -side left -fill x -expand 1

    pack .tb -side top -fill x
    pack .sb -side bottom -fill x
    pack .pw -side top -fill both -expand 1

    setupTags
    updateTabs
    installProxy $ed
    setupBindings

    bind $gut <Configure> sc::schedGutter
    bind $ed <Configure> sc::schedGutter
    bind $ed <<Modified>> sc::updateTitle
    wm protocol . WM_DELETE_WINDOW sc::quit

    # posição inicial do divisor
    after idle {
        update idletasks
        set h [winfo height .pw]
        if {$h > 50} { catch {.pw sashpos 0 [expr {int($h * $::sc::cfg(sash))}]} }
    }

    detectVersion
}

proc sc::buildMenus {} {
    variable cfg
    menu .mb -tearoff 0
    . configure -menu .mb

    set m [menu .mb.file -tearoff 0]
    .mb add cascade -label Arquivo -menu $m
    $m add command -label "Novo"               -accelerator Ctrl+N       -command sc::newFile
    $m add cascade -label "Novo a partir de modelo" -menu [menu $m.tpl -tearoff 0]
    $m.tpl add command -label "JVM"           -command {sc::newFromTemplate jvm}
    $m.tpl add command -label "Scala.js"      -command {sc::newFromTemplate js}
    $m.tpl add command -label "Scala Native"  -command {sc::newFromTemplate native}
    $m add command -label "Abrir…"             -accelerator Ctrl+O       -command sc::openFile
    $m add cascade -label "Recentes"           -menu [menu $m.recent -tearoff 0]
    $m add separator
    $m add command -label "Salvar"             -accelerator Ctrl+S       -command sc::save
    $m add command -label "Salvar como…"       -accelerator Ctrl+Shift+S -command sc::saveAs
    $m add command -label "Fechar arquivo"     -accelerator Ctrl+F4      -command sc::closeFile
    $m add separator
    $m add command -label "Sair"               -accelerator Ctrl+Q       -command sc::quit
    updateRecentMenu

    set m [menu .mb.edit -tearoff 0]
    .mb add cascade -label Editar -menu $m
    $m add command -label "Desfazer"           -accelerator Ctrl+Z       -command {sc::editCmd undo}
    $m add command -label "Refazer"            -accelerator Ctrl+Y       -command {sc::editCmd redo}
    $m add separator
    $m add command -label "Recortar"           -accelerator Ctrl+X       -command {event generate $::sc::ed <<Cut>>}
    $m add command -label "Copiar"             -accelerator Ctrl+C       -command {event generate [focus] <<Copy>>}
    $m add command -label "Colar"              -accelerator Ctrl+V       -command {sc::paste $::sc::ed}
    $m add command -label "Selecionar tudo"    -accelerator Ctrl+A       -command {sc::selectAll $::sc::ed}
    $m add separator
    $m add command -label "Duplicar linha"     -accelerator Ctrl+D       -command sc::duplicateLine
    $m add command -label "Comentar/descomentar" -accelerator Ctrl+/     -command sc::toggleComment
    $m add separator
    $m add command -label "Localizar…"         -accelerator Ctrl+F       -command {sc::showFind 0}
    $m add command -label "Substituir…"        -accelerator Ctrl+H       -command {sc::showFind 1}
    $m add command -label "Localizar próximo"  -accelerator F3           -command {sc::findNext 1}
    $m add command -label "Localizar anterior" -accelerator Shift+F3     -command {sc::findNext 0}
    $m add command -label "Ir para linha…"     -accelerator Ctrl+L       -command sc::gotoDialog

    set m [menu .mb.script -tearoff 0]
    .mb add cascade -label Script -menu $m
    $m add command -label "Executar"           -accelerator Ctrl+R       -command {sc::run 0}
    $m add command -label "Executar seleção"   -accelerator Ctrl+Shift+R -command {sc::run 1}
    $m add command -label "Interromper"        -accelerator Ctrl+Break   -command sc::stop -state disabled
    $m add separator
    $m add command -label "Limpar saída"       -accelerator Ctrl+W       -command sc::clearConsole
    $m add checkbutton -label "Limpar saída antes de executar" -variable ::sc::cfg(autoclear)
    $m add separator
    $m add command -label "Opções de execução…" -accelerator Ctrl+E      -command sc::optionsDialog

    set m [menu .mb.view -tearoff 0]
    .mb add cascade -label Exibir -menu $m
    $m add command -label "Aumentar fonte"     -accelerator Ctrl++       -command {sc::zoom 1}
    $m add command -label "Diminuir fonte"     -accelerator Ctrl+-       -command {sc::zoom -1}
    $m add command -label "Fonte padrão"       -accelerator Ctrl+0       -command {sc::zoom 0}
    $m add separator
    $m add checkbutton -label "Quebra de linha" -variable ::sc::cfg(wrap) -command sc::applyWrap

    set m [menu .mb.help -tearoff 0]
    .mb add cascade -label Ajuda -menu $m
    $m add command -label "Atalhos"  -command sc::showShortcuts
    $m add command -label "Sobre"    -command sc::about

    # menus de contexto
    set m [menu .edpop -tearoff 0]
    $m add command -label "Recortar"         -command {event generate $::sc::ed <<Cut>>}
    $m add command -label "Copiar"           -command {event generate $::sc::ed <<Copy>>}
    $m add command -label "Colar"            -command {sc::paste $::sc::ed}
    $m add separator
    $m add command -label "Selecionar tudo"  -command {sc::selectAll $::sc::ed}
    $m add command -label "Executar seleção" -command {sc::run 1}

    set m [menu .conpop -tearoff 0]
    $m add command -label "Copiar"           -command {event generate $::sc::con <<Copy>>}
    $m add command -label "Selecionar tudo"  -command {$::sc::con tag add sel 1.0 end}
    $m add separator
    $m add command -label "Limpar saída"     -command sc::clearConsole
}

proc sc::buildFindBar {w} {
    ttk::frame $w -padding {4 3}
    ttk::label $w.l1 -text "Localizar:"
    ttk::entry $w.pat -textvariable ::sc::find(pat) -width 28
    ttk::button $w.prev -text "▲" -width 3 -command {sc::findNext 0} -takefocus 0
    ttk::button $w.next -text "▼" -width 3 -command {sc::findNext 1} -takefocus 0
    ttk::checkbutton $w.case -text "Aa" -variable ::sc::find(case) -command sc::markAll -takefocus 0
    ttk::checkbutton $w.re   -text ".*" -variable ::sc::find(regex) -command sc::markAll -takefocus 0
    ttk::label $w.l2 -text "Substituir:"
    ttk::entry $w.rep -textvariable ::sc::find(rep) -width 22
    ttk::button $w.r1 -text "Substituir" -command sc::replaceOne -takefocus 0
    ttk::button $w.ra -text "Todos" -command sc::replaceAll -takefocus 0
    ttk::button $w.x -text "✕" -width 3 -style Tool.TButton -command sc::hideFind -takefocus 0
    ttk::label $w.info -textvariable ::sc::find(info) -foreground #8a8a8a
    pack $w.l1 $w.pat $w.prev $w.next $w.case $w.re -side left -padx 2
    pack $w.l2 -side left -padx {12 2}
    pack $w.rep $w.r1 $w.ra -side left -padx 2
    pack $w.info -side left -padx 8
    pack $w.x -side right

    trace add variable ::sc::find(pat) write {apply {args {after idle sc::markAll}}}
    foreach e [list $w.pat $w.rep] {
        bind $e <Return>       {sc::findNext 1; break}
        bind $e <Shift-Return> {sc::findNext 0; break}
        bind $e <Escape>       {sc::hideFind; break}
    }
}

proc sc::setupTags {} {
    variable ed
    variable con
    variable C
    foreach t {keyword defname type string comment number interp annot brace directive} {
        $ed tag configure $t -foreground $C($t)
    }
    $ed tag configure keyword   -font ScMonoB
    $ed tag configure defname   -font ScMonoB
    $ed tag configure comment   -font ScMonoI
    $ed tag configure directive -font ScMonoI
    $ed tag configure curline   -background $C(curline)
    $ed tag configure errline   -background $C(errline)
    $ed tag configure found     -background $C(found)
    $ed tag configure bmatch    -background $C(bmatch) -font ScMonoB
    $ed tag configure bbad      -background $C(bbad)
    $ed tag lower curline
    $ed tag raise interp
    $ed tag raise errline
    $ed tag raise found
    $ed tag raise bmatch
    $ed tag raise bbad
    $ed tag raise sel

    $con tag configure stdout -foreground $C(confg)
    $con tag configure stderr -foreground $C(stderr)
    $con tag configure warn   -foreground $C(warn)
    $con tag configure info   -foreground $C(info) -font ScMonoI
    $con tag configure link   -underline 1
    $con tag bind link <Enter> [list $con configure -cursor hand2]
    $con tag bind link <Leave> [list $con configure -cursor xterm]
    # cores ANSI na saída do programa (ex.: pprint)
    foreach {n c} {
        30 #7f7f7f 31 #ff6b68 32 #8fbf6a 33 #d7ba7d 34 #6897bb 35 #b294bb 36 #5fb3b3 37 #d0d0d0
        90 #9a9a9a 91 #ff8b88 92 #a8d88a 93 #f0d58d 94 #8ab4e0 95 #cfa8d8 96 #7fd3d3 97 #ffffff
    } {
        $con tag configure ansi$n -foreground $c
    }
    $con tag configure ansiB -font ScMonoB
    $con tag raise sel
}

proc sc::updateTabs {} {
    $::sc::ed configure -tabs [expr {$::sc::cfg(indent) * [font measure ScMono 0]}]
}

# Atalhos globais: a tag ScKeys fica antes da classe dos widgets para que
# atalhos como Ctrl+O/Ctrl+F não executem as ações "emacs" do Text/Entry.
proc sc::setupBindings {} {
    variable ed
    variable con
    set keys {
        <Control-n>         sc::newFile
        <Control-o>         sc::openFile
        <Control-s>         sc::save
        <Control-S>         sc::saveAs
        <Control-F4>        sc::closeFile
        <Control-q>         sc::quit
        <Control-r>         {sc::run 0}
        <Control-Return>    {sc::run 0}
        <Control-R>         {sc::run 1}
        <Control-Break>     sc::stop
        <Control-Pause>     sc::stop
        <Control-w>         sc::clearConsole
        <Control-e>         sc::optionsDialog
        <Control-f>         {sc::showFind 0}
        <Control-h>         {sc::showFind 1}
        <F3>                {sc::findNext 1}
        <Shift-F3>          {sc::findNext 0}
        <Control-l>         sc::gotoDialog
        <Control-plus>      {sc::zoom 1}
        <Control-equal>     {sc::zoom 1}
        <Control-KP_Add>    {sc::zoom 1}
        <Control-minus>     {sc::zoom -1}
        <Control-KP_Subtract> {sc::zoom -1}
        <Control-0>         {sc::zoom 0}
        <Control-a>         {sc::selectAll %W}
    }
    foreach {seq cmd} $keys {
        catch {bind ScKeys $seq "$cmd; break"}
        catch {bind . $seq $cmd}
    }
    event add <<Redo>> <Control-y>

    # teclas específicas do editor
    bind ScEdit <Tab>           {sc::indent 1; break}
    bind ScEdit <Shift-Tab>     {sc::indent 0; break}
    catch {bind ScEdit <ISO_Left_Tab> {sc::indent 0; break}}
    bind ScEdit <Return>        {sc::newline; break}
    bind ScEdit <KP_Enter>      {sc::newline; break}
    bind ScEdit <braceright>    {sc::closeChar "\}"; break}
    bind ScEdit <parenright>    {sc::closeChar ")"; break}
    bind ScEdit <bracketright>  {sc::closeChar "\]"; break}
    bind ScEdit <Control-d>     {sc::duplicateLine; break}
    bind ScEdit <Control-slash> {sc::toggleComment; break}
    bind ScEdit <<Paste>>       {sc::paste %W; break}
    bind ScEdit <Control-MouseWheel> {sc::zoom [expr {%D > 0 ? 1 : -1}]; break}
    bind ScEdit <Button-3>      {focus %W; tk_popup .edpop %X %Y; break}
    bind ScEdit <<Undo>>        {sc::editCmd undo; break}
    bind ScEdit <<Redo>>        {sc::editCmd redo; break}

    bindtags $ed [list $ed ScKeys ScEdit Text . all]
    bindtags $con [list $con ScKeys Text . all]
    foreach e {.pw.ed.find.pat .pw.ed.find.rep} {
        bindtags $e [list $e ScKeys TEntry . all]
    }
    bind $con <Button-3> {tk_popup .conpop %X %Y}
    bind $con <1> {focus %W}

    set gut $::sc::gut
    bind $gut <MouseWheel> {sc::wheel %D}
    catch {bind $gut <Button-4> {$::sc::ed yview scroll -3 units}}
    catch {bind $gut <Button-5> {$::sc::ed yview scroll 3 units}}
    bind $gut <1> {sc::gutterClick %y}
}

proc sc::wheel {d} {
    $::sc::ed yview scroll [expr {$d > 0 ? -3 : 3}] units
}

# Proxy do widget de texto: detecta qualquer alteração do conteúdo e do cursor.
proc sc::installProxy {w} {
    rename $w ::sc::_edw
    interp alias {} $w {} ::sc::edProxy
}

proc sc::edProxy {args} {
    if {[catch {::sc::_edw {*}$args} r o]} {
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
# Destaque de sintaxe
# ---------------------------------------------------------------------------

proc sc::initKeywords {} {
    variable kw
    foreach w {
        abstract case catch class def do else enum export extends false final
        finally for given if implicit import lazy match new null object
        override package private protected return sealed super then this throw
        trait true try type val var while with yield
    } {
        dict set kw $w hard
    }
    # palavras-chave "soft" do Scala 3
    foreach w {as derives end extension infix inline opaque open transparent using} {
        dict set kw $w soft
    }
}

# Palavras após as quais o próximo identificador é um nome sendo definido.
set sc::defKw {def val var class object trait enum type given}

# grupos: 1 diretiva, 2 comentário, 3 string, 4 char, 5 número, 6 anotação,
#         7 identificador, 8 chaves/parênteses
set sc::hlRe [join {
    {(//>[^\n]*)}
    {(//(?!>)[^\n]*|/\*(?:[^*]|\*(?!/))*(?:\*/)?)}
    {((?:[[:alpha:]_][[:alnum:]_]*)?(?:"""(?:[^"]|"(?!""))*(?:"""+)?|"(?:[^"\\\n]|\\.)*"?))}
    {('(?:\\u[0-9a-fA-F]{4}|\\.|[^'\\\n])')}
    {(\m(?:0[xX][0-9a-fA-F_]+[lL]?|[0-9][0-9_]*(?:\.[0-9][0-9_]*)?(?:[eE][-+]?[0-9]+)?[lLfFdD]?)\M)}
    {(@[[:alpha:]_][[:alnum:]_]*)}
    {([[:alpha:]_][[:alnum:]_]*)}
    {([][{}()])}
} |]

proc sc::schedHighlight {} {
    variable hlAfter
    after cancel $hlAfter
    set hlAfter [after 120 sc::highlight]
}

proc sc::highlight {} {
    variable ed
    variable kw
    variable hlRe
    variable defKw
    set txt [$ed get 1.0 end-1c]
    set starts {}
    set o 0
    foreach ln [split $txt \n] {
        lappend starts $o
        incr o [expr {[string length $ln] + 1}]
    }
    set tags {directive comment string number annot keyword defname type interp brace}
    foreach t $tags { set rng($t) {} }
    set defNext 0
    foreach {all d c s ch n an w b} [regexp -all -inline -indices -- $hlRe $txt] {
        if {[lindex $d 0] >= 0} {
            lassign $d a z; set tag directive
        } elseif {[lindex $c 0] >= 0} {
            lassign $c a z; set tag comment
        } elseif {[lindex $s 0] >= 0} {
            lassign $s a z; set tag string
            # interpolações em s"..", f"..", etc.
            set str [string range $txt $a $z]
            if {[string index $str 0] ne "\""} {
                foreach r [regexp -all -inline -indices -- \
                        {\$\{[^\}\n]*\}?|\$[[:alpha:]_][[:alnum:]_]*} $str] {
                    lassign $r ia iz
                    lappend rng(interp) [off2idx $starts [expr {$a + $ia}]] \
                                        [off2idx $starts [expr {$a + $iz + 1}]]
                }
            }
        } elseif {[lindex $ch 0] >= 0} {
            lassign $ch a z; set tag string
        } elseif {[lindex $n 0] >= 0} {
            lassign $n a z; set tag number
        } elseif {[lindex $an 0] >= 0} {
            lassign $an a z; set tag annot
        } elseif {[lindex $w 0] >= 0} {
            lassign $w a z
            set word [string range $txt $a $z]
            if {[dict exists $kw $word]} {
                set tag keyword
                set defNext [expr {$word in $defKw}]
            } elseif {$defNext} {
                set tag defname
                set defNext 0
            } elseif {[string is upper [string index $word 0]]} {
                set tag type
            } else {
                set defNext 0
                continue
            }
        } elseif {[lindex $b 0] >= 0} {
            lassign $b a z; set tag brace
            set defNext 0
        } else {
            continue
        }
        if {$tag ni {keyword defname brace}} { set defNext 0 }
        lappend rng($tag) [off2idx $starts $a] [off2idx $starts [expr {$z + 1}]]
    }
    foreach t $tags {
        ::sc::_edw tag remove $t 1.0 end
        if {[llength $rng($t)]} { ::sc::_edw tag add $t {*}$rng($t) }
    }
    if {[winfo ismapped .pw.ed.find]} { markAll }
}

# offset de caractere -> índice do widget text
proc sc::off2idx {starts off} {
    set L [lsearch -bisect -integer $starts $off]
    return [expr {$L + 1}].[expr {$off - [lindex $starts $L]}]
}

# ---------------------------------------------------------------------------
# Números de linha, cursor, pares de chaves
# ---------------------------------------------------------------------------

proc sc::edYscroll {args} {
    .pw.ed.sy set {*}$args
    schedGutter
}

proc sc::schedGutter {} {
    variable gutPending
    if {!$gutPending} {
        set gutPending 1
        after idle sc::drawGutter
    }
}

proc sc::drawGutter {} {
    variable ed
    variable gut
    variable C
    variable gutPending 0
    $gut delete all
    set last [lindex [split [$ed index end-1c] .] 0]
    set digits [expr {max(3, [string length $last])}]
    set w [expr {[font measure ScMono [string repeat 9 $digits]] + 18}]
    if {[$gut cget -width] != $w} { $gut configure -width $w }
    set cur [lindex [split [$ed index insert] .] 0]
    set i [$ed index "@0,0 linestart"]
    if {[$ed dlineinfo $i] eq ""} { set i [$ed index "$i +1 line"] }
    while {[$ed compare $i < end]} {
        set d [$ed dlineinfo $i]
        if {$d eq ""} break
        set n [lindex [split $i .] 0]
        $gut create text [expr {$w - 10}] [lindex $d 1] -anchor ne -text $n \
            -font ScMono -fill [expr {$n == $cur ? $C(gutcur) : $C(gutfg)}]
        set i [$ed index "$i +1 line"]
    }
}

proc sc::gutterClick {y} {
    variable ed
    set i [$ed index "@0,$y linestart"]
    $ed mark set insert $i
    $ed tag remove sel 1.0 end
    $ed tag add sel $i "$i +1 line"
    focus $ed
}

proc sc::onChange {} {
    ::sc::_edw tag remove errline 1.0 end
    schedHighlight
    schedGutter
    onCursor
}

proc sc::onCursor {} {
    variable curPending
    if {!$curPending} {
        set curPending 1
        after idle sc::updateCursor
    }
}

proc sc::updateCursor {} {
    variable ed
    variable curPending 0
    lassign [split [$ed index insert] .] l c
    set ::sc::lncol "Ln $l, Col [expr {$c + 1}]"
    ::sc::_edw tag remove curline 1.0 end
    ::sc::_edw tag add curline "insert linestart" "insert lineend +1c"
    matchBrackets
    schedGutter
}

# Verdadeiro se a posição está dentro de string/comentário (pelo destaque).
proc sc::inLiteral {idx} {
    foreach t [::sc::_edw tag names $idx] {
        if {$t in {string comment directive}} { return 1 }
    }
    return 0
}

proc sc::matchBrackets {} {
    variable ed
    ::sc::_edw tag remove bmatch 1.0 end
    ::sc::_edw tag remove bbad 1.0 end
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
            set pos [::sc::_edw search -forwards -regexp -- $re "$pos +1c" end]
        } else {
            set pos [::sc::_edw search -backwards -regexp -- $re $pos 1.0]
        }
        if {$pos eq ""} break
        if {[inLiteral $pos]} continue
        if {[$ed get $pos] eq $ch} { incr depth } else { incr depth -1 }
        if {$depth == 0} {
            ::sc::_edw tag add bmatch $i "$i +1c" $pos "$pos +1c"
            return
        }
    }
    ::sc::_edw tag add bbad $i "$i +1c"
}

# ---------------------------------------------------------------------------
# Comandos de edição
# ---------------------------------------------------------------------------

# Executa várias alterações como um único passo de desfazer.
proc sc::atomic {script} {
    set ed $::sc::ed
    $ed edit separator
    $ed configure -autoseparators 0
    try {
        uplevel 1 $script
    } finally {
        $ed configure -autoseparators 1
        $ed edit separator
    }
}

proc sc::editCmd {what} {
    catch {$::sc::ed edit $what}
    $::sc::ed see insert
}

proc sc::selectAll {w} {
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

proc sc::paste {w} {
    if {[catch {clipboard get} data]} return
    atomic {
        catch {$w delete sel.first sel.last}
        $w insert insert $data
    }
    $w see insert
}

proc sc::selLines {} {
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

proc sc::indentStr {} {
    return [string repeat " " $::sc::cfg(indent)]
}

proc sc::indent {in} {
    variable ed
    variable cfg
    set hasSel [llength [$ed tag ranges sel]]
    lassign [selLines] a z
    set ind [indentStr]
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
                set lead [$ed get $l.0 $l.$cfg(indent)]
                regexp "^( {1,$cfg(indent)}|\t)?" $lead -> ws
                if {$ws ne ""} { $ed delete $l.0 "$l.0 +[string length $ws]c" }
            }
        }
    }
    if {$hasSel} {
        $ed tag remove sel 1.0 end
        $ed tag add sel $a.0 "$z.0 lineend +1c"
    }
}

# Enter com auto-indentação: indenta mais um nível após "{", "(", "[", "=",
# "=>", ":" e palavras que abrem bloco na sintaxe de indentação do Scala 3.
proc sc::newline {} {
    variable ed
    catch {$ed delete sel.first sel.last}
    set before [$ed get "insert linestart" insert]
    regexp {^[ \t]*} $before ws
    set code [regsub {\s*//.*$} $before ""]
    set extra ""
    if {[regexp {(?:[\{\[\(]|=>?|:|<-|->|\m(?:then|else|do|yield|try|catch|finally|match|with))\s*$} $code]} {
        set extra [indentStr]
    }
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

proc sc::closeChar {ch} {
    variable ed
    variable cfg
    catch {$ed delete sel.first sel.last}
    set before [$ed get "insert linestart" insert]
    # linha só com espaços: desindenta um nível antes de fechar o bloco
    if {[regexp {^[ \t]+$} $before]} {
        if {[string index $before end] eq "\t"} {
            set n 1
        } else {
            set n [expr {[string length $before] % $cfg(indent)}]
            if {$n == 0} { set n $cfg(indent) }
        }
        $ed delete "insert -${n}c" insert
    }
    $ed insert insert $ch
    $ed see insert
}

proc sc::duplicateLine {} {
    variable ed
    lassign [selLines] a z
    set chunk [$ed get $a.0 "$z.0 lineend"]
    $ed insert "$z.0 lineend" "\n$chunk"
    $ed mark set insert "insert +[expr {$z - $a + 1}] lines"
    $ed see insert
}

proc sc::toggleComment {} {
    variable ed
    lassign [selLines] a z
    set all 1
    for {set l $a} {$l <= $z} {incr l} {
        set line [$ed get $l.0 "$l.0 lineend"]
        if {[string trim $line] ne "" && ![regexp {^\s*//} $line]} { set all 0; break }
    }
    atomic {
        for {set l $a} {$l <= $z} {incr l} {
            set line [$ed get $l.0 "$l.0 lineend"]
            if {$all} {
                if {[regexp -indices {^\s*(// ?)} $line -> r]} {
                    $ed delete $l.[lindex $r 0] $l.[expr {[lindex $r 1] + 1}]
                }
            } elseif {[string trim $line] ne ""} {
                regexp {^\s*} $line ws
                $ed insert $l.[string length $ws] "// "
            }
        }
    }
    if {$a == $z && ![llength [$ed tag ranges sel]]} {
        $ed mark set insert "insert +1 line"
    }
}

proc sc::zoom {d} {
    variable cfg
    if {$d == 0} {
        set cfg(fontsize) 12
    } else {
        set cfg(fontsize) [expr {max(6, min(48, $cfg(fontsize) + $d))}]
    }
    foreach f {ScMono ScMonoB ScMonoI} { font configure $f -size $cfg(fontsize) }
    updateTabs
    schedGutter
    set ::sc::status "Fonte: $cfg(fontsize) pt"
}

proc sc::applyWrap {} {
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

proc sc::showFind {replace} {
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

proc sc::hideFind {} {
    grid remove .pw.ed.find
    $::sc::ed tag remove found 1.0 end
    focus $::sc::ed
}

proc sc::searchOpts {} {
    variable find
    set o {}
    if {!$find(case)}  { lappend o -nocase }
    if {$find(regex)}  { lappend o -regexp }
    return $o
}

proc sc::markAll {} {
    variable ed
    variable find
    ::sc::_edw tag remove found 1.0 end
    .pw.ed.find.pat configure -style TEntry
    set find(info) ""
    if {$find(pat) eq "" || ![winfo ismapped .pw.ed.find]} return
    set cnt {}
    if {[catch {::sc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} {
        set find(info) "regex inválida"
        .pw.ed.find.pat configure -style NotFound.TEntry
        return
    }
    set r {}
    foreach h $hits n $cnt {
        if {$n > 0} { lappend r $h "$h +${n}c" }
    }
    if {[llength $r]} { ::sc::_edw tag add found {*}$r }
    set find(info) "[llength $hits] ocorrência(s)"
    if {![llength $hits]} { .pw.ed.find.pat configure -style NotFound.TEntry }
}

proc sc::findNext {fwd} {
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
    if {[catch {::sc::_edw search $dir {*}[searchOpts] -count n -- $find(pat) $start} idx]} return
    if {$idx eq ""} {
        set ::sc::status "Não encontrado: $find(pat)"
        return
    }
    $ed tag remove sel 1.0 end
    $ed tag add sel $idx "$idx +${n}c"
    $ed mark set insert [expr {$fwd ? "$idx +${n}c" : $idx}]
    $ed see $idx
    set ::sc::status ""
}

proc sc::replaceText {matched} {
    variable find
    if {!$find(regex)} { return $find(rep) }
    set o {}
    if {!$find(case)} { lappend o -nocase }
    regsub {*}$o -- $find(pat) $matched $find(rep) out
    return $out
}

proc sc::replaceOne {} {
    variable ed
    variable find
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        set o [searchOpts]
        if {[catch {::sc::_edw search {*}$o -count n -- $find(pat) sel.first sel.last} idx] == 0
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

proc sc::replaceAll {} {
    variable ed
    variable find
    if {$find(pat) eq ""} return
    set cnt {}
    if {[catch {::sc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} return
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
    set ::sc::status "$k substituição(ões)"
    markAll
}

proc sc::gotoDialog {} {
    set w .goto
    if {[winfo exists $w]} { raise $w; focus $w.e; return }
    toplevel $w -background $::sc::C(ui)
    wm title $w "Ir para linha"
    wm transient $w .
    wm resizable $w 0 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text "Linha:"
    ttk::entry $w.e -width 10 -textvariable ::sc::gotoLine
    ttk::button $w.f.ok -text OK -command sc::gotoApply
    pack $w.f -fill both
    pack $w.f.l -in $w.f -side left
    pack $w.e -in $w.f -side left -padx 6
    pack $w.f.ok -side left
    bind $w <Return> sc::gotoApply
    bind $w <Escape> [list destroy $w]
    set ::sc::gotoLine [lindex [split [$::sc::ed index insert] .] 0]
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    focus $w.e
    $w.e selection range 0 end
}

proc sc::gotoApply {} {
    if {[string is integer -strict $::sc::gotoLine]} {
        gotoLine $::sc::gotoLine
    }
    destroy .goto
}

proc sc::gotoLine {n {col 0}} {
    variable ed
    $ed mark set insert $n.$col
    $ed tag remove sel 1.0 end
    $ed see insert
    focus $ed
}

# ---------------------------------------------------------------------------
# Opções de execução
# ---------------------------------------------------------------------------

proc sc::optionsDialog {} {
    variable cfg
    set w .opts
    if {[winfo exists $w]} { raise $w; focus $w.f.o; return }
    set ::sc::optTmp(scalaopts) $cfg(scalaopts)
    set ::sc::optTmp(args)      $cfg(args)
    toplevel $w -background $::sc::C(ui)
    wm title $w "Opções de execução"
    wm transient $w .
    wm resizable $w 1 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.lo -text "Opções do scala:"
    ttk::entry $w.f.o -width 60 -textvariable ::sc::optTmp(scalaopts)
    ttk::label $w.f.ho -foreground #8a8a8a \
        -text "ex.: -S 3.3.4   --dep com.lihaoyi::os-lib:0.11.4   -J -Xmx2g   -q"
    ttk::label $w.f.la -text "Argumentos do programa:"
    ttk::entry $w.f.a -width 60 -textvariable ::sc::optTmp(args)
    ttk::frame $w.f.b
    ttk::button $w.f.b.ok -text OK -command sc::optionsApply
    ttk::button $w.f.b.cancel -text Cancelar -command [list destroy $w]
    pack $w.f.b.cancel $w.f.b.ok -side right -padx {6 0}
    grid $w.f.lo $w.f.o -sticky w -pady 3
    grid x $w.f.ho -sticky w
    grid $w.f.la $w.f.a -sticky w -pady {10 3}
    grid $w.f.b - -sticky e -pady {10 0}
    grid configure $w.f.o $w.f.a -sticky ew
    grid columnconfigure $w.f 1 -weight 1
    pack $w.f -fill both -expand 1
    bind $w <Return> sc::optionsApply
    bind $w <Escape> [list destroy $w]
    wm geometry $w +[expr {[winfo rootx .] + 120}]+[expr {[winfo rooty .] + 100}]
    focus $w.f.o
}

proc sc::optionsApply {} {
    variable cfg
    set cfg(scalaopts) [string trim $::sc::optTmp(scalaopts)]
    set cfg(args)      [string trim $::sc::optTmp(args)]
    destroy .opts
    saveCfg
    set ::sc::status "Opções de execução atualizadas"
}

# ---------------------------------------------------------------------------
# Arquivos
# ---------------------------------------------------------------------------

proc sc::updateTitle {} {
    variable file
    set name [expr {$file eq "" ? "Sem título" : [file tail $file]}]
    set mod [expr {[$::sc::ed edit modified] ? " •" : ""}]
    set dir [expr {$file eq "" ? "" : "  —  [file dirname $file]"}]
    wm title . "$name$mod$dir  —  sconsole"
}

proc sc::confirmDiscard {} {
    if {![$::sc::ed edit modified]} { return 1 }
    set r [tk_messageBox -parent . -icon warning -type yesnocancel \
        -title sconsole -message "Salvar as alterações?" \
        -detail "O arquivo foi modificado."]
    switch -- $r {
        yes     { return [save] }
        no      { return 1 }
        default { return 0 }
    }
}

proc sc::setContent {data} {
    variable ed
    $ed delete 1.0 end
    $ed insert 1.0 $data
    $ed edit reset
    $ed edit modified 0
    $ed mark set insert 1.0
    $ed see 1.0
    ::sc::_edw tag remove errline 1.0 end
    highlight
    updateTitle
}

# Modelos de projeto configurados por diretivas do scala-cli. @SCALA@ é
# trocado pela versão padrão do Scala detectada.
# Referência: https://scala-cli.virtuslab.org/docs/reference/directives
set sc::templates(jvm) {// Modelo JVM -- configuração por diretivas "//> using" do scala-cli.
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/reference/directives

// versão do Scala e do Java (a JVM é baixada automaticamente se necessário)
//> using scala @SCALA@
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

set sc::templates(js) {// Modelo Scala.js -- configuração por diretivas "//> using" do scala-cli.
// Executa no Node.js (precisa do "node" no PATH).
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/guides/advanced/scala-js

//> using scala @SCALA@
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

set sc::templates(native) {// Modelo Scala Native -- configuração por diretivas "//> using" do scala-cli.
// Gera um executável nativo (precisa do clang/LLVM). A 1ª compilação é lenta.
// Diretivas desativadas estão comentadas com "// //>"; remova o "// " para usar.
// Referência: https://scala-cli.virtuslab.org/docs/guides/advanced/scala-native

//> using scala @SCALA@
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

proc sc::newFromTemplate {kind} {
    variable templates
    if {![confirmDiscard]} return
    set ver [expr {[info exists ::sc::scalaVer] ? $::sc::scalaVer : "3.9.0"}]
    variable file ""
    setContent [string map [list @SCALA@ $ver] $templates($kind)]
    set name [dict get {jvm JVM js Scala.js native "Scala Native"} $kind]
    set ::sc::status "Modelo $name · Ctrl+R executa (a 1ª execução baixa as dependências)"
}

proc sc::newFile {{force 0}} {
    if {!$force && ![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::sc::status "Novo arquivo"
}

proc sc::closeFile {} {
    if {![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::sc::status "Arquivo fechado"
}

proc sc::fileTypes {} {
    return {{"Scala" {.sc .scala}} {"Script Scala" .sc} {"Fonte Scala" .scala}
            {"Todos os arquivos" *}}
}

proc sc::openFile {{path ""}} {
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
        tk_messageBox -parent . -icon error -title sconsole \
            -message "Não foi possível abrir o arquivo." -detail $data
        return
    }
    if {[string index $data end] eq "\n"} { set data [string range $data 0 end-1] }
    variable file [file normalize $path]
    set cfg(lastdir) [file dirname $file]
    setContent $data
    addRecent $file
    set ::sc::status "Aberto: $file"
}

proc sc::save {} {
    variable file
    if {$file eq ""} { return [saveAs] }
    return [saveTo $file]
}

proc sc::saveAs {} {
    variable cfg
    variable file
    set ext [expr {[guessKind [$::sc::ed get 1.0 end-1c]] eq "scala" ? ".scala" : ".sc"}]
    set opts [list -parent . -title "Salvar como" -filetypes [fileTypes] -defaultextension $ext]
    if {$file ne ""} {
        lappend opts -initialdir [file dirname $file] -initialfile [file tail $file]
    } elseif {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
        lappend opts -initialdir $cfg(lastdir)
    }
    set path [tk_getSaveFile {*}$opts]
    if {$path eq ""} { return 0 }
    return [saveTo [file normalize $path]]
}

proc sc::saveTo {path} {
    variable ed
    variable cfg
    set data [$ed get 1.0 end-1c]
    if {$data ne "" && [string index $data end] ne "\n"} { append data \n }
    if {[catch {writeFile $path $data} err]} {
        tk_messageBox -parent . -icon error -title sconsole \
            -message "Não foi possível salvar o arquivo." -detail $err
        return 0
    }
    variable file $path
    set cfg(lastdir) [file dirname $path]
    $ed edit modified 0
    addRecent $path
    updateTitle
    set ::sc::status "Salvo: $path"
    return 1
}

proc sc::addRecent {path} {
    variable cfg
    set l [lsearch -all -inline -not -exact $cfg(recent) $path]
    set cfg(recent) [lrange [linsert $l 0 $path] 0 9]
    updateRecentMenu
}

proc sc::updateRecentMenu {} {
    variable cfg
    set m .mb.file.recent
    $m delete 0 end
    foreach p $cfg(recent) {
        $m add command -label $p -command [list sc::openFile $p]
    }
    if {![llength $cfg(recent)]} {
        $m add command -label "(vazio)" -state disabled
    } else {
        $m add separator
        $m add command -label "Limpar lista" -command {set ::sc::cfg(recent) {}; sc::updateRecentMenu}
    }
}

proc sc::quit {} {
    if {![confirmDiscard]} return
    stop
    saveCfg
    catch {file delete -force [tmpDir]}
    exit
}

# ---------------------------------------------------------------------------
# Console e execução
# ---------------------------------------------------------------------------

proc sc::conAppend {text tag} {
    variable con
    $con configure -state normal
    $con insert end $text $tag
    # limita o tamanho do console
    set lines [lindex [split [$con index end] .] 0]
    if {$lines > 50000} { $con delete 1.0 [expr {$lines - 40000}].0 }
    $con configure -state disabled
    $con see end
}

proc sc::clearConsole {} {
    variable con
    $con configure -state normal
    $con delete 1.0 end
    $con configure -state disabled
}

# Versão do Scala (em segundo plano: o launcher pode demorar alguns segundos).
proc sc::detectVersion {} {
    set s [findScala]
    if {$s eq ""} {
        set ::sc::interp "scala não encontrado"
        return
    }
    set ::sc::interp "[file tail [lindex $s end]] …"
    if {[catch {open |[list {*}$s --version << "" 2>@1] r} f]} {
        set ::sc::interp "[file tail [lindex $s end]] (erro)"
        return
    }
    fconfigure $f -blocking 0
    set ::sc::verBuf ""
    fileevent $f readable [list sc::onVersion $f]
}

proc sc::onVersion {f} {
    append ::sc::verBuf [read $f]
    if {![eof $f]} return
    catch {close $f}
    set out [regsub -all {\x1b\[[0-9;]*[A-Za-z]} $::sc::verBuf ""]
    set tail [file tail [lindex [findScala] end]]
    if {[regexp {Scala version[^:]*:\s*(\S+)} $out -> v]} {
        set s "Scala $v"
        if {[regexp {runner version:\s*(\S+)} $out -> r]} { append s " · runner $r" }
        set ::sc::interp $s
        set ::sc::scalaVer $v
    } elseif {[regexp {version:?\s*(\S+)} $out -> v]} {
        set ::sc::interp "$tail $v"
    } else {
        set ::sc::interp $tail
    }
}

# "scala" (fonte com @main/main/App) ou "sc" (script).
proc sc::guessKind {code} {
    if {[regexp {(?n)^\s*@main\M|\mdef\s+main\s*[\[(]|\mextends\s+App\M} $code]} {
        return scala
    }
    return sc
}

proc sc::setRunning {on} {
    set s [expr {$on ? "disabled" : "!disabled"}]
    set ns [expr {$on ? "!disabled" : "disabled"}]
    .tb.run state $s
    .tb.stop state $ns
    .mb.script entryconfigure 0 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 1 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 2 -state [expr {$on ? "normal" : "disabled"}]
}

proc sc::run {selOnly} {
    variable ed
    variable R
    variable cfg
    variable file
    if {[info exists R(fd)]} {
        set ::sc::status "Já existe uma execução em andamento (Ctrl+Break para interromper)"
        return
    }
    set lineoff 0
    if {$selOnly} {
        if {![llength [$ed tag ranges sel]]} {
            set ::sc::status "Nenhum texto selecionado"
            return
        }
        set code [$ed get sel.first sel.last]
        set lineoff [expr {[lindex [split [$ed index sel.first] .] 0] - 1}]
    } else {
        set code [$ed get 1.0 end-1c]
    }
    set scala [findScala]
    if {$scala eq ""} {
        conAppend "scala/scala-cli não encontrado. Defina a variável SCONSOLE_SCALA.\n" stderr
        return
    }
    if {$cfg(autoclear)} { clearConsole }
    ::sc::_edw tag remove errline 1.0 end

    # tipo de fonte: pela extensão do arquivo ou pelo conteúdo
    set ext [string tolower [file extension $file]]
    if {!$selOnly && $ext in {.sc .scala}} {
        set kind [string range $ext 1 end]
    } else {
        set kind [guessKind $code]
    }
    set disp [expr {$file eq "" ? "Sem título" : [file tail $file]}]
    if {$kind eq "sc"} {
        # o nome do script vira nome de objeto: precisa ser um identificador
        set base [expr {$file eq "" ? "script" : [file rootname [file tail $file]]}]
        set base [regsub -all {[^A-Za-z0-9_]} $base _]
        if {![regexp {^[A-Za-z_]} $base]} { set base "s$base" }
        set name $base.sc
    } else {
        set name [expr {$ext eq ".scala" ? [file tail $file] : "Main.scala"}]
    }
    if {$file eq ""} { set disp $name }

    set dir [tmpDir]
    set script [file join $dir $name]
    if {$code ne "" && [string index $code end] ne "\n"} { append code \n }
    writeFile $script $code
    set wd [expr {$file eq "" ? [pwd] : [file dirname $file]}]

    set cmd [list {*}$scala run {*}[splitArgs $cfg(scalaopts)] $script]
    set pargs [splitArgs $cfg(args)]
    if {[llength $pargs]} { lappend cmd -- {*}$pargs }

    lassign [chan pipe] er ew
    set old [pwd]
    catch {cd $wd}
    set rc [catch {open |[list {*}$cmd 2>@ $ew] r+} fd]
    cd $old
    if {$rc} {
        close $er; close $ew
        conAppend "Erro ao iniciar o scala: $fd\n" stderr
        return
    }
    close $ew
    catch {chan close $fd write}
    foreach c [list $fd $er] {
        fconfigure $c -blocking 0 -buffering none -translation auto
        setEncoding $c
    }
    set nlines [llength [split [string trimright $code \n] \n]]
    array set R [list fd $fd er $er open 2 t0 [clock milliseconds] \
        lineoff $lineoff script $script name $name disp $disp nlines $nlines \
        killed 0 jumped 0 pend "" sgr {} pid [lindex [pid $fd] 0]]
    fileevent $fd readable [list sc::onStdout $fd]
    fileevent $er readable [list sc::onStderr $er]

    set what [expr {$selOnly ? "seleção de $disp (a partir da linha [expr {$lineoff + 1}])" : $disp}]
    set mode [expr {$kind eq "sc" ? "script" : "fonte .scala"}]
    conAppend "▶ $what  ·  $mode  ·  [clock format [clock seconds] -format %H:%M:%S]\n" info
    setRunning 1
    set ::sc::status "Executando…"
}

proc sc::onStdout {fd} {
    set data [read $fd]
    if {$data ne ""} { conAnsi $data stdout }
    if {[eof $fd]} {
        fileevent $fd readable {}
        streamClosed
    }
}

# Texto com sequências ANSI SGR (cores/negrito) -> tags do console.
proc sc::conAnsi {data base} {
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

proc sc::onStderr {er} {
    while {[gets $er line] >= 0} { errLine $line }
    if {[eof $er]} {
        fileevent $er readable {}
        streamClosed
    }
}

# Uma linha do stderr (mensagens do scala-cli/compilador e exceções).
proc sc::errLine {raw} {
    variable R
    # barras de progresso: fica só com o último trecho após \r
    set k [string last \r $raw]
    if {$k >= 0} { set raw [string range $raw $k+1 end] }
    set gray [string match "*\x1b\\\[90m*" $raw]
    set line [regsub -all {\x1b\[[0-9;?]*[A-Za-z]} $raw ""]
    if {[string match {\[warn\]*} $line]} {
        set tag warn
    } elseif {[string match {\[info\]*} $line] || ($gray && ![string match {\[error\]*} $line])} {
        set tag info
    } else {
        set tag stderr
    }
    linkify $line $tag
}

# Troca referências "caminho/arquivo:linha[:coluna]" ao script temporário por
# links clicáveis para a linha correspondente no editor.
proc sc::linkify {line tag} {
    variable R
    variable con
    variable linkSeq
    set nm [regsub -all {[][\\{}()*+?.^$|]} $R(name) {\\&}]
    set re "(?:\[^\\s:(\]*\[/\\\\\])?$nm:(\[0-9\]+)(?::(\[0-9\]+))?"
    set pos 0
    foreach {m l c} [regexp -all -inline -indices -- $re $line] {
        set n [string range $line {*}$l]
        # linhas além do fim são do código gerado pelo scala-cli
        if {$n < 1 || $n > $R(nlines)} continue
        set target [expr {$n + $R(lineoff)}]
        set col [expr {[lindex $c 0] >= 0 ? [string range $line {*}$c] - 1 : 0}]
        conAppend [string range $line $pos [lindex $m 0]-1] $tag
        set txt "$R(disp):$target"
        if {[lindex $c 0] >= 0} { append txt ":[expr {$col + 1}]" }
        set lt link[incr linkSeq]
        conAppend $txt [list $tag link $lt]
        $con tag bind $lt <1> [list sc::gotoLine $target $col]
        set pos [expr {[lindex $m 1] + 1}]
        if {$tag eq "stderr"} {
            ::sc::_edw tag add errline $target.0 "$target.0 lineend +1c"
            if {!$R(jumped)} {
                set R(jumped) 1
                $::sc::ed see $target.0
            }
        }
    }
    conAppend [string range $line $pos end]\n $tag
}

proc sc::streamClosed {} {
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
        set ::sc::status "Interrompido"
    } else {
        set tag [expr {$code eq "0" ? "info" : "stderr"}]
        conAppend "■ Finalizado em [format %.3f $secs] s (código de saída $code)\n" $tag
        set ::sc::status "Finalizado em [format %.3f $secs] s"
    }
    array unset R
    setRunning 0
}

# Processos filhos (o launcher `scala` é um script que dispara a JVM).
proc sc::descendants {pid} {
    set out {}
    if {![catch {exec pgrep -P $pid} kids]} {
        foreach k $kids { lappend out $k {*}[descendants $k] }
    }
    return $out
}

proc sc::stop {} {
    variable R
    if {![info exists R(pid)]} return
    set R(killed) 1
    if {$::tcl_platform(platform) eq "windows"} {
        catch {exec {*}[auto_execok taskkill] /F /T /PID $R(pid)}
        return
    }
    set all [linsert [descendants $R(pid)] 0 $R(pid)]
    catch {exec kill {*}$all}
    # a JVM pode demorar a sair (shutdown hooks): força após 3 s
    after 3000 [list apply {{all t0} {
        if {[info exists ::sc::R(t0)] && $::sc::R(t0) == $t0} {
            catch {exec kill -9 {*}$all}
        }
    }} $all $R(t0)]
}

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

proc sc::showShortcuts {} {
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

proc sc::about {} {
    tk_messageBox -parent . -title "Sobre" -message "sconsole $::sc::version" \
        -detail "Editor simples para testes rápidos em Scala 3.\n\n$::sc::interp\nComando: [join [findScala]]\nTcl [info patchlevel] · Tk [package present Tk]"
}

# ---------------------------------------------------------------------------

proc sc::main {argv} {
    loadCfg
    initKeywords
    setupTheme
    buildUI
    if {[llength $argv]} {
        openFile [lindex $argv 0]
    } else {
        newFile 1
    }
    focus $::sc::ed
    updateCursor
}

if {![info exists ::sc_nomain]} {
    sc::main $argv
}
