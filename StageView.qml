import QtQuick
import QtQuick.Effects
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// What the stage shows inside its frame (or full-bleed): the visualizer, at a
// resolution auto quality picks from the measured frame rate, with the title
// card, the kinetic lyrics and the fps readout over it.
Item {
  id: view

  property var engine: null
  property string styleName: "skyline"

  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property string family: Style.font.family
  readonly property real bloom: Tui.bloom(engine)
  // Type scales with the stage: a card on a desk and a 3440 px wall both read.
  readonly property real unit: Math.max(10, Math.min(width / 46, height / 18))

  readonly property var api: engine ? engine.api : null
  readonly property var track: api ? api.track : null

  // ---- what there is to show ---------------------------------------------------
  //
  // Paused, nothing loaded, signed out or deaf: the visuals settle back and a
  // line says why, so a still picture reads as resting, not broken. Debounced:
  // a skip passes through "no track" for a poll or two, and the Api starts out
  // "offline" until its first answer.
  readonly property bool playing: !!(engine && engine.playing)
  readonly property bool hasTrack: !!(engine && engine.player)
  readonly property string loginState: api && api.login ? (api.login.state || "") : ""
  readonly property string idleWant: !engine ? ""
                                     : api && api.reconnecting === true ? "reconnecting"
                                     : api && api.connecting === true ? "connecting"
                                     : loginState === "signed-out" ? "signed out"
                                     : !hasTrack ? "nothing playing"
                                     : !engine.hasCava && playing ? "deaf"
                                     : !playing ? "paused" : ""
  property string idle: ""
  onIdleWantChanged: idleWait.restart()
  Timer { id: idleWait; interval: view.idle === "" ? 900 : 250; onTriggered: view.idle = view.idleWant }
  Component.onCompleted: { idleWait.restart(); if (trackKey !== "" && engine && engine.trackTitle) titleCard.play() }
  // The player window's global key (on Windows as the hotkeys actually bound it).
  readonly property string libraryKey: {
    if (typeof OrpheusKeys === "undefined") return "super+shift+m"
    var b = OrpheusKeys.bindings || []
    for (var i = 0; i < b.length; i++) if (b[i].action === "library" && b[i].combo) return String(b[i].combo).toLowerCase()
    return ""
  }

  Viz {
    id: viz
    anchors.fill: parent
    engine: view.engine
    styleName: view.styleName
    renderScale: view.scale_
    // At rest the picture steps back; the music brings it forward again.
    opacity: view.idle === "" || view.idle === "deaf" ? 1 : 0.55
    Behavior on opacity { NumberAnimation { duration: Tui.PAGE; easing.type: Easing.InOutCubic } }
  }

  // ---- auto quality --------------------------------------------------------
  //
  // Count frames the window actually presents (frameSwapped; QML queues it over
  // from the render thread) once a second. Below the target for 3 s running:
  // shade at the next step down (100 -> 75 -> 50 %). At the target for a while:
  // try the next step up; if that drops frames again, wait twice as long before
  // the next try. If stepping down did not help, the shader was never the limit
  // (the timer, vsync or the monitor's refresh is), so go back up and treat
  // that rate as the target (until the style or the configured fps changes).
  readonly property var steps: [1, 0.75, 0.5]
  property int step: 0
  readonly property real scale_: engine && engine.autoQuality ? steps[step] : 1
  property real fps: 0
  property real cap: 1e9               // a ceiling that is not ours to fix
  readonly property real target: Math.min(engine ? engine.fps : 60, cap)
  onStyleNameChanged: { cap = 1e9; low = 0; good = 0; fpsBeforeDrop = 0 }
  readonly property int fpsSetting: engine ? engine.fps : 60
  onFpsSettingChanged: cap = 1e9
  property int frames: 0
  property real sampledAt: Date.now()
  property int low: 0                  // consecutive slow seconds
  property int good: 0                 // consecutive seconds at target
  property int upWait: 15              // seconds at target before trying a step up
  property real fpsBeforeDrop: 0
  property real steppedUpAt: 0

  Connections {
    target: view.Window.window
    function onFrameSwapped() { view.frames++ }
  }

  Timer {
    interval: 1000
    repeat: true
    running: view.visible && !!view.engine
    onTriggered: view.sample()
  }

  function sample() {
    var now = Date.now()
    fps = frames * 1000 / Math.max(1, now - sampledAt)
    frames = 0
    sampledAt = now
    if (!engine || !engine.autoQuality) { step = 0; low = 0; good = 0; return }

    if (fps < target * 0.85) { low++; good = 0 } else { low = 0 }
    if (fps >= target * 0.95) good++

    if (low >= 3) {
      low = 0
      if (step > 0 && fpsBeforeDrop > 0 && fps < fpsBeforeDrop * 1.1) {
        // Shading less bought nothing: not a GPU limit. Undo, and aim lower.
        cap = Math.max(20, fps * 1.02)
        step--
        fpsBeforeDrop = 0
        return
      }
      if (step < steps.length - 1) {
        if (now - steppedUpAt < 12000) upWait = Math.min(240, upWait * 2)   // the step up failed
        fpsBeforeDrop = fps
        step++
      }
    } else if (step > 0 && good >= upWait) {
      good = 0
      step--
      fpsBeforeDrop = 0
      steppedUpAt = now
    }
  }

  // ---- lyrics over the visualizer -----------------------------------------
  //
  // The same source the lyrics page reads, so nothing is fetched twice for a
  // reason the page would not; only loaded while the overlay is on.
  LyricsSource {
    id: lyr
    api: view.engine && view.engine.lyricsOverViz ? view.api : null
    track: view.track
  }
  readonly property bool lyricsOn: !!engine && engine.lyricsOverViz && lyr.lines.length > 0
  readonly property real pos: api ? (api.position || 0) : 0
  readonly property int lineIdx: lyricsOn ? lyr.lineAt(pos + 0.45 - lyr.offset) : -1
  readonly property string lineText: lineIdx >= 0 ? (lyr.lines[lineIdx].text || "") : ""
  readonly property string nextText: lyricsOn && lineIdx + 1 < lyr.lines.length ? (lyr.lines[lineIdx + 1].text || "") : ""

  // ---- kinetic lyrics ----------------------------------------------------------
  //
  // Each word flies in out of depth (tilted back, small, faint) and lands on
  // the plane exactly when it is sung -- on its own tag when the lyrics carry
  // word timing, else spread over the line by word length (LyricsSource) --
  // then lights in the accent with the bloom budget's glow, punched by the
  // kick while it is being sung. When the next line arrives the old one
  // breaks apart: its words drift off on their own headings toward the
  // camera and fade. Two line slots take turns, so the outgoing one can
  // scatter while the incoming one lands. On light themes the bloom budget is
  // zero: no glow, the same motion, contrast-checked colors.
  //
  // The song clock runs per frame from the API's own anchor (its `position`
  // only steps 12 times a second, which reads as stutter in motion).
  property real songNow: 0
  FrameAnimation {
    running: view.lyricsOn && view.visible
    onTriggered: view.songNow = view.songClock()
  }
  function songClock() {
    if (!api) return 0
    var playing = api.player && api.player.playing === true
    var p = playing && api.posAt > 0 ? api.posBase + (Date.now() - api.posAt) / 1000 : (api.position || 0)
    return p - lyr.offset
  }

  property int front: 0               // which slot holds the current line
  property var models: [null, null]
  onLineIdxChanged: {
    var m = models.slice(), next = 1 - front
    m[next] = lineIdx >= 0 ? layoutLine(lineIdx) : null
    models = m
    var out = front === 0 ? slotA : slotB, inn = next === 0 ? slotA : slotB
    out.scatter()
    inn.arrive()
    front = next
  }

  // Word layout for line `idx`: one row if it fits big enough, else two.
  // Widths come from FontMetrics at 100 px and scale linearly.
  function layoutLine(idx) {
    var line = lyr.lines[idx], text = line.text || ""
    var toks = lyr.tokenize(text), sp = lyr.wordSpans(idx)
    if (!toks.length) return null
    var W = kinetic.width, cap = unit * 1.7, space = kfm.advanceWidth(" ")
    var ws = [], i
    for (i = 0; i < toks.length; i++) ws.push(kfm.advanceWidth(toks[i].text))
    function rowWidth(a, b) { var s = 0; for (var j = a; j < b; j++) s += ws[j] + (j > a ? space : 0); return s }
    var split = toks.length, size = Math.min(cap, 100 * W / Math.max(1, rowWidth(0, toks.length)))
    if (size < unit * 1.0 && toks.length > 1) {
      // two rows, split where the widths balance best
      var best = 1, bestMax = 1e9
      for (i = 1; i < toks.length; i++) {
        var mx = Math.max(rowWidth(0, i), rowWidth(i, toks.length))
        if (mx < bestMax) { bestMax = mx; best = i }
      }
      split = best
      size = Math.min(cap, 100 * W / Math.max(1, bestMax))
    }
    size = Math.max(12, size)
    var k = size / 100, out = [], rows = split < toks.length ? 2 : 1
    for (var r = 0; r < rows; r++) {
      var a = r === 0 ? 0 : split, b = r === 0 ? split : toks.length
      var x = (W - rowWidth(a, b) * k) / 2
      for (i = a; i < b; i++) {
        var s = sp[i] || { t: line.t, end: line.t + 1 }
        out.push({ text: toks[i].text, t: s.t, end: s.end, x: x, w: ws[i] * k, row: r, i: i })
        x += (ws[i] + space) * k
      }
    }
    var last = out.length ? out[out.length - 1].end : line.t
    return { size: size, rows: rows, words: out, last: last, seed: idx * 7919 }
  }

  // A scrim so text reads over any style, only where the text is.
  Rectangle {
    visible: view.lyricsOn
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: parent.height * 0.38
    gradient: Gradient {
      GradientStop { position: 0; color: "transparent" }
      GradientStop { position: 1; color: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.72) }
    }
  }

  FontMetrics { id: kfm; font.family: view.family; font.pixelSize: 100; font.bold: true }

  Item {
    id: kinetic
    visible: view.lyricsOn
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height * 0.64
    width: parent.width * 0.88
    height: parent.height * 0.30
    readonly property real kick: view.engine ? view.engine.kick : 0

    KLine { id: slotA; model: view.models[0] }
    KLine { id: slotB; model: view.models[1] }

    // What comes next, small and flat under the current line.
    Text {
      readonly property var cur: view.models[view.front]
      y: cur ? cur.size * 1.22 * cur.rows + cur.size * 0.15 : 0
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: view.nextText
      font.family: view.family; font.pixelSize: Math.max(11, (cur ? cur.size : view.unit) * 0.5)
      color: view.dim
      opacity: 0.75
    }
  }

  component KLine: Item {
    id: kl
    property var model: null
    property real gone: 1               // 0 = on stage, 1 = scattered away
    property bool done: false           // ended on its own (a long gap after it)
    width: kinetic.width
    height: kinetic.height
    visible: !!model && gone < 1

    function arrive() { leave.stop(); gone = 0; done = false }
    function scatter() { if (gone < 1 && !leave.running) leave.restart() }
    NumberAnimation { id: leave; target: kl; property: "gone"; to: 1; duration: 850; easing.type: Easing.OutCubic }
    // Nothing follows for a while (an instrumental): let the line go anyway.
    Connections {
      target: view
      function onSongNowChanged() {
        if (kl.model && kl.gone === 0 && !kl.done && view.songNow > kl.model.last + 2.5) { kl.done = true; kl.scatter() }
      }
    }

    Repeater {
      model: kl.model ? kl.model.words : []
      delegate: Item {
        id: wd
        required property var modelData
        readonly property var m: kl.model
        readonly property real lead: 0.38
        // 0 -> 1 as the word flies in, landing exactly at its start
        readonly property real pin: Math.max(0, Math.min(1, (view.songNow - modelData.t + lead) / lead))
        // 1 while sung, fading over 0.6 s after
        readonly property real hot: view.songNow < modelData.t ? 0
                                    : view.songNow < modelData.end ? 1
                                    : Math.max(0, 1 - (view.songNow - modelData.end) / 0.6)
        readonly property real punch: hot * kinetic.kick
        readonly property real g: kl.gone
        // a heading per word, stable for the line
        readonly property real rnd: { var h = Math.sin((modelData.i + 1) * 12.9898 + (m ? m.seed : 0) * 78.233) * 43758.5453; return h - Math.floor(h) }
        readonly property real rnd2: { var h = Math.sin((modelData.i + 1) * 39.3467 + (m ? m.seed : 0) * 11.135) * 24634.6345; return h - Math.floor(h) }
        function outBack(x) { var c = 1.70158; return 1 + (c + 1) * Math.pow(x - 1, 3) + c * Math.pow(x - 1, 2) }

        x: modelData.x
        y: m ? modelData.row * m.size * 1.22 : 0
        width: modelData.w
        height: m ? m.size * 1.22 : 0
        opacity: Math.min(1, pin * 1.6) * (1 - g) * (1 - g)
        visible: opacity > 0.003

        GlowText {
          id: word
          anchors.centerIn: parent
          text: wd.modelData.text
          font.family: view.family
          font.pixelSize: wd.m ? wd.m.size : 12
          font.bold: true
          color: Tui.mix(view.fg, view.accentText, Math.max(wd.hot, 0.35 * wd.punch))
          glowColor: view.accentText
          glowRadius: wd.m ? Math.min(32, Math.round(wd.m.size * 0.35)) : 8
          glow: Math.min(1, view.bloom * (0.2 * wd.pin + 0.7 * wd.hot + 0.6 * wd.punch) * (1 - wd.g))
          // one layer for the word's whole life on stage, not one per flash
          glowLive: view.bloom > 0 && wd.pin > 0 && wd.g < 1
          transform: [
            // tilted back into the screen while far away, flat once landed
            Rotation {
              origin.x: word.width / 2; origin.y: word.height
              axis { x: 1; y: 0; z: 0 }
              angle: -65 * (1 - wd.pin) * (1 - wd.pin) + 25 * wd.g * (wd.rnd - 0.5)
            },
            Scale {
              origin.x: word.width / 2; origin.y: word.height / 2
              readonly property real s: (0.3 + 0.7 * wd.outBack(wd.pin)) * (1 + 0.14 * wd.punch) * (1 + 0.7 * wd.g)
              xScale: s; yScale: s
            },
            Rotation {
              origin.x: word.width / 2; origin.y: word.height / 2
              angle: (wd.rnd2 - 0.5) * 50 * wd.g
            },
            Translate {
              // rise in from a little below; scatter outward from the line's centre and up,
              // clear of the incoming line
              x: wd.g * ((wd.modelData.x + wd.modelData.w / 2 - kinetic.width / 2) * 0.5 + (wd.rnd - 0.5) * view.unit * 4)
              y: (1 - wd.pin) * (wd.m ? wd.m.size : 0) * 0.5 - wd.g * view.unit * (2.5 + 2.5 * wd.rnd2)
            }
          ]
        }
      }
    }
  }

  // ---- title card ------------------------------------------------------------
  //
  // When the track changes: an accent rule draws out, the title resolves from
  // wide tracking, the artist follows, it holds, and it all fades away.
  readonly property string trackKey: track ? String(track.id || track.title || "") : ""
  onTrackKeyChanged: {
    if (trackKey !== "" && engine && engine.trackTitle) titleCard.play()
    else titleCard.clear()                 // nothing loaded: no stale title over an empty stage
  }

  // The card's own scrim: the same falloff as the lyrics', from the edge it
  // sits nearest, so the title reads over the brightest style.
  Rectangle {
    id: cardScrim
    readonly property bool atTop: view.lyricsOn
    visible: titleCard.visible
    opacity: titleCard.opacity
    anchors.left: parent.left
    anchors.right: parent.right
    y: atTop ? 0 : parent.height - height
    height: parent.height * (atTop ? 0.42 : 0.6)
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, cardScrim.atTop ? 0.6 : 0) }
      GradientStop { position: 1; color: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, cardScrim.atTop ? 0 : 0.6) }
    }
  }

  Item {
    id: titleCard
    x: parent.width * 0.06
    y: parent.height * (view.lyricsOn ? 0.12 : 0.56)
    width: parent.width * 0.8
    height: col.height
    opacity: 0
    visible: opacity > 0

    property real spread: 0      // extra letter spacing, eases to 0
    property real rule: 0        // accent rule length, 0..1
    property string title: ""
    property string artist: ""

    property string nextTitle: ""
    property string nextArtist: ""
    function play() {
      var t = view.track
      nextTitle = t ? (t.title || "") : ""
      nextArtist = t ? (Array.isArray(t.artists) ? t.artists.join(", ") : (t.artist || "")) : ""
      if (!nextTitle) { clear(); return }
      // A skip while a card is up: the old one steps out first, never cut.
      gone.stop()
      handover.duration = opacity > 0.01 ? Tui.STATE : 0
      card.restart()
    }
    function clear() {
      card.stop()
      if (opacity > 0.01) gone.restart()
    }
    NumberAnimation { id: gone; target: titleCard; property: "opacity"; to: 0; duration: Tui.STATE; easing.type: Easing.InOutCubic }

    Column {
      id: col
      spacing: view.unit * 0.25
      Rectangle {
        width: titleCard.width * 0.18 * titleCard.rule
        height: Math.max(2, view.unit * 0.1)
        color: view.accentText
      }
      // The title's halo flares while the letters resolve and settles with them.
      GlowText {
        width: titleCard.width
        text: titleCard.title
        glow: view.bloom * (0.3 + 0.7 * Math.min(1, titleCard.spread / Math.max(1, view.unit * 0.9)))
        glowLive: titleCard.visible && view.bloom > 0
        glowColor: view.accentText
        glowRadius: Math.min(32, Math.round(view.unit * 0.45))
        elide: Text.ElideRight
        font.family: view.family
        font.pixelSize: view.unit * 2.1
        font.bold: true
        font.letterSpacing: titleCard.spread
        color: view.fg
        style: Text.Raised
        styleColor: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.6)
      }
      Text {
        id: artistText
        width: titleCard.width
        text: titleCard.artist
        elide: Text.ElideRight
        font.family: view.family
        font.pixelSize: view.unit * 1.0
        font.letterSpacing: view.unit * 0.12
        color: view.accentText
        opacity: 0
      }
    }

    SequentialAnimation {
      id: card
      NumberAnimation { id: handover; target: titleCard; property: "opacity"; to: 0; easing.type: Easing.InOutCubic }
      ScriptAction { script: { titleCard.title = titleCard.nextTitle; titleCard.artist = titleCard.nextArtist
                               titleCard.opacity = 0; artistText.opacity = 0; titleCard.rule = 0 } }
      ParallelAnimation {
        NumberAnimation { target: titleCard; property: "opacity"; from: 0; to: 1; duration: 1200; easing.type: Easing.OutCubic }
        NumberAnimation { target: titleCard; property: "spread"; from: view.unit * 0.9; to: view.unit * 0.04; duration: 1800; easing.type: Easing.OutQuart }
        NumberAnimation { target: titleCard; property: "rule"; from: 0; to: 1; duration: 900; easing.type: Easing.OutCubic }
        SequentialAnimation {
          PauseAnimation { duration: 600 }
          NumberAnimation { target: artistText; property: "opacity"; from: 0; to: 1; duration: 900 }
        }
      }
      PauseAnimation { duration: 3800 }
      NumberAnimation { target: titleCard; property: "opacity"; to: 0; duration: 1600; easing.type: Easing.InOutSine }
    }
  }

  // ---- readouts ----------------------------------------------------------------

  Text {
    visible: !!view.engine && view.engine.showFps
    anchors { top: parent.top; right: parent.right; margins: Math.max(6, view.unit * 0.4) }
    text: Math.round(view.fps) + " fps" + (view.scale_ < 1 ? " · " + Math.round(view.scale_ * 100) + "%" : "")
    font.family: view.family
    font.pixelSize: Math.max(Style.font.caption, view.unit * 0.45)
    color: view.fps < view.target * 0.85 ? view.accentText : view.dim
    style: Text.Outline
    styleColor: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.7)
  }

  // ---- at rest ------------------------------------------------------------------
  //
  // Nothing to play, signed out, or no way to hear it: one calm line in the
  // middle, breathing on the shared clock. Paused: a small mark in the corner;
  // the title and the lyrics stay where they were.
  readonly property real breath: engine && engine.time >= 0 ? 0.5 + 0.5 * Math.sin(engine.time * 1.2) : 1
  Column {
    id: rest
    anchors.centerIn: parent
    width: parent.width * 0.8
    spacing: view.unit * 0.3
    readonly property bool on: view.idle !== "" && view.idle !== "paused"
    opacity: on ? 1 : 0
    visible: opacity > 0.01
    Behavior on opacity { NumberAnimation { duration: Tui.PAGE; easing.type: Easing.InOutCubic } }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(view.accentText) + '">╱╱</font> '
            + (view.idle === "deaf" ? "can’t hear the music" : Tui.esc(view.idle))
      font.family: view.family
      font.pixelSize: Math.max(Style.font.body, view.unit * 0.8)
      font.bold: true
      font.letterSpacing: view.unit * 0.05
      color: view.fg
      opacity: 0.7 + 0.3 * view.breath
      style: Text.Outline
      styleColor: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.6)
    }
    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
      text: view.idle === "signed out" ? "sign in from the player" + (view.libraryKey ? " · " + view.libraryKey : "")
          : view.idle === "nothing playing" ? "pick something in the player" + (view.libraryKey ? " · " + view.libraryKey : "")
          : view.idle === "reconnecting" || view.idle === "connecting" ? "waiting for the player service"
          : view.idle === "deaf" ? (Qt.platform.os === "windows" ? "the audio capture is not running" : "install cava to see the music")
          : ""
      font.family: view.family
      font.pixelSize: Math.max(Style.font.caption, view.unit * 0.42)
      color: view.dim
      style: Text.Outline
      styleColor: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.6)
    }
  }

  Text {
    id: pausedMark
    anchors { left: parent.left; bottom: parent.bottom; margins: Math.max(8, view.unit * 0.6) }
    textFormat: Text.StyledText
    text: '<font color="' + Tui.hex(view.accentText) + '">‖</font> paused'
    font.family: view.family
    font.pixelSize: Math.max(Style.font.caption, view.unit * 0.42)
    color: view.dim
    readonly property bool on: view.idle === "paused"
    property real shown: on ? 1 : 0
    Behavior on shown { NumberAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
    opacity: shown * (0.6 + 0.4 * view.breath)
    visible: shown > 0.01
    style: Text.Outline
    styleColor: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.7)
  }
}
