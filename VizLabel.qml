import QtQuick
import qs.Commons
import "Tui.js" as Tui

// The name of the visualizer, centred over it for a moment after a change,
// so a click that swapped the picture also says what it swapped to.
//   VizLabel { anchors.fill: plane; id: lbl }  ...  lbl.flash("prism")
Item {
  id: lbl

  property int pixelSize: Style.font.body + 2
  property string text: ""

  readonly property color bgc: Color.background
  readonly property color bg: Qt.rgba(bgc.r, bgc.g, bgc.b, 1)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)

  function flash(name) {
    text = String(name || "").toLowerCase()
    fade.restart()
  }

  Rectangle {
    id: chip
    anchors.centerIn: parent
    opacity: 0
    visible: opacity > 0.01
    width: name.implicitWidth + fm.advanceWidth("M") * 3
    height: name.implicitHeight + fm.height * 0.6
    color: Qt.rgba(lbl.bg.r, lbl.bg.g, lbl.bg.b, 0.82)
    border.width: 1
    border.color: Tui.alpha(lbl.accentText, 0.7)
    FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: lbl.pixelSize }
    Text {
      id: name
      anchors.centerIn: parent
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(lbl.accentText) + '">╱╱</font> ' + Tui.esc(lbl.text)
      font.family: Style.font.family
      font.pixelSize: lbl.pixelSize
      font.bold: true
      font.letterSpacing: 1
      color: Tui.ensure(Color.foreground, lbl.bg, 7)
    }
  }

  SequentialAnimation {
    id: fade
    NumberAnimation { target: chip; property: "opacity"; to: 1; duration: 140; easing.type: Easing.OutCubic }
    PauseAnimation { duration: 900 }
    NumberAnimation { target: chip; property: "opacity"; to: 0; duration: 500; easing.type: Easing.InOutSine }
  }
}
