#!/usr/bin/env wish
# tconsole.tcl -- editor/console simples para testes rápidos em Tcl/Tk.
#
# Inspirado no groovyConsole: editor em cima, saída da execução embaixo.
# O script é executado em um processo tclsh separado (a interface não trava
# e o script pode ser interrompido). Requer Tcl/Tk 8.6 ou 9.x.
#
# Uso: wish tconsole.tcl ?arquivo.tcl?
#
# Variável de ambiente opcional: TCONSOLE_TCLSH=/caminho/do/tclsh

package require Tk 8.6-

namespace eval tc {
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
        lastdir "" sash 0.65
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
        keyword  #cc7832   tkcmd    #ffc66d   procname #ffc66d
        string   #6a8759   comment  #808080   number   #6897bb
        var      #9876aa   option   #bbb529   brace    #d0a86a
        stderr   #ff6b68   result   #8fbf6a   info     #6f7f8f
    }
}

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------

proc tc::homeDir {} {
    if {![catch {file home} h]} { return $h }
    foreach v {HOME USERPROFILE} {
        if {[info exists ::env($v)]} { return $::env($v) }
    }
    return [pwd]
}

proc tc::tmpDir {} {
    variable tmpdir
    if {[info exists tmpdir] && [file isdirectory $tmpdir]} { return $tmpdir }
    if {![catch {file tempdir} d]} { return [set tmpdir $d] }
    set base /tmp
    foreach v {TMPDIR TEMP TMP} {
        if {[info exists ::env($v)]} { set base $::env($v); break }
    }
    set tmpdir [file join $base tconsole-[pid]-[clock clicks]]
    file mkdir $tmpdir
    return $tmpdir
}

proc tc::setEncoding {chan} {
    fconfigure $chan -encoding utf-8
    catch {fconfigure $chan -profile replace}   ;# Tcl 9
}

proc tc::readFile {path} {
    set f [open $path r]
    setEncoding $f
    set data [read $f]
    close $f
    return $data
}

proc tc::writeFile {path data} {
    set f [open $path w]
    setEncoding $f
    puts -nonewline $f $data
    close $f
}

proc tc::findTclsh {} {
    if {[info exists ::env(TCONSOLE_TCLSH)]} { return [list $::env(TCONSOLE_TCLSH)] }
    set exe [info nameofexecutable]
    if {[string match -nocase tclsh* [file tail $exe]]} { return [list $exe] }
    set dir [file dirname $exe]
    set v [info tclversion]
    foreach n [list tclsh$v tclsh[string map {. ""} $v] tclsh] {
        foreach c [list [file join $dir $n] [file join $dir $n.exe]] {
            if {[file isfile $c] && [file executable $c]} { return [list $c] }
        }
        set p [auto_execok $n]
        if {$p ne ""} { return $p }
    }
    return ""
}

proc tc::pickFont {} {
    set fams [font families]
    foreach f {"JetBrains Mono" "Fira Code" "Source Code Pro" "Cascadia Code"
               "Hack" "DejaVu Sans Mono" "Liberation Mono" "Consolas" "Menlo"
               "Monaco" "Courier New"} {
        if {[lsearch -nocase -exact $fams $f] >= 0} { return $f }
    }
    return [font actual TkFixedFont -family]
}

proc tc::loadCfg {} {
    variable cfg
    set rc [file join [homeDir] .tconsolerc]
    if {[file readable $rc]} {
        catch {
            set d [readFile $rc]
            foreach k [array names cfg] {
                if {[dict exists $d $k]} { set cfg($k) [dict get $d $k] }
            }
        }
    }
    if {![string is integer -strict $cfg(fontsize)]} { set cfg(fontsize) 12 }
}

proc tc::saveCfg {} {
    variable cfg
    catch {
        set cfg(geometry) [wm geometry .]
        set h [winfo height .pw]
        if {$h > 50} { set cfg(sash) [format %.3f [expr {double([.pw sashpos 0]) / $h}]] }
    }
    set out ""
    foreach k [lsort [array names cfg]] { append out [list $k $cfg($k)] \n }
    catch { writeFile [file join [homeDir] .tconsolerc] $out }
}

# ---------------------------------------------------------------------------
# Tema
# ---------------------------------------------------------------------------

proc tc::setupTheme {} {
    variable C
    variable cfg
    set fam [pickFont]
    font create TcMono  -family $fam -size $cfg(fontsize)
    font create TcMonoB -family $fam -size $cfg(fontsize) -weight bold
    font create TcMonoI -family $fam -size $cfg(fontsize) -slant italic

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

proc tc::buildUI {} {
    variable C
    variable cfg
    variable ed
    variable con
    variable gut

    wm title . tconsole
    wm geometry . $cfg(geometry)
    wm minsize . 500 350
    . configure -background $C(ui)

    buildMenus

    # Barra de ferramentas
    ttk::frame .tb -padding {4 3}
    set i 0
    foreach {name label cmd} {
        new   "Novo"         tc::newFile
        open  "Abrir…"       tc::openFile
        save  "Salvar"       tc::save
        -     -              -
        undo  "↶"            {tc::editCmd undo}
        redo  "↷"            {tc::editCmd redo}
        -     -              -
        run   "▶ Executar"   {tc::run 0}
        stop  "■ Parar"      tc::stop
        clear "⌫ Limpar"     tc::clearConsole
        -     -              -
        find  "Localizar"    {tc::showFind 0}
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
        -font TcMono -undo 1 -maxundo 0 -autoseparators 1 \
        -wrap [expr {$cfg(wrap) ? "word" : "none"}] \
        -bd 0 -highlightthickness 0 -padx 6 -pady 4 -tabstyle wordprocessor \
        -yscrollcommand tc::edYscroll -xscrollcommand [list $f.sx set]]
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
        -font TcMono -wrap char -bd 0 -highlightthickness 0 -padx 6 -pady 4 \
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
    ttk::label .sb.msg -textvariable ::tc::status -style Status.TLabel -anchor w
    ttk::label .sb.pos -textvariable ::tc::lncol -style Status.TLabel -width 16
    ttk::label .sb.tcl -textvariable ::tc::interp -style Status.TLabel
    pack .sb.tcl .sb.pos -side right
    pack .sb.msg -side left -fill x -expand 1

    pack .tb -side top -fill x
    pack .sb -side bottom -fill x
    pack .pw -side top -fill both -expand 1

    setupTags
    updateTabs
    installProxy $ed
    setupBindings

    bind $gut <Configure> tc::schedGutter
    bind $ed <Configure> tc::schedGutter
    bind $ed <<Modified>> tc::updateTitle
    wm protocol . WM_DELETE_WINDOW tc::quit

    # posição inicial do divisor
    after idle {
        update idletasks
        set h [winfo height .pw]
        if {$h > 50} { catch {.pw sashpos 0 [expr {int($h * $::tc::cfg(sash))}]} }
    }

    set t [findTclsh]
    set ::tc::interp [expr {$t eq "" ? "tclsh não encontrado" : "[file tail [lindex $t end]] · Tk [package present Tk]"}]
}

proc tc::buildMenus {} {
    variable cfg
    menu .mb -tearoff 0
    . configure -menu .mb

    set m [menu .mb.file -tearoff 0]
    .mb add cascade -label Arquivo -menu $m
    $m add command -label "Novo"               -accelerator Ctrl+N       -command tc::newFile
    $m add command -label "Abrir…"             -accelerator Ctrl+O       -command tc::openFile
    $m add cascade -label "Recentes"           -menu [menu $m.recent -tearoff 0]
    $m add separator
    $m add command -label "Salvar"             -accelerator Ctrl+S       -command tc::save
    $m add command -label "Salvar como…"       -accelerator Ctrl+Shift+S -command tc::saveAs
    $m add command -label "Fechar arquivo"     -accelerator Ctrl+F4      -command tc::closeFile
    $m add separator
    $m add command -label "Sair"               -accelerator Ctrl+Q       -command tc::quit
    updateRecentMenu

    set m [menu .mb.edit -tearoff 0]
    .mb add cascade -label Editar -menu $m
    $m add command -label "Desfazer"           -accelerator Ctrl+Z       -command {tc::editCmd undo}
    $m add command -label "Refazer"            -accelerator Ctrl+Y       -command {tc::editCmd redo}
    $m add separator
    $m add command -label "Recortar"           -accelerator Ctrl+X       -command {event generate $::tc::ed <<Cut>>}
    $m add command -label "Copiar"             -accelerator Ctrl+C       -command {event generate [focus] <<Copy>>}
    $m add command -label "Colar"              -accelerator Ctrl+V       -command {tc::paste $::tc::ed}
    $m add command -label "Selecionar tudo"    -accelerator Ctrl+A       -command {tc::selectAll $::tc::ed}
    $m add separator
    $m add command -label "Duplicar linha"     -accelerator Ctrl+D       -command tc::duplicateLine
    $m add command -label "Comentar/descomentar" -accelerator Ctrl+/     -command tc::toggleComment
    $m add separator
    $m add command -label "Localizar…"         -accelerator Ctrl+F       -command {tc::showFind 0}
    $m add command -label "Substituir…"        -accelerator Ctrl+H       -command {tc::showFind 1}
    $m add command -label "Localizar próximo"  -accelerator F3           -command {tc::findNext 1}
    $m add command -label "Localizar anterior" -accelerator Shift+F3     -command {tc::findNext 0}
    $m add command -label "Ir para linha…"     -accelerator Ctrl+L       -command tc::gotoDialog

    set m [menu .mb.script -tearoff 0]
    .mb add cascade -label Script -menu $m
    $m add command -label "Executar"           -accelerator Ctrl+R       -command {tc::run 0}
    $m add command -label "Executar seleção"   -accelerator Ctrl+Shift+R -command {tc::run 1}
    $m add command -label "Interromper"        -accelerator Ctrl+Break   -command tc::stop -state disabled
    $m add separator
    $m add command -label "Limpar saída"       -accelerator Ctrl+W       -command tc::clearConsole
    $m add checkbutton -label "Limpar saída antes de executar" -variable ::tc::cfg(autoclear)

    set m [menu .mb.view -tearoff 0]
    .mb add cascade -label Exibir -menu $m
    $m add command -label "Aumentar fonte"     -accelerator Ctrl++       -command {tc::zoom 1}
    $m add command -label "Diminuir fonte"     -accelerator Ctrl+-       -command {tc::zoom -1}
    $m add command -label "Fonte padrão"       -accelerator Ctrl+0       -command {tc::zoom 0}
    $m add separator
    $m add checkbutton -label "Quebra de linha" -variable ::tc::cfg(wrap) -command tc::applyWrap

    set m [menu .mb.help -tearoff 0]
    .mb add cascade -label Ajuda -menu $m
    $m add command -label "Atalhos"  -command tc::showShortcuts
    $m add command -label "Sobre"    -command tc::about

    # menus de contexto
    set m [menu .edpop -tearoff 0]
    $m add command -label "Recortar"         -command {event generate $::tc::ed <<Cut>>}
    $m add command -label "Copiar"           -command {event generate $::tc::ed <<Copy>>}
    $m add command -label "Colar"            -command {tc::paste $::tc::ed}
    $m add separator
    $m add command -label "Selecionar tudo"  -command {tc::selectAll $::tc::ed}
    $m add command -label "Executar seleção" -command {tc::run 1}

    set m [menu .conpop -tearoff 0]
    $m add command -label "Copiar"           -command {event generate $::tc::con <<Copy>>}
    $m add command -label "Selecionar tudo"  -command {$::tc::con tag add sel 1.0 end}
    $m add separator
    $m add command -label "Limpar saída"     -command tc::clearConsole
}

proc tc::buildFindBar {w} {
    ttk::frame $w -padding {4 3}
    ttk::label $w.l1 -text "Localizar:"
    ttk::entry $w.pat -textvariable ::tc::find(pat) -width 28
    ttk::button $w.prev -text "▲" -width 3 -command {tc::findNext 0} -takefocus 0
    ttk::button $w.next -text "▼" -width 3 -command {tc::findNext 1} -takefocus 0
    ttk::checkbutton $w.case -text "Aa" -variable ::tc::find(case) -command tc::markAll -takefocus 0
    ttk::checkbutton $w.re   -text ".*" -variable ::tc::find(regex) -command tc::markAll -takefocus 0
    ttk::label $w.l2 -text "Substituir:"
    ttk::entry $w.rep -textvariable ::tc::find(rep) -width 22
    ttk::button $w.r1 -text "Substituir" -command tc::replaceOne -takefocus 0
    ttk::button $w.ra -text "Todos" -command tc::replaceAll -takefocus 0
    ttk::button $w.x -text "✕" -width 3 -style Tool.TButton -command tc::hideFind -takefocus 0
    ttk::label $w.info -textvariable ::tc::find(info) -foreground #8a8a8a
    pack $w.l1 $w.pat $w.prev $w.next $w.case $w.re -side left -padx 2
    pack $w.l2 -side left -padx {12 2}
    pack $w.rep $w.r1 $w.ra -side left -padx 2
    pack $w.info -side left -padx 8
    pack $w.x -side right

    trace add variable ::tc::find(pat) write {apply {args {after idle tc::markAll}}}
    foreach e [list $w.pat $w.rep] {
        bind $e <Return>       {tc::findNext 1; break}
        bind $e <Shift-Return> {tc::findNext 0; break}
        bind $e <Escape>       {tc::hideFind; break}
    }
}

proc tc::setupTags {} {
    variable ed
    variable con
    variable C
    foreach t {keyword tkcmd procname string comment number var option brace} {
        $ed tag configure $t -foreground $C($t)
    }
    $ed tag configure keyword  -font TcMonoB
    $ed tag configure procname -font TcMonoB
    $ed tag configure comment  -font TcMonoI
    $ed tag configure curline  -background $C(curline)
    $ed tag configure errline  -background $C(errline)
    $ed tag configure found    -background $C(found)
    $ed tag configure bmatch   -background $C(bmatch) -font TcMonoB
    $ed tag configure bbad     -background $C(bbad)
    $ed tag lower curline
    $ed tag raise errline
    $ed tag raise found
    $ed tag raise bmatch
    $ed tag raise bbad
    $ed tag raise sel

    $con tag configure stdout -foreground $C(confg)
    $con tag configure stderr -foreground $C(stderr)
    $con tag configure result -foreground $C(result)
    $con tag configure info   -foreground $C(info) -font TcMonoI
    $con tag configure link   -underline 1
    $con tag bind link <Enter> [list $con configure -cursor hand2]
    $con tag bind link <Leave> [list $con configure -cursor xterm]
    $con tag raise sel
}

proc tc::updateTabs {} {
    $::tc::ed configure -tabs [expr {4 * [font measure TcMono 0]}]
}

# Atalhos globais: a tag TcKeys fica antes da classe dos widgets para que
# atalhos como Ctrl+O/Ctrl+F não executem as ações "emacs" do Text/Entry.
proc tc::setupBindings {} {
    variable ed
    variable con
    set keys {
        <Control-n>         tc::newFile
        <Control-o>         tc::openFile
        <Control-s>         tc::save
        <Control-S>         tc::saveAs
        <Control-F4>        tc::closeFile
        <Control-q>         tc::quit
        <Control-r>         {tc::run 0}
        <Control-Return>    {tc::run 0}
        <Control-R>         {tc::run 1}
        <Control-Break>     tc::stop
        <Control-Pause>     tc::stop
        <Control-w>         tc::clearConsole
        <Control-f>         {tc::showFind 0}
        <Control-h>         {tc::showFind 1}
        <F3>                {tc::findNext 1}
        <Shift-F3>          {tc::findNext 0}
        <Control-l>         tc::gotoDialog
        <Control-plus>      {tc::zoom 1}
        <Control-equal>     {tc::zoom 1}
        <Control-KP_Add>    {tc::zoom 1}
        <Control-minus>     {tc::zoom -1}
        <Control-KP_Subtract> {tc::zoom -1}
        <Control-0>         {tc::zoom 0}
        <Control-a>         {tc::selectAll %W}
    }
    foreach {seq cmd} $keys {
        catch {bind TcKeys $seq "$cmd; break"}
        catch {bind . $seq $cmd}
    }
    event add <<Redo>> <Control-y>

    # teclas específicas do editor
    bind TcEdit <Tab>           {tc::indent 1; break}
    bind TcEdit <Shift-Tab>     {tc::indent 0; break}
    catch {bind TcEdit <ISO_Left_Tab> {tc::indent 0; break}}
    bind TcEdit <Return>        {tc::newline; break}
    bind TcEdit <KP_Enter>      {tc::newline; break}
    bind TcEdit <braceright>    {tc::closeBrace; break}
    bind TcEdit <Control-d>     {tc::duplicateLine; break}
    bind TcEdit <Control-slash> {tc::toggleComment; break}
    bind TcEdit <<Paste>>       {tc::paste %W; break}
    bind TcEdit <Control-MouseWheel> {tc::zoom [expr {%D > 0 ? 1 : -1}]; break}
    bind TcEdit <Button-3>      {focus %W; tk_popup .edpop %X %Y; break}
    bind TcEdit <<Undo>>        {tc::editCmd undo; break}
    bind TcEdit <<Redo>>        {tc::editCmd redo; break}

    bindtags $ed [list $ed TcKeys TcEdit Text . all]
    bindtags $con [list $con TcKeys Text . all]
    foreach e {.pw.ed.find.pat .pw.ed.find.rep} {
        bindtags $e [list $e TcKeys TEntry . all]
    }
    bind $con <Button-3> {tk_popup .conpop %X %Y}
    bind $con <1> {focus %W}

    set gut $::tc::gut
    bind $gut <MouseWheel> {tc::wheel %D}
    catch {bind $gut <Button-4> {$::tc::ed yview scroll -3 units}}
    catch {bind $gut <Button-5> {$::tc::ed yview scroll 3 units}}
    bind $gut <1> {tc::gutterClick %y}
}

proc tc::wheel {d} {
    $::tc::ed yview scroll [expr {$d > 0 ? -3 : 3}] units
}

# Proxy do widget de texto: detecta qualquer alteração do conteúdo e do cursor.
proc tc::installProxy {w} {
    rename $w ::tc::_edw
    interp alias {} $w {} ::tc::edProxy
}

proc tc::edProxy {args} {
    if {[catch {::tc::_edw {*}$args} r o]} {
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

proc tc::initKeywords {} {
    variable kw
    set i [interp create]
    foreach c [$i eval {info commands}] { dict set kw $c core }
    interp delete $i
    foreach c {oo::class oo::define oo::objdefine oo::object oo::copy self next
               my method constructor destructor msgcat::mc} {
        dict set kw $c core
    }
    foreach c {else elseif then finally on trap} { dict set kw $c ctrl }
    foreach c {
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
    } {
        dict set kw $c tk
    }
}

# grupos: 1 comentário, 2 string, 3 variável, 4 número, 5 opção, 6 palavra, 7 chaves
set tc::hlRe [join {
    {(?w)(^[ \t]*#[^\n]*|;[ \t]*#[^\n]*)}
    {("(?:[^"\\]|\\.)*"?)}
    {(\$(?:\{[^\}\n]*\}|(?:::)?[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*(?:\([^)\n]*\))?))}
    {(\m(?:0[xX][0-9a-fA-F]+|[0-9]+(?:\.[0-9]+)?(?:[eE][-+]?[0-9]+)?)\M)}
    {([ \t]-[A-Za-z][-A-Za-z0-9_]*)}
    {((?:::)?[A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*)}
    {([\[\]\{\}])}
} |]

proc tc::schedHighlight {} {
    variable hlAfter
    after cancel $hlAfter
    set hlAfter [after 120 tc::highlight]
}

proc tc::highlight {} {
    variable ed
    variable kw
    variable hlRe
    set txt [$ed get 1.0 end-1c]
    set starts {}
    set o 0
    foreach ln [split $txt \n] {
        lappend starts $o
        incr o [expr {[string length $ln] + 1}]
    }
    set nl [llength $starts]
    set tags {comment string var number option keyword tkcmd procname brace}
    foreach t $tags { set rng($t) {} }
    set L 0
    set procNext 0
    foreach {all c s v n op w b} [regexp -all -inline -indices -- $hlRe $txt] {
        if {[lindex $c 0] >= 0} {
            lassign $c a z
            set a [string first # $txt $a]
            set tag comment
        } elseif {[lindex $s 0] >= 0} {
            lassign $s a z; set tag string
        } elseif {[lindex $v 0] >= 0} {
            lassign $v a z; set tag var
        } elseif {[lindex $n 0] >= 0} {
            lassign $n a z; set tag number
        } elseif {[lindex $op 0] >= 0} {
            lassign $op a z; incr a; set tag option
        } elseif {[lindex $w 0] >= 0} {
            lassign $w a z
            set word [string range $txt $a $z]
            if {$procNext} {
                set tag procname
                set procNext 0
            } elseif {[dict exists $kw $word]} {
                set kind [dict get $kw $word]
                if {$kind ne "ctrl"} {
                    # só destaca comandos em posição de comando
                    set p [expr {$a - 1}]
                    while {$p >= 0 && [string index $txt $p] in {" " "\t"}} { incr p -1 }
                    if {$p >= 0 && [string index $txt $p] ni [list \n \; \[ \{]} continue
                }
                set tag [expr {$kind eq "tk" ? "tkcmd" : "keyword"}]
                if {$word eq "proc"} { set procNext 1 }
            } else {
                continue
            }
        } elseif {[lindex $b 0] >= 0} {
            lassign $b a z; set tag brace
        } else {
            continue
        }
        if {$tag ne "procname" && $tag ne "keyword"} { set procNext 0 }
        # offsets -> índices do text (tokens chegam em ordem crescente)
        while {$L + 1 < $nl && [lindex $starts $L+1] <= $a} { incr L }
        set e [expr {$z + 1}]
        set L2 $L
        while {$L2 + 1 < $nl && [lindex $starts $L2+1] <= $e} { incr L2 }
        lappend rng($tag) [expr {$L + 1}].[expr {$a - [lindex $starts $L]}] \
                          [expr {$L2 + 1}].[expr {$e - [lindex $starts $L2]}]
    }
    foreach t $tags {
        ::tc::_edw tag remove $t 1.0 end
        if {[llength $rng($t)]} { ::tc::_edw tag add $t {*}$rng($t) }
    }
    if {[winfo ismapped .pw.ed.find]} { markAll }
}

# ---------------------------------------------------------------------------
# Números de linha, cursor, pares de chaves
# ---------------------------------------------------------------------------

proc tc::edYscroll {args} {
    .pw.ed.sy set {*}$args
    schedGutter
}

proc tc::schedGutter {} {
    variable gutPending
    if {!$gutPending} {
        set gutPending 1
        after idle tc::drawGutter
    }
}

proc tc::drawGutter {} {
    variable ed
    variable gut
    variable C
    variable gutPending 0
    $gut delete all
    set last [lindex [split [$ed index end-1c] .] 0]
    set digits [expr {max(3, [string length $last])}]
    set w [expr {[font measure TcMono [string repeat 9 $digits]] + 18}]
    if {[$gut cget -width] != $w} { $gut configure -width $w }
    set cur [lindex [split [$ed index insert] .] 0]
    set i [$ed index "@0,0 linestart"]
    if {[$ed dlineinfo $i] eq ""} { set i [$ed index "$i +1 line"] }
    while {[$ed compare $i < end]} {
        set d [$ed dlineinfo $i]
        if {$d eq ""} break
        set n [lindex [split $i .] 0]
        $gut create text [expr {$w - 10}] [lindex $d 1] -anchor ne -text $n \
            -font TcMono -fill [expr {$n == $cur ? $C(gutcur) : $C(gutfg)}]
        set i [$ed index "$i +1 line"]
    }
}

proc tc::gutterClick {y} {
    variable ed
    set i [$ed index "@0,$y linestart"]
    $ed mark set insert $i
    $ed tag remove sel 1.0 end
    $ed tag add sel $i "$i +1 line"
    focus $ed
}

proc tc::onChange {} {
    ::tc::_edw tag remove errline 1.0 end
    schedHighlight
    schedGutter
    onCursor
}

proc tc::onCursor {} {
    variable curPending
    if {!$curPending} {
        set curPending 1
        after idle tc::updateCursor
    }
}

proc tc::updateCursor {} {
    variable ed
    variable curPending 0
    lassign [split [$ed index insert] .] l c
    set ::tc::lncol "Ln $l, Col [expr {$c + 1}]"
    ::tc::_edw tag remove curline 1.0 end
    ::tc::_edw tag add curline "insert linestart" "insert lineend +1c"
    matchBrackets
    schedGutter
}

proc tc::matchBrackets {} {
    variable ed
    ::tc::_edw tag remove bmatch 1.0 end
    ::tc::_edw tag remove bbad 1.0 end
    set pairs {\{ \} \[ \] ( )}
    set i ""
    foreach cand {"insert -1c" insert} {
        set ch [$ed get $cand]
        if {$ch in $pairs && [$ed compare $cand < end-1c]} {
            set i [$ed index $cand]
            break
        }
    }
    if {$i eq "" || [$ed get "$i -1c"] eq "\\"} return
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
            set pos [::tc::_edw search -forwards -regexp -- $re "$pos +1c" end]
        } else {
            set pos [::tc::_edw search -backwards -regexp -- $re $pos 1.0]
        }
        if {$pos eq ""} break
        if {[$ed get "$pos -1c"] eq "\\"} continue
        if {[$ed get $pos] eq $ch} { incr depth } else { incr depth -1 }
        if {$depth == 0} {
            ::tc::_edw tag add bmatch $i "$i +1c" $pos "$pos +1c"
            return
        }
    }
    ::tc::_edw tag add bbad $i "$i +1c"
}

# ---------------------------------------------------------------------------
# Comandos de edição
# ---------------------------------------------------------------------------

# Executa várias alterações como um único passo de desfazer.
proc tc::atomic {script} {
    set ed $::tc::ed
    $ed edit separator
    $ed configure -autoseparators 0
    try {
        uplevel 1 $script
    } finally {
        $ed configure -autoseparators 1
        $ed edit separator
    }
}

proc tc::editCmd {what} {
    catch {$::tc::ed edit $what}
    $::tc::ed see insert
}

proc tc::selectAll {w} {
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

proc tc::paste {w} {
    if {[catch {clipboard get} data]} return
    atomic {
        catch {$w delete sel.first sel.last}
        $w insert insert $data
    }
    $w see insert
}

proc tc::selLines {} {
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

proc tc::indent {in} {
    variable ed
    set hasSel [llength [$ed tag ranges sel]]
    lassign [selLines] a z
    if {$in && (!$hasSel || $a == $z && [$ed get sel.first sel.last] ne [$ed get $a.0 "$a.0 lineend"])} {
        catch {$ed delete sel.first sel.last}
        $ed insert insert "    "
        $ed see insert
        return
    }
    atomic {
        for {set l $a} {$l <= $z} {incr l} {
            if {$in} {
                if {[$ed get $l.0 "$l.0 lineend"] ne ""} { $ed insert $l.0 "    " }
            } else {
                set lead [$ed get $l.0 $l.4]
                regexp {^( {1,4}|\t)?} $lead -> ws
                if {$ws ne ""} { $ed delete $l.0 "$l.0 +[string length $ws]c" }
            }
        }
    }
    if {$hasSel} {
        $ed tag remove sel 1.0 end
        $ed tag add sel $a.0 "$z.0 lineend +1c"
    }
}

proc tc::newline {} {
    variable ed
    catch {$ed delete sel.first sel.last}
    set before [$ed get "insert linestart" insert]
    regexp {^[ \t]*} $before ws
    set extra ""
    if {[regexp {[\{\[]\s*$} $before]} { set extra "    " }
    if {$extra ne "" && [$ed get insert] in {\} \]}} {
        $ed insert insert "\n$ws$extra"
        set m [$ed index insert]
        $ed insert insert "\n$ws"
        $ed mark set insert $m
    } else {
        $ed insert insert "\n$ws$extra"
    }
    $ed see insert
}

proc tc::closeBrace {} {
    variable ed
    catch {$ed delete sel.first sel.last}
    set before [$ed get "insert linestart" insert]
    # linha só com espaços: desindenta um nível antes de fechar o bloco
    if {[regexp {^[ \t]+$} $before]} {
        if {[string index $before end] eq "\t"} {
            set n 1
        } else {
            set n [expr {[string length $before] % 4}]
            if {$n == 0} { set n 4 }
        }
        $ed delete "insert -${n}c" insert
    }
    $ed insert insert "\}"
    $ed see insert
}

proc tc::duplicateLine {} {
    variable ed
    lassign [selLines] a z
    set chunk [$ed get $a.0 "$z.0 lineend"]
    $ed insert "$z.0 lineend" "\n$chunk"
    $ed mark set insert "insert +[expr {$z - $a + 1}] lines"
    $ed see insert
}

proc tc::toggleComment {} {
    variable ed
    lassign [selLines] a z
    set all 1
    for {set l $a} {$l <= $z} {incr l} {
        set line [$ed get $l.0 "$l.0 lineend"]
        if {[string trim $line] ne "" && ![regexp {^\s*#} $line]} { set all 0; break }
    }
    atomic {
        for {set l $a} {$l <= $z} {incr l} {
            set line [$ed get $l.0 "$l.0 lineend"]
            if {$all} {
                if {[regexp -indices {^\s*(# ?)} $line -> r]} {
                    $ed delete $l.[lindex $r 0] $l.[expr {[lindex $r 1] + 1}]
                }
            } elseif {[string trim $line] ne ""} {
                regexp {^\s*} $line ws
                $ed insert $l.[string length $ws] "# "
            }
        }
    }
    if {$a == $z && ![llength [$ed tag ranges sel]]} {
        $ed mark set insert "insert +1 line"
    }
}

proc tc::zoom {d} {
    variable cfg
    if {$d == 0} {
        set cfg(fontsize) 12
    } else {
        set cfg(fontsize) [expr {max(6, min(48, $cfg(fontsize) + $d))}]
    }
    foreach f {TcMono TcMonoB TcMonoI} { font configure $f -size $cfg(fontsize) }
    updateTabs
    schedGutter
    set ::tc::status "Fonte: $cfg(fontsize) pt"
}

proc tc::applyWrap {} {
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

proc tc::showFind {replace} {
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

proc tc::hideFind {} {
    grid remove .pw.ed.find
    $::tc::ed tag remove found 1.0 end
    focus $::tc::ed
}

proc tc::searchOpts {} {
    variable find
    set o {}
    if {!$find(case)}  { lappend o -nocase }
    if {$find(regex)}  { lappend o -regexp }
    return $o
}

proc tc::markAll {} {
    variable ed
    variable find
    ::tc::_edw tag remove found 1.0 end
    .pw.ed.find.pat configure -style TEntry
    set find(info) ""
    if {$find(pat) eq "" || ![winfo ismapped .pw.ed.find]} return
    set cnt {}
    if {[catch {::tc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} {
        set find(info) "regex inválida"
        .pw.ed.find.pat configure -style NotFound.TEntry
        return
    }
    set r {}
    foreach h $hits n $cnt {
        if {$n > 0} { lappend r $h "$h +${n}c" }
    }
    if {[llength $r]} { ::tc::_edw tag add found {*}$r }
    set find(info) "[llength $hits] ocorrência(s)"
    if {![llength $hits]} { .pw.ed.find.pat configure -style NotFound.TEntry }
}

proc tc::findNext {fwd} {
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
    if {[catch {::tc::_edw search $dir {*}[searchOpts] -count n -- $find(pat) $start} idx]} return
    if {$idx eq ""} {
        set ::tc::status "Não encontrado: $find(pat)"
        return
    }
    $ed tag remove sel 1.0 end
    $ed tag add sel $idx "$idx +${n}c"
    $ed mark set insert [expr {$fwd ? "$idx +${n}c" : $idx}]
    $ed see $idx
    set ::tc::status ""
}

proc tc::replaceText {matched} {
    variable find
    if {!$find(regex)} { return $find(rep) }
    set o {}
    if {!$find(case)} { lappend o -nocase }
    regsub {*}$o -- $find(pat) $matched $find(rep) out
    return $out
}

proc tc::replaceOne {} {
    variable ed
    variable find
    if {[llength [$ed tag ranges sel]]} {
        set s [$ed get sel.first sel.last]
        set o [searchOpts]
        if {[catch {::tc::_edw search {*}$o -count n -- $find(pat) sel.first sel.last} idx] == 0
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

proc tc::replaceAll {} {
    variable ed
    variable find
    if {$find(pat) eq ""} return
    set cnt {}
    if {[catch {::tc::_edw search {*}[searchOpts] -all -count cnt -- $find(pat) 1.0 end} hits]} return
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
    set ::tc::status "$k substituição(ões)"
    markAll
}

proc tc::gotoDialog {} {
    set w .goto
    if {[winfo exists $w]} { raise $w; focus $w.e; return }
    toplevel $w -background $::tc::C(ui)
    wm title $w "Ir para linha"
    wm transient $w .
    wm resizable $w 0 0
    ttk::frame $w.f -padding 10
    ttk::label $w.f.l -text "Linha:"
    ttk::entry $w.e -width 10 -textvariable ::tc::gotoLine
    ttk::button $w.f.ok -text OK -command tc::gotoApply
    pack $w.f -fill both
    pack $w.f.l -in $w.f -side left
    pack $w.e -in $w.f -side left -padx 6
    pack $w.f.ok -side left
    bind $w <Return> tc::gotoApply
    bind $w <Escape> [list destroy $w]
    set ::tc::gotoLine [lindex [split [$::tc::ed index insert] .] 0]
    wm geometry $w +[expr {[winfo rootx .] + 200}]+[expr {[winfo rooty .] + 120}]
    focus $w.e
    $w.e selection range 0 end
}

proc tc::gotoApply {} {
    if {[string is integer -strict $::tc::gotoLine]} {
        gotoLine $::tc::gotoLine
    }
    destroy .goto
}

proc tc::gotoLine {n} {
    variable ed
    $ed mark set insert $n.0
    $ed tag remove sel 1.0 end
    $ed see insert
    focus $ed
}

# ---------------------------------------------------------------------------
# Arquivos
# ---------------------------------------------------------------------------

proc tc::updateTitle {} {
    variable file
    set name [expr {$file eq "" ? "Sem título" : [file tail $file]}]
    set mod [expr {[$::tc::ed edit modified] ? " •" : ""}]
    set dir [expr {$file eq "" ? "" : "  —  [file dirname $file]"}]
    wm title . "$name$mod$dir  —  tconsole"
}

proc tc::confirmDiscard {} {
    if {![$::tc::ed edit modified]} { return 1 }
    set r [tk_messageBox -parent . -icon warning -type yesnocancel \
        -title tconsole -message "Salvar as alterações?" \
        -detail "O arquivo foi modificado."]
    switch -- $r {
        yes     { return [save] }
        no      { return 1 }
        default { return 0 }
    }
}

proc tc::setContent {data} {
    variable ed
    $ed delete 1.0 end
    $ed insert 1.0 $data
    $ed edit reset
    $ed edit modified 0
    $ed mark set insert 1.0
    $ed see 1.0
    ::tc::_edw tag remove errline 1.0 end
    highlight
    updateTitle
}

proc tc::newFile {{force 0}} {
    if {!$force && ![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::tc::status "Novo arquivo"
}

proc tc::closeFile {} {
    if {![confirmDiscard]} return
    variable file ""
    setContent ""
    set ::tc::status "Arquivo fechado"
}

proc tc::fileTypes {} {
    return {{"Scripts Tcl" {.tcl .tk .tm .test}} {"Todos os arquivos" *}}
}

proc tc::openFile {{path ""}} {
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
        tk_messageBox -parent . -icon error -title tconsole \
            -message "Não foi possível abrir o arquivo." -detail $data
        return
    }
    if {[string index $data end] eq "\n"} { set data [string range $data 0 end-1] }
    variable file [file normalize $path]
    set cfg(lastdir) [file dirname $file]
    setContent $data
    addRecent $file
    set ::tc::status "Aberto: $file"
}

proc tc::save {} {
    variable file
    if {$file eq ""} { return [saveAs] }
    return [saveTo $file]
}

proc tc::saveAs {} {
    variable cfg
    variable file
    set opts [list -parent . -title "Salvar como" -filetypes [fileTypes] -defaultextension .tcl]
    if {$file ne ""} {
        lappend opts -initialdir [file dirname $file] -initialfile [file tail $file]
    } elseif {$cfg(lastdir) ne "" && [file isdirectory $cfg(lastdir)]} {
        lappend opts -initialdir $cfg(lastdir)
    }
    set path [tk_getSaveFile {*}$opts]
    if {$path eq ""} { return 0 }
    return [saveTo [file normalize $path]]
}

proc tc::saveTo {path} {
    variable ed
    variable cfg
    set data [$ed get 1.0 end-1c]
    if {$data ne "" && [string index $data end] ne "\n"} { append data \n }
    if {[catch {writeFile $path $data} err]} {
        tk_messageBox -parent . -icon error -title tconsole \
            -message "Não foi possível salvar o arquivo." -detail $err
        return 0
    }
    variable file $path
    set cfg(lastdir) [file dirname $path]
    $ed edit modified 0
    addRecent $path
    updateTitle
    set ::tc::status "Salvo: $path"
    return 1
}

proc tc::addRecent {path} {
    variable cfg
    set l [lsearch -all -inline -not -exact $cfg(recent) $path]
    set cfg(recent) [lrange [linsert $l 0 $path] 0 9]
    updateRecentMenu
}

proc tc::updateRecentMenu {} {
    variable cfg
    set m .mb.file.recent
    $m delete 0 end
    foreach p $cfg(recent) {
        $m add command -label $p -command [list tc::openFile $p]
    }
    if {![llength $cfg(recent)]} {
        $m add command -label "(vazio)" -state disabled
    } else {
        $m add separator
        $m add command -label "Limpar lista" -command {set ::tc::cfg(recent) {}; tc::updateRecentMenu}
    }
}

proc tc::quit {} {
    if {![confirmDiscard]} return
    stop
    saveCfg
    catch {file delete -force [tmpDir]}
    exit
}

# ---------------------------------------------------------------------------
# Console e execução
# ---------------------------------------------------------------------------

proc tc::conAppend {text tag} {
    variable con
    $con configure -state normal
    $con insert end $text $tag
    # limita o tamanho do console
    set lines [lindex [split [$con index end] .] 0]
    if {$lines > 50000} { $con delete 1.0 [expr {$lines - 40000}].0 }
    $con configure -state disabled
    $con see end
}

proc tc::clearConsole {} {
    variable con
    $con configure -state normal
    $con delete 1.0 end
    $con configure -state disabled
}

set tc::wrapperScript {
    set ::__tc_file [lindex $argv 0]
    catch {cd [lindex $argv 1]}
    set argv {}
    set argc 0
    set argv0 $::__tc_file
    fconfigure stdout -buffering none -encoding utf-8
    fconfigure stderr -encoding utf-8
    set ::__tc_code [catch {uplevel #0 [list source -encoding utf-8 $::__tc_file]} ::__tc_res ::__tc_opts]
    if {$::__tc_code == 1} {
        set ei [dict get $::__tc_opts -errorinfo]
        set k [string last "(file \"$::__tc_file\" line" $ei]
        if {$k >= 0} {
            set e [string first "\n" $ei $k]
            if {$e > 0} { set ei [string range $ei 0 $e-1] }
        }
        puts stderr "\x01E[string map {\n \x02} $ei]"
        exit 1
    }
    if {$::__tc_res ne ""} {
        puts stderr "\x01R[string map {\n \x02} $::__tc_res]"
    }
    if {[info commands ::tk] ne "" && [winfo exists .]} { tkwait window . }
    exit 0
}

proc tc::setRunning {on} {
    set s [expr {$on ? "disabled" : "!disabled"}]
    set ns [expr {$on ? "!disabled" : "disabled"}]
    .tb.run state $s
    .tb.stop state $ns
    .mb.script entryconfigure 0 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 1 -state [expr {$on ? "disabled" : "normal"}]
    .mb.script entryconfigure 2 -state [expr {$on ? "normal" : "disabled"}]
}

proc tc::run {selOnly} {
    variable ed
    variable R
    variable cfg
    variable file
    variable wrapperScript
    if {[info exists R(fd)]} {
        set ::tc::status "Já existe um script em execução (Ctrl+Break para interromper)"
        return
    }
    set lineoff 0
    if {$selOnly} {
        if {![llength [$ed tag ranges sel]]} {
            set ::tc::status "Nenhum texto selecionado"
            return
        }
        set code [$ed get sel.first sel.last]
        set lineoff [expr {[lindex [split [$ed index sel.first] .] 0] - 1}]
    } else {
        set code [$ed get 1.0 end-1c]
    }
    set tclsh [findTclsh]
    if {$tclsh eq ""} {
        conAppend "tclsh não encontrado. Defina a variável TCONSOLE_TCLSH.\n" stderr
        return
    }
    if {$cfg(autoclear)} { clearConsole }
    ::tc::_edw tag remove errline 1.0 end

    set dir [tmpDir]
    set wrapper [file join $dir wrapper.tcl]
    set script [file join $dir [expr {$file eq "" ? "script.tcl" : [file tail $file]}]]
    writeFile $wrapper $wrapperScript
    writeFile $script $code
    set wd [expr {$file eq "" ? [pwd] : [file dirname $file]}]

    lassign [chan pipe] er ew
    if {[catch {open |[list {*}$tclsh $wrapper $script $wd 2>@ $ew] r+} fd]} {
        close $er; close $ew
        conAppend "Erro ao iniciar o tclsh: $fd\n" stderr
        return
    }
    close $ew
    catch {chan close $fd write}
    foreach c [list $fd $er] {
        fconfigure $c -blocking 0 -buffering none -translation auto
        setEncoding $c
    }
    array set R [list fd $fd er $er open 2 t0 [clock milliseconds] \
        lineoff $lineoff script $script name [file tail $script] killed 0 \
        pid [lindex [pid $fd] 0]]
    fileevent $fd readable [list tc::onStdout $fd]
    fileevent $er readable [list tc::onStderr $er]

    set what [expr {$selOnly ? "seleção de [file tail $script] (a partir da linha [expr {$lineoff + 1}])" : [file tail $script]}]
    conAppend "▶ $what  ·  [clock format [clock seconds] -format %H:%M:%S]\n" info
    setRunning 1
    set ::tc::status "Executando…"
}

proc tc::onStdout {fd} {
    set data [read $fd]
    if {$data ne ""} { conAppend $data stdout }
    if {[eof $fd]} {
        fileevent $fd readable {}
        streamClosed
    }
}

proc tc::onStderr {er} {
    while {[gets $er line] >= 0} {
        switch -glob -- $line {
            "\x01R*" {
                conAppend "Resultado: [string map {\x02 \n} [string range $line 2 end]]\n" result
            }
            "\x01E*" {
                showError [string map {\x02 \n} [string range $line 2 end]]
            }
            default {
                conAppend $line\n stderr
            }
        }
    }
    if {[eof $er]} {
        fileevent $er readable {}
        streamClosed
    }
}

proc tc::showError {ei} {
    variable R
    variable con
    variable linkSeq
    set script $R(script)
    set name $R(name)
    set target ""
    set re "\\(file \"[regsub -all {[][\\{}()*+?.^$|]} $script {\\&}]\" line (\[0-9\]+)\\)"
    set hits [regexp -all -inline -indices -- $re $ei]
    if {[llength $hits]} {
        lassign [lindex $hits end-1] a z
        set n [string range $ei {*}[lindex $hits end]]
        set target [expr {$n + $R(lineoff)}]
        set pre  [string map [list $script $name] [string range $ei 0 $a-1]]
        set post [string map [list $script $name] [string range $ei $z+1 end]]
        set tag link[incr linkSeq]
        conAppend $pre stderr
        conAppend "(file \"$name\" line $target)" [list stderr link $tag]
        conAppend $post\n stderr
        $con tag bind $tag <1> [list tc::gotoLine $target]
        ::tc::_edw tag add errline $target.0 "$target.0 lineend +1c"
        $::tc::ed see $target.0
    } else {
        conAppend [string map [list $script $name] $ei]\n stderr
    }
}

proc tc::streamClosed {} {
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
        set ::tc::status "Interrompido"
    } else {
        set tag [expr {$code eq "0" ? "info" : "stderr"}]
        conAppend "■ Finalizado em [format %.3f $secs] s (código de saída $code)\n" $tag
        set ::tc::status "Finalizado em [format %.3f $secs] s"
    }
    array unset R
    setRunning 0
}

proc tc::stop {} {
    variable R
    if {![info exists R(pid)]} return
    set R(killed) 1
    if {$::tcl_platform(platform) eq "windows"} {
        catch {exec {*}[auto_execok taskkill] /F /T /PID $R(pid)}
    } else {
        catch {exec kill $R(pid)}
    }
}

# ---------------------------------------------------------------------------
# Ajuda
# ---------------------------------------------------------------------------

proc tc::showShortcuts {} {
    tk_messageBox -parent . -title "Atalhos" -message "Atalhos de teclado" -detail [join {
        "Ctrl+R / Ctrl+Enter   Executar script"
        "Ctrl+Shift+R          Executar seleção"
        "Ctrl+Break            Interromper execução"
        "Ctrl+W                Limpar saída"
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

proc tc::about {} {
    tk_messageBox -parent . -title "Sobre" -message "tconsole $::tc::version" \
        -detail "Editor simples para testes rápidos em Tcl/Tk.\n\nTcl [info patchlevel] · Tk [package present Tk]\nInterpretador: [join [findTclsh]]"
}

# ---------------------------------------------------------------------------

proc tc::main {argv} {
    loadCfg
    initKeywords
    setupTheme
    buildUI
    if {[llength $argv]} {
        openFile [lindex $argv 0]
    } else {
        newFile 1
    }
    focus $::tc::ed
    updateCursor
}

if {![info exists ::tc_nomain]} {
    tc::main $argv
}
