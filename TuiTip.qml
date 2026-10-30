import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// A tooltip in the TUI's own terms: a square 1px chip in the theme colours,
// what the control does and, in the accent, the key that does it too.
//
//   MouseArea { id: ma; hoverEnabled: true
//               TuiTip { text: "next track"; key: "n" } }
//
// Drop it inside the MouseArea it describes: it covers that area, watches the
// pointer with its own HoverHandler (passive, so the MouseArea still gets
// every click), shows after `delay` ms, hides on press or leave, and draws in
// the window's content item so a clipping box cannot cut it off. With
// `follow`, it tracks the pointer along x and shows at once (the seek time).
Item {
  id: tip

  property Item target: parent
  property string text: ""
  property string key: ""
  property int delay: 500
  property bool follow: false
  property real at: -1                  // x in the target to point at; -1 = its centre
  property bool force: false            // show regardless of hover (a scrub in progress)

  width: target ? target.width : 0
  height: target ? target.height : 0
  HoverHandler { id: hh }
  readonly property bool hovered: hh.hovered && !(target && target.pressed === true)
  readonly property bool want: text !== "" && (force || hovered)
  property bool shown: false

  readonly property color bgc: Color.background
  readonly property color bg: Qt.rgba(bgc.r, bgc.g, bgc.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color keyColor: Tui.ensure(Color.accent, bg, 4.5)
  readonly property color line: Tui.ensure(Tui.mix(Color.foreground, bg, 0.6), bg, 2)

  Timer { id: wait; interval: Math.max(1, tip.delay); onTriggered: tip.shown = tip.want }
  onWantChanged: {
    if (!want) { wait.stop(); shown = false }
    else if (follow || delay <= 0 || force) shown = true
    else wait.restart()
  }
  onShownChanged: if (shown) place()
  onAtChanged: if (shown) place()
  onTextChanged: if (shown) Qt.callLater(place)

  function place() {
    var host = chip.parent
    if (!host || !target) return
    var p = target.mapToItem(host, at >= 0 ? at : target.width / 2, 0)
    var gap = 4
    chip.x = Math.round(Math.max(2, Math.min(host.width - chip.width - 2, p.x - chip.width / 2)))
    var above = p.y - chip.height - gap
    chip.y = Math.round(above >= 2 ? above : p.y + target.height + gap)
  }

  Rectangle {
    id: chip
    parent: tip.Window.contentItem
    visible: tip.shown && !!parent
    z: 100000
    width: label.implicitWidth + fm.advanceWidth("M") * 1.6
    height: label.implicitHeight + 6
    color: tip.bg
    border.width: 1
    border.color: tip.line
    opacity: visible ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 90 } }
    FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Text {
      id: label
      anchors.centerIn: parent
      textFormat: Text.StyledText
      text: Tui.esc(tip.text) + (tip.key ? '&nbsp;&nbsp;<font color="' + Tui.hex(tip.keyColor) + '">' + Tui.esc(tip.key) + '</font>' : "")
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      color: tip.fg
    }
  }
}
