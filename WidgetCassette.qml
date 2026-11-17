import QtQuick
import QtQuick.Window
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import "Tui.js" as Tui

// The vertical widget -- "Studio". A tall, narrow deck for people who run a
// portrait bar: the visualizer on top, then the track (big art on a soft glow,
// the title large, the artist small and spaced out, chips for the stream's
// quality and a like), a mirrored spectrum, the time, a hairline seek line, and
// a control row that prints the key of each control when the window can take
// keys. (The config style is still called "cassette"; the spinning reels went
// with 16aea30 and are not coming back.)
//
// The deck is a double hairline frame -- an outer rule, a 3 px gap, an inner
// rule -- not a card: square corners, text in the shell font, box-drawing
// weight. Pixels are for the album art and the live spectrum only. Every
// colour comes off the live theme through Tui, so it reads in light and dark.
//
// Room decides what shows, from the height it is actually given. The corner
// widget (a layer surface, no keyboard) keeps the art, the track, the seek line
// and the controls; the header's tempo, the chips, the mirror, the time row and
// the key labels only come in a window (`fill`) with the height to spare. The
// visualizer takes whatever is left, so nothing can overlap at any size.
// Same corner-widget plumbing as WidgetBody (the horizontal form).
Item {
  id: box

  property var engine: null
  property bool full: true           // unused here; Widget.qml sets it on every body
  property bool fill: false
  // True only where the host can give this window the keyboard (WidgetWindow).
  // The corner widget is a layer surface with no keyboard focus, so it prints
  // no key labels and handles no keys: a label for a key that does nothing is
  // worse than none.
  property bool keys: false

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height

  readonly property var player: engine ? engine.player : null
  readonly property var orpheusTrack: engine && engine.api && player && player.identity === "Orpheus" ? engine.api.track : null
  readonly property bool liked: !!orpheusTrack && engine.api.isLiked("track", orpheusTrack.id)

  // --- position / length (copied from WidgetBody: MPRIS never ticks position) ---
  readonly property bool ours: !!player && player.identity === "Orpheus" && !!engine && !!engine.api
  readonly property var apiPlayer: ours && engine.api.player ? engine.api.player : null
  property real mprisBase: 0
  property real mprisAt: 0
  property real mprisPos: 0
  readonly property real length: apiPlayer ? (apiPlayer.duration || 0)
                                           : (player && player.lengthSupported ? player.length : 0)
  readonly property real position: ours ? (engine.api.position || 0) : mprisPos
  onPlayerChanged: { mprisBase = 0; mprisAt = Date.now(); mprisPos = 0 }
  // How far through the track we are, 0..1.
  readonly property real frac: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0
  // Scrubbing the seek line: the line and the elapsed time follow the pointer
  // until release, when the player is told once.
  property bool scrubbing: false
  property real scrubFrac: 0
  readonly property real sfrac: scrubbing ? scrubFrac : frac

  // The deck scales up with the window, so a big panel doesn't show a
  // corner-sized mechanism floating in empty space.
  readonly property real dscale: fill ? Math.max(1, Math.min(1.8, Math.min(width / (cw * 34), height / (ch * 40)))) : 1

  readonly property color baseBg: Commons.Color.background !== undefined ? Commons.Color.background : "#000000"
  readonly property color bg: Qt.rgba(baseBg.r, baseBg.g, baseBg.b, 1)
  readonly property color fg: Tui.ensure(Commons.Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Commons.Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Commons.Color.accent, bg, 3)
  // The frame and the chips' borders: decoration, so they sit well back.
  readonly property color rule: Tui.mix(dim, bg, 0.6)
  readonly property real bloom: Tui.bloom(engine)
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property real beat: engine && playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0
  readonly property bool titleFx: !!engine && engine.titleFx && !engine.gameMode
  readonly property string trackKey: player ? (player.trackTitle || "") + " | " + (player.trackArtist || "") : ""

  readonly property string libraryKey: {
    if (typeof OrpheusKeys === "undefined") return "super+shift+m"
    var b = OrpheusKeys.bindings || []
    for (var i = 0; i < b.length; i++) if (b[i].action === "library" && b[i].combo) return String(b[i].combo).toLowerCase()
    return ""
  }

  // --- the header's tempo and section ----------------------------------------
  // Only what the engine is sure of. The tempo is the eased estimate and shows
  // once its confidence has built up; the section is the director's reading and
  // means nothing while the director is off or has no beat lock. Silence and
  // pause hide both: a stale number is worse than none.
  readonly property bool tempoOk: settled && !!engine && playing && engine.tempo > 0 && engine.tempoConfidence >= 0.5
  readonly property bool sectionOk: settled && !!engine && playing && engine.director && engine.beatConfidence >= 0.4 && engine.section !== ""
  // After a track change the engine's tempo and section (and the daemon's
  // stream) still describe the last track until the analysis catches up, and
  // during continuous audio their confidence never dips. So all three sit out a
  // settle window; the live confidence checks then decide when they return.
  property bool settled: false
  Timer { id: settleTimer; interval: 6000; running: true; onTriggered: box.settled = true }
  onTrackKeyChanged: { settled = false; settleTimer.restart() }
  // A section change lights the word in the accent and lets it cool: build into
  // drop is the moment the header is for.
  property real secFlash: 0
  NumberAnimation on secFlash { id: flashAnim; running: false; from: 1; to: 0; duration: Tui.PAGE; easing.type: Easing.OutCubic }
  Connections {
    target: box.engine
    function onSectionCodeChanged() { if (box.sectionOk) flashAnim.restart() }
  }

  // The stream's own quality, from the daemon's player state (the same figures
  // the player window's quality chip prints). Empty when the daemon has none.
  readonly property var stream: apiPlayer && apiPlayer.stream ? apiPlayer.stream : null
  readonly property string qualityLabel: {
    var s = stream
    // The daemon's stream state carries no track id, so it can't be matched to
    // the track: hide it through the settle window instead.
    if (!settled || !s || !s.quality) return ""
    var lossy = { HIGH: 320, LOW: 96 }[s.quality]
    if (lossy) return ((s.codec || "AAC") + " " + lossy).toUpperCase()
    var res = s.bitDepth && s.sampleRate ? " " + s.bitDepth + "/" + (s.sampleRate / 1000) : ""
    var fmt = s.codec || (res ? "" : String(s.quality))
    return (String(fmt).toUpperCase() + res).trim()
  }

  // Fade up whenever the window shows, like WidgetBody.
  property real appear: 0
  opacity: appear
  NumberAnimation on appear { id: appearAnim; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.InOutCubic }
  Connections {
    target: box.Window.window
    function onVisibleChanged() { if (box.Window.window.visible) appearAnim.restart() }
  }

  readonly property bool live: !!box.Window.window && box.Window.window.visible
                               && box.Window.window.visibility !== Window.Minimized
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

  // What the controls do -- one place for the buttons and the keys.
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

  // Keys, when the host gave us the keyboard. The same letters as the player
  // window (space, n, p, F, V); anything with a modifier is left for the
  // compositor's own binds.
  focus: keys
  Keys.onPressed: function(e) {
    if (!keys || (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
    // Holding a key must not skip tracks or flicker play/pause.
    if (e.isAutoRepeat) { e.accepted = true; return }
    var a = e.key === Qt.Key_Space ? "toggle" : e.text === "n" ? "next" : e.text === "p" ? "previous"
          : e.text === "F" ? "like" : e.text === "V" ? "stage" : ""
    if (a !== "") e.accepted = act(a)
  }

  // --- layout: from the room we are given --------------------------------------
  readonly property real frameInset: 4                       // outer rule, 3 px gap, inner rule
  readonly property real padX: Math.round(cw * 0.9)
  readonly property real padY: Math.round(ch * 0.6)
  readonly property real innerW: Math.max(0, width - 2 * (frameInset + 1 + padX))
  readonly property real availH: Math.max(0, height - 2 * (frameInset + 1 + padY))
  readonly property real sp: Math.round(ch * 0.55)

  readonly property real headH: Math.round(ch * 1.3)
  // The art takes 38% of the width, but never more than a third of a short
  // window's height: a wide, shallow tile keeps room for the visualizer.
  readonly property real artSize: Math.round(fill ? Math.min(innerW * 0.38, Math.max(ch * 4, availH * 0.3)) : innerW * 0.38)
  readonly property bool showChips: fill && availH >= ch * 30
  readonly property real chipH: Math.round(ch * 1.3)
  readonly property real metaH: Math.max(artSize, titleCol.implicitHeight + (showChips ? chipH + sp : 0))
  readonly property real timeH: Math.round(ch * 1.1)
  readonly property real seekH: Math.round(ch * 0.9)
  readonly property real ctlH: Math.round(Tui.px("lead", Style.font.body) * dscale * 1.15 + (keys ? ch * 1.2 : ch * 0.5))
  readonly property real mirrorH: Math.round(ch * 4.5 * Math.min(dscale, 1.4))
  // Rows that are always there: header, visualizer, track, seek, controls (+ the
  // time row in a window). Spacings between them are `sp` each.
  readonly property real fixedH: headH + metaH + seekH + ctlH + (fill ? timeH : 0) + sp * (fill ? 5 : 4)
  readonly property real vizMin: Math.round(ch * 6)
  // The mirror only joins when the visualizer keeps a decent height without it.
  readonly property bool showMirror: fill && availH - fixedH - mirrorH - sp >= vizMin
  readonly property real vizH: fill ? Math.max(Math.round(ch * 3), availH - fixedH - (showMirror ? mirrorH + sp : 0))
                                    : Math.round(innerW * 0.4)

  implicitHeight: body.implicitHeight + 2 * (frameInset + 1 + padY)

  // The shell is more opaque than the horizontal card (and solid when filling a
  // window), so less desktop shows through the deck.
  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background !== undefined ? Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, box.fill ? (Commons.Color.glass === true ? 0 : 1) : 0.92) : "#000000"
    border.width: 1; border.color: box.rule
  }
  Rectangle {
    anchors.fill: parent; anchors.margins: box.frameInset
    color: "transparent"
    border.width: 1; border.color: box.rule
  }

  // MPRIS position doesn't tick by itself (copied from WidgetBody).
  Timer {
    interval: 1000
    repeat: true
    running: box.visible && !!box.player && box.player.isPlaying
    onTriggered: {
      box.player.positionChanged()
      if (box.apiPlayer) return
      var p = box.player.positionSupported ? box.player.position : 0
      if (Math.abs(p - box.mprisBase) > 0.05) { box.mprisBase = p; box.mprisAt = Date.now() }
      box.mprisPos = box.mprisBase + (Date.now() - box.mprisAt) / 1000
    }
  }

  // One of the art's two swap layers (see `art`).
  component ArtLayer: Image {
    property Item owner: null
    property bool shown: false
    property bool pending: false
    anchors.fill: parent; anchors.margins: 1
    fillMode: Image.PreserveAspectCrop; asynchronous: true
    sourceSize: owner ? Qt.size(owner.width * 2, owner.height * 2) : Qt.size(0, 0)
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
    onStatusChanged: if (owner) owner.layerStatus(this)
  }

  // A little tag with a hairline border, for the quality and the like.
  component Chip: Rectangle {
    id: chip
    property string label: ""
    property color tone: box.dim
    property bool clickable: false
    property string tip: ""
    signal clicked()
    implicitWidth: chipText.implicitWidth + Math.round(box.cw * 1.2)
    implicitHeight: box.chipH
    color: "transparent"
    border.width: 1
    border.color: Tui.mix(tone, box.bg, 0.55)
    Text {
      id: chipText
      anchors.centerIn: parent
      text: chip.label
      font.family: Style.font.family; font.pixelSize: Style.font.caption
      color: chip.tone
    }
    MouseArea {
      anchors.fill: parent
      enabled: chip.clickable
      cursorShape: Qt.PointingHandCursor
      hoverEnabled: true
      onClicked: chip.clicked()
      TuiTip { text: chip.tip; key: box.keys ? "F" : "" }
    }
  }

  Column {
    id: body
    x: box.frameInset + 1 + box.padX
    y: box.frameInset + 1 + box.padY
    width: box.innerW
    spacing: box.sp

    // 1. Header: what this is and which visualizer, and on the right the
    // engine's tempo and section when it is sure of them.
    Item {
      width: parent.width
      height: box.headH
      Text {
        id: headLeft
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        width: Math.max(0, parent.width - headRight.width - box.cw)
        elide: Text.ElideRight
        text: "orpheus · " + (box.engine ? (box.engine.styleLabels[box.engine.widgetViz] || "") : "").toLowerCase()
        font.family: Style.font.family; font.pixelSize: Style.font.caption
        color: box.dim
      }
      Row {
        id: headRight
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        spacing: box.cw * 0.6
        Text {
          visible: box.fill && box.tempoOk
          text: box.engine ? Math.round(box.engine.tempo) + " bpm" : ""
          font.family: Style.font.family; font.pixelSize: Style.font.caption; font.features: { "tnum": 1 }
          color: box.dim
        }
        Text {
          visible: box.fill && box.tempoOk && box.sectionOk
          text: "·"
          font.family: Style.font.family; font.pixelSize: Style.font.caption
          color: box.dim
        }
        Text {
          visible: box.fill && box.sectionOk
          text: box.engine ? box.engine.section : ""
          font.family: Style.font.family; font.pixelSize: Style.font.caption
          font.bold: box.secFlash > 0.3
          color: Tui.mix(box.dim, box.accent, box.secFlash)
        }
        Text {
          id: closeMark
          text: "✕"
          font.family: Style.font.family; font.pixelSize: Style.font.caption
          color: closeMouse.containsMouse ? box.accent : box.dim
          MouseArea {
            id: closeMouse
            anchors.fill: parent; anchors.margins: -4
            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: if (box.engine) box.engine.setWidget("enabled", "off")
            TuiTip { text: "close the widget" }
          }
        }
      }
    }

    // 2. The visualizer. Sized to the width in the corner; in a window it
    // swallows the spare height, so it is the part that grows and the rows
    // below always keep their seat. Click it to cycle the style.
    Rectangle {
      id: vizRect
      width: parent.width
      height: box.vizH
      color: Qt.rgba(box.bg.r, box.bg.g, box.bg.b, 0.55)
      border.width: 1
      border.color: box.rule
      clip: true

      Viz {
        anchors.fill: parent
        anchors.margins: 1
        visible: box.live
        engine: box.engine
        styleName: box.engine ? box.engine.widgetViz : "prism"
        MouseArea {
          id: vizMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
          property real wheelAcc: 0
          onClicked: function(m) { if (box.engine) box.engine.cycleWidgetViz(m.button === Qt.RightButton ? -1 : 1) }
          onWheel: function(w) { var n = Tui.notches(vizMouse, w.angleDelta.y); if (n && box.engine) box.engine.cycleWidgetViz(-n) }
          TuiTip { text: "click: next style · right-click: back · scroll"; delay: 900 }
        }
        VizLabel { id: vizLabel; anchors.fill: parent }
        Connections {
          target: box.engine
          function onWidgetVizChanged() { vizLabel.flash(box.engine.styleLabels[box.engine.widgetViz] || box.engine.widgetViz) }
        }
      }
    }

    // 3. The track: art on a glow, the title large, the artist small and spaced,
    // chips at the foot. Art and text cross over on a track change.
    Item {
      id: meta
      width: parent.width
      height: box.metaH

      Item {
        id: artBox
        width: box.artSize; height: box.artSize

        // The glow: the accent, blurred once, sitting behind the art. Only its
        // opacity moves (a composite, never a re-blur), breathing with the beat
        // when title effects are on. Off with bloom (and on light themes), and
        // in game mode.
        Loader {
          active: box.live && box.bloom > 0 && !!box.engine && !box.engine.gameMode
          anchors.fill: parent
          sourceComponent: Item {
            Rectangle { id: glowSrc; anchors.fill: parent; color: box.accent; visible: false }
            MultiEffect {
              source: glowSrc
              anchors.fill: glowSrc
              autoPaddingEnabled: true
              blurEnabled: true
              blur: 1
              blurMax: 36
              scale: 1.1
              opacity: box.bloom * (0.2 + (box.titleFx ? 0.3 * box.beat : 0.1))
            }
          }
        }

        Rectangle {
          id: art
          anchors.fill: parent
          color: Tui.mix(box.accent, box.bg, 0.88)
          border.width: 1; border.color: box.rule
          clip: true

          // Two layers that trade roles. The one on show never changes source:
          // a new cover loads into the other, and only once it is Ready does it
          // fade in over the first, which is then emptied (freeing its decode).
          // No art, or a failed load, fades both out to the placeholder, so a
          // stale cover is never left up.
          readonly property string url: box.player && box.player.trackArtUrl ? box.player.trackArtUrl : ""
          property Item front: layerA
          property bool hasArt: false
          onUrlChanged: show(url)
          Component.onCompleted: show(url)
          function show(u) {
            if (u === "") { clear(); return }
            var h = front === layerA ? layerB : layerA
            h.pending = true
            h.source = u
            // a cached cover is Ready at once, before any status change fires
            if (h.status === Image.Ready) layerStatus(h)
          }
          function clear() {
            layerA.pending = false; layerB.pending = false
            layerA.shown = false; layerB.shown = false
            hasArt = false
            wipe.restart()
          }
          function layerStatus(l) {
            if (!l.pending) return
            if (l.status === Image.Ready) {
              l.pending = false
              var o = l === layerA ? layerB : layerA
              o.z = 1; l.z = 2
              l.shown = true
              front = l
              hasArt = true
              wipe.restart()
            } else if (l.status === Image.Error) {
              clear()
            }
          }
          // After the fade, empty whichever layer is no longer on show.
          Timer {
            id: wipe
            interval: Tui.STATE + 40
            onTriggered: {
              var ls = [layerA, layerB]
              for (var i = 0; i < 2; i++)
                if (!ls[i].pending && (ls[i] !== art.front || !art.hasArt)) { ls[i].shown = false; ls[i].source = "" }
            }
          }

          Text {
            anchors.centerIn: parent; opacity: art.hasArt ? 0 : 1
            Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
            text: "╱╱╱"; font.family: Style.font.family; font.pixelSize: Style.font.body; color: box.dim
          }
          ArtLayer { id: layerA; owner: art }
          ArtLayer { id: layerB; owner: art }
          MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: if (box.engine) box.engine.libraryOpen = true
                      TuiTip { text: "open the player" } }
        }
      }

      // slide and fade in on a track change, at the shared state pace
      property real swap: 1
      NumberAnimation on swap { id: swapAnim; running: false; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.OutCubic }
      Connections { target: box; function onTrackKeyChanged() { swapAnim.restart() } }

      Column {
        id: titleCol
        x: box.artSize + box.cw * 1.2 + (1 - meta.swap) * box.cw
        width: Math.max(0, parent.width - box.artSize - box.cw * 1.2)
        opacity: 0.25 + 0.75 * meta.swap
        spacing: Math.round(box.ch * 0.25)
        ScrambleText {
          width: parent.width; elide: Text.ElideRight; wrapMode: Text.Wrap; maximumLineCount: 2
          textFormat: Text.PlainText
          animate: box.titleFx; key: box.trackKey
          target: box.player ? (box.player.trackTitle || "unknown track") : "nothing playing"
          font.family: Style.font.family; font.pixelSize: Math.round(Tui.px("title", Style.font.body) * Math.min(box.dscale, 1.35)); font.bold: true
          color: box.fg
        }
        ScrambleText {
          width: parent.width; elide: Text.ElideRight
          textFormat: Text.PlainText
          animate: box.titleFx; key: box.trackKey; duration: Tui.DECODE
          target: box.player ? (box.player.trackArtist || "") : "pick something in the player" + (box.libraryKey ? " · " + box.libraryKey : "")
          font.family: Style.font.family; font.pixelSize: Math.round(Style.font.caption * Math.min(box.dscale, 1.3))
          font.capitalization: Font.AllUppercase; font.letterSpacing: 1.2
          color: box.dim
        }
      }

      Row {
        visible: box.showChips
        x: titleCol.x
        anchors.bottom: parent.bottom
        spacing: Math.round(box.cw * 0.6)
        Chip { id: chipQ; visible: box.qualityLabel !== "" && implicitWidth <= titleCol.width; label: box.qualityLabel }
        Chip {
          visible: box.liked && (chipQ.visible ? chipQ.width + parent.spacing : 0) + implicitWidth <= titleCol.width
          label: "♥"
          tone: box.accent
          clickable: true
          tip: "unlike"
          onClicked: box.act("like")
        }
      }
    }

    // 4. The mirrored spectrum: the live bands as bars rising from a baseline,
    // with a faint reflection fading out below it. Pixels, because it is the
    // spectrum.
    Item {
      id: mirror
      visible: box.showMirror
      readonly property bool active: box.showMirror && box.live
      width: parent.width
      height: box.mirrorH
      readonly property int bars: 30
      readonly property real gap: 2
      readonly property real bw: Math.max(1, Math.floor((width - (bars - 1) * gap) / bars))
      readonly property real baseY: Math.round(height * 0.62)
      readonly property real span: bars * bw + (bars - 1) * gap
      Repeater {
        model: mirror.active ? mirror.bars : 0
        Item {
          required property int index
          readonly property real v: box.playing && box.engine && box.engine.levels
                                    ? Math.max(0, Math.min(1, (box.engine.levels[index] || 0) * 1.4)) : 0
          x: Math.round((mirror.width - mirror.span) / 2) + index * (mirror.bw + mirror.gap)
          width: mirror.bw; height: mirror.height
          Rectangle {
            width: parent.width; height: Math.max(1, Math.round(mirror.baseY * parent.v))
            y: mirror.baseY - height
            color: Tui.mix(box.accent, box.fg, 0.15)
          }
          Rectangle {
            y: mirror.baseY + 2
            width: parent.width; height: Math.round((mirror.height - mirror.baseY - 2) * parent.v)
            gradient: Gradient {
              GradientStop { position: 0; color: Tui.alpha(box.accent, 0.3) }
              GradientStop { position: 1; color: Tui.alpha(box.accent, 0) }
            }
          }
        }
      }
      Rectangle { y: mirror.baseY; width: parent.width; height: 1; color: box.rule }
    }

    // 5. Time: elapsed on the left, what is left on the right.
    Item {
      visible: box.fill
      width: parent.width
      height: box.timeH
      Text {
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        text: box.clock(box.scrubbing ? box.scrubFrac * box.length : box.position)
        font.family: Style.font.family; font.pixelSize: Style.font.caption; font.features: { "tnum": 1 }
        color: box.fg
      }
      Text {
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        visible: box.length > 0
        text: "−" + box.clock(box.length * (1 - box.sfrac))
        font.family: Style.font.family; font.pixelSize: Style.font.caption; font.features: { "tnum": 1 }
        color: box.dim
      }
    }

    // 6. The seek line: a 2 px hairline with an accent fill and a soft glow,
    // a touch thicker under the pointer. Click or drag to seek, as ever.
    Item {
      id: seekBar
      width: parent.width
      height: box.seekH
      readonly property bool hot: seekMouse.containsMouse || box.scrubbing
      property real th: hot ? 3 : 2
      Behavior on th { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width; height: seekBar.th
        color: Tui.mix(box.dim, box.bg, 0.6)
      }
      Rectangle {
        anchors { verticalCenter: parent.verticalCenter; left: parent.left }
        visible: box.bloom > 0 && box.player !== null
        width: Math.round(parent.width * box.sfrac); height: seekBar.th + 6
        color: Tui.alpha(box.accent, 0.22 * box.bloom)
      }
      Rectangle {
        anchors { verticalCenter: parent.verticalCenter; left: parent.left }
        width: Math.round(parent.width * box.sfrac); height: seekBar.th
        color: box.accent
      }
      Rectangle {
        visible: seekBar.hot && box.length > 0
        anchors.verticalCenter: parent.verticalCenter
        x: Math.max(0, Math.min(parent.width - width, Math.round(parent.width * box.sfrac) - width / 2))
        width: 3; height: Math.round(box.ch * 0.7)
        color: box.accent
      }
      MouseArea {
        id: seekMouse
        anchors.fill: parent
        enabled: !!(box.player && box.player.canSeek) && box.length > 0
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        function fracAt(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))) }
        onPressed: function(m) { box.scrubFrac = fracAt(m.x); box.scrubbing = true }
        onPositionChanged: function(m) { if (pressed) box.scrubFrac = fracAt(m.x) }
        onReleased: {
          if (!box.scrubbing) return
          if (box.player) box.player.position = box.scrubFrac * box.length
          box.scrubbing = false
        }
        onCanceled: box.scrubbing = false
        TuiTip {
          follow: true; force: box.scrubbing
          at: Math.max(0, Math.min(seekMouse.width, seekMouse.mouseX))
          text: box.length > 0 ? box.clock((box.scrubbing ? box.scrubFrac : seekMouse.fracAt(seekMouse.mouseX)) * box.length) : ""
        }
      }
    }

    // 7. Controls, each with its key printed small underneath where the window
    // takes keys. The cells share the width, so five (or four) always fit.
    Row {
      id: controls
      width: parent.width
      height: box.ctlH
      readonly property int count: box.orpheusTrack !== null ? 5 : 4
      Repeater {
        model: [
          { g: "󰒮", a: "previous", k: "p", tip: "previous track" },
          { g: "󰐊", a: "toggle", k: "space", tip: "play / pause" },
          { g: "󰒭", a: "next", k: "n", tip: "next track" },
          { g: "󰋕", a: "like", k: "F", tip: "like / unlike" },
          { g: "󰺢", a: "stage", k: "V", tip: "open or close the big visualizer" }
        ]
        Item {
          id: cell
          required property var modelData
          readonly property bool isPlay: modelData.a === "toggle"
          readonly property bool isLike: modelData.a === "like"
          visible: !isLike || box.orpheusTrack !== null
          width: controls.width / controls.count
          height: controls.height

          Column {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Math.round(box.ch * 0.1)
            GlowText {
              id: glyph
              anchors.horizontalCenter: parent.horizontalCenter
              text: cell.isPlay ? (box.playing ? "󰏤" : "󰐊") : cell.isLike ? (box.liked ? "󰋑" : "󰋕") : cell.modelData.g
              font.family: Style.font.family; font.pixelSize: Math.round(Tui.px("lead", Style.font.body) * box.dscale * 1.15)
              property real hot: cm.containsMouse ? 1 : 0
              Behavior on hot { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
              color: cell.isLike && box.liked ? Commons.Color.accent
                     : Tui.mix(cell.isPlay && box.playing ? Tui.mix(box.fg, Commons.Color.accent, 0.45 + 0.55 * box.beat) : box.fg, Commons.Color.accent, hot)
              scale: cm.pressed ? 0.86 : 1
              Behavior on scale { enabled: !cm.pressed; SpringAnimation { spring: Tui.SPRING.spring; damping: Tui.SPRING.damping } }
              glowLive: box.bloom > 0 && ((cell.isPlay && box.playing) || (cell.isLike && box.liked))
              glow: !glowLive ? 0 : cell.isPlay ? box.bloom * (0.3 + 0.7 * box.beat) : box.bloom * 0.4
            }
            Text {
              visible: box.keys
              anchors.horizontalCenter: parent.horizontalCenter
              text: cell.modelData.k
              font.family: Style.font.family; font.pixelSize: Style.font.caption - 1
              color: box.dim
            }
          }
          MouseArea {
            id: cm
            anchors.fill: parent
            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: box.act(cell.modelData.a)
            TuiTip {
              text: cell.isPlay ? (box.playing ? "pause" : "play") : cell.isLike ? (box.liked ? "unlike" : "like") : cell.modelData.tip
              key: box.keys ? cell.modelData.k : ""
            }
          }
        }
      }
    }
  }
}
