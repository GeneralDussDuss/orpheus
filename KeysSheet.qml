import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "Tui.js" as Tui

// `?`: every key the player answers to, and the global hotkeys this run
// actually got (with the ones it did not, and why). j/k scroll, any of
// esc / ? / q closes.
//
// The host (the player window, the visualizer stage) provides cw, ch, accent,
// dim, bg, baseBg, fg, accentText, family, clock and refocus(): the metrics
// and colours the sheet draws with, and where the keys go when it closes.
Item {
  id: sheet

  property var host: null
  property bool shown: false
  // The section named here comes first, for a host whose own keys are the ones
  // wanted at a glance (the stage opens on "in the visualizer window").
  property string lead: ""

  anchors.fill: parent
  visible: opacity > 0
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
  z: 50

  // opening lands at the top at once; only the keys glide
  property bool snap: false
  function open() {
    snap = true; flick.contentY = 0; snap = false; shown = true; flick.forceActiveFocus()
    askHyprland()
  }
  function close() { shown = false; host.refocus() }

  readonly property bool hasKeys: typeof OrpheusKeys !== "undefined"

  // ---- the global hotkeys on Linux --------------------------------------------
  //
  // Omarchy's are Hyprland binds (hypr/orpheus.lua), so ask Hyprland what is
  // bound right now, each time the sheet opens: the answer follows a rebind, or
  // orpheus_bindings = false. Under the Lua config the dispatcher is an opaque
  // `__lua` and its arg an id, so the binds are told apart by description, the
  // names orpheus.lua registers them under.
  readonly property var hyprBinds: [
    ["Music", "the player: open or close"],
    ["Music visualizer", "the visualizer window: open or close"],
    ["Music widget", "the desktop widget: on or off"],
    ["Orpheus sign-in", "sign in to TIDAL"]
  ]
  // [{ combo, label, what }] once Hyprland has answered; null until then
  property var hyprRows: null
  property bool hyprFailed: false

  function askHyprland() {
    if (hasKeys || Qt.platform.os === "windows" || hyprProc.running) return
    hyprProc.running = true
  }
  // SHIFT=1 CAPS=2 CTRL=4 ALT=8 MOD2=16 (num lock) MOD3=32 MOD5=128 SUPER=64
  function comboOf(b) {
    var names = [[64, "super"], [4, "ctrl"], [8, "alt"], [1, "shift"]], out = []
    for (var i = 0; i < names.length; i++) if (b.modmask & names[i][0]) out.push(names[i][1])
    out.push(String(b.key).toLowerCase())
    return out.join("+")
  }
  function readBinds(text) {
    var all
    try { all = JSON.parse(text) } catch (e) { hyprFailed = true; return }
    // an error answer is JSON too, just not a list: say so, not "not bound"
    if (!Array.isArray(all)) { hyprFailed = true; return }
    var rows = []
    for (var i = 0; i < hyprBinds.length; i++) {
      var found = null
      for (var j = 0; j < all.length && !found; j++) if (all[j].description === hyprBinds[i][0]) found = all[j]
      rows.push({ combo: found ? comboOf(found) : "", label: hyprBinds[i][0].toLowerCase(), what: hyprBinds[i][1], bound: !!found })
    }
    hyprFailed = false
    hyprRows = rows
  }
  Process {
    id: hyprProc
    command: ["hyprctl", "binds", "-j"]
    stdout: StdioCollector { onStreamFinished: sheet.readBinds(text) }
    onExited: function(code) { if (code !== 0) sheet.hyprFailed = true }
  }

  // the sections, the lead one first
  readonly property var ordered: {
    if (lead === "") return sections
    var first = sections.filter(function(s) { return s[0] === lead })
    return first.concat(sections.filter(function(s) { return s[0] !== lead }))
  }

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
    ["visualizer", [["v", "cycle the player rail"], ["V", "open / close the visualizer window"], ["t", "cassette deck on / off"]]],
    ["in the visualizer window", [["l h  → ←", "next / previous style · in the deck: shuttle ± 10 s"], ["1-9  0  ⇧1-9", "pick a style (leaves the deck)"],
                                  ["g", "pilgrimage on / off"], ["n", "next leg · pilgrimage"], ["?", "this sheet"],
                                  ["t", "cassette deck / visualizer"], ["e", "eject · cassette deck only"], ["f", "fullscreen show / window"],
                                  ["p", "mini player on / off"], ["space", "play / pause"], ["esc", "close it"]]],
    ["mouse · player", [["click row", "select it"], ["dbl-click row", "play or open it"], ["right-click", "menu: queue, radio, link"],
                        ["click picture", "next rail visual · right-click back"], ["scroll picture", "step through visuals"],
                        ["‹ name ›", "step, or pick from a list"], ["click art · artist", "go to the album / artist"],
                        ["click up next", "play it now"], ["drag seek bar", "scrub; hover shows the time"],
                        ["vol", "click, drag or scroll"], ["drag top edge", "move the window"], ["eq", "click opens · right-click bypass"],
                        ["click a hint", "key hints are buttons too"], ["hover", "what it does, and its key"]]],
    ["mouse · visualizer, widget", [["click", "next style · right-click back"], ["scroll", "step through styles"],
                                    ["dbl-click show", "back to a window"],
                                    ["drag title", "move the floating widget, or the visualizer's window card"],
                                    ["dbl-click title", "visualizer window card: back to the centre"], ["drag a reel", "scrub the tape · scroll ± 5 s"],
                                    ["click a j-card track", "play it"], ["drop a .frag", "import it as a style"]]],
    ["menus", [["j k  ↓ ↑", "move"], ["⇥ ⇧⇥", "the same"], ["⏎  space", "run"], ["g G  home end", "first / last"], ["esc  q", "close"]]],
    ["video page", [["⇥", "next provider"], ["⏎", "watch"], ["a", "listen instead"], ["c", "hand over to curd"],
                    ["space", "pause the video"], ["l h  → ←", "seek the video"], ["F", "fullscreen"], ["x", "close the video"]]],
    ["equalizer", [["h l  ← →", "pick a band"], ["k j  ↑ ↓", "band up / down a step"], ["K J", "up / down coarse"], ["0  z", "zero the band / all"],
                   ["p  P", "next / previous preset"], ["b", "bypass"], ["]  [", "preamp up / down"], ["\\", "auto headroom"],
                   ["A", "find headphones (AutoEQ)"], ["x  X", "AutoEQ on / off · clear"],
                   ["drag  scroll", "set a band"], ["middle-click", "zero a band"], ["right-click", "bypass"]]],
    ["autoeq picker", [["type", "filter"], ["⏎", "apply"], ["↑ ↓", "move"], ["pgup pgdn", "page"],
                       ["ctrl+r", "refresh the index"], ["esc", "back to the bars"]]],
    ["lyrics", [["]  [", "sync later / earlier"], ["\\", "reset the sync"], ["m", "entrance: wave, rain, plain"], ["j k  ↓ ↑", "scroll"], ["g  G", "top / bottom"], ["click a line", "seek to that line"]]],
    ["stats", [["⇥ ⇧⇥  ] [", "next / previous range"], ["l h  → ←", "the same"], ["w", "wrapped"], ["r", "reload"],
               ["j k  ↓ ↑", "scroll"], ["pgdn pgup", "scroll a page"], ["g  G", "top / bottom"]]],
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

  readonly property color base: Commons.Color.background
  // As many columns as fit at a readable width (keys 13 cells, words ~25),
  // so a small window gets one long column rather than squeezed text.
  readonly property real gap: host.cw * 3
  readonly property int cols: Math.max(1, Math.min(3, Math.floor((box.width - host.cw * 2 + gap) / (host.cw * 40 + gap))))
  readonly property real colW: Math.floor((box.width - host.cw * 2 - gap * (cols - 1)) / cols)
  readonly property real keyW: host.cw * 15
  readonly property var columns: {
    var total = 0, i
    for (i = 0; i < ordered.length; i++) total += ordered[i][1].length + 2
    var share = total / cols, out = [[]], acc = 0
    for (i = 0; i < ordered.length; i++) {
      var n = ordered[i][1].length + 2
      if (acc > 0 && acc + n / 2 > share * out.length && out.length < cols) out.push([])
      out[out.length - 1].push(ordered[i])
      acc += n
    }
    return out
  }

  TuiBox {
    id: box
    anchors.centerIn: parent
    width: Math.min(parent.width - host.cw * 4, host.cw * 135)
    height: parent.height - host.ch * 3
    // it settles into place as it fades in, like the command palette
    scale: sheet.shown ? 1 : 0.985
    Behavior on scale { NumberAnimation { duration: Tui.STATE; easing.type: Tui.OUT } }
    transform: Translate {
      y: sheet.shown ? 0 : host.ch * 0.5
      Behavior on y { NumberAnimation { duration: Tui.STATE; easing.type: Tui.OUT } }
    }
    background: Qt.rgba(sheet.base.r, sheet.base.g, sheet.base.b, 1)
    title: "keys"
    hintItems: [{ k: "j/k", l: "scroll" }, { k: "esc", l: "close", run: function() { sheet.close() } }]
    focused: true
    flickable: flick
    clock: host.clock

    MouseArea { anchors.fill: parent }

    Flickable {
      id: flick
      anchors.fill: parent
      clip: true
      contentHeight: content.height
      boundsBehavior: Flickable.StopAtBounds
      flickDeceleration: Tui.FLICK.decel; maximumFlickVelocity: Tui.FLICK.vmax
      // keys glide; the wheel and a drag stay direct
      Behavior on contentY { enabled: !flick.moving && !sheet.snap; NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
      Keys.onPressed: function(e) {
        var k = e.key, t = e.text
        var step = host.ch * 3
        if (k === Qt.Key_Escape || t === "?" || t === "q") sheet.close()
        else if (k === Qt.Key_Down || t === "j") Tui.scrollTo(flick, contentY + step)
        else if (k === Qt.Key_Up || t === "k") Tui.scrollTo(flick, contentY - step)
        else if (k === Qt.Key_PageDown || k === Qt.Key_Space) Tui.scrollTo(flick, contentY + height * 0.8)
        else if (k === Qt.Key_PageUp) Tui.scrollTo(flick, contentY - height * 0.8)
        else if (t === "g") Tui.scrollTo(flick, 0)
        else if (t === "G") Tui.scrollTo(flick, contentHeight)
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
          visible: !sheet.hasKeys && !sheet.hyprRows
          text: sheet.hyprFailed ? "could not ask Hyprland (hyprctl binds); the binds live in hypr/orpheus.lua" : "asking Hyprland…"
          font.family: host.family; font.pixelSize: Style.font.body
          color: host.dim
        }
        Repeater {
          model: sheet.hasKeys ? [] : (sheet.hyprRows || [])
          Row {
            required property var modelData
            Text {
              width: host.cw * 22
              text: modelData.bound ? modelData.combo : "not bound"
              font.family: host.family; font.pixelSize: Style.font.body
              color: modelData.bound ? host.accentText : host.dim
            }
            Text {
              width: host.cw * 32
              text: modelData.label
              font.family: host.family; font.pixelSize: Style.font.body
              color: modelData.bound ? host.fg : host.dim
            }
            Text {
              text: modelData.bound ? modelData.what : "orpheus_bindings = false, or you rebound it"
              font.family: host.family; font.pixelSize: Style.font.caption
              color: host.dim
            }
          }
        }
        Text {
          visible: !sheet.hasKeys && !!sheet.hyprRows
          topPadding: host.ch * 0.3
          text: "the binds are registered by hypr/orpheus.lua"
          font.family: host.family; font.pixelSize: Style.font.caption
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
                color: Commons.Color.urgent
              }
            }
            Repeater {
              model: parent.misses
              Text {
                required property var modelData
                leftPadding: host.cw * 2
                text: "✕ " + modelData.combo + "  " + modelData.reason
                font.family: host.family; font.pixelSize: Style.font.caption
                color: Tui.mix(host.dim, Commons.Color.urgent, 0.35)
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
