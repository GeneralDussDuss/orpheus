import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
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
  property color background: Commons.Color.background
  property color line: Tui.ensure(Tui.mix(Commons.Color.foreground, Commons.Color.background, 0.72), Commons.Color.background, 1.6)
  property color text: Commons.Color.foreground
  property real clock: -1               // engine heartbeat (seconds), for callers that animate content
  property real glow: 0                 // bloom budget (Tui.bloom) for the focused edge; 0 = none (menus, sheets)
  property Flickable flickable: null
  default property alias content: inner.data

  readonly property color opaqueBg: Qt.rgba(background.r, background.g, background.b, 1)
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height
  // Focused: the border breathes toward the accent on the shared clock.
  readonly property real breath: focused && clock >= 0 ? 0.5 + 0.5 * Math.sin(clock * 1.6) : 1
  readonly property color edge: focused ? Tui.mix(line, Commons.Color.accent, 0.55 + 0.45 * breath) : line

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }

  // Title decode when the box is born (~0.35 s), and again when the title changes.
  // Runs on the animation driver, so it always settles even if nothing else moves.
  // The noise churns at ~22 Hz off the progress, like ScrambleText.
  property real decodeProgress: 0
  property int bornAt: 7
  readonly property int churn: Math.floor(decodeProgress * decodeAnim.duration / 45)
  NumberAnimation on decodeProgress { id: decodeAnim; from: 0; to: 1; duration: Math.round(Tui.DECODE * 0.67); running: true }
  onTitleChanged: decodeAnim.restart()
  // Decode the title again (the boot screen hands over to a page that's already
  // settled: replaying makes the reveal land on something moving).
  function replay() { bornAt = (bornAt + 1) % 97; decodeAnim.restart() }

  // The title fits between the corner and the hints: the target is cut to the
  // cells that are free BEFORE decoding, so the fixed-width decode holds.
  // (Counted in the title's own cell: `cw` measures the default font, wider.)
  TextMetrics { id: titleCell; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; text: "MMMMMMMMMM" }
  readonly property real titleCellW: titleCell.advanceWidth > 0 ? titleCell.advanceWidth / 10 : cw
  readonly property real rightUsed: (hintItems.length > 0 ? hintBar.implicitWidth + hintPad.advanceWidth * 2
                                     : keyHint !== "" ? keyText.implicitWidth : 0)
                                    + (titleExtra !== null ? titleExtraBox.width : 0)
  readonly property int titleCells: Math.max(4, Math.floor((width - cw * 2 - rightUsed) / Math.max(1, titleCellW)) - 3)

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
        border.color: Commons.Color.accent
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
    clip: true
    color: box.background
    Text {
      id: titleText
      text: " " + Tui.decode(Tui.fit(box.title, box.titleCells), box.decodeProgress, box.bornAt + box.churn) + " "
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: box.focused
      color: box.focused ? Tui.ensure(Commons.Color.accent, box.opaqueBg, 4.5) : Tui.ensure(box.text, box.opaqueBg, 4.5)
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
      keyColor: Tui.ensure(Commons.Color.accent, box.opaqueBg, 4.5)
      labelColor: Tui.muted(Commons.Color.foreground, box.opaqueBg, 4.5)
      hoverColor: Tui.ensure(Commons.Color.accent, box.opaqueBg, 4.5)
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
      color: box.focused ? Tui.ensure(Commons.Color.accent, box.opaqueBg, 4.5) : Tui.muted(Commons.Color.foreground, box.opaqueBg, 4.5)
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
      color: Tui.muted(Commons.Color.foreground, box.opaqueBg, 4.5)
    }
  }

  Rectangle {
    id: scrollThumb
    readonly property real trackTop: box.ch / 2 + 2
    readonly property real trackH: Math.max(0, box.height - trackTop - 2)
    readonly property real ratio: box.flickable ? Math.max(0.08, Math.min(1, box.flickable.visibleArea.heightRatio)) : 1
    readonly property real pos: box.flickable ? Math.max(0, Math.min(1 - ratio, box.flickable.visibleArea.yPosition)) : 0
    visible: !!box.flickable && box.flickable.visible && box.flickable.contentHeight > box.flickable.height + 1
    x: box.width - 2
    y: Math.round(trackTop + pos * trackH)
    width: 2
    height: Math.max(Math.round(box.ch * 0.8), Math.round(ratio * trackH))
    color: box.focused ? Tui.ensure(Commons.Color.accent, box.opaqueBg, 3) : Tui.mix(box.line, Commons.Color.accent, 0.45)
    opacity: 0.85
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
