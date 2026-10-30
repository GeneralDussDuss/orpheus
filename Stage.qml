import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Tui.js" as Tui

// The big visualizer. Its placement is fixed for the life of the window (the
// engine makes a new one on a switch):
//   overlay     a card over everything on the focused monitor (Esc closes)
//   desktop     on Linux, a card above the wallpaper, below windows; on Windows
//               the live wallpaper, full monitor, behind the desktop icons
//   fullscreen  the show: full-bleed on showMonitor, no frame
PanelWindow {
  id: win

  property var engine: null
  property string mode: engine ? engine.placement : "overlay"
  // Ask the owner for a fresh window (the wallpaper's host went away, or it
  // has to move to another monitor).
  signal rebuild()

  readonly property bool windows: Qt.platform.os === "windows"
  readonly property bool desktop: mode === "desktop"
  readonly property bool show: mode === "fullscreen"
  readonly property bool wallpaperMode: desktop && windows
  readonly property bool bleed: show || wallpaperMode       // no card: the visuals are the window
  readonly property var hyprMonitor: Hyprland.monitorFor(screen)
  readonly property bool fullscreen: !!(hyprMonitor && hyprMonitor.activeWorkspace
                                        && hyprMonitor.activeWorkspace.hasFullscreen)

  screen: {
    var list = Quickshell.screens
    var want = win.bleed && win.engine ? win.engine.showMonitor : ""
    if (want)
      for (var j = 0; j < list.length; j++) if (list[j].name === want) return list[j]
    var focused = Hyprland.focusedMonitor
    for (var i = 0; i < list.length; i++)
      if (focused && list[i].name === focused.name) return list[i]
    return list.length ? list[0] : null
  }

  // Opaque reference surface for contrast guards (Color.background carries alpha).
  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property bool playing: !!(engine && engine.player && engine.player.isPlaying)

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property int vizWidth: Math.round(Math.min(860, (screen ? screen.width : 1600) * 0.5))
  readonly property int vizHeight: Math.round(vizWidth * 0.48)

  implicitWidth: vizWidth + Math.round(fm.advanceWidth("M") * 3)
  implicitHeight: card.height
  // Windows hit-tests a translucent (layered) window by its pixels' alpha, and a
  // GPU-drawn Qt window reads as fully clear to it, so every click fell through.
  // An opaque window takes the mouse normally; the card fills it anyway.
  color: bleed || Qt.platform.os === "windows" ? bg : "transparent"
  exclusionMode: ExclusionMode.Ignore
  // Game mode: a fullscreen game is in front. Every placement steps back (the
  // overlay and the show are topmost; the wallpaper would only burn GPU behind
  // the game) and comes back when the game does.
  visible: !(desktop && !windows && fullscreen) && !(engine && engine.gameMode)

  anchors.left: bleed
  anchors.right: bleed
  anchors.top: bleed
  anchors.bottom: desktop || bleed
  margins.bottom: desktop && !bleed ? Style.gapsOut * 8 : 0

  WlrLayershell.layer: wallpaperMode ? WlrLayer.Background : desktop ? WlrLayer.Bottom : WlrLayer.Overlay
  WlrLayershell.namespace: "orpheus-stage"
  WlrLayershell.keyboardFocus: desktop ? WlrKeyboardFocus.None
                             : show ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

  // The wallpaper window is a child of Explorer's; when Explorer restarts it
  // goes too, and moving monitors means re-parenting. Both: start over.
  Connections {
    target: win
    ignoreUnknownSignals: true          // Quickshell's PanelWindow has no such signal
    function onWallpaperLost() { win.rebuild() }
  }
  onScreenChanged: if (wallpaperMode && win["wallpaperLayout"]) rebuild()

  // ---- style ---------------------------------------------------------------
  //
  // autoStyle changes style on the stage only (config and the widget keep the
  // chosen one); any manual pick takes over again.
  property string liveStyle: ""
  readonly property string current: engine ? (engine.autoStyle && liveStyle ? liveStyle : engine.style) : "skyline"

  // Every manual change says what it changed to (VizLabel over the visuals).
  signal picked(string name)
  function pick(name) { liveStyle = ""; engine.setStyle(name); picked(engine.styleLabels[name] || name) }
  function stepStyle(d) {
    var s = engine.styles, i = s.indexOf(current)
    pick(s[(i + d + s.length) % s.length])
  }

  // With the director on (the default), a style change rides its `drop`: a
  // build resolving into full band, landed on the downbeat it re-anchors.
  // Without it, the heuristic below. Either way, never more often than every 20 s.
  Connections {
    target: win.engine
    ignoreUnknownSignals: true
    function onDropsChanged() { if (win.engine.autoStyle && win.engine.director) win.switchOnDrop() }
  }
  function switchOnDrop() {
    var now = Date.now()
    if (now - lastSwitch < cooldownMs) return
    lastSwitch = now
    var s = engine.styles, options = []
    for (var i = 0; i < s.length; i++) if (s[i] !== current) options.push(s[i])
    liveStyle = options[Math.floor(Math.random() * options.length)]
  }

  // Drop detection, on the shared onset signals. A drop is a breakdown (the
  // loudness envelope well under its own 10 s average for 2 s or more) that
  // ends in a slam (swell back above the average with a hard kick), or, with
  // no breakdown, a sudden surge of both. Never more often than every 20 s.
  property real slowSwell: 0
  property real quietFor: 0
  property real swellAgo: 0            // swell ~1.5 s ago (a slow follower)
  property real lastSwitch: Date.now()
  readonly property int cooldownMs: 20000

  Timer {
    interval: 100
    repeat: true
    running: !!win.engine && win.engine.autoStyle && !win.engine.director && win.playing
    onTriggered: win.watchDrops(0.1)
    onRunningChanged: if (running) win.seedDrops()
  }
  // Start the followers where the music is, not at silence, or the first beat
  // after a pause would read as a surge.
  function seedDrops() { slowSwell = engine.swell; swellAgo = engine.swell; quietFor = 0 }

  function watchDrops(dt) {
    var e = engine, sw = e.swell
    slowSwell += (sw - slowSwell) * (dt / 10)
    swellAgo += (sw - swellAgo) * (dt / 1.5)
    if (sw < slowSwell * 0.65) quietFor += dt
    else if (sw > slowSwell * 0.9) quietFor = Math.max(0, quietFor - dt * 0.5)

    var slam = e.kick > 0.6 && sw > 0.22
    var afterBreak = quietFor >= 2 && sw > slowSwell * 1.15
    var surge = sw - swellAgo > 0.28 && e.energy > slowSwell * 1.3
    if (!(slam && (afterBreak || surge))) return
    quietFor = 0
    switchOnDrop()
  }

  // ---- keys ------------------------------------------------------------------

  function handleKey(e) {
    if (e.key === Qt.Key_Escape) leave(close)
    else if (e.key === Qt.Key_Right || e.text === "l") stepStyle(1)
    else if (e.key === Qt.Key_Left || e.text === "h") stepStyle(-1)
    else if (e.text === "p" && !bleed) engine.setMiniPlayer(!engine.miniPlayer)
    else if (e.text === "f") leave(toggleShow)
    else if (e.text >= "1" && e.text <= "9" && Number(e.text) <= engine.styles.length) pick(engine.styles[Number(e.text) - 1])
    else if (e.key === Qt.Key_Space && engine.player) engine.player.togglePlaying()
    else return false
    return true
  }

  function close() { engine.open = false }
  function toggleShow() { engine.setPlacement(show ? "overlay" : "fullscreen") }

  // ---- coming and going ------------------------------------------------------
  //
  // The window opens on its theme's background (opaque, so nothing black or
  // stale shows first) and its contents fade up over it: the show at page
  // pace, the card at state pace. Leaving from here (esc, f, double-click)
  // fades them back down before the window goes; a close from elsewhere (a
  // hotkey, the tray) still cuts, since the window is gone by then.
  property real presence: 0
  NumberAnimation on presence { id: arrive; from: 0; to: 1; duration: win.bleed ? Tui.PAGE : Tui.STATE; easing.type: Easing.InOutCubic }
  property var leaving: null
  function leave(then) {
    if (leaving) return
    leaving = then
    arrive.stop()
    depart.from = presence
    depart.restart()
  }
  NumberAnimation { id: depart; target: win; property: "presence"; to: 0; duration: Tui.STATE; easing.type: Easing.InOutCubic
                    onFinished: { var f = win.leaving; win.leaving = null; if (f) f() } }

  // ---- the show's mouse ------------------------------------------------------
  //
  // The pointer and the key strip are there while the mouse moves and leave
  // after 2 s of stillness, so the show is only the show. Any movement
  // brings both back.
  property bool awake: true
  function wake() { awake = true; sleepTimer.restart() }
  // (Not while the pointer rests on the key strip itself: it would vanish under the click.)
  Timer { id: sleepTimer; interval: 2000; running: win.show; onTriggered: if (hintHover.hovered) restart(); else win.awake = false }
  // Show-unit type: the same scale StageView uses, so a 3440 px wall reads.
  readonly property real unit: Math.max(10, Math.min(width / 46, height / 18))

  // ---- full-bleed: the show and the wallpaper ---------------------------------

  Item {
    id: full
    anchors.fill: parent
    visible: win.bleed
    focus: win.show
    Keys.onPressed: function(e) { e.accepted = win.handleKey(e) }

    Loader {
      anchors.fill: parent
      active: win.bleed
      opacity: win.presence
      sourceComponent: StageView {
        engine: win.engine
        styleName: win.current
      }
    }

    // The show takes the mouse for style changes; the wallpaper takes nothing.
    // A left click waits out the double-click time, so the double-click that
    // leaves the show does not change the style on its way out.
    MouseArea {
      id: showMouse
      anchors.fill: parent
      enabled: win.show
      visible: win.show
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: win.awake ? Qt.ArrowCursor : Qt.BlankCursor
      property real wheelAcc: 0
      onPositionChanged: win.wake()
      onPressed: win.wake()
      onClicked: function(m) {
        if (m.button === Qt.RightButton) win.stepStyle(-1)
        else clickWait.restart()
      }
      onDoubleClicked: { clickWait.stop(); win.leave(function() { win.engine.setPlacement("overlay") }) }
      // one style per notch: a touchpad's stream of small deltas used to race through them
      onWheel: function(w) { win.wake(); var n = Tui.notches(showMouse, w.angleDelta.y); if (n) win.stepStyle(-n) }
      Timer { id: clickWait; interval: Qt.styleHints.mouseDoubleClickInterval; onTriggered: win.stepStyle(1) }
    }
    VizLabel {
      id: showLabel
      anchors.fill: parent
      visible: win.show
      opacity: win.presence
      pixelSize: Math.round(Math.max(Style.font.body * 2, win.unit * 0.7))
    }
    Connections { target: win; function onPicked(name) { if (win.show) showLabel.flash(name) } }

    // The way around and the way out, at the bottom while the mouse is about.
    HintBar {
      id: showHints
      visible: win.show && opacity > 0.01
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Math.round(win.unit * 0.6)
      pixelSize: Math.round(Math.max(Style.font.caption, win.unit * 0.36))
      keyColor: win.accentText
      labelColor: win.dim
      opacity: win.presence * (win.awake ? 1 : 0)
      HoverHandler { id: hintHover }
      Behavior on opacity { NumberAnimation { duration: win.awake ? Tui.STATE : Tui.PAGE; easing.type: Easing.InOutCubic } }
      items: [
        { k: "←→", l: "style", run: function() { win.stepStyle(1) }, tip: "next style · click, right-click and scroll work too", tipKey: "← →" },
        { k: "space", l: "play", run: function() { if (win.engine.player) win.engine.player.togglePlaying() }, tip: "play / pause" },
        { k: "f", l: "window", run: function() { win.leave(win.toggleShow) }, tip: "back to the window · or double-click" },
        { k: "esc", l: "close", run: function() { win.leave(win.close) }, tip: "close the visualizer" }]
    }
  }

  // ┌─ orpheus · skyline ──────── ←→ style  p player  esc ┐
  TuiBox {
    id: card
    visible: !win.bleed
    width: parent ? parent.width : 0
    height: column.implicitHeight + ch * 2
    opacity: win.presence
    title: "orpheus · " + (win.engine ? win.engine.styleLabels[win.current].toLowerCase() : "")
    // The hints give way before the title does: labels first, then the
    // lesser keys. Every key still works, and each hint keeps its tooltip.
    readonly property var allHints: [
      { k: "←→", l: "style", run: function() { win.stepStyle(1) }, tip: "next style · click, right-click and scroll the picture too", tipKey: "← →", keep: 1 },
      { k: "p", l: "player", run: function() { win.engine.setMiniPlayer(!win.engine.miniPlayer) }, tip: (win.engine && win.engine.miniPlayer ? "hide" : "show") + " the mini player", keep: 2 },
      { k: "f", l: "full", run: function() { win.leave(win.toggleShow) }, tip: "fullscreen show", keep: 0 },
      { k: "space", l: "play", run: function() { if (win.engine.player) win.engine.player.togglePlaying() }, tip: "play / pause", keep: 1 },
      { k: "esc", l: "close", run: function() { win.leave(win.close) }, tip: "close the visualizer", keep: 0 }]
    TextMetrics { id: titleM; font.family: Style.font.family; font.pixelSize: Style.font.body; text: "  " + card.title + "  " }
    TextMetrics { id: hintM; font.family: Style.font.family; font.pixelSize: Style.font.caption; text: "x" }
    // room on the top edge for the hints, in caption cells
    readonly property real room: (width - card.cw * 4 - titleM.advanceWidth) / Math.max(1, hintM.advanceWidth)
    function hintCells(list) {
      var n = 0
      for (var i = 0; i < list.length; i++) n += list[i].k.length + (list[i].l ? list[i].l.length + 1 : 0) + (i ? 3 : 0)
      return n + 2
    }
    function hintsFor(room) {
      var full = allHints, i
      if (hintCells(full) <= room) return full
      var keys = []
      for (i = 0; i < full.length; i++) keys.push(Object.assign({}, full[i], { l: "" }))
      if (hintCells(keys) <= room) return keys
      for (var keep = 1; keep <= 2; keep++) {
        var few = keys.filter(function(h) { return h.keep < keep })
        if (hintCells(few) <= room) return few
      }
      return []
    }
    hintItems: win.desktop ? [] : hintsFor(room)
    footer: win.engine && !win.engine.hasCava ? "install cava to hear the music" : ""
    focused: !win.desktop
    clock: win.engine ? win.engine.time : -1
    background: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, win.desktop ? 0.6 : 0.97)

    focus: !win.bleed
    Keys.onPressed: function(e) { e.accepted = win.handleKey(e) }

    Column {
      id: column
      width: parent.width
      spacing: card.ch * 0.4

      // Style tabs as text: [1 skyline]  2 horizon ...  The chosen one is lit; the
      // right edge carries the pulse (eq + pace), muted so the visuals stay the subject.
      Item {
        id: tabs
        width: parent.width
        height: card.ch
        // Too narrow for every name: the others keep only their numbers.
        FontMetrics { id: tabM; font.family: Style.font.family; font.pixelSize: Style.font.caption }
        readonly property real fullWidth: {
          var s = win.engine ? win.engine.styles : [], w = 0
          for (var i = 0; i < s.length; i++) w += tabM.advanceWidth(" " + (i + 1) + " " + win.engine.styleLabels[s[i]] + " ") + card.cw * 2
          return w
        }
        readonly property bool compact: fullWidth > width - (pulse.visible ? pulse.implicitWidth : 0) - card.cw * 2
        Row {
          spacing: tabs.compact ? card.cw : card.cw * 2
          Repeater {
            model: win.engine ? win.engine.styles : []
            Text {
              required property string modelData
              required property int index
              readonly property bool current: win.current === modelData
              text: (current ? "[" : " ") + (index + 1) + (current || !tabs.compact ? " " + win.engine.styleLabels[modelData].toLowerCase() : "") + (current ? "]" : " ")
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: current
              color: current || tabMouse.containsMouse ? win.accentText : win.dim
              font.underline: tabMouse.containsMouse && !current
              Behavior on color { ColorAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
              MouseArea { id: tabMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.pick(parent.modelData)
                          TuiTip { text: win.engine.styleLabels[modelData].toLowerCase(); key: String(index + 1) } }
            }
          }
        }
        Text {
          id: pulse
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: win.engine && win.engine.hasCava
          textFormat: Text.StyledText
          text: '<font color="' + Tui.hex(win.playing ? win.accentText : win.dim) + '">'
                + (win.playing ? Tui.eq(win.engine.time, 3) : "‖‖‖") + '</font>'
                + (win.playing && win.engine.tempo > 0 ? '&nbsp;&nbsp;' + Math.round(win.engine.tempo) + ' bpm' : '')
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: win.dim
        }
      }

      Loader {
        width: parent.width
        height: win.vizHeight
        active: !win.bleed
        sourceComponent: StageView {
          engine: win.engine
          styleName: win.current

          MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property real wheelAcc: 0
            onClicked: function(m) { win.stepStyle(m.button === Qt.RightButton ? -1 : 1) }
            onWheel: function(w) { var n = Tui.notches(cardMouse, w.angleDelta.y); if (n) win.stepStyle(-n) }
            TuiTip { text: "click: next style · right-click: back · scroll"; key: "← →"; delay: 900 }
          }
          VizLabel { id: cardLabel; anchors.fill: parent }
          Connections { target: win; function onPicked(name) { cardLabel.flash(name) } }
        }
      }

      MiniPlayer {
        engine: win.engine
        width: parent.width
        visible: win.engine && win.engine.miniPlayer
      }
    }
  }
}
