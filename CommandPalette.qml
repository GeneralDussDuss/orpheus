import QtQuick
import Quickshell.Io
import qs.Commons
import "Tui.js" as Tui

// Ctrl+K: every action in the player by name. Type a few letters of it, in
// order, anywhere in the words ("nxt", "set sty orb", "thm nord"); ↑/↓ or
// ctrl+j/k pick, ⏎ runs, esc closes. Every entry reads "verb object", with
// the value after a ·  ("set theme · nord", "toggle trails"), its state on the
// right ("on", "● now") and the key that does the same from the player.
//
// The catalogue is built here, fresh on each open so a toggle reads the way it
// is right now. What you run is counted (state/palette.json), so the things you
// reach for come first: under "recent" on an empty prompt, and ahead of an
// equally good match when you type.
Item {
  id: pal

  property var host: null
  property bool shown: false
  property var all: []            // [{ id, group, label, key, now, run }]
  property var hits: []           // indices into `all`, best first; -1 = a group header
  property var heads: []          // for each hit: the group header to draw above it, or ""
  property int cursor: 0

  anchors.fill: parent
  visible: opacity > 0
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.InOutCubic } }
  z: 50

  function open() {
    all = catalogue()
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
    if (!c) return
    used(c.id)
    c.run()
  }

  // ---- what you use ----------------------------------------------------------
  property var usage: ({})        // id -> { n: times run, t: last run (ms) }
  FileView {
    id: usageFile
    path: pal.host && pal.host.engine ? pal.host.engine.stateDir + "/palette.json" : ""
    printErrors: false
    onLoaded: { try { pal.usage = JSON.parse(text()) || {} } catch (e) { pal.usage = {} } }
  }
  function used(id) {
    var u = JSON.parse(JSON.stringify(usage))
    var e = u[id] || { n: 0, t: 0 }
    e.n += 1; e.t = Date.now()
    u[id] = e
    // keep the file small: the 60 most recent
    var ids = Object.keys(u).sort(function(a, b) { return u[b].t - u[a].t })
    for (var i = 60; i < ids.length; i++) delete u[ids[i]]
    usage = u
    if (usageFile.path) usageFile.setText(JSON.stringify(u))
  }
  // frecency: how often, discounted by how long ago (a week halves it)
  function rank(id) {
    var e = usage[id]
    if (!e) return 0
    var days = Math.max(0, (Date.now() - e.t) / 86400000)
    return Math.log(1 + e.n) * Math.pow(0.5, days / 7)
  }

  // ---- the catalogue ----------------------------------------------------------
  //
  // Groups in the order a list reads best; each entry's `id` is stable across
  // runs (it is what the usage counts key on).
  readonly property var groupOrder: ["playback", "go", "visuals", "sound", "sleep", "behaviour", "integrations", "theme", "advanced"]

  function catalogue() {
    var out = [], h = host, e = h.engine, a = h.api, st = h.st || {}
    function add(id, group, label, key, now, run) { out.push({ id: id, group: group, label: label, key: key || "", now: now || "", run: run }) }
    function onOff(v) { return v ? "on" : "off" }
    // a key the player already answers to, pressed for you: the palette and the
    // keyboard can never disagree about what it does
    function press(text, key) { return function() { h.handleKey({ text: text, key: key || 0, modifiers: 0, accepted: false }) } }
    function cfgSet(k, v) { return function() { e.updateConfig(function(c) { c[k] = v }) } }

    // playback
    if (a) {
      add("play.toggle", "playback", st.playing ? "pause" : (h.track ? "resume" : "play"), "space", "", function() { a.control("toggle") })
      add("play.next", "playback", "play next track", "n", "", function() { a.control("next") })
      add("play.prev", "playback", "play previous track", "p", "", function() { a.control("previous") })
      add("play.fwd", "playback", "seek forward 10 s", "l", "", function() { a.control("seek", { position: (a.position || 0) + 10 }) })
      add("play.back", "playback", "seek back 10 s", "h", "", function() { a.control("seek", { position: Math.max(0, (a.position || 0) - 10) }) })
      add("play.volup", "playback", "raise volume", "+", "", press("+", Qt.Key_Plus))
      add("play.voldown", "playback", "lower volume", "-", "", press("-", Qt.Key_Minus))
      add("play.shuffle", "playback", "toggle shuffle", "s", onOff(st.shuffle), function() { a.control("shuffle") })
      add("play.repeat", "playback", "cycle repeat", "r", st.repeat || "off", function() { a.control("repeat") })
      if (h.track) {
        var liked = a.isLiked && a.isLiked("track", h.track.id)
        add("play.like", "playback", liked ? "unlike this track" : "like this track", "F", "", function() { a.toggleLike("track", h.track.id) })
        add("share.link", "playback", "copy track link", "y", "", function() { h.share(false) })
        add("share.universal", "playback", "copy universal link", "Y", "", function() { h.share(true) })
      }
      if (h.pageTracks && h.pageTracks.length) {
        add("play.page", "playback", "play this page", "P", "", function() { h.playPage(false) })
        add("play.pageShuffle", "playback", "shuffle this page", "S", "", function() { h.playPage(true) })
      }
    }

    // go
    var nav = h.navItems || []
    for (var n = 0; n < nav.length; n++)
      (function(it) { add("go." + it.label, "go", "go to " + it.label, it.key, "", function() { h.go(it.page) }) })(nav[n])
    add("go.eq", "go", "open equalizer", "e", "", h.showEq)
    add("go.lyrics", "go", "open lyrics", "L", "", h.showLyrics)
    add("go.keys", "go", "open keys sheet", "?", "", press("?"))
    add("go.wrapped", "go", "open wrapped · this month", "", "", function() { h.go({ type: "stats", title: "stats", range: "wrapped" }) })
    add("go.login", "go", "open sign in", "", "", h.showLogin)
    add("go.close", "go", "close player", "q", "", function() { e.libraryOpen = false })

    if (e) {
      // visuals
      add("viz.window", "visuals", "toggle visualizer window", "V", e.open ? "open" : "closed", function() { e.open = !e.open })
      add("viz.nextStyle", "visuals", "cycle visualizer style", "", "", function() { e.nextStyle(1) })
      for (var i = 0; i < e.styles.length; i++)
        (function(s) {
          add("viz.style." + s, "visuals", "set style · " + e.styleLabels[s].toLowerCase(), "", e.style === s ? "● now" : "", function() { e.setStyle(s) })
        })(e.styles[i])
      add("viz.nextRail", "visuals", "cycle rail visual", "v", "", function() { e.cycleRailViz(1) })
      var rails = ["off"].concat(e.styles)
      for (var ri = 0; ri < rails.length; ri++)
        (function(s) {
          add("viz.rail." + s, "visuals", "set rail · " + (s === "off" ? "album art" : e.styleLabels[s].toLowerCase()), "", e.railViz === s ? "● now" : "", function() { e.setRailViz(s) })
        })(rails[ri])
      var places = e.placements || ["overlay", "desktop"], placeNames = { overlay: "window on top", desktop: "wallpaper", fullscreen: "fullscreen show" }
      for (var pl = 0; pl < places.length; pl++)
        (function(p) { add("viz.as." + p, "visuals", "set visualizer as · " + (placeNames[p] || p), "", e.placement === p ? "● now" : "", function() { e.setPlacement(p) }) })(places[pl])
      var levels = ["off", "subtle", "full"]
      for (var b = 0; b < levels.length; b++)
        (function(lv) {
          add("viz.bloom." + lv, "visuals", "set bloom · " + lv, "", e.bloom === lv ? "● now" : "", function() { e.setBloom(lv) })
          if (e.setFeedback)
            add("viz.trails." + lv, "visuals", "set trails · " + lv, "", e.feedback === lv ? "● now" : "", function() { e.setFeedback(lv) })
        })(levels[b])
      var flags = [["trackTitle", "toggle title card"], ["lyricsOverViz", "toggle lyrics over visualizer"],
                   ["director", "toggle song structure"], ["beatLock", "toggle beat lock"], ["autoStyle", "toggle style switch on drops"]]
      for (var g = 0; g < flags.length; g++)
        (function(fl) {
          if (typeof e[fl[0]] !== "boolean") return
          add("viz." + fl[0], "visuals", fl[1], "", onOff(e[fl[0]]), function() { e.setStageFlag(fl[0], "toggle") })
        })(flags[g])

      // sound
      if (a) {
        var qs = [["high", "320k"], ["lossless", "lossless"], ["hires", "hi-res"]]
        for (var q = 0; q < qs.length; q++)
          (function(x) {
            add("sound.quality." + x[0], "sound", "set quality · " + x[1], "", a.status && a.status.quality === x[0] ? "● now" : "", function() {
              if (x[0] === "hires" && !(a.login && a.login.hires)) h.go({ type: "login", title: "sign in", hires: true })
              else a.post("/quality", { quality: x[0] })
            })
          })(qs[q])
        add("sound.eq", "sound", "toggle equalizer", "", h.eqActive ? "on" : "bypassed", function() { a.post("/eq", { enabled: !h.eqActive }, function() {}) })
      }
      var endless = e.config.endless !== false
      add("sound.endless", "sound", "toggle endless play", "", onOff(endless), cfgSet("endless", !endless))
      var xf = Number(e.config.crossfade) || 0, xs = [0, 2, 4, 6, 8, 10, 12]
      for (var j = 0; j < xs.length; j++)
        (function(s) { add("sound.crossfade." + s, "sound", "set crossfade · " + (s ? s + " s" : "off"), "", xf === s ? "● now" : "", cfgSet("crossfade", s)) })(xs[j])
    }

    // sleep
    if (a) {
      var sl = (a.status && a.status.listening && a.status.listening.sleep) || a.sleepState || { active: false }
      var mins = [15, 30, 60]
      for (var m = 0; m < mins.length; m++)
        (function(mn) { add("sleep." + mn, "sleep", "set sleep timer · " + mn + " min", "", "", function() { a.sleep(mn); h.say("☾ sleeping in " + mn + " min") }) })(mins[m])
      add("sleep.end", "sleep", "set sleep timer · end of track", "", sl.active && sl.endOfTrack ? "● now" : "", function() { a.sleepAtEnd(); h.say("☾ sleeping at the end of this track") })
      if (sl.active) add("sleep.cancel", "sleep", "cancel sleep timer", "", "", function() { a.cancelSleep(); h.say("sleep timer off") })
    }

    if (e) {
      // behaviour
      var w = e.widget
      add("widget.toggle", "behaviour", "toggle widget", "", onOff(w.enabled !== false), function() { e.setWidget("enabled", "toggle") })
      var wstyles = ["compact", "full"]
      for (var ws = 0; ws < wstyles.length; ws++)
        (function(s) { add("widget.style." + s, "behaviour", "set widget style · " + s, "", w.style === s ? "● now" : "", function() { e.setWidget("style", s) }) })(wstyles[ws])
      var corners = ["top-left", "top-right", "bottom-left", "bottom-right"]
      for (var k = 0; k < corners.length; k++)
        (function(cn) { add("widget.corner." + cn, "behaviour", "set widget corner · " + cn, "", w.corner === cn ? "● now" : "", function() { e.setWidget("corner", cn) }) })(corners[k])
      add("widget.sync", "behaviour", "toggle widget follows visualizer", "", onOff(e.syncViz), cfgSet("syncViz", !e.syncViz))
      add("widget.mini", "behaviour", "toggle mini player", "", onOff(e.miniPlayer), function() { e.setMiniPlayer(e.miniPlayer ? "off" : "on") })
      if (typeof OrpheusKeys !== "undefined" && OrpheusKeys.windows) {
        add("win.startup", "behaviour", "toggle start with windows", "", onOff(OrpheusKeys.startWithWindows), function() { OrpheusKeys.setStartWithWindows(!OrpheusKeys.startWithWindows) })
        var toasts = e.config.toasts !== false
        add("win.toasts", "behaviour", "toggle track notifications", "", onOff(toasts), cfgSet("toasts", !toasts))
      }
      if (typeof OrpheusGame !== "undefined") {
        var gm = !(e.config.gameMode === "off" || e.config.gameMode === false)
        add("game.mode", "behaviour", "toggle step back for games", "", onOff(gm), cfgSet("gameMode", gm ? "off" : "auto"))
        var hud = !(e.config.hud === "off" || e.config.hud === false)
        add("game.hud", "behaviour", "toggle in-game HUD", "", onOff(hud), cfgSet("hud", hud ? "off" : "on"))
        add("game.hudShow", "behaviour", "show HUD now", "", "", function() { OrpheusGame.showHud() })
      }

      // integrations
      var lan = e.config.remote === "lan"
      add("remote.toggle", "integrations", "toggle phone remote", "", onOff(lan), function() {
        e.updateConfig(function(c) { c.remote = lan ? "off" : "lan" })
        if (!lan) h.say("phone remote on · the pairing code is in settings ▸ integrations")
      })
    }

    // theme
    if (typeof Color.themeList !== "undefined" && Color.themeList) {
      add("theme.builder", "theme", "open theme builder", "", "", function() { Color.openBuilder() })
      add("theme.next", "theme", "cycle theme", "", "", function() { Color.cycle(1) })
      var tl = Color.themeList
      for (var t = 0; t < tl.length; t++)
        (function(th) { add("theme." + th.name, "theme", "set theme · " + th.label.toLowerCase(), "", Color.name === th.name ? "● now" : "", function() { Color.setTheme(th.name); h.say("theme ╱╱ " + th.label) }) })(tl[t])
    }

    // advanced
    if (e) {
      var fpsList = [30, 60, 90, 120]
      for (var f = 0; f < fpsList.length; f++)
        (function(v) { add("adv.fps." + v, "advanced", "set frame rate · " + v + " fps", "", e.fps === v ? "● now" : "", cfgSet("fps", v)) })(fpsList[f])
      add("adv.autoQuality", "advanced", "toggle lower resolution when frames drop", "", onOff(e.autoQuality), function() { e.setStageFlag("autoQuality", "toggle") })
      add("adv.showFps", "advanced", "toggle fps counter", "", onOff(e.showFps), function() { e.setStageFlag("showFps", "toggle") })
    }

    // grouped, in a fixed order; the catalogue order inside a group is kept
    var order = groupOrder
    out.forEach(function(c, i) { c.ord = i })
    out.sort(function(x, y) { return (order.indexOf(x.group) - order.indexOf(y.group)) || (x.ord - y.ord) })
    return out
  }

  // ---- matching ----------------------------------------------------------------
  //
  // Subsequence match, scored: runs of consecutive letters and letters that
  // start a word count most, so "vo" finds "raise volume" before "set
  // visualizer as · overlay". Usage breaks near-ties.
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
    var q = input.text.trim().toLowerCase(), out = [], hd = []
    if (!q) {
      // recent first, then everything else by group (nothing listed twice)
      var rec = []
      for (var r = 0; r < all.length; r++) { var rk = rank(all[r].id); if (rk > 0) rec.push({ i: r, s: rk }) }
      rec.sort(function(a, b) { return b.s - a.s })
      rec = rec.slice(0, 5)
      var inRec = {}
      for (var k = 0; k < rec.length; k++) { inRec[rec[k].i] = true; out.push(rec[k].i); hd.push(k === 0 ? "recent" : "") }
      var last = ""
      for (var i = 0; i < all.length; i++) {
        if (inRec[i]) continue
        out.push(i); hd.push(all[i].group !== last ? all[i].group : "")
        last = all[i].group
      }
    } else {
      var sc = []
      for (var j = 0; j < all.length; j++) {
        var s = score(q, all[j].label)
        var sg = score(q, all[j].group + " " + all[j].label)
        var best = Math.max(s, sg - 1)
        // the letters as one piece beat the same letters scattered ("eq" is
        // the equalizer, not "set quality"), more so at the start of a word
        var at = all[j].label.toLowerCase().indexOf(q)
        if (best >= 0 && at >= 0) best += 6 + (at === 0 || " ·/-".indexOf(all[j].label.charAt(at - 1)) >= 0 ? 6 : 0)
        if (best >= 0) sc.push({ i: j, s: best + Math.min(3, rank(all[j].id) * 2) })
      }
      sc.sort(function(a, b) { return b.s - a.s || a.i - b.i })
      for (var n = 0; n < sc.length; n++) { out.push(sc[n].i); hd.push("") }
    }
    hits = out
    heads = hd
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
    width: Math.min(parent.width - host.cw * 4, host.cw * 80)
    height: Math.min(parent.height * 0.76, host.ch * 28)
    background: Qt.rgba(pal.base.r, pal.base.g, pal.base.b, 1)
    title: "commands"
    hintItems: [{ k: "⏎", l: "run", run: function() { pal.run(pal.cursor) } }, { k: "↑↓", l: "pick" },
                { k: "esc", l: "close", run: function() { pal.close() } }]
    footer: (input.text.trim() ? pal.hits.length + " of " + pal.all.length : pal.all.length + " commands")
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
          text: "a command: pause, set theme, toggle trails, open lyrics…"
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
      onCountChanged: { currentIndex = -1; currentIndex = Qt.binding(function() { return pal.cursor }) }
      highlight: Rectangle {
        width: results.width
        height: results.currentItem ? results.currentItem.rowH : 0
        y: results.currentItem ? results.currentItem.y + results.currentItem.headH : 0
        visible: !!results.currentItem
        color: host.cursorFill
        Behavior on y { NumberAnimation { duration: 120; easing.type: Easing.InOutCubic } }
        Rectangle { width: Math.max(2, host.cw * 0.3); height: parent.height; color: host.accent }
      }
      delegate: Item {
        id: hit
        required property int index
        readonly property var c: pal.all[pal.hits[index]] || ({})
        readonly property string head: pal.heads[index] || ""
        readonly property bool isCursor: index === pal.cursor
        readonly property real rowH: host.ch * 1.3
        readonly property real headH: head ? host.ch * (index === 0 ? 1.2 : 1.7) : 0
        width: ListView.view.width
        height: headH + rowH
        // ╱╱ group ──── above the first entry of each group (empty prompt only)
        Text {
          visible: hit.head !== ""
          anchors.bottom: rowArea.top; anchors.bottomMargin: host.ch * 0.1
          width: parent.width
          clip: true
          textFormat: Text.StyledText
          text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + Tui.esc(hit.head)
                + ' <font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(120) + '</font>'
          font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
          color: host.dim
        }
        Item {
          id: rowArea
          y: hit.headH
          width: parent.width
          height: hit.rowH
          Text {
            id: groupText
            x: host.cw
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.trim() !== ""
            width: visible ? host.cw * 13 : 0
            text: hit.c.group || ""
            font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            color: hit.isCursor ? host.accentText : host.dim
          }
          Text {
            anchors.left: groupText.right; anchors.leftMargin: groupText.visible ? 0 : host.cw * 1.5
            anchors.right: nowText.left; anchors.rightMargin: host.cw
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: hit.c.label || ""
            font.family: host.family; font.pixelSize: Style.font.body
            color: hit.isCursor ? host.fg : Tui.mix(host.fg, host.dim, 0.35)
          }
          Text {
            id: nowText
            anchors.right: keyText.left; anchors.rightMargin: host.cw * 2
            anchors.verticalCenter: parent.verticalCenter
            text: hit.c.now || ""
            font.family: host.family; font.pixelSize: Style.font.caption
            color: hit.c.now === "on" || hit.c.now === "● now" ? host.accentText : host.dim
          }
          Text {
            id: keyText
            anchors.right: parent.right; anchors.rightMargin: host.cw
            anchors.verticalCenter: parent.verticalCenter
            width: host.cw * 6
            horizontalAlignment: Text.AlignRight
            text: hit.c.key || ""
            font.family: host.family; font.pixelSize: Style.font.caption
            color: hit.isCursor ? host.accentText : host.dim
          }
          // The pointer moves the cursor and a click runs, like ⏎: a double-click
          // to run a command read as a palette that ignored the first click.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: if (pal.cursor !== hit.index) pal.cursor = hit.index
            onClicked: pal.run(hit.index)
          }
        }
      }
      Text {
        anchors.centerIn: parent
        visible: !pal.hits.length
        text: "nothing by that name · try fewer letters"
        font.family: host.family; font.pixelSize: Style.font.body
        color: host.dim
      }
    }
  }
}
