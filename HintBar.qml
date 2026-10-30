import QtQuick
import qs.Commons
import "Tui.js" as Tui

// Key hints that are also buttons: `space play  n next  q close`. Each item is
// { k: key, l: label, run: function, tip: what it does }; one with a `run`
// takes the pointer and lights in the accent on hover, one without is just
// the hint it always was.
Row {
  id: bar

  property var items: []
  property color keyColor: Color.accent
  property color labelColor: Color.foreground
  property color hoverColor: keyColor
  property int pixelSize: Style.font.caption
  property bool interactive: true

  spacing: gap.advanceWidth
  TextMetrics { id: gap; font.family: Style.font.family; font.pixelSize: bar.pixelSize; text: "   " }

  Repeater {
    model: bar.items
    Text {
      id: cell
      required property var modelData
      readonly property bool live: bar.interactive && typeof modelData.run === "function"
      readonly property bool hot: live && ma.containsMouse
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(hot ? bar.hoverColor : bar.keyColor) + '">' + Tui.esc(modelData.k) + '</font>'
            + (modelData.l ? ' <font color="' + Tui.hex(hot ? bar.hoverColor : bar.labelColor) + '">' + Tui.esc(modelData.l) + '</font>' : "")
      font.family: Style.font.family
      font.pixelSize: bar.pixelSize
      font.underline: hot
      MouseArea {
        id: ma
        anchors.fill: parent
        anchors.margins: -3
        enabled: cell.live
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: cell.modelData.run()
        TuiTip { text: cell.modelData.tip || ""; key: !cell.modelData.tip ? "" : cell.modelData.tipKey !== undefined ? cell.modelData.tipKey : cell.modelData.k }
      }
    }
  }
}
