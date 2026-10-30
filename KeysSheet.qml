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
  visible: shown
  z: 50

  function open() { shown = true; flick.contentY = 0; flick.forceActiveFocus() }
  function close() { shown = false; host.refocus() }

  readonly property bool hasKeys: typeof OrpheusKeys !== "undefined"

  // [title, [[keys, what], ...]]
  readonly property var sections: [
    ["anywhere", [["ctrl+k", "command palette"], ["?", "this sheet"], [",", "settings"], ["/", "search"],
                  ["1-9", "library sections"], ["e", "equalizer"], ["L", "lyrics"], ["esc ⌫", "back"], ["q  ctrl+w", "close the player"]]],
    ["playback", [["space", "play / pause"], ["n  p", "next / previous"], ["h l  ← →", "seek 10 s"], ["+ -", "volume"],
                  ["s", "shuffle"], ["r", "repeat"], ["F", "like what is playing"], ["y  Y", "copy link / universal link"]]],
    ["lists", [["j k  ↑ ↓", "move"], ["pgup pgdn", "move 10"], ["g  G", "top / bottom"], ["⏎", "open or play"],
               ["a", "add to queue"], ["f", "like the row"], ["P  S", "play all / shuffle all"]]],
    ["visualizer", [["v", "cycle the player rail"], ["V", "open / close the visualizer"],
                    ["a", "album art in the visuals on / off (in the visualizer)"], ["f", "fullscreen show (in the visualizer)"]]],
    ["video page", [["⇥", "next provider"], ["⏎", "watch"], ["a", "listen instead"], ["c", "hand over to curd"],
                    ["space", "pause the video"], ["h l", "seek the video"], ["F", "fullscreen"], ["x", "close the video"]]],
    ["equalizer", [["h l", "pick a band"], ["j k", "± a step"], ["J K", "± coarse"], ["0  z", "zero band / all"],
                   ["p  P", "presets"], ["b", "bypass"], ["[ ]", "preamp"], ["\\", "auto headroom"]]],
    ["lyrics", [["[ ]", "nudge the sync"], ["\\", "reset the sync"], ["m", "layout"], ["j k", "scroll"]]],
    ["settings", [["⇥  ⇧⇥", "section"], ["j k", "move"], ["h l", "change a value"], ["⏎", "set / rebind"],
                  ["x", "hotkey off"], ["d", "hotkey default"]]],
    ["command palette", [["type", "filter"], ["↑ ↓  ctrl+j/k", "pick"], ["⏎", "run"], ["esc", "close"]]]
  ]

  Rectangle {
    anchors.fill: parent
    color: Tui.alpha(host.baseBg, 0.6)
    MouseArea { anchors.fill: parent; onClicked: sheet.close() }
  }

  readonly property color base: Color.background
  readonly property real colW: host.cw * 40

  TuiBox {
    id: box
    anchors.centerIn: parent
    width: Math.min(parent.width - host.cw * 4, sheet.colW * 2 + host.cw * 7)
    height: parent.height - host.ch * 3
    background: Qt.rgba(sheet.base.r, sheet.base.g, sheet.base.b, 1)
    title: "keys"
    keyHint: Tui.hints([["j/k", "scroll"], ["esc", "close"]], host.accentText, host.dim)
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

        Flow {
          width: parent.width
          spacing: host.cw * 3
          Repeater {
            model: sheet.sections
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
                    width: host.cw * 15
                    text: modelData[0]
                    font.family: host.family; font.pixelSize: Style.font.body
                    color: host.accentText
                  }
                  Text {
                    width: sheet.colW - host.cw * 15
                    elide: Text.ElideRight
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
