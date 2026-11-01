import QtQuick
import qs.Commons
import "Tui.js" as Tui

// An empty, loading or failed page, said the same way everywhere:
//
//     ╱╱  nothing queued  ╱╱
//   after this, playback stops
//        / search
//
// kind "empty": the mark in the accent around a title, a dim reason under it,
// and optional HintBar actions. "error": a ✕ in the urgent colour leads instead.
// "busy": the spinner and the title only, and only once a fetch has taken
// longer than Tui.SPINNER_DELAY, so a fast one never flashes.
//
// `host` lends the fonts and colours (family, fg, dim, accentText, bg, clock);
// without one it falls back to the theme. It fades on STATE and costs nothing
// while hidden.
Column {
  id: e

  property var host: null
  property string kind: "empty"         // "empty" | "busy" | "error"
  property string title: ""
  property string reason: ""
  property var actions: []
  property bool shown: true

  readonly property string family: host && host.family ? host.family : Style.font.family
  readonly property color bg: host && host.bg !== undefined ? host.bg : Color.background
  readonly property color fg: host && host.fg !== undefined ? host.fg : Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: host && host.dim !== undefined ? host.dim : Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accentText: host && host.accentText !== undefined ? host.accentText : Tui.ensure(Color.accent, bg, 4.5)
  readonly property color urgent: Tui.ensure(Color.urgent, bg, 4.5)
  readonly property color mark: kind === "error" ? urgent : accentText
  readonly property real clock: host && host.clock !== undefined ? host.clock : 0

  // Busy waits SPINNER_DELAY before it shows; any other kind shows at once.
  property bool armed: kind !== "busy"
  Timer { id: arm; interval: Tui.SPINNER_DELAY; onTriggered: e.armed = true }
  function rearm() { arm.stop(); armed = kind !== "busy"; if (!armed && shown) arm.start() }
  onKindChanged: rearm()
  onShownChanged: rearm()
  Component.onCompleted: rearm()

  spacing: Tui.T.body * 0.45
  visible: opacity > 0.01
  opacity: shown && armed ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }

  Text {
    width: parent.width
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    textFormat: Text.StyledText
    font.family: e.family; font.pixelSize: Tui.T.body
    color: e.fg
    text: e.kind === "busy"
          ? Tui.busy(e.clock, e.title, Tui.hex(e.accentText))
          : '<font color="' + Tui.hex(e.mark) + '">' + (e.kind === "error" ? "✕" : "╱╱") + '</font>&nbsp;&nbsp;'
            + Tui.esc(e.title)
            + (e.kind === "error" ? "" : '&nbsp;&nbsp;<font color="' + Tui.hex(e.mark) + '">╱╱</font>')
  }
  Text {
    width: parent.width
    visible: e.kind !== "busy" && e.reason !== ""
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    text: e.reason
    font.family: e.family; font.pixelSize: Tui.T.caption
    color: e.dim
  }
  HintBar {
    anchors.horizontalCenter: parent.horizontalCenter
    visible: e.kind !== "busy" && items.length > 0
    keyColor: e.accentText; labelColor: e.fg; hoverColor: e.accentText
    items: e.actions || []
  }
}
