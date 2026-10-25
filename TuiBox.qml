import QtQuick
import qs.Commons
import "Tui.js" as Tui

// ┌─ title ───────────── key ┐
// │ content                  │
// └──────────────── footer ──┘
// Square, 1px, theme-coloured. The border turns accent when focused, and a
// title decodes in when the box is born.
Item {
  id: box

  property string title: ""
  property string keyHint: ""
  property string footer: ""
  property bool focused: false
  property color background: Color.background
  property color line: Tui.ensure(Tui.mix(Color.foreground, Color.background, 0.72), Color.background, 1.6)
  property color text: Color.foreground
  property real clock: -1               // engine heartbeat (seconds), for callers that animate content
  default property alias content: inner.data

  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height
  // Focused: the border breathes toward the accent on the shared clock.
  readonly property real breath: focused && clock >= 0 ? 0.5 + 0.5 * Math.sin(clock * 1.6) : 1
  readonly property color edge: focused ? Tui.mix(line, Color.accent, 0.55 + 0.45 * breath) : line

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }

  // Title decode when the box is born (~0.35 s), and again when the title changes.
  // Runs on the animation driver, so it always settles even if nothing else moves.
  property real decodeProgress: 0
  readonly property real bornAt: 7
  NumberAnimation on decodeProgress { id: decodeAnim; from: 0; to: 1; duration: 350; running: true }
  onTitleChanged: decodeAnim.restart()

  Rectangle {
    anchors.fill: parent
    anchors.topMargin: box.ch / 2
    color: box.background
    border.width: 1
    border.color: box.edge

  }

  Rectangle {
    visible: box.title !== ""
    x: box.cw
    height: box.ch
    width: titleText.implicitWidth
    color: box.background
    Text {
      id: titleText
      text: " " + Tui.decode(box.title, box.decodeProgress, box.bornAt) + " "
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: box.focused
      color: box.focused ? Color.accent : box.text
    }
  }

  Rectangle {
    visible: box.keyHint !== ""
    anchors.right: parent.right
    anchors.rightMargin: box.cw
    height: box.ch
    width: keyText.implicitWidth
    color: box.background
    Text {
      id: keyText
      text: "&nbsp;" + box.keyHint + "&nbsp;"
      textFormat: Text.StyledText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      color: box.focused ? Color.accent : Tui.muted(Color.foreground, Color.background, 4.5)
    }
  }

  Rectangle {
    visible: box.footer !== ""
    anchors.right: parent.right
    anchors.rightMargin: box.cw * 2
    anchors.bottom: parent.bottom
    anchors.bottomMargin: -box.ch / 2
    height: box.ch
    width: footText.implicitWidth
    color: box.background
    Text {
      id: footText
      text: " " + box.footer + " "
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      color: Tui.muted(Color.foreground, Color.background, 4.5)
    }
  }

  Item {
    id: inner
    anchors.fill: parent
    anchors.topMargin: box.ch * 1.25
    anchors.bottomMargin: box.ch * 0.5
    anchors.leftMargin: box.cw * 1.5
    anchors.rightMargin: box.cw * 1.5
    clip: true
  }
}
