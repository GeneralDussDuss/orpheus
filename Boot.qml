import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// The boot screen: ~1.4 s over the player window the first time it opens in a
// run (Library.qml mounts it in a Loader and drops it on `finished`).
//
//   0.00  the screen powers on out of a lit line (shaders/boot.frag)
//   0.04  ORPHEUS decodes in left to right, in the accent, with its halo
//   0.30  the boot log: one line per part of the app, each settling to
//         ok / skip / … from the REAL state (service, session, capture,
//         queue, theme). Nothing waits on them: a part that isn't up by the
//         deadline reads "…" and the library shows its own state after.
//   0.32  the spectrum rises off the progress rule: live bands if music is
//         already playing, otherwise a sweep
//   1.10  the screen dissolves cell by cell, left to right, into the library
//
// Any key or click skips it. A game in front or a hidden window skips it at
// once. Never more than 1.6 s whatever happens.
Item {
  id: boot
  anchors.fill: parent

  property var host: null
  property var engine: null
  signal finished()

  focus: true

  // ---- timeline (seconds) ---------------------------------------------------
  readonly property real logAt: 0.30
  readonly property real logStep: 0.075
  readonly property real deadline: 1.02      // a part not up by now reads "…"
  readonly property real revealAt: 1.10
  readonly property real revealLen: 0.32
  readonly property real endAt: revealAt + revealLen
  property real t: 0

  NumberAnimation on t {
    id: clock
    from: 0; to: boot.endAt
    duration: boot.endAt * 1000
    easing.type: Easing.Linear
    running: false
    onFinished: boot.finish()
  }
  Timer { interval: 1600; running: true; onTriggered: boot.finish() }   // hard cap

  property bool done: false
  function finish() {
    if (done) return
    done = true
    clock.stop()
    // later, not now: the Loader connects to `finished` after this item is made
    Qt.callLater(boot.finished)
  }
  function maybeSkip() {
    if (done) return
    var w = boot.Window.window
    if ((engine && engine.gameMode) || (w && (!w.visible || w.visibility === Window.Minimized))) finish()
  }
  onEngineChanged: maybeSkip()
  Connections {
    target: boot.engine
    ignoreUnknownSignals: true
    function onGameModeChanged() { boot.maybeSkip() }
  }
  Connections {
    target: boot.Window.window
    ignoreUnknownSignals: true
    function onVisibleChanged() { boot.maybeSkip() }
    function onVisibilityChanged() { boot.maybeSkip() }
  }
  // Keys have to land here while it shows. The player moves focus to its list
  // as it opens, in the same pass that mounts this, so take it back after
  // that, and again if something takes it mid-boot (a few times, never a fight).
  property int retakes: 0
  function take() { if (!done) forceActiveFocus() }
  onActiveFocusChanged: if (!activeFocus && !done && retakes < 4) { retakes++; Qt.callLater(take) }
  onHostChanged: Qt.callLater(take)
  Component.onCompleted: {
    take()
    Qt.callLater(take)
    clock.start()
    Qt.callLater(maybeSkip)
  }

  // Everything is eaten while it shows: keys skip, Shortcuts don't fire.
  Keys.onShortcutOverride: function(e) { e.accepted = true }
  Keys.onPressed: function(e) { e.accepted = true; boot.finish() }
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    hoverEnabled: true
    preventStealing: true
    onPressed: function(m) { m.accepted = true; boot.finish() }
    onWheel: function(w) { w.accepted = true }
  }

  // ---- look -------------------------------------------------------------------
  readonly property var api: host && host.api ? host.api : (engine ? engine.api : null)
  readonly property color bg: Color.background
  readonly property color fg: host ? host.fg : Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: host ? host.dim : Tui.muted(Color.foreground, bg, 4.5)
  readonly property color acc: host ? host.accentText : Tui.ensure(Color.accent, bg, 4.5)
  readonly property color accRaw: Color.accent
  readonly property color faint: Tui.mix(dim, bg, 0.55)
  readonly property string family: host && host.family ? host.family : Style.font.family
  readonly property bool light: Tui.lum(bg) > 0.4
  readonly property real glowK: Tui.bloom(engine)

  // A boot screen reads from across the room: on a tall window the type
  // grows past the player's body size, up to half again.
  readonly property real k: Math.max(1, Math.min(1.5, height / 960))
  readonly property int bodyPx: Math.round(Style.font.body * k)
  readonly property int capPx: Math.round(Style.font.caption * k)
  TextMetrics { id: cellM; font.family: boot.family; font.pixelSize: boot.bodyPx; text: "MMMMMMMMMM" }
  readonly property real colW: cellM.advanceWidth > 0 ? cellM.advanceWidth / 10 : 8
  readonly property real rowH: cellM.height > 0 ? cellM.height : 16
  readonly property int cols: 48             // the log, the bars and the rule share this width
  readonly property int markSize: Math.round(bodyPx * 3.6)

  function clamp01(v) { return Math.max(0, Math.min(1, v)) }
  function smooth(a, b, v) { var x = clamp01((v - a) / (b - a)); return x * x * (3 - 2 * x) }

  // Text mid-decode: noise first, then settling left to right. One glyph per
  // character, spaces kept, so the monospace line never changes width.
  readonly property string noise: "!<>-_\\/[]{}=+*^?#%&$@01░▒▓"
  readonly property int churn: Math.floor(t * 24)           // the noise moves at 24 Hz, not per frame
  function decode(s, p, salt) {
    s = String(s)
    if (p >= 1) return s
    var settled = Math.floor(s.length * clamp01((p - 0.15) / 0.85))
    var out = s.slice(0, settled)
    for (var i = settled; i < s.length; i++) {
      var c = s.charAt(i)
      out += c === " " ? " " : noise.charAt(Math.floor(Math.abs(Math.sin((i + 1) * 12.9898 + (churn + salt) * 78.233) * 43758.5453)) % noise.length)
    }
    return out
  }
  function pad(s, n) { s = String(s); while (s.length < n) s += " "; return s.length > n ? s.slice(0, n) : s }
  function lpad(s, n) { s = String(s); while (s.length < n) s = " " + s; return s }

  // ---- real state ---------------------------------------------------------------
  function themeLabel() {
    var n = Color.name
    if (!n) return "omarchy"
    return (n === "album" ? "album art" : String(n).replace(/-/g, " ")) + (light ? " · light" : "")
  }
  // { s: "ok" | "skip" | "wait", d: detail }
  function probe(i) {
    var a = boot.api, on = !!a && a.online === true
    switch (i) {
    case 0:
      if (on) return { s: "ok", d: "online" }
      return { s: "wait", d: a && a.reconnecting ? "reconnecting" : a && !a.connecting && a.active ? "not running" : "starting" }
    case 1:
      if (!on) return { s: "wait", d: "waiting on service" }
      if (a.signedIn) return { s: "ok", d: a.login && a.login.hires ? "signed in · hi-res" : "signed in · lossless" }
      return { s: "skip", d: "signed out" }
    case 2:
      if (!engine) return { s: "wait", d: "" }
      if (engine.listening) return { s: "ok", d: "live" }
      if (engine.hasCava) return { s: "ok", d: engine.useAudiocap ? "loopback ready" : "cava ready" }
      return { s: "skip", d: "unavailable" }
    case 3:
      if (!on) return { s: "wait", d: "" }
      var n = (a.player && a.player.queueLength) || 0
      if (n > 0) return { s: "ok", d: n + (n === 1 ? " track" : " tracks") + (a.player.playing ? " · playing" : "") }
      return { s: "skip", d: "empty" }
    default:
      return { s: "ok", d: themeLabel() }
    }
  }
  readonly property var labels: ["player service", "tidal session", "audio capture", "queue", "theme"]

  // Each line settles once it has been on screen a beat AND its part is up
  // (or the deadline passed). A "…" line can still settle later if its part
  // arrives before the reveal.
  property var settled: [null, null, null, null, null]       // { s, d, at }
  onTChanged: {
    if (done) return
    var changed = false, next = settled.slice()
    for (var i = 0; i < labels.length; i++) {
      var ready = t >= logAt + i * logStep + 0.16
      if (!ready) continue
      var cur = next[i]
      if (cur && cur.s !== "…") continue
      var pr = probe(i)
      if (pr.s !== "wait") { next[i] = { s: pr.s, d: pr.d, at: t }; changed = true }
      else if (!cur && t >= deadline) { next[i] = { s: "…", d: pr.d, at: t }; changed = true }
    }
    if (changed) settled = next
  }
  readonly property real progress: {
    var n = 0
    for (var i = 0; i < settled.length; i++) if (settled[i]) n += settled[i].s === "…" ? 0.5 : 1
    return clamp01(0.15 * smooth(0.1, 0.4, t) + 0.85 * n / settled.length)
  }

  // ---- live bands ---------------------------------------------------------------
  readonly property bool live: {
    if (!engine || !engine.listening || !engine.levels || engine.levels.length < 8) return false
    var m = 0
    for (var i = 0; i < engine.levels.length; i++) m = Math.max(m, engine.levels[i] || 0)
    return m > 0.03
  }
  function level(x) {          // x 0..1 across the bars, 0..1 out
    var rise = smooth(0.32, 0.62, t)
    if (live) {
      var lv = engine.levels, n = lv.length
      var f = x * (n - 1), i = Math.floor(f), k = f - i
      var v = (lv[i] || 0) * (1 - k) + (lv[Math.min(n - 1, i + 1)] || 0) * k
      return clamp01(rise * (0.06 + v))
    }
    // a sweep: a crest runs across once, over a gently moving floor
    var pos = (t - 0.32) / 0.72 * 1.5 - 0.25
    var crest = Math.exp(-Math.pow((x - pos) / 0.11, 2))
    var floor = 0.16 + 0.10 * (0.5 + 0.5 * Math.sin(x * 19.0 + t * 7.0)) * (0.5 + 0.5 * Math.sin(x * 7.3 - t * 4.1))
    var tilt = 1 - 0.45 * x
    return clamp01(rise * (floor * tilt + 0.78 * crest))
  }

  // ---- the screen ---------------------------------------------------------------
  Item {
    id: screen
    anchors.fill: parent

    layer.enabled: true
    layer.effect: ShaderEffect {
      fragmentShader: "shaders/boot.frag.qsb"
      property vector2d res: Qt.vector2d(boot.width, boot.height)
      property vector2d cell: Qt.vector2d(boot.colW, boot.rowH)
      property real power: boot.clamp01(boot.t / 0.16)
      property real flick: boot.t < 0.2 ? 0.7 + 0.3 * Math.abs(Math.sin(boot.t * 211.0)) : 1
      property real scan: boot.light ? 0 : 1 - boot.smooth(0.15, 0.6, boot.t) * 0.85
      property real reveal: boot.smooth(boot.revealAt, boot.endAt, boot.t)
      property real seed: 7.31
      property real light: boot.light ? 1 : 0
      property color bg: boot.bg
      property color accent: boot.accRaw
    }

    Rectangle { anchors.fill: parent; color: boot.bg }

    Column {
      id: stack
      anchors.centerIn: parent
      anchors.verticalCenterOffset: -boot.height * 0.03
      spacing: boot.rowH * 0.5

      // ORPHEUS between two runs of slashes, the sign-in page's header writ large
      Item {
        width: boot.cols * boot.colW
        height: mark.implicitHeight
        GlowText {
          id: mark
          readonly property real p: boot.clamp01((boot.t - 0.04) / 0.5)
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.horizontalCenterOffset: boot.markSize * 0.21   // tracking trails the last glyph
          text: boot.decode("ORPHEUS", p, 3)
          font.family: boot.family
          font.pixelSize: boot.markSize
          font.bold: true
          font.letterSpacing: boot.markSize * 0.42
          color: p >= 1 ? boot.acc : Tui.mix(boot.acc, boot.fg, 0.25)
          // a lift as the last glyph lands, then a steady halo
          glow: boot.glowK * (0.55 + 0.45 * Math.exp(-Math.max(0, boot.t - 0.54) * 9) * (p >= 1 ? 1 : 0.4))
          glowColor: boot.accRaw
          glowRadius: 18
        }
        Text {
          anchors.right: mark.left; anchors.rightMargin: boot.colW * 2
          anchors.verticalCenter: mark.verticalCenter
          text: "╱╱╱╱".slice(0, Math.round(4 * boot.smooth(0.12, 0.5, boot.t)))
          font.family: boot.family; font.pixelSize: Math.round(boot.bodyPx * 1.45); font.bold: true
          color: boot.faint
        }
        Text {
          anchors.left: mark.right; anchors.leftMargin: boot.colW * 2 - boot.markSize * 0.42
          anchors.verticalCenter: mark.verticalCenter
          text: "╱╱╱╱".slice(4 - Math.round(4 * boot.smooth(0.12, 0.5, boot.t)))
          font.family: boot.family; font.pixelSize: Math.round(boot.bodyPx * 1.45); font.bold: true
          color: boot.faint
        }
      }

      Item { width: 1; height: boot.rowH * 0.6 }

      // the boot log
      Column {
        spacing: boot.rowH * 0.18
        Repeater {
          model: boot.labels.length
          Row {
            id: line
            required property int index
            readonly property real at: boot.logAt + index * boot.logStep
            readonly property var st: boot.settled[index]
            readonly property real since: st ? boot.t - st.at : 0
            readonly property string detail: st ? boot.decode(st.d, since / 0.16, 11 + index) : ""
            readonly property string label: boot.decode(boot.labels[index], (boot.t - at) / 0.16, 5 + index)
            opacity: boot.t >= at ? 1 : 0
            Text {   // status, right-aligned in four cells
              width: boot.colW * 4
              horizontalAlignment: Text.AlignRight
              text: !line.st ? Tui.spinner(boot.t) : line.st.s
              color: !line.st ? boot.acc : line.st.s === "ok" ? boot.acc : boot.dim
              font.family: boot.family; font.pixelSize: boot.bodyPx; font.bold: !!line.st && line.st.s === "ok"
            }
            Text {
              text: "  " + line.label + " "
              color: boot.fg
              font.family: boot.family; font.pixelSize: boot.bodyPx
            }
            Text {   // leader dots out to the detail
              readonly property int n: Math.max(2, boot.cols - 4 - 3 - line.label.length - line.detail.length - 1)
              text: "·".repeat(n) + " "
              color: boot.faint
              font.family: boot.family; font.pixelSize: boot.bodyPx
            }
            Text {
              text: line.detail
              color: line.st && line.st.s === "ok" ? boot.fg : boot.dim
              font.family: boot.family; font.pixelSize: boot.bodyPx
            }
          }
        }
      }

      Item { width: 1; height: boot.rowH * 0.5 }

      // the spectrum, standing on the progress rule
      Item {
        width: boot.cols * boot.colW
        height: barRow.height + rule.height
        Row {
          id: barRow
          height: boot.rowH * 2.5
          Repeater {
            model: boot.cols
            Item {
              required property int index
              width: boot.colW
              height: barRow.height
              readonly property real step: boot.rowH / 4            // heights land on quarter cells, like ▂▄▆█
              readonly property real v: boot.level(index / (boot.cols - 1))
              Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.max(1, parent.width - 2)
                height: Math.round(parent.v * parent.height / parent.step) * parent.step
                color: boot.acc
                opacity: 0.35 + 0.65 * parent.v
              }
            }
          }
        }
        Text {
          id: rule
          anchors.top: barRow.bottom
          textFormat: Text.StyledText
          text: Tui.meterRich(boot.progress, boot.cols, boot.acc, boot.faint)
          font.family: boot.family; font.pixelSize: boot.bodyPx
        }
        Text {
          anchors.top: rule.bottom; anchors.topMargin: boot.rowH * 0.15
          anchors.right: parent.right
          text: boot.t < 0.4 ? "" : boot.decode(boot.progress >= 1 ? "ready" : "booting", (boot.t - 0.4) / 0.2, 21)
          color: boot.progress >= 1 ? boot.acc : boot.dim
          font.family: boot.family; font.pixelSize: boot.capPx
        }
        Text {
          anchors.top: rule.bottom; anchors.topMargin: boot.rowH * 0.15
          text: boot.t < 0.4 ? "" : (boot.live ? "live input" : "any key to skip")
          color: boot.dim
          font.family: boot.family; font.pixelSize: boot.capPx
        }
      }
    }
  }
}
