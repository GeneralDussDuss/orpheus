import QtQuick
import qs.Commons
import "Tui.js" as Tui

// Ctrl+K: every action in the player by name. Type a few letters of it, in
// order, anywhere in the words ("nxt", "vz orb", "thm nord"); ↑/↓ or ctrl+j/k
// pick, ⏎ runs, esc closes. The actions come from the host, built fresh each
// time this opens so toggles read the way they are right now.
Item {
  id: pal

  property var host: null
  property bool shown: false
  property var all: []            // [{ group, label, key, run }]
  property var hits: []           // indices into `all`, best first
  property int cursor: 0

  anchors.fill: parent
  visible: shown
  z: 50

  function open() {
    all = host.commands()
    input.text = ""
    filter()
    shown = true
    input.forceActiveFocus()
  }
  function close() {
    shown = false
    host.refocus()
  }
  function run(i) {
    var c = all[hits[i]]
    close()
    if (c) c.run()
  }

  // Subsequence match, scored: runs of consecutive letters and letters that
  // start a word count most, so "vo" finds "volume" before "visualizer · orb".
  function score(q, s) {
    s = s.toLowerCase()
    var total = 0, at = 0, run = 0
    for (var i = 0; i < q.length; i++) {
      var ch = q.charAt(i)
      if (ch === " ") { run = 0; continue }
      var j = s.indexOf(ch, at)
      if (j < 0) return -1
      var startOfWord = j === 0 || " ·/-:".indexOf(s.charAt(j - 1)) >= 0
      run = j === at && i > 0 ? run + 1 : 0
      total += 1 + run * 3 + (startOfWord ? 4 : 0) - Math.min(3, (j - at) * 0.1)
      at = j + 1
    }
    return total - s.length * 0.01
  }
  function filter() {
    var q = input.text.trim().toLowerCase(), out = []
    for (var i = 0; i < all.length; i++) {
      var sc = q ? score(q, all[i].group + " " + all[i].label) : 0
      if (sc >= 0) out.push({ i: i, s: sc })
    }
    if (q) out.sort(function(a, b) { return b.s - a.s || a.i - b.i })
    hits = out.map(function(x) { return x.i })
    cursor = 0
  }

  // the window behind, dimmed; a click outside closes
  Rectangle {
    anchors.fill: parent
    color: Tui.alpha(host.baseBg, 0.6)
    MouseArea { anchors.fill: parent; onClicked: pal.close() }
  }

  readonly property color base: Color.background

  TuiBox {
    id: box
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height * 0.12
    width: Math.min(parent.width - host.cw * 4, host.cw * 76)
    height: Math.min(parent.height * 0.76, host.ch * 26)
    background: Qt.rgba(pal.base.r, pal.base.g, pal.base.b, 1)
    title: "commands"
    keyHint: Tui.hints([["⏎", "run"], ["↑↓", "pick"], ["esc", "close"]], host.accentText, host.dim)
    footer: pal.hits.length + " of " + pal.all.length
    focused: true
    clock: host.clock

    MouseArea { anchors.fill: parent }   // keep clicks inside from closing it

    Row {
      id: prompt
      width: parent.width
      Text { text: "❯ "; font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText; font.bold: true }
      TextInput {
        id: input
        width: parent.width - host.cw * 3
        font.family: host.family; font.pixelSize: Style.font.body
        color: host.fg
        selectionColor: Tui.alpha(Color.accent, 0.35)
        cursorDelegate: Rectangle { width: host.cw; color: host.accent; opacity: 0.7 }
        onTextEdited: pal.filter()
        Keys.onPressed: function(e) {
          var k = e.key, ctrl = e.modifiers & Qt.ControlModifier
          if (k === Qt.Key_Escape) { pal.close(); e.accepted = true }
          else if (k === Qt.Key_Return || k === Qt.Key_Enter) { pal.run(pal.cursor); e.accepted = true }
          else if (k === Qt.Key_Down || (ctrl && (k === Qt.Key_J || k === Qt.Key_N))) { pal.cursor = Math.min(pal.hits.length - 1, pal.cursor + 1); e.accepted = true }
          else if (k === Qt.Key_Up || (ctrl && (k === Qt.Key_K || k === Qt.Key_P))) {
            // ctrl+k on an empty prompt closes, the way it opened
            if (ctrl && k === Qt.Key_K && !text) pal.close()
            else pal.cursor = Math.max(0, pal.cursor - 1)
            e.accepted = true
          }
          else if (k === Qt.Key_PageDown) { pal.cursor = Math.min(pal.hits.length - 1, pal.cursor + 8); e.accepted = true }
          else if (k === Qt.Key_PageUp) { pal.cursor = Math.max(0, pal.cursor - 8); e.accepted = true }
        }
        Text {
          visible: !parent.text
          text: "play, next, a style, a theme, settings…"
          font: parent.font
          color: host.dim
        }
      }
    }

    ListView {
      id: results
      anchors.top: prompt.bottom; anchors.topMargin: host.ch * 0.5
      anchors.bottom: parent.bottom
      width: parent.width
      clip: true
      model: pal.hits.length
      currentIndex: pal.cursor
      highlightFollowsCurrentItem: false
      boundsBehavior: Flickable.StopAtBounds
      onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
      highlight: Rectangle {
        width: results.width
        height: results.currentItem ? results.currentItem.height : 0
        y: results.currentItem ? results.currentItem.y : 0
        visible: !!results.currentItem
        color: host.cursorFill
        Rectangle { width: Math.max(2, host.cw * 0.3); height: parent.height; color: host.accent }
      }
      delegate: Item {
        id: hit
        required property int index
        readonly property var c: pal.all[pal.hits[index]] || ({})
        readonly property bool isCursor: index === pal.cursor
        width: ListView.view.width
        height: host.ch * 1.3
        Text {
          id: groupText
          x: host.cw
          anchors.verticalCenter: parent.verticalCenter
          width: host.cw * 11
          text: hit.c.group || ""
          font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
          color: hit.isCursor ? host.accentText : host.dim
        }
        Text {
          anchors.left: groupText.right
          anchors.right: keyText.left; anchors.rightMargin: host.cw
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: hit.c.label || ""
          font.family: host.family; font.pixelSize: Style.font.body
          color: hit.isCursor ? host.fg : Tui.mix(host.fg, host.dim, 0.35)
        }
        Text {
          id: keyText
          anchors.right: parent.right; anchors.rightMargin: host.cw
          anchors.verticalCenter: parent.verticalCenter
          text: hit.c.key || ""
          font.family: host.family; font.pixelSize: Style.font.caption
          color: hit.isCursor ? host.accentText : host.dim
        }
        MouseArea {
          anchors.fill: parent
          onClicked: { pal.cursor = hit.index; input.forceActiveFocus() }
          onDoubleClicked: pal.run(hit.index)
        }
      }
      Text {
        anchors.centerIn: parent
        visible: !pal.hits.length
        text: "nothing by that name"
        font.family: host.family; font.pixelSize: Style.font.body
        color: host.dim
      }
    }
  }
}
