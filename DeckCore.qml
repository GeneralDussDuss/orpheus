import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
import "Tui.js" as Tui

// The brains every vertical hardware deck shares (WidgetMonolith,
// WidgetReference, WidgetField): the track, position and seek, the like, the
// stream's quality, the tempo and section with their settle window, the
// controls and their keys, the live-count bookkeeping, and the theme colours.
// A deck drops one of these in (`DeckCore { id: core; engine: deck.engine;
// keys: deck.keys }`), forwards its keys (`Keys.onPressed: (e) => core.key(e)`)
// and only draws. Lifted from WidgetCassette (the Studio deck), which keeps
// its own copy.
Item {
  id: core
  visible: false

  property var engine: null
  property bool keys: false

  readonly property var player: engine ? engine.player : null
  readonly property bool ours: !!player && player.identity === "Orpheus" && !!engine && !!engine.api
  readonly property var orpheusTrack: ours ? engine.api.track : null
  readonly property bool liked: !!orpheusTrack && engine.api.isLiked("track", orpheusTrack.id)
  readonly property bool canLike: !!orpheusTrack
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  readonly property string album: player ? (player.trackAlbum || "") : ""
  readonly property string artUrl: player && player.trackArtUrl ? player.trackArtUrl : ""
  readonly property string trackKey: title + " | " + artist

  // --- position / length (MPRIS never ticks position by itself) --------------
  readonly property var apiPlayer: ours && engine.api.player ? engine.api.player : null
  property real mprisBase: 0
  property real mprisAt: 0
  property real mprisPos: 0
  readonly property real length: apiPlayer ? (apiPlayer.duration || 0)
                                           : (player && player.lengthSupported ? player.length : 0)
  readonly property real position: ours ? (engine.api.position || 0) : mprisPos
  onPlayerChanged: { mprisBase = 0; mprisAt = Date.now(); mprisPos = 0 }
  readonly property real frac: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0
  // Scrubbing: the deck sets `scrubbing`/`scrubFrac` while dragging and calls
  // commitScrub() on release; `sfrac` and `shownPos` follow the pointer meanwhile.
  property bool scrubbing: false
  property real scrubFrac: 0
  readonly property real sfrac: scrubbing ? scrubFrac : frac
  readonly property real shownPos: scrubbing ? scrubFrac * length : position
  function beginScrub(f) { scrubFrac = Math.max(0, Math.min(1, f)); scrubbing = true }
  function moveScrub(f) { if (scrubbing) scrubFrac = Math.max(0, Math.min(1, f)) }
  function commitScrub() {
    if (!scrubbing) return
    if (player && length > 0) player.position = scrubFrac * length
    scrubbing = false
  }
  function cancelScrub() { scrubbing = false }
  // Nudge the play head by `d` seconds (wheels, scroll steps), clamped to the track.
  function seekBy(d) {
    if (!player || length <= 0) return
    player.position = Math.max(0, Math.min(length - 0.5, position + d))
  }

  Timer {
    interval: 1000
    repeat: true
    running: core.live && !!core.player && core.player.isPlaying
    onTriggered: {
      core.player.positionChanged()
      if (core.apiPlayer) return
      var p = core.player.positionSupported ? core.player.position : 0
      if (Math.abs(p - core.mprisBase) > 0.05) { core.mprisBase = p; core.mprisAt = Date.now() }
      core.mprisPos = core.mprisBase + (Date.now() - core.mprisAt) / 1000
    }
  }

  // --- the theme -----------------------------------------------------------
  // Everything a deck paints derives from these five and the mixes below, so a
  // theme switch re-tints the whole device: metal, glass, glow and ink.
  readonly property color baseBg: Commons.Color.background !== undefined ? Commons.Color.background : "#000000"
  readonly property color bg: Qt.rgba(baseBg.r, baseBg.g, baseBg.b, 1)
  readonly property color fg: Tui.ensure(Commons.Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Commons.Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Commons.Color.accent, bg, 3)
  // The theme's urgent colour for red zones, like lamps and pointers -- unless
  // the theme left it grey (e.g. "white"), when the accent stands in.
  readonly property color hot: Commons.Color.urgent !== undefined && Commons.Color.urgent.hslSaturation > 0.18
                               ? Tui.ensure(Commons.Color.urgent, bg, 3) : accent
  readonly property color rawAccent: Commons.Color.accent !== undefined ? Commons.Color.accent : accent
  readonly property bool light: Tui.lum(bg) > 0.4 || (!!engine && !!engine.lightTheme)
  readonly property real bloom: Tui.bloom(engine)
  readonly property string fontFamily: Style.font.family

  // --- the music (pass straight into shader uniforms) -------------------------
  readonly property real beat: engine && playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0
  readonly property real kick: engine && playing ? (engine.kick || 0) : 0
  readonly property real snap: engine && playing ? (engine.snap || 0) : 0
  readonly property real swell: engine && playing ? (engine.swell || 0) : 0
  readonly property real energy: engine && playing ? (engine.energy || 0) : 0
  readonly property real bass: engine && playing ? (engine.bass || 0) : 0
  readonly property real beatPhase: engine ? (engine.beatPhase || 0) : 0
  readonly property real drop: engine && playing ? (engine.drop || 0) : 0
  readonly property bool titleFx: !!engine && engine.titleFx && !engine.gameMode
  readonly property bool gameMode: !!engine && engine.gameMode

  // --- tempo, section, quality: only once the analysis has caught up ---------
  property bool settled: false
  Timer { id: settleTimer; interval: 6000; running: true; onTriggered: core.settled = true }
  onTrackKeyChanged: { settled = false; settleTimer.restart() }
  readonly property bool tempoOk: settled && !!engine && playing && engine.tempo > 0 && engine.tempoConfidence >= 0.5
  readonly property bool sectionOk: settled && !!engine && playing && engine.director && engine.beatConfidence >= 0.4 && engine.section !== ""
  readonly property string tempoLabel: tempoOk ? Math.round(engine.tempo) + " BPM" : ""
  readonly property string sectionLabel: sectionOk ? String(engine.section).toUpperCase() : ""
  // 1 on a section change, cooling to 0 (light the word, let it fade).
  property real secFlash: 0
  NumberAnimation on secFlash { id: flashAnim; running: false; from: 1; to: 0; duration: Tui.PAGE; easing.type: Easing.OutCubic }
  Connections {
    target: core.engine
    function onSectionCodeChanged() { if (core.sectionOk) flashAnim.restart() }
  }
  readonly property var stream: apiPlayer && apiPlayer.stream ? apiPlayer.stream : null
  readonly property string qualityLabel: {
    var s = stream
    if (!settled || !s || !s.quality) return ""
    var lossy = { HIGH: 320, LOW: 96 }[s.quality]
    if (lossy) return ((s.codec || "AAC") + " " + lossy).toUpperCase()
    var res = s.bitDepth && s.sampleRate ? " " + s.bitDepth + "/" + (s.sampleRate / 1000) : ""
    var fmt = s.codec || (res ? "" : String(s.quality))
    return (String(fmt).toUpperCase() + res).trim()
  }

  // --- live count (the engine runs analysis only while someone watches) -------
  readonly property bool live: !!core.Window.window && core.Window.window.visible
                               && core.Window.window.visibility !== Window.Minimized
  property bool counted: false
  function report() {
    if (!engine || counted === live) return
    counted = live
    engine.widgetLiveCount += live ? 1 : -1
  }
  onLiveChanged: report()
  onEngineChanged: report()
  Component.onCompleted: report()
  Component.onDestruction: if (counted && engine) { counted = false; engine.widgetLiveCount-- }

  function clock(s) {
    s = Math.max(0, Math.floor(s || 0))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }
  // Zero-padded mm:ss, for drum counters and segment displays.
  function clock2(s) {
    s = Math.max(0, Math.floor(s || 0))
    var m = Math.min(99, Math.floor(s / 60))
    return (m < 10 ? "0" : "") + m + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  // --- the controls: one place for buttons and keys ---------------------------
  // Actions: toggle, next, previous, like, stage (open the visualizer).
  function act(a) {
    var p = player
    if (a === "stage") { if (engine) engine.open = !engine.open; return true }
    if (a === "like") { if (orpheusTrack) engine.api.toggleLike("track", orpheusTrack.id); return !!orpheusTrack }
    if (!p) return false
    if (a === "toggle") p.togglePlaying()
    else if (a === "next" && p.canGoNext) p.next()
    else if (a === "previous" && p.canGoPrevious) p.previous()
    else return false
    return true
  }
  // The key printed on each control (only when the host gives us the keyboard).
  readonly property var keyLabels: ({ toggle: "space", next: "n", previous: "p", like: "F", stage: "V" })
  // Same letters as the player window; anything with a modifier is left for
  // the compositor's binds, and a held key never repeats an action.
  function key(e) {
    if (!keys || (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
    if (e.isAutoRepeat) { e.accepted = true; return }
    var a = e.key === Qt.Key_Space ? "toggle" : e.text === "n" ? "next" : e.text === "p" ? "previous"
          : e.text === "F" ? "like" : e.text === "V" ? "stage" : ""
    if (a !== "") e.accepted = act(a)
  }
}
