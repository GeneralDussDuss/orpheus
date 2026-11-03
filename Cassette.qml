import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui
import "Cassette.js" as Deck

// The stage's second scene: a cassette deck in the theme's colours, in place
// of the visualizer (StageView loads one or the other; `t` swaps them).
//
//   ┌ LO ╮ ┌count┐ ╭ HI ┐   ┌ j-card ───────────┐
//   │  ╲ │ │ 042 │ │ ╱  │   │ SIDE A  ▸ 05 song │
//   ┌─ A  mixtape · artist ─┐ │ SIDE B    06 ...  │
//   │  ( ◎ )  ════  ( ◎ )   │ │                   │
//   └──────╱ ▭ ╲────────────┘ └───────────────────┘
//      ⏮    ⏯    ⏭    ▲
//
// One analytic shader (shaders/cassette.frag) draws every mechanism pixel;
// Qt Text draws every glyph, in the shell font. Geometry is worked out once,
// below, and both the shader and the MouseAreas read it, so what you grab is
// what you see. The maths lives in Cassette.js.
//
// Motion is a virtual tape (seconds) soft-locked to the song clock: the reels'
// angles are the closed form of that tape (no drift), and the transients ride
// on it: the motor spins up on play and coasts down on pause into a small
// backwards brake kiss; a seek, a skip or a shuttle runs the tape there fast
// with the spokes blurred toward a disc and the tape fluttering. It steps on
// the engine's clock while it moves and not at all once it has settled, so a
// paused deck with its needles down costs nothing and redraws nothing.
Item {
  id: deck

  property var engine: null
  property real unit: 10
  property bool cursorHidden: false
  signal moved()
  signal leave()
  signal ejected()

  // Colours, the house derivation (StageView, MiniPlayer). Nothing else paints.
  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Color.accent, bg, 3)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property color line: Tui.ensure(Tui.mix(Color.foreground, bg, 0.72), bg, 1.6)
  readonly property color redText: Tui.ensure(engine ? engine.c3 : Color.accent, bg, 3)
  readonly property bool light: !!engine && engine.lightTheme
  readonly property bool glassy: typeof Color.glass !== "undefined" && Color.glass === true
  readonly property string family: Style.font.family
  readonly property real bloom: Tui.bloom(engine)

  // ---- the song, and who plays it ---------------------------------------------
  //
  // Orpheus's own track reads the daemon (the clock every other view uses);
  // anyone else's MPRIS player is read through Quickshell (MiniPlayer's rule).
  readonly property var player: engine ? engine.player : null
  readonly property bool ours: !!player && player.identity === "Orpheus" && !!engine && !!engine.api
  readonly property var st: ours ? engine.api.player : null
  readonly property bool hasTape: !!player
  readonly property bool playing: !!(engine && engine.playing)
  readonly property real len: ours ? (st.duration || (st.track && st.track.duration) || 0)
                                   : (player && player.lengthSupported ? player.length : 0)
  readonly property var track: st && st.track ? st.track : null
  readonly property string title: track ? (track.title || "") : player ? (player.trackTitle || "") : ""
  readonly property string artist: track ? (Array.isArray(track.artists) ? track.artists.join(", ") : (track.artist || ""))
                                         : player ? (player.trackArtist || "") : ""
  readonly property string tapeName: {
    var c = st && st.context ? st.context : null
    if (c && c.title) return String(c.title)
    if (track && track.album) return String(typeof track.album === "object" ? (track.album.title || "") : track.album)
    if (!ours && player && player.trackAlbum) return player.trackAlbum
    return "mixtape"
  }
  readonly property string side: jcard.side

  // A self-issued seek holds the clock at its target until the player agrees
  // (the daemon's answer lags a poll), so the deck never rewinds to the old
  // position and then lurches forward again.
  property real seekTo: -1
  property real seekAt: 0
  function songPos() {          // per tick, not bound (api.position steps at 80 ms)
    var raw
    if (ours) {
      var a = engine.api
      raw = a.player.playing === true && a.posAt > 0 ? a.posBase + (Date.now() - a.posAt) / 1000 : (a.position || 0)
    } else raw = player && player.positionSupported ? player.position : 0
    raw = Math.min(len > 0 ? len : 1e9, Math.max(0, raw))
    if (seekTo >= 0) {
      var now = Date.now(), want = seekTo + (playing ? (now - seekAt) / 1000 : 0)
      if (Math.abs(raw - want) < 0.75 || now - seekAt > 2500) seekTo = -1
      else return Math.min(len > 0 ? len : 1e9, want)
    }
    return raw
  }

  // ---- state the tick moves -----------------------------------------------------
  property real tape: 0                 // seconds of tape past the head
  property real spin: 0                 // motor 0..1
  property real brake: 0                // the brake kiss, radians
  property real wobble: 0               // tape flutter after a shuttle, 0..1
  property real angL: 0
  property real angR: 0
  property real offL: 0                 // angle offsets easing out after a scrub
  property real offR: 0
  property real motion: 0               // the faster reel's travel this frame, radians
  property real vuL: 0
  property real vuR: 0
  property real vuLv: 0
  property real vuRv: 0
  property real ledL: 0
  property real ledR: 0
  property real thump: 0
  property real swellNow: 0
  property real bassNow: 0              // the shader's music: gated copies of the engine's
  property real snapNow: 0
  property real buildNow: 0
  property real dropNow: 0
  property real needleKick: 0
  property real clock: 0                // the shader's time: advances only while live
  property real lastPos: -1
  property real lastMs: 0
  property bool scrubbing: false
  property real scrubPos: 0
  property real hand: 0
  property int grabbed: 0
  property real baseL: 0
  property real baseR: 0
  property int hover: 0
  property real ejectAmt: 1
  property bool ejecting: false
  readonly property real frac: Deck.frac(tape, len)

  readonly property bool settled: !playing && !scrubbing && spin < 0.002 && wobble < 0.003
      && !shuttleAnim.running && !brakeAnim.running && !offAnim.running && !powerAnim.running
      && Math.abs(vuLv) < 2e-3 && Math.abs(vuRv) < 2e-3 && vuL < 0.002 && vuR < 0.002
      && ledL < 0.01 && ledR < 0.01 && thump < 0.002 && swellNow < 0.002
      && bassNow < 0.002 && snapNow < 0.002 && buildNow < 0.002 && dropNow < 0.002
      && !ejectAnim.running && !insertAnim.running && needleKick === 0
  readonly property bool live: visible && !!engine && !engine.gameMode && !!Window.window && Window.window.visible && !settled
  Connections { target: deck.engine; function onTimeChanged() { if (deck.live) deck.step(-1) } }
  // A settled deck never steps, so a seek made elsewhere while paused (the
  // player's h/l, MPRIS, the remote) would leave the reels and counter behind
  // until play. Four looks a second, only while settled and on screen.
  Timer {
    interval: 250
    repeat: true
    running: deck.settled && deck.visible && deck.hasTape && !!deck.engine && !deck.engine.gameMode
    onTriggered: if (deck.lastPos >= 0 && Math.abs(deck.songPos() - deck.lastPos) > 0.75) deck.step(-1)
  }

  property bool ready: false
  Component.onCompleted: { ejectAmt = hasTape ? 0 : 1; lastTrack = trackKey; tape = hasTape ? songPos() : 0; ready = true }

  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)) }
  function sgn(x) { return x > 0 ? 1 : x < 0 ? -1 : 0 }
  function levelsNow() { return engine && engine.levels ? engine.levels : [] }

  function step(dt) {
    var now = Date.now()
    if (dt < 0) dt = lastMs > 0 ? clamp((now - lastMs) / 1000, 0.004, 0.05) : 1 / 60
    lastMs = now
    var on = playing ? 1 : 0
    var p = scrubbing ? scrubPos : songPos()

    // 1. a jump the clock did not explain is a seek from elsewhere
    var pred = lastPos + (playing ? dt : 0)
    if (lastPos >= 0 && !scrubbing && Math.abs(p - pred) > 0.75) seeked(p - pred, p)
    lastPos = p

    // 2. the motor: spins up briskly, coasts down, and the brake bites at the end
    var want = playing && !scrubbing && !shuttleAnim.running && ejectAmt < 0.01 ? 1 : 0
    var was = spin
    spin += (want - spin) * (1 - Math.exp(-dt / (want > spin ? 0.18 : 0.55)))
    if (want === 0 && was >= 0.08 && spin < 0.08) { spin = 0; brakeAnim.restart() }

    // 3. the tape: the motor drives it, the song clock steers it (never backwards
    // while playing: after a coast the reels run slow until the song catches up)
    if (scrubbing) tape = scrubPos
    else if (!shuttleAnim.running) {
      var t = tape + dt * spin
      if (playing) t += Math.max((p - t) * (1 - Math.exp(-dt / 0.25)), -dt * spin * 0.6)
      tape = clamp(t, 0, len > 0 ? len : 1e9)
    }

    // 4. the reels: closed form of the tape, plus a scrubbing hand, the brake
    // kiss, the easing-out offset of a released scrub and the flutter
    var f = Deck.frac(tape, len), rS = Deck.supplyR(f), rT = Deck.takeR(f)
    var flutter = 0.06 * wobble * Math.sin(clock * 37)
    var aL, aR
    if (scrubbing) {
      aL = baseL + (grabbed === 1 ? hand : hand * rT / rS)
      aR = baseR + (grabbed === 2 ? hand : hand * rS / rT)
    } else {
      aL = -Deck.supplyAngle(tape, len) + brake + offL + flutter
      aR = -Deck.takeAngle(tape, len) + brake + offR + flutter
    }
    motion = Math.max(Math.abs(aL - angL), Math.abs(aR - angR))
    angL = aL
    angR = aR

    // 5. the needles: damped springs on the low and the high bands
    var lv = levelsNow(), gate = on * (1 - ejectAmt)
    var tl = needleKick > 0 ? 1 : Deck.vuTarget(lv, 0, 12) * gate
    var th = needleKick > 0 ? 1 : Deck.vuTarget(lv, 12, 32) * gate
    var nl = Deck.needleStep(vuL, vuLv, tl, dt), nr = Deck.needleStep(vuR, vuRv, th, dt)
    vuL = nl[0]; vuLv = nl[1]; vuR = nr[0]; vuRv = nr[1]
    if (vuL < 0.002 && Math.abs(vuLv) < 2e-3 && tl === 0) { vuL = 0; vuLv = 0 }
    if (vuR < 0.002 && Math.abs(vuRv) < 2e-3 && th === 0) { vuR = 0; vuRv = 0 }

    // 6. peak LEDs on the kick and the snap, the cabinet thump, the bloom swell
    var hold = Math.exp(-dt / 0.09)
    ledL = Math.max((engine ? engine.kick : 0) * gate, ledL * hold)
    ledR = Math.max((engine ? engine.snap : 0) * gate, ledR * hold)
    if (ledL < 0.01) ledL = 0
    if (ledR < 0.01) ledR = 0
    thump = (engine ? engine.kick : 0) * gate
    swellNow = (engine ? engine.swell : 0) * gate
    if (thump < 0.002) thump = 0
    if (swellNow < 0.002) swellNow = 0
    // the rest of the music, for the light: eased so a paused deck still settles
    var ease = 1 - Math.exp(-dt / 0.12)
    bassNow += ((engine ? engine.bass : 0) * gate - bassNow) * ease
    snapNow = (engine ? engine.snap : 0) * gate
    buildNow += ((engine ? engine.build : 0) * gate - buildNow) * ease
    dropNow += ((engine ? engine.drop : 0) * gate - dropNow) * ease
    if (bassNow < 0.002) bassNow = 0
    if (snapNow < 0.002) snapNow = 0
    if (buildNow < 0.002) buildNow = 0
    if (dropNow < 0.002) dropNow = 0

    // 7. flutter dies away; the deck's own clock moves
    wobble *= Math.exp(-dt / 0.45)
    if (wobble < 0.003) wobble = 0
    if (spin < 0.002 && want === 0) spin = 0
    clock = (clock + dt) % 4000
  }

  // A jump of `delta` seconds to song position `p`: the tape shuttles there
  // (fast-forward or rewind, the motor off), the spokes blur and the tape
  // flutters. Never more than 60 s worth of spinning, however far the jump.
  function seeked(delta, p) {
    wobble = 1
    vuLv += 0.8 * sgn(delta)
    vuRv += 0.8 * sgn(delta)
    shuttleAnim.stop()
    shuttleAnim.from = Math.abs(delta) > 60 ? p - sgn(delta) * 60 : tape
    shuttleAnim.to = p
    shuttleAnim.start()
  }
  NumberAnimation { id: shuttleAnim; target: deck; property: "tape"; duration: 450; easing.type: Easing.OutCubic }
  SequentialAnimation {
    id: brakeAnim
    NumberAnimation { target: deck; property: "brake"; to: 0.05; duration: 60; easing.type: Easing.OutQuad }
    NumberAnimation { target: deck; property: "brake"; to: 0; duration: 140; easing.type: Easing.OutBack }
  }
  ParallelAnimation {
    id: offAnim
    NumberAnimation { target: deck; property: "offL"; to: 0; duration: Tui.STATE; easing.type: Easing.OutCubic }
    NumberAnimation { target: deck; property: "offR"; to: 0; duration: Tui.STATE; easing.type: Easing.OutCubic }
  }

  // A new track: the tape rewinds onto it.
  readonly property string trackKey: (st && st.track ? String(st.track.id) : player ? (player.trackTitle || "") : "") + "|" + len
  property string lastTrack: ""
  onTrackKeyChanged: {
    if (!ready || trackKey === lastTrack) return
    lastTrack = trackKey
    seekTo = -1
    lastPos = -1
    if (hasTape) seeked(-tape, songPos())
  }

  // ---- transport ---------------------------------------------------------------
  function seekBy(s) {
    if (!player || !player.canSeek || !(len > 0)) return
    var from = songPos(), to = clamp(from + s, 0, Math.max(0, len - 0.5))
    player.position = to
    seekTo = to
    seekAt = Date.now()
    lastPos = to
    seeked(to - tape, to)
  }
  function shuttle(seconds) { seekBy(seconds); moved() }
  function togglePlay() { if (player) player.togglePlaying() }
  function next() { if (player && player.canGoNext) player.next() }
  function previous() { if (player && player.canGoPrevious) player.previous() }

  // Power-on: the needles swing up to the pegs and fall back, the LEDs blink,
  // the j-card's rows come in one after another.
  function powerOn() {
    spin = 0
    ledL = 1
    ledR = 1
    powerAnim.restart()
    jcard.stagger()
  }
  SequentialAnimation {
    id: powerAnim
    PropertyAction { target: deck; property: "needleKick"; value: 1 }
    PauseAnimation { duration: 150 }
    PropertyAction { target: deck; property: "needleKick"; value: 0 }
  }

  // Eject: the motor stops, the needles drop, the cassette lifts out of the
  // well and the j-card slides away; then the stage closes.
  function eject() {
    if (ejectAmt > 0.99) { ejected(); return }
    ejecting = true
    insertAnim.stop()
    ejectAnim.from = ejectAmt
    ejectAnim.restart()
  }
  NumberAnimation {
    id: ejectAnim
    target: deck; property: "ejectAmt"; to: 1; duration: 700; easing.type: Easing.InOutCubic
    onFinished: if (deck.ejecting) { deck.ejecting = false; deck.ejected() }
  }
  NumberAnimation { id: insertAnim; target: deck; property: "ejectAmt"; to: 0; duration: 600; easing.type: Easing.OutCubic }
  onHasTapeChanged: {
    if (ejecting || !ready) return
    if (hasTape) { tape = songPos(); lastPos = -1; ejectAnim.stop(); insertAnim.from = ejectAmt; insertAnim.restart() }
    else { insertAnim.stop(); ejectAnim.from = ejectAmt; ejectAnim.restart() }
  }

  // ---- geometry: one set of rects, for the shader and the mouse ----------------
  //
  // The deck block is 100 x 98 units (VU row, shell, keys); the j-card takes
  // the rest of the width. Small: no keys and no j-card; short: no meters.
  readonly property bool compact: width < 520 || height < 200
  readonly property bool facesOn: height >= 160
  readonly property bool keysOn: !compact
  readonly property real deckX: compact ? 0 : unit * 0.6
  readonly property real deckW: compact ? width : Math.min(width * 0.60, height * 1.03)
  readonly property real rowTop: facesOn ? 0 : 24
  readonly property real rows: (keysOn ? 98 : 86) - rowTop
  readonly property real u: Math.max(0.1, Math.min(deckW / 100, height / rows))
  readonly property real ox: deckX + (deckW - 100 * u) / 2
  readonly property real oy: (height - rows * u) / 2 - rowTop * u
  function ur(x, y, w, h) { return Qt.rect(ox + x * u, oy + y * u, w * u, h * u) }
  readonly property rect bodyR: ur(4, 26, 92, 58)
  readonly property rect faceLR: facesOn ? ur(3, 2, 40, 22) : Qt.rect(0, 0, 0, 0)
  readonly property rect faceRR: facesOn ? ur(57, 2, 40, 22) : Qt.rect(0, 0, 0, 0)
  readonly property rect counterR: ur(45, 7, 10, 12)
  readonly property rect keysR: ur(21, 87, 58, 9)
  readonly property real rMax: 0.17 * bodyR.width
  readonly property real cxL: bodyR.x + bodyR.width * 0.2875
  readonly property real cxR: bodyR.x + bodyR.width * 0.7125
  readonly property real cy: bodyR.y + bodyR.height * 0.47
  readonly property real lift: 0.35 * bodyR.height * ejectAmt      // the shader's eject offset
  readonly property rect paperR: compact ? Qt.rect(0, 0, 0, 0)
                                         : Qt.rect(deckX + deckW + unit, unit * 0.6, Math.max(0, width - deckX - deckW - unit * 1.6), height - unit * 1.2)

  // ---- the room light behind the machine ----------------------------------------
  Ambient {
    anchors.fill: parent
    z: -1
    engine: deck.engine
    styleName: deck.engine ? deck.engine.style : "prism"
    level: deck.engine ? deck.engine.ambient : "off"
  }

  // ---- the mechanism --------------------------------------------------------
  readonly property bool bloomOn: bloom > 0 && Math.min(width, height) >= 48 && !!engine && !engine.gameMode
  ShaderEffect {
    id: mech
    objectName: "cassetteMech"
    x: 0; y: 0
    width: Math.min(deck.width, deck.deckX + deck.deckW + deck.unit * 0.4)
    height: deck.height
    fragmentShader: deck.engine && deck.engine.deckLook === "light" ? "shaders/cassette_light.frag.qsb" : "shaders/cassette.frag.qsb"
    property real time: deck.clock
    property vector2d res: Qt.vector2d(width, height)
    property color c1: deck.engine ? deck.engine.c1 : deck.accent
    property color c2: deck.engine ? deck.engine.c2 : deck.accent
    property color c3: deck.engine ? deck.engine.c3 : deck.accent
    property color bg: deck.bg
    property color fg: deck.fg
    property vector4d body: Qt.vector4d(deck.bodyR.x, deck.bodyR.y, deck.bodyR.width, deck.bodyR.height)
    property vector4d faceL: Qt.vector4d(deck.faceLR.x, deck.faceLR.y, deck.faceLR.width, deck.faceLR.height)
    property vector4d faceR: Qt.vector4d(deck.faceRR.x, deck.faceRR.y, deck.faceRR.width, deck.faceRR.height)
    property vector4d reel: Qt.vector4d(deck.cxL, deck.cxR, deck.cy, deck.rMax)
    property vector4d ang: Qt.vector4d(deck.angL, deck.angR, deck.motion, deck.wobble)
    property vector4d pack: Qt.vector4d(Deck.supplyR(deck.frac), Deck.takeR(deck.frac), deck.spin, deck.tape * deck.bodyR.width * 0.05)
    property vector4d vu: Qt.vector4d(deck.vuL, deck.vuR, deck.ledL, deck.ledR)
    property vector4d state: Qt.vector4d(deck.ejectAmt, deck.hover, deck.scrubbing ? 1 : 0, deck.hasTape ? 1 : 0)
    property real light: deck.light ? 1 : 0
    property real bloomAmt: deck.bloomOn ? (deck.engine.bloom === "full" ? 1.0 : 0.6) : 0
    property real glassy: deck.glassy ? 1 : 0
    property real kick: deck.thump
    property vector4d music: Qt.vector4d(deck.bassNow, deck.swellNow, deck.buildNow, deck.dropNow)
    property vector2d hits: Qt.vector2d(deck.snapNow, deck.engine ? deck.engine.kicks : 0)

    // Static per (setting, theme, size): never toggled by the music. Not a
    // recursive source, and no textureSize override: the layer is the item's size.
    layer.enabled: deck.bloomOn
    layer.format: ShaderEffectSource.RGBA16F
    layer.smooth: true
    layer.effect: Bloom {
      intensity: deck.engine && deck.engine.bloom === "full" ? 1.0 : 0.6
      kick: deck.thump
      swell: deck.swellNow
      quality: 2
    }
  }

  // ---- glyphs ------------------------------------------------------------------
  FontMetrics { id: capM; font.family: deck.family; font.pixelSize: deck.capPx }
  readonly property real capPx: Math.max(Style.font.caption, Math.round(u * 2.1))

  // The counter: three drums of take-up revolutions, the carry rolling over.
  Item {
    id: counter
    visible: deck.facesOn
    x: deck.counterR.x; y: deck.counterR.y; width: deck.counterR.width; height: deck.counterR.height
    readonly property var drums: Deck.drums(Deck.revs(deck.tape, deck.len))
    readonly property real cellH: height * 0.52
    readonly property real cellW: (width - 4) / 3
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.top
      anchors.bottomMargin: deck.u * 0.4
      text: "COUNT"
      font.family: deck.family; font.pixelSize: Math.max(8, Math.round(deck.u * 1.7)); font.bold: true
      font.letterSpacing: deck.u * 0.2
      color: deck.dim
    }
    Rectangle {
      id: drumBox
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width; height: counter.cellH + 4
      color: Tui.alpha(deck.fg, 0.04)
      border.width: 1; border.color: deck.line
      Row {
        x: 2; y: 2
        Repeater {
          model: 3
          Item {
            id: cell
            required property int index
            width: counter.cellW; height: counter.cellH
            clip: true
            // the drum: 0-9 and 0 again, rolled up by its fractional digit
            Column {
              y: -counter.drums[2 - cell.index] * counter.cellH
              Repeater {
                model: 11
                Text {
                  required property int index
                  width: counter.cellW; height: counter.cellH
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: String(index % 10)
                  font.family: deck.family; font.pixelSize: Math.round(counter.cellH * 0.74); font.bold: true
                  color: deck.fg
                }
              }
            }
            Rectangle { visible: cell.index > 0; width: 1; height: parent.height; color: deck.line }
          }
        }
      }
      // the axle hairline across the drums
      Rectangle { anchors.verticalCenter: parent.verticalCenter; x: 1; width: parent.width - 2; height: 1; color: Tui.alpha(deck.dim, 0.35) }
      TuiTip { text: Deck.clock(deck.tape) + " / " + Deck.clock(deck.len) + " · take-up turns" }
    }
  }

  // VU scale numbers and captions, on the arcs the shader draws.
  component VuText: Item {
    id: vt
    property rect face
    property string caption: ""
    property string tip: ""
    x: face.x; y: face.y; width: face.width; height: face.height
    visible: deck.facesOn
    readonly property real px: Math.max(8, Math.round(face.height * 0.11))
    Repeater {
      model: [{ v: 0, t: "-20" }, { v: 0.30, t: "-10" }, { v: 0.52, t: "-5" }, { v: 0.71, t: "0" }, { v: 1.0, t: "+3" }]
      Text {
        required property var modelData
        readonly property real a: (-47 + 94 * modelData.v) * Math.PI / 180
        readonly property real r: vt.height * 1.0          // just outside the ticks (cassette.frag face())
        x: vt.width / 2 + Math.sin(a) * r - width / 2
        y: vt.height * 1.08 - Math.cos(a) * r - height / 2
        text: modelData.t
        font.family: deck.family; font.pixelSize: vt.px
        color: modelData.v > 0.7 ? deck.redText : deck.dim
      }
    }
    Text {
      x: vt.height * 0.12
      anchors.verticalCenter: parent.bottom
      anchors.verticalCenterOffset: -vt.height * 0.10
      text: vt.caption
      font.family: deck.family; font.pixelSize: Math.round(vt.px * 1.1); font.bold: true
      font.letterSpacing: vt.px * 0.2
      color: deck.dim
    }
    Text {
      anchors.right: parent.right; anchors.rightMargin: vt.height * 0.12
      anchors.verticalCenter: parent.bottom
      anchors.verticalCenterOffset: -vt.height * 0.10
      text: "VU"
      font.family: deck.family; font.pixelSize: vt.px
      color: deck.dim
    }
    TuiTip { text: vt.tip }
  }
  VuText { face: deck.faceLR; caption: "LO"; tip: "vu · the low bands (the capture is mono)" }
  VuText { face: deck.faceRR; caption: "HI"; tip: "vu · the high bands (the capture is mono)" }

  // The label on the shell: side letter, the tape's name, the artist. It rides
  // the cassette out on eject, and flips over when the j-card turns the side.
  property string shownSide: "a"
  onSideChanged: if (side !== shownSide) flipAnim.restart()
  property real flip: 0
  SequentialAnimation {
    id: flipAnim
    NumberAnimation { target: deck; property: "flip"; from: 0; to: 0.5; duration: 350; easing.type: Easing.InCubic }
    ScriptAction { script: deck.shownSide = deck.side }
    NumberAnimation { target: deck; property: "flip"; from: 0.5; to: 1; duration: 350; easing.type: Easing.OutCubic }
    PropertyAction { target: deck; property: "flip"; value: 0 }
  }
  Item {
    id: label
    x: deck.bodyR.x + deck.bodyR.width * 0.075
    y: deck.bodyR.y + deck.bodyR.height * 0.065 - deck.lift
    width: deck.bodyR.width * 0.85
    height: deck.bodyR.height * 0.125
    opacity: (1 - deck.ejectAmt) * (deck.hasTape ? 1 : 0)
    visible: opacity > 0.01
    transform: Scale { origin.y: label.height / 2; yScale: Math.abs(Math.cos(Math.PI * deck.flip)) }
    Text {
      id: sideLetter
      anchors.verticalCenter: parent.verticalCenter
      text: deck.shownSide.toUpperCase()
      font.family: deck.family; font.pixelSize: Math.round(label.height * 0.78); font.bold: true
      color: deck.accentText
    }
    ScrambleText {
      id: tapeTitle
      anchors.left: sideLetter.right; anchors.leftMargin: label.height * 0.5
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth, (label.width - sideLetter.width - label.height) * 0.62)
      textFormat: Text.PlainText
      animate: !!deck.engine && deck.engine.titleFx && !deck.engine.gameMode
      duration: 520
      target: deck.tapeName
      elide: Text.ElideRight
      font.family: deck.family; font.pixelSize: Math.round(label.height * 0.46); font.bold: true
      color: deck.fg
    }
    Text {
      anchors.left: tapeTitle.right; anchors.leftMargin: label.height * 0.35
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: deck.artist ? "· " + deck.artist : ""
      elide: Text.ElideRight
      font.family: deck.family; font.pixelSize: Math.round(label.height * 0.40)
      color: deck.dim
    }
  }

  // ---- the mouse ---------------------------------------------------------------
  //
  // Under everything: wake the show, double-click out of it, scroll to shuttle.
  MouseArea {
    id: deckMouse
    anchors.fill: parent
    z: 0
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: deck.cursorHidden ? Qt.BlankCursor : Qt.ArrowCursor
    property real wheelAcc: 0
    onPositionChanged: deck.moved()
    onPressed: deck.moved()
    onDoubleClicked: deck.leave()
    onWheel: function(w) { var n = Tui.notches(deckMouse, w.angleDelta.y); if (n) deck.shuttle(-n * 5) }
  }

  // The reels: grab one and turn it. One turn is 30 s; counter-clockwise is
  // forward. The grabbed reel stays under the finger and the other follows
  // through the tape; the seek goes out once, on release.
  function reelAt(x, y) {
    var r = 1.1 * rMax
    if (Math.hypot(x - cxL, y - cy) <= r) return 1
    if (Math.hypot(x - cxR, y - cy) <= r) return 2
    return 0
  }
  readonly property bool canScrub: hasTape && !!player && player.canSeek && len > 0 && ejectAmt < 0.01
  MouseArea {
    id: reelMouse
    z: 1
    x: deck.bodyR.x; y: deck.bodyR.y; width: deck.bodyR.width; height: deck.bodyR.height
    hoverEnabled: true
    preventStealing: true
    property real wheelAcc: 0
    property real grab: 0
    readonly property int over: containsMouse ? deck.reelAt(mouseX + x, mouseY + y) : 0
    onOverChanged: if (!deck.scrubbing) deck.hover = deck.canScrub ? over : 0
    cursorShape: deck.cursorHidden ? Qt.BlankCursor
                 : deck.scrubbing ? Qt.ClosedHandCursor : over && deck.canScrub ? Qt.OpenHandCursor : Qt.ArrowCursor
    function angleAt(m) {
      var cx = deck.grabbed === 1 ? deck.cxL : deck.cxR
      return Math.atan2(m.y + y - deck.cy, m.x + x - cx)
    }
    onPositionChanged: function(m) {
      deck.moved()
      if (!deck.scrubbing) return
      var a = angleAt(m), dA = a - grab
      if (dA > Math.PI) dA -= 2 * Math.PI
      else if (dA < -Math.PI) dA += 2 * Math.PI
      grab = a
      deck.hand += dA
      deck.scrubPos = deck.clamp(deck.scrubPos + Deck.scrubDelta(dA), 0, Math.max(0, deck.len - 0.5))   // as seekBy: never onto EOF
      deck.wobble = Math.min(1, Math.abs(dA) * 4)
      if (!deck.live) deck.step(-1)
    }
    onPressed: function(m) {
      deck.moved()
      var side = deck.reelAt(m.x + x, m.y + y)
      if (!side || !deck.canScrub) { m.accepted = false; return }
      offAnim.stop(); shuttleAnim.stop()
      deck.grabbed = side
      deck.baseL = deck.angL
      deck.baseR = deck.angR
      deck.hand = 0
      deck.scrubPos = deck.songPos()
      deck.scrubbing = true
      deck.hover = side
      grab = angleAt(m)
    }
    onReleased: {
      if (!deck.scrubbing) return
      var to = deck.scrubPos
      if (deck.player) deck.player.position = to
      deck.seekTo = to
      deck.seekAt = Date.now()
      deck.lastPos = to
      deck.tape = to
      // where the reels are shown, against where the tape says they are: the
      // difference eases out (hubs repeat every sixth of a turn, so never far)
      function wrap6(a) { var k = Math.PI / 3; return a - k * Math.round(a / k) }
      deck.offL = wrap6(deck.angL + Deck.supplyAngle(to, deck.len) - deck.brake)
      deck.offR = wrap6(deck.angR + Deck.takeAngle(to, deck.len) - deck.brake)
      deck.scrubbing = false
      deck.grabbed = 0
      deck.hand = 0
      deck.hover = over
      offAnim.restart()
    }
    onCanceled: { deck.scrubbing = false; deck.grabbed = 0; deck.hand = 0; deck.hover = 0 }
    onWheel: function(w) { var n = Tui.notches(reelMouse, w.angleDelta.y); if (n) deck.shuttle(-n * 5) }
    TuiTip {
      follow: true
      force: deck.scrubbing
      at: Math.max(0, Math.min(reelMouse.width, reelMouse.mouseX))
      text: deck.scrubbing || (reelMouse.over && deck.canScrub)
            ? Deck.clock(deck.scrubbing ? deck.scrubPos : deck.tape) + " · drag to scrub · scroll ± 5 s" : ""
    }
  }

  // ---- the transport keys: piano keys under the deck ---------------------------
  Row {
    id: keys
    z: 2
    visible: deck.keysOn
    x: deck.keysR.x; y: deck.keysR.y
    spacing: deck.u * 2
    Repeater {
      model: [
        { act: "previous", tip: "previous track", key: "" },
        { act: "toggle", tip: "play / pause", key: "space" },
        { act: "next", tip: "next track", key: "" },
        { act: "eject", tip: "eject · close the deck", key: "e" }
      ]
      Item {
        id: pk
        required property var modelData
        readonly property bool isPlay: modelData.act === "toggle"
        readonly property bool isEject: modelData.act === "eject"
        readonly property bool engaged: isPlay && deck.playing
        readonly property bool down: km.pressed || engaged
        width: deck.u * 13; height: deck.keysR.height
        opacity: deck.hasTape || isEject ? 1 : 0.4
        property real press: km.pressed ? 1 : 0
        Behavior on press { NumberAnimation { duration: km.pressed ? 40 : Tui.HOVER; easing.type: Easing.OutCubic } }
        Rectangle {
          y: pk.down ? 1 : 0
          width: parent.width; height: parent.height
          color: pk.engaged && !km.pressed ? Tui.alpha(deck.accent, 0.16)
                 : Tui.alpha(deck.fg, 0.04 + 0.26 * pk.press)
          border.width: 1
          border.color: pk.engaged ? Tui.mix(deck.line, deck.accent, 0.5) : deck.line
          // the key's lip
          Rectangle { anchors.bottom: parent.bottom; anchors.bottomMargin: 1; x: 1; width: parent.width - 2; height: 1
                      color: Tui.alpha(deck.fg, pk.down ? 0.03 : 0.10) }
          GlowText {
            visible: !pk.isEject
            anchors.centerIn: parent
            text: pk.modelData.act === "previous" ? "󰒮" : pk.modelData.act === "next" ? "󰒭" : deck.playing ? "󰏤" : "󰐊"
            font.family: deck.family
            font.pixelSize: Math.round(parent.height * 0.5)
            readonly property real beat: deck.engine && deck.playing ? Math.max(0, Math.min(1, deck.engine.beat || 0)) : 0
            color: km.containsMouse ? deck.accentText
                   : (pk.isPlay && deck.playing ? Tui.mix(deck.fg, deck.accentText, 0.45 + 0.55 * beat) : deck.fg)
            Behavior on color { ColorAnimation { duration: Tui.HOVER } }
            glowLive: pk.isPlay && deck.playing && deck.bloom > 0
            glow: glowLive ? deck.bloom * (0.3 + 0.7 * beat) : 0
          }
          Column {
            visible: pk.isEject
            anchors.centerIn: parent
            spacing: Math.max(1, parent.height * 0.06)
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "▲"
              font.family: deck.family; font.pixelSize: Math.round(pk.height * 0.34)
              color: km.containsMouse ? deck.accentText : deck.fg
              Behavior on color { ColorAnimation { duration: Tui.HOVER } }
            }
            Rectangle { anchors.horizontalCenter: parent.horizontalCenter; width: pk.height * 0.34; height: 1
                        color: km.containsMouse ? deck.accentText : deck.fg }
          }
        }
        MouseArea {
          id: km
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: deck.cursorHidden ? Qt.BlankCursor : Qt.PointingHandCursor
          onPositionChanged: deck.moved()
          onClicked: {
            deck.moved()
            var a = pk.modelData.act
            if (a === "eject") deck.eject()
            else if (a === "toggle") deck.togglePlay()
            else if (a === "next") deck.next()
            else deck.previous()
          }
          TuiTip { text: pk.modelData.tip; key: pk.modelData.key }
        }
      }
    }
  }

  // ---- the j-card ----------------------------------------------------------------
  JCard {
    id: jcard
    z: 2
    deck: deck
    engine: deck.engine
    unit: deck.unit
    x: deck.paperR.x + deck.unit * 2 * deck.ejectAmt * (deck.hasTape ? 1 : 0)
    y: deck.paperR.y
    width: deck.paperR.width
    height: deck.paperR.height
    visible: !deck.compact && width > deck.unit * 8
    opacity: deck.hasTape ? 1 - 0.8 * deck.ejectAmt : 1
  }
}
