import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// Settings, as a page of the player: everything the tray menu and config.json
// used to be the only way to reach.
//
// Keyboard first, like the equalizer: ⇥ moves between sections, j/k between
// rows, h/l changes a value in place, ⏎ sets or toggles. Every change is written
// straight to config.json (or to the theme / the hotkeys), so there is no save
// step to forget. Anything the pane does not use goes to the window's own keys.
Rectangle {
  id: pane

  property var host: null
  readonly property var engine: host ? host.engine : null
  readonly property var api: host ? host.api : null

  // Opaque, for the same reason as the equalizer: Color.background carries alpha.
  readonly property color base: Color.background
  color: Qt.rgba(base.r, base.g, base.b, 1)
  focus: true

  MouseArea { anchors.fill: parent; onPressed: function(m) { pane.forceActiveFocus(); m.accepted = false } }

  // Desktop-only pieces: Omarchy's own Color has no theme list, and the global
  // hotkeys there are Hyprland binds, so both sections say so instead.
  readonly property bool hasThemes: typeof Color.themeList !== "undefined" && Color.themeList !== null
  readonly property bool hasKeys: typeof OrpheusKeys !== "undefined"
  readonly property var keys: hasKeys ? OrpheusKeys : null

  readonly property var sections: [
    { id: "theme", label: "theme" },
    { id: "viz", label: "visualizer" },
    { id: "widget", label: "widget" },
    { id: "show", label: "show mode" },
    { id: "hotkeys", label: "hotkeys" },
    { id: "system", label: "system" }
  ]
  property int section: 0
  property int cursor: 0
  property string editing: ""        // the hotkey action being rebound, if any

  readonly property var cfg: engine ? engine.config : ({})
  readonly property var styles: engine ? engine.styles : []
  function styleName(s) { return s === "off" ? "album art" : (engine && engine.styleLabels[s] || s) }

  // ---- rows ----------------------------------------------------------------
  //
  // Plain objects; every value is read back through value() so the page follows
  // config.json when it changes underneath (hand edits, the tray, a hotkey).
  readonly property var rows: {
    var id = sections[section].id
    var r = []
    if (id === "theme") {
      if (!hasThemes) return [{ kind: "note", label: "themes follow Omarchy here · omarchy-theme-set" }]
      r.push({ kind: "action", id: "builder", label: "theme builder…", hint: "make your own palette" })
      var list = Color.themeList || [], group = ""
      for (var i = 0; i < list.length; i++) {
        if (list[i].group !== group) { group = list[i].group; r.push({ kind: "header", label: group.toLowerCase() }) }
        r.push({ kind: "theme", id: list[i].name, label: list[i].label })
      }
    } else if (id === "viz") {
      r.push({ kind: "choice", id: "style", label: "visualizer style", options: styles })
      r.push({ kind: "choice", id: "railViz", label: "player rail", options: ["off"].concat(styles), hint: "v cycles it" })
      r.push({ kind: "choice", id: "fps", label: "frame rate", options: [30, 60, 90, 120] })
      r.push({ kind: "choice", id: "bloom", label: "bloom", options: ["off", "subtle", "full"], hint: "dark themes" })
      r.push({ kind: "toggle", id: "syncViz", label: "widget follows the visualizer" })
      r.push({ kind: "toggle", id: "stage", label: "visualizer window open", hint: "V" })
    } else if (id === "widget") {
      r.push({ kind: "toggle", id: "widget.enabled", label: "desktop widget" })
      r.push({ kind: "choice", id: "widget.style", label: "widget style", options: ["compact", "full"] })
      r.push({ kind: "choice", id: "widget.corner", label: "widget corner", options: ["top-left", "top-right", "bottom-left", "bottom-right"] })
      r.push({ kind: "choice", id: "widget.viz", label: "widget visualizer", options: styles })
      r.push({ kind: "toggle", id: "miniPlayer", label: "mini player on the stage" })
    } else if (id === "show") {
      r.push({ kind: "choice", id: "placement", label: "visualizer as", options: engine && engine.placements ? engine.placements : ["overlay", "desktop"] })
      var mons = [""]
      var scr = Quickshell.screens || []
      for (var s = 0; s < scr.length; s++) if (scr[s] && scr[s].name) mons.push(scr[s].name)
      r.push({ kind: "choice", id: "showMonitor", label: "show on screen", options: mons })
      r.push({ kind: "toggle", id: "autoStyle", label: "switch styles on drops" })
      r.push({ kind: "toggle", id: "trackTitle", label: "track title fades in" })
      r.push({ kind: "toggle", id: "lyricsOverViz", label: "lyrics over the visualizer" })
      r.push({ kind: "toggle", id: "autoQuality", label: "lower resolution when fps drops" })
      r.push({ kind: "toggle", id: "showFps", label: "show the frame rate" })
    } else if (id === "hotkeys") {
      if (!hasKeys) return [{ kind: "note", label: "global keys are Hyprland binds here · see hypr/" }]
      var b = keys.bindings || []
      for (var k = 0; k < b.length; k++) r.push({ kind: "hotkey", id: b[k].action, label: b[k].label, row: b[k] })
      r.push({ kind: "action", id: "hotkeysReset", label: "all back to defaults" })
    } else if (id === "system") {
      r.push({ kind: "choice", id: "quality", label: "streaming quality", options: ["high", "lossless", "hires"] })
      if (hasKeys && keys.windows) r.push({ kind: "toggle", id: "startWithWindows", label: "start with Windows" })
      r.push({ kind: "action", id: "openConfig", label: "open config.json", hint: "everything here lives in it" })
    }
    return r
  }
  function selectable(r) { return r && r.kind !== "header" && r.kind !== "note" }

  onRowsChanged: if (!selectable(rows[cursor])) cursor = firstRow()
  onSectionChanged: { cursor = firstRow(); editing = "" }
  function firstRow() {
    for (var i = 0; i < rows.length; i++) if (selectable(rows[i])) return i
    return 0
  }
  function move(d) {
    var i = cursor
    do { i += d } while (i >= 0 && i < rows.length && !selectable(rows[i]))
    if (i >= 0 && i < rows.length) cursor = i
  }

  // ---- values --------------------------------------------------------------
  readonly property var defaultsOn: ({ syncViz: true, miniPlayer: true })
  function value(r) {
    if (!r || !engine) return undefined
    var c = cfg
    switch (r.id) {
    case "style": return engine.style
    case "railViz": return engine.railViz
    case "fps": return engine.fps
    case "bloom": return engine.bloom
    case "stage": return engine.open
    case "widget.enabled": return engine.widget.enabled !== false
    case "widget.style": return engine.widget.style
    case "widget.corner": return engine.widget.corner
    case "widget.viz": return engine.widgetViz
    case "placement": return engine.placement
    case "showMonitor": return c.showMonitor || ""
    case "quality": return api && api.status ? api.status.quality : ""
    case "startWithWindows": return keys ? keys.startWithWindows : false
    }
    // the engine's own reading of a flag when it has one, so defaults agree
    if (r.kind === "toggle" && typeof engine[r.id] === "boolean") return engine[r.id]
    if (r.kind === "toggle") return defaultsOn[r.id] ? c[r.id] !== false : c[r.id] === true
    return c[r.id]
  }
  function valueText(r) {
    var v = value(r)
    if (r.kind === "toggle") return v ? "[x] on" : "[ ] off"
    if (r.id === "style" || r.id === "railViz" || r.id === "widget.viz") return styleName(v)
    if (r.id === "fps") return v + " fps"
    if (r.id === "placement") return ({ desktop: "wallpaper", fullscreen: "fullscreen show", overlay: "window on top" })[v] || v
    if (r.id === "showMonitor") return v || "the current one"
    if (r.id === "quality") return ({ high: "320k", lossless: "lossless", hires: "hi-res" })[v] || "unknown"
    return String(v === undefined ? "" : v)
  }

  function setValue(r, v) {
    if (!engine) return
    switch (r.id) {
    case "style": engine.setStyle(v); return
    case "railViz": engine.setRailViz(v); return
    case "fps": engine.updateConfig(function(c) { c.fps = v }); return
    case "bloom": engine.setBloom(v); return
    case "stage": engine.open = !!v; return
    case "widget.enabled": engine.setWidget("enabled", v ? "on" : "off"); return
    case "widget.style": engine.setWidget("style", v); return
    case "widget.corner": engine.setWidget("corner", v); return
    case "widget.viz": engine.setWidget("viz", v); return
    case "placement": engine.setPlacement(v); return
    case "showMonitor": if (engine.setShowMonitor) { engine.setShowMonitor(v); return } break
    case "miniPlayer": engine.setMiniPlayer(v ? "on" : "off"); return
    case "startWithWindows": if (keys) keys.setStartWithWindows(!!v); return
    case "quality":
      if (v === "hires" && api && api.login && !api.login.hires) { host.go({ type: "login", title: "sign in", hires: true }); return }
      if (api) api.post("/quality", { quality: v })
      return
    }
    engine.updateConfig(function(c) { c[r.id] = v })
  }

  // h/l on a row: step a choice, flip a toggle.
  function change(dir) {
    var r = rows[cursor]
    if (!r) return
    if (r.kind === "toggle") { setValue(r, !value(r)); return }
    if (r.kind !== "choice") return
    var o = r.options, i = o.indexOf(value(r))
    setValue(r, o[((i < 0 ? 0 : i) + dir + o.length) % o.length])
  }

  // ⏎ on a row.
  function activate() {
    var r = rows[cursor]
    if (!r) return
    if (r.kind === "toggle" || r.kind === "choice") { change(1); return }
    if (r.kind === "theme") { Color.setTheme(r.id); host.say("theme ╱╱ " + r.label); return }
    if (r.kind === "hotkey") { startEdit(r); return }
    if (r.id === "builder") { Color.openBuilder(); return }
    if (r.id === "openConfig") { Qt.openUrlExternally("file:///" + String(engine.configPath).replace(/\\/g, "/").replace(/^\/+/, "")); return }
    if (r.id === "hotkeysReset") { engine.updateConfig(function(c) { delete c.hotkeys }); host.say("hotkeys back to defaults"); return }
  }

  // ---- hotkeys ----------------------------------------------------------------
  function setHotkey(action, combo) {
    engine.updateConfig(function(c) {
      c.hotkeys = c.hotkeys || {}
      if (combo === undefined) delete c.hotkeys[action]
      else c.hotkeys[action] = combo
      if (!Object.keys(c.hotkeys).length) delete c.hotkeys
    })
  }
  function startEdit(r) {
    editing = r.id
    Qt.callLater(function() {
      if (!list.currentItem || !list.currentItem.editor) return
      var ed = list.currentItem.editor
      ed.text = r.row.combo || ""
      ed.selectAll()
      ed.forceActiveFocus()
    })
  }
  function commitEdit(text) {
    var action = editing
    editing = ""
    pane.forceActiveFocus()
    text = String(text || "").trim()
    if (!text) { setHotkey(action, undefined); host.say("back to the default"); return }
    var err = keys.check(text)
    if (err) { host.say("can't use " + text + " · " + err); return }
    var combo = keys.normalize(text)
    setHotkey(action, combo)
    host.say("bound " + combo + " · registering…")
  }
  function cancelEdit() { editing = ""; pane.forceActiveFocus() }

  // A key press as the combo it would be, for typing a hotkey by pressing it.
  function comboOf(e) {
    var k = e.key, name = ""
    if (k >= Qt.Key_A && k <= Qt.Key_Z) name = String.fromCharCode(k)
    else if (k >= Qt.Key_0 && k <= Qt.Key_9) name = String.fromCharCode(k)
    else if (k >= Qt.Key_F1 && k <= Qt.Key_F24) name = "F" + (k - Qt.Key_F1 + 1)
    else {
      var m = {}
      m[Qt.Key_Space] = "Space"; m[Qt.Key_Left] = "Left"; m[Qt.Key_Right] = "Right"; m[Qt.Key_Up] = "Up"; m[Qt.Key_Down] = "Down"
      m[Qt.Key_Home] = "Home"; m[Qt.Key_End] = "End"; m[Qt.Key_PageUp] = "PgUp"; m[Qt.Key_PageDown] = "PgDn"
      m[Qt.Key_Insert] = "Insert"; m[Qt.Key_Delete] = "Delete"; m[Qt.Key_Comma] = ","; m[Qt.Key_Period] = "."
      m[Qt.Key_Minus] = "-"; m[Qt.Key_Equal] = "="; m[Qt.Key_Plus] = "="; m[Qt.Key_Slash] = "/"; m[Qt.Key_Semicolon] = ";"
      m[Qt.Key_BracketLeft] = "["; m[Qt.Key_BracketRight] = "]"; m[Qt.Key_Backslash] = "\\"; m[Qt.Key_QuoteLeft] = "`"
      m[Qt.Key_Apostrophe] = "'"; m[Qt.Key_MediaTogglePlayPause] = "MediaPlayPause"; m[Qt.Key_MediaPlay] = "MediaPlayPause"
      m[Qt.Key_MediaNext] = "MediaNext"; m[Qt.Key_MediaPrevious] = "MediaPrev"; m[Qt.Key_MediaStop] = "MediaStop"
      m[Qt.Key_VolumeUp] = "VolumeUp"; m[Qt.Key_VolumeDown] = "VolumeDown"; m[Qt.Key_VolumeMute] = "VolumeMute"
      name = m[k] || ""
    }
    if (!name) return ""
    var mods = e.modifiers, out = []
    if (mods & Qt.MetaModifier) out.push("Win")
    if (mods & Qt.ControlModifier) out.push("Ctrl")
    if (mods & Qt.AltModifier) out.push("Alt")
    if (mods & Qt.ShiftModifier) out.push("Shift")
    out.push(name)
    return out.join("+")
  }

  // ---- keys -----------------------------------------------------------------
  Keys.onPressed: function(e) {
    var t = e.text, k = e.key
    if (k === Qt.Key_Tab || t === "]") { section = (section + 1) % sections.length; e.accepted = true }
    else if (k === Qt.Key_Backtab || t === "[") { section = (section + sections.length - 1) % sections.length; e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { move(1); e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { move(-1); e.accepted = true }
    else if (t === "g") { cursor = firstRow(); e.accepted = true }
    else if (t === "G") { cursor = rows.length - 1; e.accepted = true }
    else if (k === Qt.Key_Right || t === "l") { change(1); e.accepted = true }
    else if (k === Qt.Key_Left || t === "h") { change(-1); e.accepted = true }
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) { activate(); e.accepted = true }
    else if (rows[cursor] && rows[cursor].kind === "hotkey" && (t === "x" || k === Qt.Key_Delete)) {
      setHotkey(rows[cursor].id, ""); host.say(rows[cursor].label + " · off"); e.accepted = true
    }
    else if (rows[cursor] && rows[cursor].kind === "hotkey" && t === "d") {
      setHotkey(rows[cursor].id, undefined); host.say(rows[cursor].label + " · default"); e.accepted = true
    }
    else e.accepted = host.handleKey(e)
  }

  // ---- drawing ----------------------------------------------------------------
  readonly property real cw: host ? host.cw : 8
  readonly property real ch: host ? host.ch : 16

  // ╱╱ SETTINGS ──── and the section tabs under it
  Column {
    id: top
    width: parent.width
    spacing: pane.ch * 0.3
    Text {
      width: parent.width
      clip: true
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> SETTINGS '
            + '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
      font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
      color: host.dim
    }
    Row {
      spacing: pane.cw * 2
      Repeater {
        model: pane.sections
        Text {
          required property var modelData
          required property int index
          readonly property bool on: index === pane.section
          text: (on ? "▰ " : "▱ ") + modelData.label
          font.family: host.family; font.pixelSize: Style.font.body; font.bold: on
          color: on ? host.accentText : (tabArea.containsMouse ? host.fg : host.dim)
          MouseArea { id: tabArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: { pane.section = parent.index; pane.forceActiveFocus() } }
        }
      }
    }
  }

  readonly property real labelW: cw * 34

  ListView {
    id: list
    anchors.top: top.bottom; anchors.topMargin: pane.ch * 0.8
    anchors.bottom: footer.top; anchors.bottomMargin: pane.ch * 0.5
    width: parent.width
    clip: true
    model: pane.rows.length
    currentIndex: pane.cursor
    boundsBehavior: Flickable.StopAtBounds
    highlightFollowsCurrentItem: false
    highlightMoveDuration: 0
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

    highlight: Rectangle {
      width: list.width
      height: list.currentItem ? list.currentItem.height : 0
      y: list.currentItem ? list.currentItem.y : 0
      visible: !!list.currentItem && pane.selectable(pane.rows[pane.cursor])
      color: host.cursorFill
      Behavior on y { SpringAnimation { spring: 6; damping: 0.45; epsilon: 0.3 } }
      Rectangle { width: Math.max(2, pane.cw * 0.3); height: parent.height; color: host.accent }
    }

    delegate: Item {
      id: rowItem
      required property int index
      readonly property var r: pane.rows[index] || ({})
      readonly property bool isCursor: index === pane.cursor
      readonly property bool isEditing: r.kind === "hotkey" && pane.editing === r.id
      // the combos that did not make it, with why
      readonly property string misses: {
        if (r.kind !== "hotkey" || !r.row) return ""
        var out = [], tried = r.row.tried || []
        for (var i = 0; i < tried.length; i++)
          if (!tried[i].ok && tried[i].reason && tried[i].reason !== "spare")
            out.push("✕ " + tried[i].combo + " " + tried[i].reason)
        return out.join("   ")
      }
      property alias editor: edit
      width: ListView.view.width
      height: pane.ch * (r.kind === "header" ? 1.7 : 1.3) + (misses ? pane.ch * 1.1 : 0)

      Text {
        visible: rowItem.r.kind === "header" || rowItem.r.kind === "note"
        anchors.bottom: parent.bottom; anchors.bottomMargin: pane.ch * 0.1
        width: parent.width
        clip: true
        textFormat: Text.StyledText
        text: rowItem.r.kind === "header"
              ? '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + Tui.esc(rowItem.r.label || "")
                + ' <font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
              : Tui.esc(rowItem.r.label || "")
        font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
        color: host.dim
      }

      Row {
        visible: pane.selectable(rowItem.r)
        x: pane.cw
        y: (pane.ch * 1.3 - height) / 2
        spacing: pane.cw * 2
        Text {
          width: pane.labelW
          elide: Text.ElideRight
          text: rowItem.r.kind === "theme" && Color.name === rowItem.r.id ? "● " + rowItem.r.label
              : rowItem.r.kind === "theme" ? "  " + rowItem.r.label : (rowItem.r.label || "")
          font.family: host.family; font.pixelSize: Style.font.body
          font.bold: rowItem.r.kind === "theme" && Color.name === rowItem.r.id
          color: rowItem.r.kind === "theme" && Color.name === rowItem.r.id ? host.accentText
               : rowItem.isCursor ? host.fg : Tui.mix(host.fg, host.dim, 0.35)
        }
        // the value: ◂ choice ▸, [x] toggle, or a hotkey with its state
        Text {
          visible: !rowItem.isEditing
          textFormat: Text.StyledText
          text: {
            var r = rowItem.r
            if (r.kind === "choice")
              return '<font color="' + Tui.hex(rowItem.isCursor ? host.accent : host.dim) + '">◂ </font>'
                   + Tui.esc(pane.valueText(r))
                   + '<font color="' + Tui.hex(rowItem.isCursor ? host.accent : host.dim) + '"> ▸</font>'
            if (r.kind === "toggle") return Tui.esc(pane.valueText(r))
            if (r.kind === "hotkey" && r.row) {
              var st = r.row.state
              var mine = (pane.cfg.hotkeys || {})[r.id] !== undefined
              return (st === "active" ? '<font color="' + Tui.hex(host.accentText) + '">● ' + Tui.esc(r.row.combo) + '</font>'
                    : st === "off" ? '<font color="' + Tui.hex(host.dim) + '">○ off</font>'
                    : '<font color="' + Tui.hex(Color.urgent) + '">✕ none registered</font>')
                   + (mine ? '<font color="' + Tui.hex(host.dim) + '">  · yours</font>' : '')
            }
            return r.hint ? '<font color="' + Tui.hex(host.dim) + '">' + Tui.esc(r.hint) + '</font>' : ""
          }
          font.family: host.family; font.pixelSize: Style.font.body
          color: rowItem.r.kind === "toggle" && pane.value(rowItem.r) ? host.accentText : host.fg
        }
        Text {
          visible: !rowItem.isEditing && !!rowItem.r.hint && (rowItem.r.kind === "choice" || rowItem.r.kind === "toggle")
          text: rowItem.r.hint || ""
          font.family: host.family; font.pixelSize: Style.font.caption
          color: host.dim
          anchors.verticalCenter: parent.verticalCenter
        }
        // Rebinding: press the combination, or type it. ⏎ sets, esc keeps the old one.
        Row {
          visible: rowItem.isEditing
          Text { text: "❯ "; font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText; font.bold: true }
          TextInput {
            id: edit
            width: pane.cw * 26
            font.family: host.family; font.pixelSize: Style.font.body
            color: host.fg
            selectionColor: Tui.alpha(Color.accent, 0.35)
            cursorDelegate: Rectangle { width: pane.cw; color: host.accent; opacity: 0.7 }
            Keys.onPressed: function(e) {
              if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { pane.commitEdit(text); e.accepted = true; return }
              if (e.key === Qt.Key_Escape) { pane.cancelEdit(); e.accepted = true; return }
              // a held Win/Ctrl/Alt means "this is the combo", not typing
              if (e.modifiers & (Qt.MetaModifier | Qt.ControlModifier | Qt.AltModifier)) {
                var c = pane.comboOf(e)
                if (c) { text = c; e.accepted = true }
              } else if (!text.length || selectedText === text) {
                var m = pane.comboOf(e)   // a lone media or F13+ key
                if (m && /^(Media|Volume|F1[3-9]|F2)/.test(m)) { text = m; e.accepted = true }
              }
            }
            onActiveFocusChanged: if (!activeFocus && rowItem.isEditing) pane.cancelEdit()
          }
          Text {
            text: "  press it or type it · ⏎ set · empty ⏎ default · esc keep"
            font.family: host.family; font.pixelSize: Style.font.caption; color: host.dim
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
      Text {
        visible: rowItem.misses !== ""
        x: pane.cw * 3 + pane.labelW
        y: pane.ch * 1.25
        width: parent.width - x
        elide: Text.ElideRight
        text: rowItem.misses
        font.family: host.family; font.pixelSize: Style.font.caption
        color: Tui.mix(host.dim, Color.urgent, 0.35)
      }

      MouseArea {
        anchors.fill: parent
        enabled: pane.selectable(rowItem.r) && !rowItem.isEditing
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(m) {
          pane.forceActiveFocus()
          pane.cursor = rowItem.index
          if (m.button === Qt.RightButton) pane.change(-1)
          else if (rowItem.r.kind === "toggle" || rowItem.r.kind === "choice") pane.change(1)
        }
        onDoubleClicked: pane.activate()
      }
    }
  }

  Text {
    id: footer
    anchors.bottom: parent.bottom
    width: parent.width
    elide: Text.ElideRight
    textFormat: Text.StyledText
    text: {
      var r = pane.rows[pane.cursor] || {}
      var h = [["⇥", "section"], ["j/k", "move"]]
      if (r.kind === "choice" || r.kind === "toggle") h.push(["h/l", "change"])
      if (r.kind === "hotkey") h = h.concat([["⏎", "rebind"], ["x", "off"], ["d", "default"]])
      else if (r.kind === "theme") h.push(["⏎", "apply"])
      else if (r.kind === "action") h.push(["⏎", "run"])
      h.push(["esc", "back"])
      return Tui.hints(h, host.accentText, host.dim)
    }
    font.family: host.family; font.pixelSize: Style.font.caption
  }

  Component.onCompleted: cursor = firstRow()
}
