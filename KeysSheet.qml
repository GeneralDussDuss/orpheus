import QtQuick
import qs.Commons
import "Tui.js" as Tui

// `?`: every key the player answers to, and the global hotkeys this run
// actually got (with the ones it did not, and why). j/k scroll, any of
// esc / ? / q closes.
Item {
  id: sheet

  property var host: null
  property bool shown: false

  anchors.fill: parent
  visible: opacity > 0
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.InOutCubic } }
  z: 50

  function open() { shown = true; flick.contentY = 0; flick.forceActiveFocus() }
  function close() { shown = false; host.refocus() }

  readonly property bool hasKeys: typeof OrpheusKeys !== "undefined"

  // [title, [[keys, what], ...]], checked against the handlers: Library.qml
  // handleKey / videoKey / the list, Stage.qml handleKey, EqPane, LyricsPane,
  // StatsPane, SettingsPane, LoginPane, TuiMenu, CommandPalette and this sheet.
  // Keep it that way: a key listed here that does nothing is worse than none.
  readonly property var sections: [
    ["anywhere in the player", [["ctrl+k", "command palette"], ["?", "this sheet"], [",", "settings"], ["/", "search"],
                  ["1-9", "library sections"], ["e", "equalizer"], ["L", "lyrics"], ["esc  ⌫", "back"], ["q  ctrl+w", "close the player"]]],
    ["playback", [["space", "play / pause"], ["n  p", "next / previous track"], ["l  h  → ←", "seek ± 10 s"], ["+  -", "volume ± 5"],
                  ["s", "shuffle"], ["r", "repeat: off, all, one"], ["F", "like what is playing"], ["y  Y", "copy link / universal link"]]],
    ["lists", [["j k  ↓ ↑", "move"], ["pgdn pgup", "move 10"], ["g  G", "top / bottom"], ["⏎", "open or play"],
               ["a", "play the row next"], ["f", "like the row"], ["P  S", "play / shuffle the page"]]],
    ["search box", [["type", "search as you type"], ["↓  esc", "to the results"], ["⏎", "open the selected result"]]],
    ["visualizer", [["v", "cycle the player rail"], ["V", "open / close the visualizer window"]]],
    ["in the visualizer window", [["l h  → ←", "next / previous style"], ["1-8", "pick a style"], ["f", "fullscreen show / window"],
                                  ["p", "mini player on / off"], ["space", "play / pause"], ["esc", "close it"]]],
    ["mouse · player", [["click row", "select it"], ["dbl-click row", "play or open it"], ["right-click", "menu: queue, radio, link"],
                        ["click picture", "next rail visual · right-click back"], ["scroll picture", "step through visuals"],
                        ["‹ name ›", "step, or pick from a list"], ["click art · artist", "go to the album / artist"],
                        ["click up next", "play it now"], ["drag seek bar", "scrub; hover shows the time"],
                        ["vol", "click, drag or scroll"], ["eq", "click opens · right-click bypass"],
                        ["click a hint", "key hints are buttons too"], ["hover", "what it does, and its key"]]],
    ["mouse · visualizer, widget", [["click", "next style · right-click back"], ["scroll", "step through styles"],
                                    ["dbl-click show", "back to a window"]]],
    ["menus", [["j k  ↓ ↑", "move"], ["⇥ ⇧⇥", "the same"], ["⏎  space", "run"], ["g G  home end", "first / last"], ["esc  q", "close"]]],
    ["video page", [["⇥", "next provider"], ["⏎", "watch"], ["a", "listen instead"], ["c", "hand over to curd"],
                    ["space", "pause the video"], ["l h  → ←", "seek the video"], ["F", "fullscreen"], ["x", "close the video"]]],
    ["equalizer", [["h l  ← →", "pick a band"], ["k j  ↑ ↓", "band up / down a step"], ["K J", "up / down coarse"], ["0  z", "zero the band / all"],
                   ["p  P", "next / previous preset"], ["b", "bypass"], ["]  [", "preamp up / down"], ["\\", "auto headroom"],
                   ["drag  scroll", "set a band"], ["middle-click", "zero a band"], ["right-click", "bypass"]]],
    ["lyrics", [["]  [", "sync later / earlier"], ["\\", "reset the sync"], ["m", "entrance: wave, rain, plain"], ["j k  ↓ ↑", "scroll"]]],
    ["stats", [["⇥ ⇧⇥  ] [", "next / previous range"], ["l h  → ←", "the same"], ["w", "wrapped"], ["r", "reload"],
               ["j k  ↓ ↑", "scroll"], ["pgdn pgup", "scroll a page"], ["g", "top"]]],
    ["settings", [["⇥  ⇧⇥  ] [", "section"], ["j k  ↓ ↑", "move"], ["pgdn pgup", "move 8"], ["g G  home end", "first / last"],
                  ["l h  → ←", "change a value"], ["⏎", "set, edit or rebind"],
                  ["d", "back to the default"], ["x  del", "hotkey off / clear a text"], ["/  ctrl+f", "search every setting"], ["esc", "clear the search, then back"],
                  ["click", "step · right-click back · dbl-click edit"]]],
    ["sign in", [["l", "sign in with a link"], ["h", "hi-res sign-in"], ["o", "sign out"], ["esc", "back, once signed in"],
                 ["q  ctrl+w", "close the player"]]],
    ["command palette", [["type", "filter"], ["↓ ↑", "pick"], ["ctrl+j/k ctrl+n/p", "the same"], ["pgdn pgup", "move 8"],
                         ["⏎  click", "run"], ["esc  ctrl+k", "close"]]],
    ["this sheet", [["j k  ↓ ↑", "scroll"], ["space pgdn pgup", "a page"], ["g  G", "top / bottom"], ["esc  ?  q", "close"]]]
  ]

  Rectangle {
    anchors.fill: parent
    color: Tui.alpha(host.baseBg, 0.6)
    MouseArea { anchors.fill: parent; onClicked: sheet.close() }
  }

  readonly property color base: Color.background
  // As many columns as fit at a readable width (keys 13 cells, words ~25),
  // so a small window gets one long column rather than squeezed text.
  readonly property real gap: host.cw * 3
  readonly property int cols: Math.max(1, Math.min(3, Math.floor((box.width - host.cw * 2 + gap) / (host.cw * 40 + gap))))
  readonly property real colW: Math.floor((box.width - host.cw * 2 - gap * (cols - 1)) / cols)
  readonly property real keyW: host.cw * 15
  readonly property var columns: {
    var total = 0, i
    for (i = 0; i < sections.length; i++) total += sections[i][1].length + 2
    var share = total / cols, out = [[]], acc = 0
    for (i = 0; i < sections.length; i++) {
      var n = sections[i][1].length + 2
      if (acc > 0 && acc + n / 2 > share * out.length && out.length < cols) out.push([])
      out[out.length - 1].push(sections[i])
      acc += n
    }
    return out
  }

  TuiBox {
    id: box
    anchors.centerIn: parent
    width: Math.min(parent.width - host.cw * 4, host.cw * 135)
    height: parent.height - host.ch * 3
    background: Qt.rgba(sheet.base.r, sheet.base.g, sheet.base.b, 1)
    title: "keys"
    hintItems: [{ k: "j/k", l: "scroll" }, { k: "esc", l: "close", run: function() { sheet.close() } }]
    focused: true
    clock: host.clock

    MouseArea { anchors.fill: parent }

    Flickable {
      id: flick
      anchors.fill: parent
      clip: true
      contentHeight: content.height
      boundsBehavior: Flickable.StopAtBounds
      Keys.onPressed: function(e) {
        var k = e.key, t = e.text
        var step = host.ch * 3, maxY = Math.max(0, contentHeight - height)
        if (k === Qt.Key_Escape || t === "?" || t === "q") sheet.close()
        else if (k === Qt.Key_Down || t === "j") contentY = Math.min(maxY, contentY + step)
        else if (k === Qt.Key_Up || t === "k") contentY = Math.max(0, contentY - step)
        else if (k === Qt.Key_PageDown || k === Qt.Key_Space) contentY = Math.min(maxY, contentY + height * 0.8)
        else if (k === Qt.Key_PageUp) contentY = Math.max(0, contentY - height * 0.8)
        else if (t === "g") contentY = 0
        else if (t === "G") contentY = maxY
        e.accepted = true
      }

      Column {
        id: content
        width: flick.width
        spacing: host.ch * 0.6

        // newspaper columns: sections in reading order, each column filled to
        // about an even share of the lines before the next one starts
        Row {
          width: parent.width
          spacing: sheet.gap
          Repeater {
            model: sheet.columns
            Column {
              required property var modelData
              width: sheet.colW
              Repeater {
                model: modelData
            Column {
              required property var modelData
              width: sheet.colW
              Text {
                width: parent.width
                clip: true
                textFormat: Text.StyledText
                text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + Tui.esc(modelData[0])
                      + ' <font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(80) + '</font>'
                font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
                color: host.dim
                bottomPadding: host.ch * 0.2
              }
              Repeater {
                model: modelData[1]
                Row {
                  required property var modelData
                  Text {
                    width: sheet.keyW
                    text: modelData[0]
                    font.family: host.family; font.pixelSize: Style.font.body
                    color: host.accentText
                  }
                  Text {
                    width: sheet.colW - sheet.keyW
                    wrapMode: Text.WordWrap
                    text: modelData[1]
                    font.family: host.family; font.pixelSize: Style.font.body
                    color: host.fg
                  }
                }
              }
              Item { width: 1; height: host.ch * 0.6 }
            }
              }
            }
          }
        }

        // The global hotkeys, as registered right now.
        Text {
          width: parent.width
          clip: true
          textFormat: Text.StyledText
          text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> global · work from any app'
                + ' <font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
          font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
          color: host.dim
        }
        Text {
          visible: !sheet.hasKeys
          text: "on Omarchy these are Hyprland binds: see hypr/ in the plugin"
          font.family: host.family; font.pixelSize: Style.font.body
          color: host.dim
        }
        Repeater {
          model: sheet.hasKeys ? OrpheusKeys.bindings : []
          Column {
            required property var modelData
            readonly property var misses: (modelData.tried || []).filter(function(t) { return !t.ok && t.reason && t.reason !== "spare" })
            Row {
              Text {
                width: host.cw * 22
                text: modelData.state === "active" ? modelData.combo : modelData.state === "off" ? "off" : "—"
                font.family: host.family; font.pixelSize: Style.font.body
                color: modelData.state === "active" ? host.accentText : host.dim
              }
              Text {
                width: host.cw * 32
                text: modelData.label
                font.family: host.family; font.pixelSize: Style.font.body
                color: modelData.state === "active" ? host.fg : host.dim
              }
              Text {
                text: modelData.state === "active" ? "" : modelData.state === "off" ? "switched off" : "none of its combos registered"
                font.family: host.family; font.pixelSize: Style.font.caption
                color: Color.urgent
              }
            }
            Repeater {
              model: parent.misses
              Text {
                required property var modelData
                leftPadding: host.cw * 2
                text: "✕ " + modelData.combo + "  " + modelData.reason
                font.family: host.family; font.pixelSize: Style.font.caption
                color: Tui.mix(host.dim, Color.urgent, 0.35)
              }
            }
          }
        }
        Text {
          visible: sheet.hasKeys
          topPadding: host.ch * 0.3
          text: "rebind them in settings ( , then ⇥ to hotkeys ) or in config.json under \"hotkeys\""
          font.family: host.family; font.pixelSize: Style.font.caption
          color: host.dim
        }
      }
    }
  }
}
