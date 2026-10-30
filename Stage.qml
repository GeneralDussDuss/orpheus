import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Tui.js" as Tui

// The big visualizer. "overlay" floats it over everything on the focused
// monitor (Esc closes); "desktop" parks it above the wallpaper, below windows.
PanelWindow {
  id: win

  property var engine: null
  property string mode: engine ? engine.placement : "overlay"
  signal rebuild()
  readonly property bool desktop: mode === "desktop"
  readonly property var hyprMonitor: Hyprland.monitorFor(screen)
  readonly property bool fullscreen: !!(hyprMonitor && hyprMonitor.activeWorkspace
                                        && hyprMonitor.activeWorkspace.hasFullscreen)

  screen: {
    var focused = Hyprland.focusedMonitor
    var list = Quickshell.screens
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
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  visible: !(desktop && fullscreen)

  anchors.bottom: desktop
  margins.bottom: desktop ? Style.gapsOut * 8 : 0

  WlrLayershell.layer: desktop ? WlrLayer.Bottom : WlrLayer.Overlay
  WlrLayershell.namespace: "orpheus-stage"
  WlrLayershell.keyboardFocus: desktop ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand

  // ┌─ orpheus · skyline ──────── ←→ style  p player  esc ┐
  TuiBox {
    id: card
    width: parent.width
    height: column.implicitHeight + ch * 2
    title: "orpheus · " + (win.engine ? win.engine.styleLabels[win.engine.style].toLowerCase() : "")
    keyHint: win.desktop ? "" : Tui.hints([["←→", "style"], ["p", "player"], ["space", "⏯"], ["esc", ""]], win.accentText, win.dim)
    footer: win.engine && !win.engine.hasCava ? "install cava to hear the music" : ""
    focused: !win.desktop
    clock: win.engine ? win.engine.time : -1
    background: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, win.desktop ? 0.6 : 0.97)

    focus: true
    Keys.onPressed: function(e) {
      if (e.key === Qt.Key_Escape) win.engine.open = false
      else if (e.key === Qt.Key_Right || e.text === "l") win.engine.nextStyle(1)
      else if (e.key === Qt.Key_Left || e.text === "h") win.engine.nextStyle(-1)
      else if (e.text === "p") win.engine.setMiniPlayer(!win.engine.miniPlayer)
      else if (e.text >= "1" && e.text <= "9" && Number(e.text) <= win.engine.styles.length) win.engine.setStyle(win.engine.styles[Number(e.text) - 1])
      else if (e.key === Qt.Key_Space && win.engine.player) win.engine.player.togglePlaying()
      else return
      e.accepted = true
    }

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
              readonly property bool current: win.engine && win.engine.style === modelData
              text: (current ? "[" : " ") + (index + 1) + " " + win.engine.styleLabels[modelData].toLowerCase() + (current ? "]" : " ")
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: current
              color: current ? win.accentText : win.dim
              Behavior on color { ColorAnimation { duration: 180 } }
              MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: win.engine.setStyle(parent.modelData) }
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

      Viz {
        engine: win.engine
        styleName: win.engine ? win.engine.style : "skyline"
        width: parent.width
        height: win.vizHeight

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          onClicked: function(m) { win.engine.nextStyle(m.button === Qt.RightButton ? -1 : 1) }
          onWheel: function(w) { win.engine.nextStyle(w.angleDelta.y > 0 ? -1 : 1) }
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
