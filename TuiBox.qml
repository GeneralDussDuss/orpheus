import QtQuick
import QtQuick.Effects
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
  // Clickable hints, drawn in place of keyHint: [{ k, l, run, tip }] (HintBar).
  property var hintItems: []
  // Drawn just after the title on the top edge (the player's viz switcher).
  property Component titleExtra: null
  property string footer: ""
  property bool focused: false
  property color background: Color.background
  property color line: Tui.ensure(Tui.mix(Color.foreground, Color.background, 0.72), Color.background, 1.6)
  property color text: Color.foreground
  property real clock: -1               // engine heartbeat (seconds), for callers that animate content
  property real glow: 0                 // bloom budget (Tui.bloom) for the focused edge; 0 = none (menus, sheets)
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

  // Focused: a soft bloom around the border, breathing with it. The halo is a
  // fixed accent ring blurred once; only its opacity follows the breath, so
  // the breathing costs a composite per frame, never a re-blur. It sits
  // behind the frame, whose fill hides the inner half: light spills outward.
  Loader {
    active: box.focused && box.glow > 0
    anchors.fill: parent
    anchors.topMargin: box.ch / 2
    sourceComponent: Item {
      Rectangle {
        id: ring
        anchors.fill: parent
        color: "transparent"
        border.width: 3
        border.color: Color.accent
        visible: false
      }
      MultiEffect {
        source: ring
        anchors.fill: ring
        autoPaddingEnabled: true
        blurEnabled: true
        blur: 1
        blurMax: 16
        brightness: 0.15
        opacity: box.glow * (0.35 + 0.65 * box.breath)
      }
    }
  }

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
    id: titleExtraBox
    visible: box.titleExtra !== null
    x: box.cw + (box.title !== "" ? titleText.implicitWidth : 0)
    height: box.ch
    width: titleExtraLoader.item ? titleExtraLoader.item.implicitWidth : 0
    color: box.background
    Loader { id: titleExtraLoader; sourceComponent: box.titleExtra; anchors.verticalCenter: parent.verticalCenter }
  }

  Rectangle {
    visible: box.hintItems.length > 0
    anchors.right: parent.right
    anchors.rightMargin: box.cw
    height: box.ch
    width: hintBar.implicitWidth + hintPad.advanceWidth * 2
    color: box.background
    TextMetrics { id: hintPad; font.family: Style.font.family; font.pixelSize: Style.font.caption; text: " " }
    HintBar {
      id: hintBar
      x: hintPad.advanceWidth
      anchors.verticalCenter: parent.verticalCenter
      items: box.hintItems
      readonly property color opaque: Qt.rgba(box.background.r, box.background.g, box.background.b, 1)
      keyColor: Tui.ensure(Color.accent, opaque, 4.5)
      labelColor: Tui.muted(Color.foreground, opaque, 4.5)
      hoverColor: Tui.ensure(Color.accent, opaque, 4.5)
    }
  }

  Rectangle {
    visible: box.keyHint !== "" && box.hintItems.length === 0
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
