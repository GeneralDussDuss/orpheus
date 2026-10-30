import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// What the stage shows inside its frame (or full-bleed): the visualizer, at a
// resolution auto quality picks from the measured frame rate, with the title
// card, the karaoke line and the fps readout over it.
Item {
  id: view

  property var engine: null
  property string styleName: "skyline"
  property bool showHints: false          // the key strip, for the full-screen show
  property string hints: ""

  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property string family: Style.font.family
  // Type scales with the stage: a card on a desk and a 3440 px wall both read.
  readonly property real unit: Math.max(10, Math.min(width / 46, height / 18))

  readonly property var api: engine ? engine.api : null
  readonly property var track: api ? api.track : null

  Viz {
    id: viz
    anchors.fill: parent
    engine: view.engine
    styleName: view.styleName
    renderScale: view.scale_
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
  readonly property real fillHead: pos + 0.12 - lyr.offset
  readonly property string lineText: lineIdx >= 0 ? (lyr.lines[lineIdx].text || "") : ""
  readonly property string nextText: lyricsOn && lineIdx + 1 < lyr.lines.length ? (lyr.lines[lineIdx + 1].text || "") : ""
  property var spans: []
  onLineIdxChanged: {
    spans = lineIdx >= 0 ? lyr.wordSpans(lineIdx) : []
    lineIn.restart()
  }

  // A scrim so text reads over any style, only where the text is.
  Rectangle {
    visible: view.lyricsOn
    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    height: parent.height * 0.36
    gradient: Gradient {
      GradientStop { position: 0; color: "transparent" }
      GradientStop { position: 1; color: Qt.rgba(view.bg.r, view.bg.g, view.bg.b, 0.72) }
    }
  }

  Item {
    id: karaoke
    visible: view.lyricsOn
    anchors.horizontalCenter: parent.horizontalCenter
    y: parent.height * 0.70
    width: parent.width * 0.88
    height: lineNow.height + lineNext.height

    FontMetrics { id: kfm; font.family: view.family; font.pixelSize: 100; font.bold: true }
    // As big as fits on one line, capped.
    readonly property real size: {
      var w = kfm.advanceWidth(view.lineText || " ")
      return Math.max(12, Math.min(view.unit * 1.5, 100 * width / Math.max(1, w)))
    }
    FontMetrics { id: lfm; font.family: view.family; font.pixelSize: karaoke.size; font.bold: true }

    // How far the singing has got, in pixels along the line.
    readonly property real filled: {
      var t = view.lineText, sp = view.spans
      if (!t || !sp.length) return 0
      var h = view.fillHead, toks = lyr.tokenize(t), done = 0
      for (var i = 0; i < sp.length && i < toks.length; i++) {
        if (h >= sp[i].end) { done = lfm.advanceWidth(t.substring(0, toks[i].b)); continue }
        if (h > sp[i].t) {
          var f = (h - sp[i].t) / Math.max(0.12, sp[i].end - sp[i].t)
          var a = lfm.advanceWidth(t.substring(0, toks[i].a)), b = lfm.advanceWidth(t.substring(0, toks[i].b))
          done = a + (b - a) * f
        }
        break
      }
      return done
    }

    Item {
      id: lineNow
      width: parent.width
      height: lfm.height * 1.15
      opacity: 0
      Text {
        id: unsung
        anchors.horizontalCenter: parent.horizontalCenter
        text: view.lineText
        font.family: view.family; font.pixelSize: karaoke.size; font.bold: true
        color: Tui.mix(view.fg, view.bg, 0.45)
      }
      Item {
        x: unsung.x
        width: Math.min(unsung.width, karaoke.filled)
        height: parent.height
        clip: true
        Text {
          text: view.lineText
          font.family: view.family; font.pixelSize: karaoke.size; font.bold: true
          color: view.accentText
        }
      }
      transform: Translate { id: lift; y: 0 }
    }
    Text {
      id: lineNext
      anchors.top: lineNow.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: view.nextText
      font.family: view.family; font.pixelSize: karaoke.size * 0.62
      color: view.dim
      opacity: 0.7
    }

    ParallelAnimation {
      id: lineIn
      NumberAnimation { target: lineNow; property: "opacity"; from: 0.15; to: 1; duration: 260; easing.type: Easing.OutCubic }
      NumberAnimation { target: lift; property: "y"; from: karaoke.size * 0.35; to: 0; duration: 320; easing.type: Easing.OutCubic }
    }
  }

  // ---- title card ------------------------------------------------------------
  //
  // When the track changes: an accent rule draws out, the title resolves from
  // wide tracking, the artist follows, it holds, and it all fades away.
  readonly property string trackKey: track ? String(track.id || track.title || "") : ""
  onTrackKeyChanged: if (trackKey !== "" && engine && engine.trackTitle) titleCard.play()
  Component.onCompleted: if (trackKey !== "" && engine && engine.trackTitle) titleCard.play()

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

    function play() {
      var t = view.track
      title = t ? (t.title || "") : ""
      artist = t ? (Array.isArray(t.artists) ? t.artists.join(", ") : (t.artist || "")) : ""
      if (!title) return
      card.restart()
    }

    Column {
      id: col
      spacing: view.unit * 0.25
      Rectangle {
        width: titleCard.width * 0.18 * titleCard.rule
        height: Math.max(2, view.unit * 0.1)
        color: view.accentText
      }
      Text {
        width: titleCard.width
        text: titleCard.title
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
      ScriptAction { script: { titleCard.opacity = 0; artistText.opacity = 0; titleCard.rule = 0 } }
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

  Text {
    id: hintText
    visible: view.showHints && opacity > 0
    anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: view.unit * 0.6 }
    textFormat: Text.StyledText
    text: view.hints
    font.family: view.family
    font.pixelSize: Style.font.caption
    color: view.dim
    opacity: 0
    SequentialAnimation on opacity {
      running: view.showHints
      NumberAnimation { to: 1; duration: 400 }
      PauseAnimation { duration: 3500 }
      NumberAnimation { to: 0; duration: 900 }
    }
  }
  function flashHints() { if (showHints) { hintText.opacity = 1; hintFade.restart() } }
  SequentialAnimation {
    id: hintFade
    PauseAnimation { duration: 2500 }
    NumberAnimation { target: hintText; property: "opacity"; to: 0; duration: 900 }
  }
}
