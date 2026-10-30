import QtQuick
import qs.Commons
import "Tui.js" as Tui

// A context menu in a box: right-click a row, or the switcher's name.
//
//   menu.popup(item, x, y, "track", [{ label: "play", key: "⏎", run: fn }, { sep: true }, ...])
//
// j/k or ↑/↓ move, ⏎ runs, esc closes; the pointer picks and clicks. A click
// anywhere outside closes it without doing anything. Entries may carry
// `on: true` (marked as the current choice) or `enabled: false` (shown, inert).
Item {
  id: menu

  property var entries: []
  property string heading: ""
  property int cursor: 0
  property bool shown: false
  signal closed()

  anchors.fill: parent
  visible: shown
  z: 60

  readonly property color bgc: Color.background
  readonly property color bg: Qt.rgba(bgc.r, bgc.g, bgc.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Color.accent, bg, 3)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height

  function usable(i) { var e = entries[i]; return !!e && !e.sep && e.enabled !== false }
  function step(d) {
    var i = cursor
    for (var n = 0; n < entries.length; n++) {
      i = (i + d + entries.length) % entries.length
      if (usable(i)) { cursor = i; return }
    }
  }

  // Open at (x, y) in `from`'s coordinates, kept inside the window.
  function popup(from, x, y, title, list) {
    entries = list || []
    heading = title || ""
    cursor = -1
    step(1)
    // a picker opens on what is chosen now, so j/k move from there
    for (var i = 0; i < entries.length; i++) if (entries[i].on && usable(i)) { cursor = i; break }
    var p = from ? from.mapToItem(menu, x, y) : Qt.point(x, y)
    box.x = Math.round(Math.max(cw * 0.5, Math.min(width - box.width - cw * 0.5, p.x)))
    box.y = Math.round(Math.max(ch * 0.5, Math.min(height - box.height - ch * 0.5, p.y)))
    shown = true
    keys.forceActiveFocus()
  }
  function close() {
    if (!shown) return
    shown = false
    closed()
  }
  function run(i) {
    if (!usable(i)) return
    var e = entries[i]
    close()
    if (e.run) e.run()
  }

  // Outside: any button closes, and nothing underneath gets the click.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onPressed: menu.close()
    onWheel: menu.close()
  }

  Item {
    id: keys
    focus: true
    Keys.onPressed: function(e) {
      var k = e.key, t = e.text
      if (k === Qt.Key_Escape || t === "q") menu.close()
      else if (k === Qt.Key_Down || t === "j" || k === Qt.Key_Tab) menu.step(1)
      else if (k === Qt.Key_Up || t === "k" || k === Qt.Key_Backtab) menu.step(-1)
      else if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Space) menu.run(menu.cursor)
      else if (k === Qt.Key_Home || t === "g") { menu.cursor = -1; menu.step(1) }
      else if (k === Qt.Key_End || t === "G") { menu.cursor = menu.entries.length; menu.step(-1) }
      e.accepted = true
    }
  }

  TuiBox {
    id: box
    readonly property real labelW: {
      var w = 0
      for (var i = 0; i < menu.entries.length; i++) w = Math.max(w, String(menu.entries[i].label || "").length)
      return w
    }
    readonly property real keyW: {
      var w = 0
      for (var i = 0; i < menu.entries.length; i++) w = Math.max(w, String(menu.entries[i].key || "").length)
      return w
    }
    width: Math.round(menu.cw * (Math.max(box.labelW + 3 + (box.keyW ? box.keyW + 4 : 0), menu.heading.length + 6) + 3))
    height: Math.round(col.implicitHeight + menu.ch * 1.9)
    background: menu.bg
    title: menu.heading
    focused: true
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }   // inside the box is not "outside"

    Column {
      id: col
      width: parent.width
      Repeater {
        model: menu.entries
        Item {
          id: row
          required property var modelData
          required property int index
          readonly property bool isCursor: index === menu.cursor
          readonly property bool live: !modelData.sep && modelData.enabled !== false
          width: col.width
          height: modelData.sep ? menu.ch * 0.6 : menu.ch * 1.25
          Rectangle {
            visible: !!row.modelData.sep
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width; height: 1
            color: Tui.mix(menu.dim, menu.bg, 0.5)
          }
          Rectangle {
            visible: row.isCursor
            anchors.fill: parent
            anchors.leftMargin: -menu.cw * 0.5; anchors.rightMargin: -menu.cw * 0.5
            color: Tui.alpha(Color.accent, 0.16)
            Rectangle { width: Math.max(2, menu.cw * 0.3); height: parent.height; color: menu.accent }
          }
          Text {
            visible: !row.modelData.sep
            x: menu.cw * 0.6
            anchors.verticalCenter: parent.verticalCenter
            text: (row.modelData.on ? "● " : "  ") + (row.modelData.label || "")
            font.family: Style.font.family; font.pixelSize: Style.font.body
            font.bold: row.modelData.on === true
            color: !row.live ? Tui.mix(menu.dim, menu.bg, 0.4)
                 : row.modelData.on ? menu.accentText : row.isCursor ? menu.fg : Tui.mix(menu.fg, menu.dim, 0.3)
          }
          Text {
            visible: !row.modelData.sep && !!row.modelData.key
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.key || ""
            font.family: Style.font.family; font.pixelSize: Style.font.caption
            color: row.isCursor ? menu.accentText : menu.dim
          }
          MouseArea {
            anchors.fill: parent
            enabled: row.live
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onContainsMouseChanged: if (containsMouse) menu.cursor = row.index
            onClicked: menu.run(row.index)
          }
        }
      }
    }
  }
}
