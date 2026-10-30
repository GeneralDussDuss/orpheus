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

  function pick(name) { liveStyle = ""; engine.setStyle(name) }
  function stepStyle(d) {
    var s = engine.styles, i = s.indexOf(current)
    pick(s[(i + d + s.length) % s.length])
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
    running: !!win.engine && win.engine.autoStyle && win.playing
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
    var now = Date.now()
    if (now - lastSwitch < cooldownMs) return
    lastSwitch = now
    var s = e.styles, options = []
    for (var i = 0; i < s.length; i++) if (s[i] !== current) options.push(s[i])
    liveStyle = options[Math.floor(Math.random() * options.length)]
  }

  // ---- keys ------------------------------------------------------------------

  function handleKey(e) {
    if (e.key === Qt.Key_Escape) engine.open = false
    else if (e.key === Qt.Key_Right || e.text === "l") stepStyle(1)
    else if (e.key === Qt.Key_Left || e.text === "h") stepStyle(-1)
    else if (e.text === "p" && !bleed) engine.setMiniPlayer(!engine.miniPlayer)
    else if (e.text === "f") engine.setPlacement(show ? "overlay" : "fullscreen")
    else if (e.text >= "1" && e.text <= "9" && Number(e.text) <= engine.styles.length) pick(engine.styles[Number(e.text) - 1])
    else if (e.key === Qt.Key_Space && engine.player) engine.player.togglePlaying()
    else return false
    return true
  }

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
      sourceComponent: StageView {
        engine: win.engine
        styleName: win.current
        showHints: win.show
        hints: Tui.hints([["←→", "style"], ["f", "window"], ["space", "⏯"], ["esc", ""]], win.accentText, win.dim)
      }
    }

    // The show takes the mouse for style changes; the wallpaper takes nothing.
    MouseArea {
      anchors.fill: parent
      enabled: win.show
      visible: win.show
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(m) { win.stepStyle(m.button === Qt.RightButton ? -1 : 1) }
      onDoubleClicked: win.engine.setPlacement("overlay")
      onWheel: function(w) { win.stepStyle(w.angleDelta.y > 0 ? -1 : 1) }
    }
  }

  // ┌─ orpheus · skyline ──────── ←→ style  p player  esc ┐
  TuiBox {
    id: card
    visible: !win.bleed
    width: parent.width
    height: column.implicitHeight + ch * 2
    title: "orpheus · " + (win.engine ? win.engine.styleLabels[win.current].toLowerCase() : "")
    keyHint: win.desktop ? "" : Tui.hints([["←→", "style"], ["p", "player"], ["f", "full"], ["space", "⏯"], ["esc", ""]], win.accentText, win.dim)
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
        width: parent.width
        height: card.ch
        Row {
          spacing: card.cw * 2
          Repeater {
            model: win.engine ? win.engine.styles : []
            Text {
              required property string modelData
              required property int index
              readonly property bool current: win.current === modelData
              text: (current ? "[" : " ") + (index + 1) + " " + win.engine.styleLabels[modelData].toLowerCase() + (current ? "]" : " ")
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: current
              color: current ? win.accentText : win.dim
              Behavior on color { ColorAnimation { duration: 180 } }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.pick(parent.modelData) }
            }
          }
        }
        Text {
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
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(m) { win.stepStyle(m.button === Qt.RightButton ? -1 : 1) }
            onWheel: function(w) { win.stepStyle(w.angleDelta.y > 0 ? -1 : 1) }
          }
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
