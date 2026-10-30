import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// Settings, as a page of the player: everything the tray menu and config.json
// used to be the only way to reach.
//
// Grouped the way you think about it: how it looks (theme, visuals), how it
// sounds, how it behaves, what it connects to, and the rare knobs last.
// Keyboard first, like the equalizer: ⇥ moves between sections, j/k between
// rows, h/l changes a value in place, ⏎ sets, toggles or edits, d puts a row
// back to its default, / searches every section. The selected row says what
// it does on the line above the keys. Every change is written straight to
// config.json (or to the theme / the hotkeys), so there is no save step to
// forget. Anything the pane does not use goes to the window's own keys.
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

  // the shared motion: a cursor step, a change of state, a page
  readonly property int tFast: 120
  readonly property int tMid: 180
  readonly property int tSlow: 420

  // Desktop-only pieces: Omarchy's own Color has no theme list, and the global
  // hotkeys there are Hyprland binds, so both sections say so instead.
  readonly property bool hasThemes: typeof Color.themeList !== "undefined" && Color.themeList !== null
  readonly property bool hasKeys: typeof OrpheusKeys !== "undefined"
  readonly property var keys: hasKeys ? OrpheusKeys : null
  readonly property bool hasGame: typeof OrpheusGame !== "undefined"
  readonly property bool onWindows: hasKeys && keys.windows === true

  readonly property var sections: [
    { id: "theme", label: "theme" },
    { id: "visuals", label: "visuals" },
    { id: "sound", label: "sound" },
    { id: "behaviour", label: "behaviour" },
    { id: "hotkeys", label: "hotkeys" },
    { id: "integrations", label: "integrations" },
    { id: "advanced", label: "advanced" }
  ]
  property int section: 0
  property int cursor: 0
  property string editing: ""        // the hotkey action / text row being edited, if any
  property string query: ""          // the search, across every section
  readonly property bool searching: query.trim() !== ""

  readonly property var cfg: engine ? engine.config : ({})
  readonly property var styles: engine ? engine.styles : []
  function styleName(s) { return s === "off" ? "album art" : (engine && engine.styleLabels[s] ? engine.styleLabels[s].toLowerCase() : s) }
  readonly property var corners: ["top-left", "top-right", "bottom-left", "bottom-right"]
  function screens() {
    var mons = [""], scr = Quickshell.screens || []
    for (var s = 0; s < scr.length; s++) if (scr[s] && scr[s].name) mons.push(scr[s].name)
    return mons
  }

  // ---- rows ----------------------------------------------------------------
  //
  // Plain objects; every value is read back through value() so the page follows
  // config.json when it changes underneath (hand edits, the tray, a hotkey).
  //   kind  header | note | qr | action | theme | hotkey | choice | toggle | number | text
  //   desc  one line on what it does, shown for the selected row
  //   def   the default, where there is one (d puts it back)
  //   key   the key that does the same from anywhere in the player
  function build(id) {
    var r = []
    var e = engine
    var d = e ? e.defaults : ({})
    if (id === "theme") {
      if (!hasThemes) return [{ kind: "note", label: "themes follow Omarchy here · omarchy-theme-set" }]
      r.push({ kind: "action", id: "builder", label: "theme builder…", hint: "make your own",
               desc: "pick a background, text and accent; the rest of the palette is worked out, and saved under yours" })
      var list = Color.themeList || [], group = ""
      for (var i = 0; i < list.length; i++) {
        if (list[i].group !== group) { group = list[i].group; r.push({ kind: "header", label: group.toLowerCase() }) }
        r.push({ kind: "theme", id: list[i].name, label: list[i].label.toLowerCase(),
                 desc: "⏎ or click to switch the whole app to " + list[i].label.toLowerCase() })
      }
    } else if (id === "visuals") {
      r.push({ kind: "choice", id: "style", label: "visualizer style", options: styles, def: d.style,
               desc: "the look of the visualizer window, the wallpaper and the fullscreen show" })
      r.push({ kind: "choice", id: "railViz", label: "player rail", options: ["off"].concat(styles), def: d.railViz, key: "v",
               desc: "the plane beside the player: a visualizer, or the album art" })
      r.push({ kind: "choice", id: "placement", label: "visualizer as", def: d.placement,
               options: e && e.placements ? e.placements : ["overlay", "desktop"],
               desc: "a window on top, live wallpaper behind the icons, or a fullscreen show" })
      r.push({ kind: "choice", id: "showMonitor", label: "show on screen", options: screens(), def: "",
               desc: "which monitor the wallpaper and the fullscreen show use" })
      r.push({ kind: "toggle", id: "stage", label: "visualizer window", key: "V",
               desc: "open or close the visualizer now (not saved)" })
      r.push({ kind: "header", label: "light" })
      r.push({ kind: "choice", id: "bloom", label: "bloom", options: ["off", "subtle", "full"], def: d.bloom,
               desc: "glow around the bright parts of the visualizer · dark themes only" })
      r.push({ kind: "choice", id: "feedback", label: "trails", options: ["off", "subtle", "full"], def: d.feedback,
               desc: "each frame leaves a fading echo of the last, like milkdrop" })
      r.push({ kind: "toggle", id: "trackTitle", label: "title card on track change", def: d.trackTitle,
               desc: "the new track's name fades in over the visualizer" })
      r.push({ kind: "toggle", id: "lyricsOverViz", label: "lyrics over the visualizer", def: d.lyricsOverViz,
               desc: "the sung line, karaoke style, over the stage" })
      r.push({ kind: "header", label: "follow the music" })
      r.push({ kind: "toggle", id: "director", label: "follow the song's structure", def: d.director,
               desc: "builds tighten, drops hit harder, breakdowns calm down" })
      r.push({ kind: "toggle", id: "beatLock", label: "lock flashes to the beat", def: d.beatLock,
               desc: "flashes land on a predicted beat grid instead of a detection late" })
      r.push({ kind: "toggle", id: "autoStyle", label: "switch styles on drops", def: d.autoStyle,
               desc: "jump to another visualizer style when a big drop lands" })
    } else if (id === "sound") {
      r.push({ kind: "choice", id: "quality", label: "streaming quality", options: ["high", "lossless", "hires"],
               desc: "320k aac, cd-quality flac, or hi-res flac up to 24/192 (needs a hi-res sign-in)" })
      r.push({ kind: "action", id: "eq", label: "equalizer…", key: "e", hint: eqHint(),
               desc: "ten bands, presets and headroom · opens the equalizer page" })
      r.push({ kind: "header", label: "flow" })
      r.push({ kind: "toggle", id: "endless", label: "endless play", def: d.endless,
               desc: "when the queue runs out, keep going with radio from the last track" })
      r.push({ kind: "choice", id: "crossfade", label: "crossfade", options: [0, 2, 4, 6, 8, 10, 12], def: d.crossfade,
               desc: "blend tracks into each other · never inside an album, so live albums stay gapless" })
      r.push({ kind: "choice", id: "sleep", label: "sleep timer", options: ["off", 15, 30, 45, 60, 90, "end"],
               desc: "pause after a while, or at the end of this track (not saved)" })
    } else if (id === "behaviour") {
      r.push({ kind: "header", label: "widget" })
      r.push({ kind: "toggle", id: "widget.enabled", label: "desktop widget", def: d.widget.enabled,
               desc: "a small now-playing card in a corner of the screen" })
      r.push({ kind: "choice", id: "widget.style", label: "widget style", options: ["compact", "full"], def: d.widget.style,
               desc: "full has the art and a visualizer; compact is one line" })
      r.push({ kind: "choice", id: "widget.corner", label: "widget corner", options: corners, def: d.widget.corner,
               desc: "where on the screen the widget sits" })
      r.push({ kind: "choice", id: "widget.monitor", label: "widget screen", options: screens(), def: d.widget.monitor,
               desc: "which monitor the widget is on" })
      r.push({ kind: "choice", id: "widget.layer", label: "widget layer", def: d.widget.layer,
               options: onWindows ? ["top", "desktop"] : ["top", "reserve", "desktop", "tile", "float"],
               desc: "above other windows (faded until hovered), or down on the desktop" })
      r.push({ kind: "toggle", id: "syncViz", label: "widget follows the visualizer", def: d.syncViz,
               desc: "the widget shows whatever style the visualizer shows" })
      r.push({ kind: "choice", id: "widget.viz", label: "widget visualizer", options: styles, def: d.widget.viz,
               disabled: value({ id: "syncViz", kind: "toggle" }) === true,
               desc: value({ id: "syncViz", kind: "toggle" }) === true
                     ? "following the visualizer · turn that off to pick one for the widget"
                     : "the style inside the widget" })
      r.push({ kind: "toggle", id: "miniPlayer", label: "mini player on the stage", def: d.miniPlayer,
               desc: "transport controls over the visualizer window" })
      if (onWindows) {
        r.push({ kind: "header", label: "windows" })
        r.push({ kind: "toggle", id: "toasts", label: "track change notifications", def: true,
                 desc: "a windows notification when the track changes and the player is not in front" })
        r.push({ kind: "toggle", id: "startWithWindows", label: "start with windows",
                 desc: "open orpheus in the tray when you sign in" })
      }
      if (hasGame) {
        r.push({ kind: "header", label: "gaming" })
        r.push({ kind: "note", label: "now: " + (OrpheusGame.gameMode ? "game mode · " : "") + OrpheusGame.reason })
        r.push({ kind: "toggle", id: "gameMode", label: "step back for games", def: true,
                 desc: "hide the widget and the visualizer while a fullscreen game has the screen" })
        r.push({ kind: "toggle", id: "hud", label: "in-game HUD on track change", def: true,
                 desc: "a small overlay over the game when the track changes" })
        r.push({ kind: "choice", id: "hudCorner", label: "HUD corner", options: corners, def: "top-left",
                 desc: "where over the game the HUD shows" })
        r.push({ kind: "action", id: "hudShow", label: "show the HUD now", hint: hudHint(),
                 desc: "flash the HUD on the screen in front, to see where it lands" })
      }
    } else if (id === "hotkeys") {
      if (!hasKeys) return [{ kind: "note", label: "global keys are Hyprland binds here · see hypr/" }]
      r.push({ kind: "note", label: "keys that work from any app · ⏎ rebind · x off · d default" })
      var b = keys.bindings || []
      for (var k = 0; k < b.length; k++)
        r.push({ kind: "hotkey", id: b[k].action, label: b[k].label, row: b[k],
                 desc: "global hotkey · ⏎ then press the new combination" })
      r.push({ kind: "action", id: "hotkeysReset", label: "all back to defaults", desc: "forget every rebinding" })
    } else if (id === "integrations") {
      // Playback keys the daemon reads from config.json, and what it reports
      // about the phone remote and scrobbling (refreshed while this is open).
      r.push({ kind: "header", label: "phone remote" })
      r.push({ kind: "toggle", id: "remote", label: "phone remote", def: false,
               desc: "a page for your phone on this network · every request needs the pairing code" })
      if (pair.listening && pair.qr && pair.qr.length) {
        r.push({ kind: "qr", label: pair.url, rows: pair.qr })
        r.push({ kind: "action", id: "remoteReset", label: "new pairing code", hint: "unpairs every phone",
                 desc: "make a new code; every phone has to scan again" })
      } else if (value({ id: "remote", kind: "toggle" })) {
        r.push({ kind: "note", label: pair.error || "starting the listener…" })
      }
      r.push({ kind: "header", label: "scrobbling" })
      var lb = scrobble.listenbrainz || {}, lf = scrobble.lastfm || {}
      r.push({ kind: "text", id: "listenbrainzToken", label: "listenbrainz token", secret: true, def: "",
               hint: lb.enabled ? "● " + (lb.user || "on") + (lb.pending ? " · " + lb.pending + " queued" : "") + (lb.error ? " · " + lb.error : "") : "",
               desc: "paste your user token from listenbrainz.org/settings to scrobble there" })
      r.push({ kind: "text", id: "lastfmKey", label: "last.fm api key", def: "",
               desc: "from last.fm/api/account/create · then the secret, then connect" })
      r.push({ kind: "text", id: "lastfmSecret", label: "last.fm api secret", secret: true, def: "",
               desc: "the shared secret that came with the api key" })
      if (lf.configured) {
        if (lf.enabled) r.push({ kind: "action", id: "lastfmDisconnect", label: "disconnect last.fm",
                                 hint: "● " + lf.user + (lf.pending ? " · " + lf.pending + " queued" : "") + (lf.error ? " · " + lf.error : ""),
                                 desc: "stop scrobbling to last.fm and forget the session" })
        else if (lf.authorising) r.push({ kind: "action", id: "lastfmFinish", label: "finish connecting last.fm", hint: "approved in the browser?",
                                          desc: "after approving orpheus on last.fm, this picks up the session" })
        else r.push({ kind: "action", id: "lastfmConnect", label: "connect last.fm", hint: "opens the browser",
                      desc: "approve orpheus on last.fm in the browser, then come back and finish" })
      }
      if (hasGame) {
        r.push({ kind: "header", label: "discord" })
        r.push({ kind: "text", id: "discordClientId", label: "discord application id", def: "",
                 hint: OrpheusGame.discord.indexOf("discordClientId") >= 0 ? "" : OrpheusGame.discord,
                 desc: "rich presence: the id of an application from discord.com/developers" })
      }
    } else if (id === "advanced") {
      r.push({ kind: "choice", id: "fps", label: "frame rate", options: [30, 60, 90, 120], def: d.fps,
               desc: "how often the visualizers draw · lower saves power" })
      r.push({ kind: "toggle", id: "autoQuality", label: "lower resolution when frames drop", def: d.autoQuality,
               desc: "the visualizer renders smaller rather than stutter" })
      r.push({ kind: "toggle", id: "showFps", label: "show the frame rate", def: d.showFps,
               desc: "an fps counter in the corner of the visualizer" })
      r.push({ kind: "number", id: "lookaheadMs", label: "beat lookahead", min: 0, max: 400, step: 5, unit: "ms", def: d.lookaheadMs,
               desc: "how far ahead the beat grid aims · raise it if flashes land late, lower if early" })
      r.push({ kind: "header", label: "phone remote" })
      r.push({ kind: "text", id: "remoteHost", label: "remote address", def: "", placeholder: "this machine's LAN address",
               desc: "the address the phone remote listens on · empty finds it" })
      r.push({ kind: "number", id: "remotePort", label: "remote port", min: 1024, max: 65535, step: 1, unit: "", def: 47838,
               desc: "the port the phone remote listens on" })
      r.push({ kind: "header", label: "files" })
      r.push({ kind: "toggle", id: "playerHint", label: "first-run tip", def: true,
               desc: "the one-line tip beside the logo; ✕ on it turns it off" })
      r.push({ kind: "action", id: "openConfig", label: "open config.json", hint: "everything here lives in it",
               desc: "open the settings file in your editor" })
    }
    return r
  }

  // Every section's rows, for the search. Rows are stamped with their section.
  function allRows() {
    var out = []
    for (var s = 0; s < sections.length; s++) {
      var rs = build(sections[s].id)
      for (var i = 0; i < rs.length; i++) { rs[i].sec = s; out.push(rs[i]) }
    }
    return out
  }
  function matches(r, words) {
    if (!selectable(r)) return false
    var hay = (sections[r.sec].label + " " + (r.label || "") + " " + (r.desc || "") + " " + (r.id || "")).toLowerCase()
    for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) < 0) return false
    return true
  }

  readonly property var rows: {
    if (!searching) {
      var own = build(sections[section].id)
      for (var j = 0; j < own.length; j++) own[j].sec = section
      return own
    }
    var words = query.trim().toLowerCase().split(/\s+/), all = allRows(), out = [], last = -1
    for (var i = 0; i < all.length; i++) {
      if (!matches(all[i], words)) continue
      if (all[i].sec !== last) { last = all[i].sec; out.push({ kind: "header", label: sections[last].label, sec: last }) }
      out.push(all[i])
    }
    if (!out.length) out.push({ kind: "note", label: "nothing matches “" + query.trim() + "” · esc clears the search" })
    return out
  }
  function selectable(r) { return r && r.kind !== "header" && r.kind !== "note" && r.kind !== "qr" }

  // ---- what the daemon says about the remote, scrobbling, the eq ------------
  property var pair: ({})
  property var scrobble: ({})
  readonly property bool wantsDaemon: searching || (sections[section] && (sections[section].id === "integrations" || sections[section].id === "sound"))
  function refreshDaemon() {
    if (!api) return
    api.get("/remote/pair", function(ok, d) { if (ok && d && typeof d === "object") pane.pair = d })
    api.get("/scrobble", function(ok, d) { if (ok && d && typeof d === "object") pane.scrobble = d })
  }
  Timer { interval: 3000; repeat: true; triggeredOnStart: true; running: pane.visible && pane.wantsDaemon; onTriggered: pane.refreshDaemon() }
  readonly property var sleepState: (api && api.status && api.status.listening && api.status.listening.sleep) || ({ active: false })
  readonly property var eqState: (api && api.status && api.status.eq) || ({})
  function eqHint() {
    if (!api || !api.status || !api.status.eq) return ""
    return eqState.active ? "● on" + (eqState.preset ? " · " + eqState.preset : " · custom") : "○ bypassed"
  }
  function hudHint() { return value({ id: "hud", kind: "toggle" }) ? "" : "the HUD is off" }

  // The list's model is a count: when it is rebuilt the ListView resets its
  // own currentIndex, and a binding to `cursor` would not notice (cursor did
  // not change), leaving the highlight on the wrong row. So it is pushed.
  onRowsChanged: {
    if (!selectable(rows[cursor])) cursor = firstRow()
    Qt.callLater(function() { list.currentIndex = pane.cursor })
  }
  onCursorChanged: list.currentIndex = cursor
  onSectionChanged: { cursor = firstRow(); editing = "" }
  function firstRow() {
    for (var i = 0; i < rows.length; i++) if (selectable(rows[i])) return i
    return 0
  }
  function lastRow() {
    for (var i = rows.length - 1; i >= 0; i--) if (selectable(rows[i])) return i
    return 0
  }
  function move(d) {
    var i = cursor
    do { i += d } while (i >= 0 && i < rows.length && !selectable(rows[i]))
    if (i >= 0 && i < rows.length) cursor = i
  }
  function goSection(i) {
    query = ""
    section = (i + sections.length) % sections.length
    cursor = firstRow()
    pane.forceActiveFocus()
  }

  // ---- values --------------------------------------------------------------
  function value(r) {
    if (!r || !engine) return undefined
    var c = cfg
    switch (r.id) {
    case "style": return engine.style
    case "railViz": return engine.railViz
    case "fps": return engine.fps
    case "bloom": return engine.bloom
    case "feedback": return engine.feedback
    case "stage": return engine.open
    case "widget.enabled": return engine.widget.enabled !== false
    case "widget.style": return engine.widget.style
    case "widget.corner": return engine.widget.corner
    case "widget.monitor": return engine.widget.monitor || ""
    case "widget.layer": return engine.widget.layer || "top"
    case "widget.viz": return engine.widgetViz
    case "placement": return engine.placement
    case "showMonitor": return c.showMonitor || ""
    case "quality": return api && api.status ? api.status.quality : ""
    case "startWithWindows": return keys ? keys.startWithWindows : false
    case "crossfade": return Number(c.crossfade) || 0
    case "remote": return c.remote === "lan"
    case "sleep": return !sleepState.active ? "off" : sleepState.endOfTrack ? "end" : Math.ceil((sleepState.remaining || 0) / 60)
    case "gameMode": return !(c.gameMode === "off" || c.gameMode === false)
    case "hud": return !(c.hud === "off" || c.hud === false)
    case "hudCorner": return corners.indexOf(c.hudCorner) >= 0 ? c.hudCorner : "top-left"
    case "toasts": return c.toasts !== false
    case "playerHint": return c.playerHint !== false
    case "endless": return c.endless !== false
    case "lookaheadMs": return typeof c.lookaheadMs === "number" ? c.lookaheadMs : 85
    case "remotePort": return Number(c.remotePort) || 47838
    }
    // the engine's own reading of a flag when it has one, so defaults agree
    if (r.kind === "toggle" && typeof engine[r.id] === "boolean") return engine[r.id]
    if (r.kind === "toggle") return r.def === true ? c[r.id] !== false : c[r.id] === true
    if (r.kind === "text") return typeof c[r.id] === "string" ? c[r.id] : ""
    return c[r.id]
  }
  function show(r, v) {
    if (r.kind === "toggle") return v ? "[x] on" : "[ ] off"
    if (r.kind === "number") return v + (r.unit ? " " + r.unit : "")
    if (r.id === "style" || r.id === "railViz" || r.id === "widget.viz") return styleName(v)
    if (r.id === "fps") return v + " fps"
    if (r.id === "placement") return ({ desktop: "wallpaper", fullscreen: "fullscreen show", overlay: "window on top" })[v] || v
    if (r.id === "showMonitor" || r.id === "widget.monitor") return v || "the main one"
    if (r.id === "widget.layer") return ({ top: "above windows", desktop: "on the desktop", reserve: "reserve space", tile: "tiled window", float: "floating window" })[v] || v
    if (r.id === "quality") return ({ high: "320k", lossless: "lossless", hires: "hi-res" })[v] || "unknown"
    if (r.id === "crossfade") return v ? v + " s" : "off · gapless"
    if (r.id === "sleep") return v === "off" ? "off" : v === "end" ? "☾ end of this track" : "☾ " + v + " min left"
    if (r.kind === "number") return v + (r.unit ? " " + r.unit : "")
    if (r.kind === "text") {
      if (!v) return r.placeholder || "not set"
      return r.secret ? "set · ••••" + String(v).slice(-4) : v
    }
    return String(v === undefined ? "" : v)
  }
  function valueText(r) { return show(r, value(r)) }
  function defaultText(r) {
    if (r.def === undefined) return ""
    if (r.kind === "text") return r.def === "" ? "" : r.def
    if (r.kind === "toggle") return r.def ? "on" : "off"
    return show(r, r.def)
  }
  function isDefault(r) {
    if (r.def === undefined) return true
    var v = value(r)
    return v === r.def || (r.kind === "text" && !v && !r.def)
  }

  function setValue(r, v) {
    if (!engine) return
    switch (r.id) {
    case "style": engine.setStyle(v); return
    case "railViz": engine.setRailViz(v); return
    case "bloom": engine.setBloom(v); return
    case "feedback": if (engine.setFeedback) { engine.setFeedback(v); return } break
    case "stage": engine.open = !!v; return
    case "widget.enabled": engine.setWidget("enabled", v ? "on" : "off"); return
    case "widget.style": case "widget.corner": case "widget.monitor": case "widget.layer": case "widget.viz":
      engine.setWidget(r.id.slice(7), v); return
    case "placement": engine.setPlacement(v); return
    case "showMonitor": if (engine.setShowMonitor) { engine.setShowMonitor(v); return } break
    case "miniPlayer": engine.setMiniPlayer(v ? "on" : "off"); return
    case "startWithWindows": if (keys) keys.setStartWithWindows(!!v); return
    case "remote":
      engine.updateConfig(function(c) { c.remote = v ? "lan" : "off" })
      if (v) host.say("phone remote on · scan the code here with the phone")
      Qt.callLater(refreshDaemon)
      return
    case "gameMode": engine.updateConfig(function(c) { c.gameMode = v ? "auto" : "off" }); return
    case "hud": engine.updateConfig(function(c) { c.hud = v ? "on" : "off" }); return
    case "sleep":
      if (api) api.post("/sleep", v === "off" ? { cancel: true } : v === "end" ? { endOfTrack: true } : { minutes: v })
      return
    case "quality":
      if (v === "hires" && api && api.login && !api.login.hires) { host.go({ type: "login", title: "sign in", hires: true }); return }
      if (api) api.post("/quality", { quality: v })
      return
    }
    if ((r.kind === "toggle" || r.kind === "choice") && engine.setStageFlag && typeof engine[r.id] === "boolean"
        && ["autoStyle", "trackTitle", "lyricsOverViz", "autoQuality", "showFps", "director", "beatLock"].indexOf(r.id) >= 0) {
      engine.setStageFlag(r.id, v ? "on" : "off"); return
    }
    engine.updateConfig(function(c) { c[r.id] = v })
  }

  // d: the row's default back. Config keys are deleted rather than written,
  // so a later change of default reaches them.
  function resetValue(r) {
    if (!r || r.def === undefined || !engine) return false
    if (isDefault(r)) { host.say(r.label + " · already the default"); return true }
    var path = r.id.split(".")
    if (r.id === "style" || r.id === "railViz" || r.id === "widget.viz") { setValue(r, r.def) }
    else engine.updateConfig(function(c) {
      if (path.length === 2) { if (c[path[0]]) delete c[path[0]][path[1]] }
      else delete c[r.id]
    })
    host.say(r.label + " · back to " + (defaultText(r) || "the default"))
    return true
  }

  // h/l on a row: step a choice or a number, flip a toggle.
  function change(dir) {
    var r = rows[cursor]
    if (!r) return
    if (r.disabled) { host.say(r.desc); return }
    if (r.kind === "toggle") { setValue(r, !value(r)); return }
    if (r.kind === "number") {
      var n = Math.max(r.min, Math.min(r.max, value(r) + dir * r.step))
      setValue(r, n); return
    }
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
    if (r.kind === "hotkey" || r.kind === "text" || r.kind === "number") { startEdit(r); return }
    if (r.id === "builder") { Color.openBuilder(); return }
    if (r.id === "eq") { host.showEq(); return }
    if (r.id === "hudShow") { OrpheusGame.showHud(); host.say("HUD ╱╱ shown on the screen in front"); return }
    if (r.id === "remoteReset") { api.post("/remote/pair/reset", {}, function(ok, d) { if (ok && d) pane.pair = d; host.say(ok ? "new pairing code · scan it again" : "couldn't reset the code") }); return }
    if (r.id === "lastfmConnect")
      return api.post("/lastfm/auth/start", {}, function(ok, d) {
        if (ok && d && d.url) { Qt.openUrlExternally(d.url); host.say("approve Orpheus on last.fm, then ⏎ finish here") }
        else host.say("last.fm · " + host.errText(d, "couldn't start the sign-in"))
        pane.refreshDaemon()
      })
    if (r.id === "lastfmFinish")
      return api.post("/lastfm/auth/finish", {}, function(ok, d) {
        host.say(ok && d ? "last.fm ╱╱ scrobbling as " + d.user : "last.fm · " + host.errText(d, "not approved yet"))
        pane.refreshDaemon()
      })
    if (r.id === "lastfmDisconnect") { api.post("/lastfm/disconnect", {}, function() { pane.refreshDaemon() }); host.say("last.fm disconnected"); return }
    if (r.id === "openConfig") { Qt.openUrlExternally("file:///" + String(engine.configPath).replace(/\\/g, "/").replace(/^\/+/, "")); return }
    if (r.id === "hotkeysReset") { engine.updateConfig(function(c) { delete c.hotkeys }); host.say("hotkeys back to defaults"); return }
  }

  // ---- editing: a hotkey, a text row, a number typed in ---------------------
  function setHotkey(action, combo) {
    engine.updateConfig(function(c) {
      c.hotkeys = c.hotkeys || {}
      if (combo === undefined) delete c.hotkeys[action]
      else c.hotkeys[action] = combo
      if (!Object.keys(c.hotkeys).length) delete c.hotkeys
    })
  }
  property var editRow: null
  function startEdit(r) {
    editing = r.id
    editRow = r
    Qt.callLater(function() {
      if (!list.currentItem || !list.currentItem.editor) return
      var ed = list.currentItem.editor
      ed.text = r.kind === "hotkey" ? (r.row.combo || "") : r.kind === "number" ? String(value(r)) : (value(r) || "")
      ed.selectAll()
      ed.forceActiveFocus()
    })
  }
  function commitEdit(text) {
    var r = editRow
    editing = ""
    editRow = null
    pane.forceActiveFocus()
    if (!r) return
    text = String(text || "").trim()
    if (r.kind === "hotkey") {
      if (!text) { setHotkey(r.id, undefined); host.say("back to the default"); return }
      var err = keys.check(text)
      if (err) { host.say("can't use " + text + " · " + err); return }
      var combo = keys.normalize(text)
      setHotkey(r.id, combo)
      host.say("bound " + combo + " · registering…")
      return
    }
    if (r.kind === "number") {
      if (!text) { resetValue(r); return }
      var n = Number(text)
      if (!isFinite(n)) { host.say(r.label + " · a number, " + r.min + " to " + r.max); return }
      n = Math.max(r.min, Math.min(r.max, Math.round(n)))
      engine.updateConfig(function(c) { c[r.id] = n })
      host.say(r.label + " · " + show(r, n))
      return
    }
    if (r.id === "discordClientId" && text && !/^\d+$/.test(text)) { host.say("an application id is all digits"); return }
    engine.updateConfig(function(c) { if (text) c[r.id] = text; else delete c[r.id] })
    host.say(r.label + (text ? " · saved" : " · cleared"))
    Qt.callLater(refreshDaemon)
  }
  function cancelEdit() { editing = ""; editRow = null; pane.forceActiveFocus() }

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

  // ---- search ---------------------------------------------------------------
  function startSearch() { search.forceActiveFocus(); search.selectAll() }
  function endSearch() { query = ""; pane.forceActiveFocus(); cursor = firstRow() }

  // ---- keys -----------------------------------------------------------------
  Keys.onPressed: function(e) {
    var t = e.text, k = e.key, r = rows[cursor]
    var ctrl = e.modifiers & Qt.ControlModifier
    if (k === Qt.Key_Tab || t === "]") { goSection(section + 1); e.accepted = true }
    else if (k === Qt.Key_Backtab || t === "[") { goSection(section - 1); e.accepted = true }
    else if (t === "/" || (ctrl && k === Qt.Key_F)) { startSearch(); e.accepted = true }
    else if (k === Qt.Key_Escape && searching) { endSearch(); e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { move(1); e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { move(-1); e.accepted = true }
    else if (k === Qt.Key_PageDown) { for (var i = 0; i < 8; i++) move(1); e.accepted = true }
    else if (k === Qt.Key_PageUp) { for (var j = 0; j < 8; j++) move(-1); e.accepted = true }
    else if (t === "g" || k === Qt.Key_Home) { cursor = firstRow(); e.accepted = true }
    else if (t === "G" || k === Qt.Key_End) { cursor = lastRow(); e.accepted = true }
    else if (k === Qt.Key_Right || t === "l") { change(1); e.accepted = true }
    else if (k === Qt.Key_Left || t === "h") { change(-1); e.accepted = true }
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) { activate(); e.accepted = true }
    else if (r && r.kind === "hotkey" && (t === "x" || k === Qt.Key_Delete)) {
      setHotkey(r.id, ""); host.say(r.label + " · off"); e.accepted = true
    }
    else if (r && r.kind === "hotkey" && t === "d") {
      setHotkey(r.id, undefined); host.say(r.label + " · default"); e.accepted = true
    }
    else if (r && t === "d" && r.def !== undefined) { resetValue(r); e.accepted = true }
    else if (r && r.kind === "text" && (t === "x" || k === Qt.Key_Delete)) { resetValue(r); e.accepted = true }
    else e.accepted = host.handleKey(e)
  }

  // ---- drawing ----------------------------------------------------------------
  readonly property real cw: host ? host.cw : 8
  readonly property real ch: host ? host.ch : 16

  // ╱╱ SETTINGS ──── / search, and the section tabs under it
  Column {
    id: top
    width: parent.width
    spacing: pane.ch * 0.3
    Item {
      width: parent.width
      height: pane.ch * 1.2
      Text {
        anchors.left: parent.left; anchors.right: searchBox.left; anchors.rightMargin: pane.cw * 2
        anchors.verticalCenter: parent.verticalCenter
        clip: true
        textFormat: Text.StyledText
        text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> SETTINGS '
              + '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
        font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
        color: host.dim
      }
      // the search: / from the keyboard, or click into it
      Row {
        id: searchBox
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        readonly property bool live: search.activeFocus || pane.searching
        Text {
          text: "/ "
          font.family: host.family; font.pixelSize: Style.font.body; font.bold: searchBox.live
          color: searchBox.live ? host.accentText : host.dim
        }
        TextInput {
          id: search
          width: pane.cw * 24
          font.family: host.family; font.pixelSize: Style.font.body
          color: host.fg
          clip: true
          selectionColor: Tui.alpha(Color.accent, 0.35)
          cursorDelegate: Rectangle { width: pane.cw; color: host.accent; opacity: 0.7; visible: search.activeFocus }
          text: pane.query
          onTextEdited: { pane.query = text; pane.cursor = pane.firstRow() }
          Keys.onPressed: function(e) {
            var k = e.key
            if (k === Qt.Key_Escape) { if (text) pane.endSearch(); else pane.forceActiveFocus(); e.accepted = true }
            else if (k === Qt.Key_Down || k === Qt.Key_Tab) { pane.forceActiveFocus(); pane.cursor = pane.firstRow(); e.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) { pane.forceActiveFocus(); pane.cursor = pane.firstRow(); pane.activate(); e.accepted = true }
          }
          Text {
            visible: !parent.text
            text: search.activeFocus ? "type to filter every section" : "search settings"
            font: parent.font
            color: Tui.mix(host.dim, host.bg, 0.25)
          }
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.IBeamCursor
            onPressed: function(m) { search.forceActiveFocus(); m.accepted = false }
            TuiTip { text: "search every setting"; key: "/" }
          }
        }
      }
    }
    Row {
      spacing: pane.cw * 2
      opacity: pane.searching ? 0.45 : 1
      Behavior on opacity { NumberAnimation { duration: pane.tMid; easing.type: Easing.InOutCubic } }
      Repeater {
        model: pane.sections
        Text {
          id: tab
          required property var modelData
          required property int index
          readonly property bool on: index === pane.section && !pane.searching
          text: (on ? "▰ " : "▱ ") + modelData.label
          font.family: host.family; font.pixelSize: Style.font.body; font.bold: on
          color: on || tabArea.containsMouse ? host.accentText : host.dim
          Behavior on color { ColorAnimation { duration: pane.tMid; easing.type: Easing.InOutCubic } }
          MouseArea { id: tabArea; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: pane.goSection(tab.index) }
        }
      }
    }
  }

  readonly property real labelW: Math.min(cw * 34, Math.max(cw * 24, width * 0.36))

  ListView {
    id: list
    anchors.top: top.bottom; anchors.topMargin: pane.ch * 0.8
    anchors.bottom: descLine.top; anchors.bottomMargin: pane.ch * 0.5
    width: parent.width
    clip: true
    model: pane.rows.length
    boundsBehavior: Flickable.StopAtBounds
    highlightFollowsCurrentItem: false
    highlightMoveDuration: 0
    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

    highlight: Rectangle {
      width: list.width
      height: list.currentItem ? list.currentItem.rowH : 0
      y: list.currentItem ? list.currentItem.y : 0
      visible: !!list.currentItem && pane.selectable(pane.rows[pane.cursor])
      color: host.cursorFill
      Behavior on y { NumberAnimation { duration: pane.tFast; easing.type: Easing.InOutCubic } }
      Rectangle { width: Math.max(2, pane.cw * 0.3); height: parent.height; color: host.accent }
    }

    delegate: Item {
      id: rowItem
      required property int index
      readonly property var r: pane.rows[index] || ({})
      readonly property bool isCursor: index === pane.cursor
      readonly property bool isEditing: (r.kind === "hotkey" || r.kind === "text" || r.kind === "number") && pane.editing === r.id && pane.editRow && pane.editRow.kind === r.kind
      readonly property bool dimmed: r.disabled === true
      // the combos that did not make it, with why
      readonly property string misses: {
        if (r.kind !== "hotkey" || !r.row) return ""
        var out = [], tried = r.row.tried || []
        for (var i = 0; i < tried.length; i++)
          if (!tried[i].ok && tried[i].reason && tried[i].reason !== "spare")
            out.push("✕ " + tried[i].combo + " " + tried[i].reason)
        return out.join("   ")
      }
      readonly property real rowH: pane.ch * 1.3
      property alias editor: edit
      width: ListView.view.width
      height: r.kind === "qr" ? qrCode.height + pane.ch * 0.8
            : r.kind === "header" ? pane.ch * (index === 0 ? 1.3 : 1.9)
            : rowH + (misses ? pane.ch * 1.1 : 0)

      // The phone remote's pairing link as a QR code: dark on light with its
      // quiet zone, whatever the theme, because that is what cameras read.
      Canvas {
        id: qrCode
        visible: rowItem.r.kind === "qr"
        readonly property var m: rowItem.r.kind === "qr" ? (rowItem.r.rows || []) : []
        readonly property int cell: Math.max(3, Math.round(pane.ch * 0.3))
        x: pane.cw
        y: pane.ch * 0.4
        width: visible ? (m.length + 8) * cell : 0
        height: width
        onMChanged: requestPaint()
        onPaint: {
          var ctx = getContext("2d")
          ctx.fillStyle = "#ffffff"
          ctx.fillRect(0, 0, width, height)
          ctx.fillStyle = "#000000"
          for (var y = 0; y < m.length; y++)
            for (var x = 0; x < m[y].length; x++)
              if (m[y].charAt(x) === "1") ctx.fillRect((x + 4) * cell, (y + 4) * cell, cell, cell)
        }
      }
      Column {
        visible: rowItem.r.kind === "qr"
        x: qrCode.x + qrCode.width + pane.cw * 2
        y: qrCode.y + pane.ch * 0.2
        width: parent.width - x
        spacing: pane.ch * 0.3
        Text {
          width: parent.width; elide: Text.ElideRight
          textFormat: Text.StyledText
          text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> scan with the phone\'s camera'
          font.family: host.family; font.pixelSize: Style.font.body; color: host.fg
        }
        Text {
          width: parent.width; wrapMode: Text.WrapAnywhere
          text: rowItem.r.label || ""
          font.family: host.family; font.pixelSize: Style.font.caption; color: host.dim
        }
        Text {
          width: parent.width; wrapMode: Text.WordWrap
          text: "same network only · the code is the key: anyone with it can drive the player"
          font.family: host.family; font.pixelSize: Style.font.caption; color: host.dim
        }
      }

      Text {
        visible: rowItem.r.kind === "header" || rowItem.r.kind === "note"
        anchors.bottom: parent.bottom; anchors.bottomMargin: pane.ch * 0.15
        x: rowItem.r.kind === "note" ? pane.cw : 0
        width: parent.width - x
        clip: true
        textFormat: Text.StyledText
        text: rowItem.r.kind === "header"
              ? '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + Tui.esc(rowItem.r.label || "")
                + ' <font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
              : Tui.esc(rowItem.r.label || "")
        font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: rowItem.r.kind === "header" ? 1 : 0
        color: host.dim
      }

      Row {
        visible: pane.selectable(rowItem.r)
        x: pane.cw * 1.5
        y: (rowItem.rowH - height) / 2
        spacing: pane.cw * 2
        Text {
          readonly property bool current: rowItem.r.kind === "theme" && Color.name === rowItem.r.id
          width: pane.labelW
          elide: Text.ElideRight
          text: (rowItem.r.kind === "theme" ? (current ? "● " : "  ") : "") + (rowItem.r.label || "")
          font.family: host.family; font.pixelSize: Style.font.body
          font.bold: current
          color: current ? host.accentText
               : rowItem.dimmed ? host.dim
               : rowItem.isCursor ? host.fg : Tui.mix(host.fg, host.dim, 0.35)
        }
        // the value: ◂ choice ▸, [x] toggle, a hotkey with its state, a text
        Row {
          id: valueRow
          visible: !rowItem.isEditing
          spacing: 0
          readonly property bool stepper: rowItem.r.kind === "choice" || rowItem.r.kind === "number"
          readonly property color arrow: rowItem.isCursor && !rowItem.dimmed ? host.accent : host.dim
          Text {
            visible: valueRow.stepper
            text: "◂ "
            font.family: host.family; font.pixelSize: Style.font.body
            color: leftArrow.containsMouse ? host.accentText : valueRow.arrow
            MouseArea { id: leftArrow; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { pane.forceActiveFocus(); pane.cursor = rowItem.index; pane.change(-1) } }
          }
          Text {
            id: valueText
            textFormat: Text.StyledText
            text: {
              var r = rowItem.r
              if (r.kind === "choice" || r.kind === "number" || r.kind === "toggle") return Tui.esc(pane.valueText(r))
              if (r.kind === "text") {
                var v = pane.value(r)
                return v ? Tui.esc(pane.valueText(r)) : '<font color="' + Tui.hex(host.dim) + '">' + Tui.esc(pane.valueText(r)) + '</font>'
              }
              if (r.kind === "hotkey" && r.row) {
                var st = r.row.state
                var mine = (pane.cfg.hotkeys || {})[r.id] !== undefined
                return (st === "active" ? '<font color="' + Tui.hex(host.accentText) + '">● ' + Tui.esc(r.row.combo) + '</font>'
                      : st === "off" ? '<font color="' + Tui.hex(host.dim) + '">○ off</font>'
                      : '<font color="' + Tui.hex(Color.urgent) + '">✕ none registered</font>')
                     + (mine ? '<font color="' + Tui.hex(host.dim) + '">  · yours</font>' : '')
              }
              return ""
            }
            font.family: host.family; font.pixelSize: Style.font.body
            font.bold: rowItem.isCursor && valueRow.stepper && !rowItem.dimmed
            color: rowItem.dimmed ? host.dim
                 : rowItem.r.kind === "toggle" && pane.value(rowItem.r) ? host.accentText : host.fg
            Behavior on color { ColorAnimation { duration: pane.tMid; easing.type: Easing.InOutCubic } }
          }
          Text {
            visible: valueRow.stepper
            text: " ▸"
            font.family: host.family; font.pixelSize: Style.font.body
            color: rightArrow.containsMouse ? host.accentText : valueRow.arrow
            MouseArea { id: rightArrow; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: { pane.forceActiveFocus(); pane.cursor = rowItem.index; pane.change(1) } }
          }
        }
        // what else there is to know: a status, a key, that it differs from the default
        Text {
          visible: !rowItem.isEditing
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.StyledText
          text: {
            var r = rowItem.r, bits = []
            if (r.hint) bits.push(Tui.esc(r.hint))
            if (r.key) bits.push('<font color="' + Tui.hex(rowItem.isCursor ? host.accentText : host.dim) + '">' + Tui.esc(r.key) + '</font>')
            if (r.def !== undefined && r.kind !== "text" && !pane.isDefault(r)) bits.push("•")
            return bits.join("  ")
          }
          font.family: host.family; font.pixelSize: Style.font.caption
          color: host.dim
        }
        // Editing: a hotkey (press the combination, or type it), a text, a number.
        Row {
          visible: rowItem.isEditing
          Text { text: "❯ "; font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText; font.bold: true }
          TextInput {
            id: edit
            width: pane.cw * (rowItem.r.kind === "hotkey" ? 26 : 34)
            font.family: host.family; font.pixelSize: Style.font.body
            color: host.fg
            clip: true
            echoMode: rowItem.r.secret ? TextInput.Password : TextInput.Normal
            inputMethodHints: rowItem.r.kind === "number" ? Qt.ImhDigitsOnly : Qt.ImhNone
            selectionColor: Tui.alpha(Color.accent, 0.35)
            cursorDelegate: Rectangle { width: pane.cw; color: host.accent; opacity: 0.7 }
            Keys.onPressed: function(e) {
              if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { pane.commitEdit(text); e.accepted = true; return }
              if (e.key === Qt.Key_Escape) { pane.cancelEdit(); e.accepted = true; return }
              if (rowItem.r.kind !== "hotkey") return
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
            text: rowItem.r.kind === "hotkey" ? "  press it or type it · ⏎ set · empty ⏎ default · esc keep"
                : rowItem.r.kind === "number" ? "  " + rowItem.r.min + "–" + rowItem.r.max + " · ⏎ set · empty ⏎ default · esc keep"
                : "  paste or type · ⏎ save · empty ⏎ clears · esc keep"
            font.family: host.family; font.pixelSize: Style.font.caption; color: host.dim
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
      Text {
        visible: rowItem.misses !== ""
        x: pane.cw * 3.5 + pane.labelW
        y: pane.ch * 1.25
        width: parent.width - x
        elide: Text.ElideRight
        text: rowItem.misses
        font.family: host.family; font.pixelSize: Style.font.caption
        color: Tui.mix(host.dim, Color.urgent, 0.35)
      }

      // under the pointer a row takes a faint fill, like the player's lists
      Rectangle {
        z: -1
        width: parent.width; height: rowItem.rowH
        opacity: rowMouse.containsMouse && !rowItem.isCursor ? 1 : 0
        color: Tui.alpha(Color.accent, 0.07)
        Behavior on opacity { NumberAnimation { duration: pane.tFast; easing.type: Easing.InOutCubic } }
      }
      // A click selects and does the obvious thing: steps a choice, flips a
      // toggle, runs an action, applies a theme. Right-click steps back; a
      // double-click edits a hotkey, a text or a number.
      MouseArea {
        id: rowMouse
        z: -1
        width: parent.width; height: rowItem.rowH
        enabled: pane.selectable(rowItem.r) && !rowItem.isEditing
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: function(m) {
          pane.forceActiveFocus()
          pane.cursor = rowItem.index
          var k = rowItem.r.kind
          if (m.button === Qt.RightButton) pane.change(-1)
          else if (k === "toggle" || k === "choice" || k === "number") pane.change(1)
          else if (k === "action" || k === "theme") pane.activate()
        }
        onDoubleClicked: function(m) {
          var k = rowItem.r.kind
          if (m.button === Qt.LeftButton && (k === "hotkey" || k === "text" || k === "number")) pane.activate()
        }
      }
    }
  }

  // ╱╱ what the selected row does, and its default
  Text {
    id: descLine
    anchors.bottom: footer.top; anchors.bottomMargin: pane.ch * 0.3
    x: pane.cw
    width: parent.width - pane.cw * 2
    elide: Text.ElideRight
    textFormat: Text.StyledText
    readonly property var r: pane.rows[pane.cursor] || ({})
    text: {
      var r = descLine.r
      if (!pane.selectable(r) || !r.desc) return " "
      var out = '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + Tui.esc(r.desc)
      var dt = pane.defaultText(r)
      if (r.def !== undefined && r.kind !== "text" && dt !== "")
        out += '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.2)) + '">   · default ' + Tui.esc(dt)
             + (pane.isDefault(r) ? "" : ", d puts it back") + '</font>'
      if (pane.searching) out += '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.2)) + '">   · in ' + Tui.esc(pane.sections[r.sec].label) + '</font>'
      return out
    }
    font.family: host.family; font.pixelSize: Style.font.caption
    color: host.fg
    opacity: 1
    onTextChanged: { opacity = 0.35; fadeIn.restart() }
    NumberAnimation { id: fadeIn; target: descLine; property: "opacity"; to: 1; duration: pane.tMid; easing.type: Easing.InOutCubic }
  }

  // the keys for the row under the cursor, each one a button too
  HintBar {
    id: footer
    anchors.bottom: parent.bottom
    x: pane.cw
    keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
    readonly property var r: pane.rows[pane.cursor] || ({})
    items: {
      var r = footer.r, h = []
      if (pane.searching) h.push({ k: "esc", l: "clear search", run: function() { pane.endSearch() } })
      else h.push({ k: "⇥", l: "section", run: function() { pane.goSection(pane.section + 1) }, tip: "next section", tipKey: "⇥" })
      h.push({ k: "j/k", l: "move" })
      if (r.kind === "choice" || r.kind === "number") h.push({ k: "h/l", l: "change", run: function() { pane.change(1) }, tip: "next value", tipKey: "l" })
      if (r.kind === "toggle") h.push({ k: "⏎", l: "toggle", run: function() { pane.activate() } })
      if (r.kind === "hotkey") h = h.concat([{ k: "⏎", l: "rebind", run: function() { pane.activate() } },
                                           { k: "x", l: "off", run: function() { pane.setHotkey(r.id, ""); host.say(r.label + " · off") } },
                                           { k: "d", l: "default", run: function() { pane.setHotkey(r.id, undefined); host.say(r.label + " · default") } }])
      else if (r.kind === "text" || r.kind === "number") h.push({ k: "⏎", l: "edit", run: function() { pane.activate() } })
      else if (r.kind === "theme") h.push({ k: "⏎", l: "apply", run: function() { pane.activate() } })
      else if (r.kind === "action") h.push({ k: "⏎", l: "run", run: function() { pane.activate() } })
      if (r.def !== undefined && r.kind !== "hotkey" && !pane.isDefault(r)) h.push({ k: "d", l: "default", run: function() { pane.resetValue(r) } })
      if (!pane.searching) h.push({ k: "/", l: "search", run: function() { pane.startSearch() } })
      h.push({ k: "esc", l: "back", run: function() { host.back() } })
      return h
    }
  }

  Component.onCompleted: cursor = firstRow()
}
