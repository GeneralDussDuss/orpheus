import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// The vertical "cassette" widget -- a standing Walkman tape, for people who run a
// portrait bar and don't want to turn their layout sideways for it. A thin
// spectrum sits in the tape window up top; two reels spin while the song plays
// and their packs wind supply -> take-up with the seek, the album art riding
// between them as the cassette label. Same corner-widget plumbing as WidgetBody
// (the horizontal form), laid out in a narrow column.
TuiBox {
  id: box

  property var engine: null
  property bool full: true           // unused here; Widget.qml sets it on every body
  property bool fill: false
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
  // How far through the tape we are, 0..1 -- drives the reels' winding.
  readonly property real frac: length > 0 ? Math.max(0, Math.min(1, position / length)) : 0

  readonly property color baseBg: Color.background !== undefined ? Color.background : "#000000"
  readonly property color bg: Qt.rgba(baseBg.r, baseBg.g, baseBg.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Color.accent, bg, 3)
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

  // --- reel spin: an accumulated angle so a pause freezes it in place rather
  // than snapping. Driven off the engine's frame clock (same one the shaders
  // use), advanced only while playing. One full turn is a few seconds of tape.
  property real spinAngle: 0
  property real _lastT: -1
  readonly property real reelSpeed: 2.4     // rad/s at play
  onClockChanged: {
    var t = clock >= 0 ? clock : 0
    var dt = t - _lastT
    _lastT = t
    if (dt > 0 && dt < 0.5 && playing) {
      spinAngle += dt * reelSpeed
      reelL.requestPaint(); reelR.requestPaint()
    }
  }

  implicitHeight: content.implicitHeight + ch * 2
  // A cassette reads as a solid object, so its shell is more opaque than the
  // horizontal card -- less desktop shows through the label and reels.
  background: Color.background !== undefined ? Qt.rgba(Color.background.r, Color.background.g, Color.background.b, fill ? (Color.glass === true ? 0 : 1) : 0.92) : "#000000"
  title: "orpheus · " + (engine ? (engine.styleLabels[engine.widgetViz] || "") : "").toLowerCase()
  hintItems: [
    { k: player && player.isPlaying ? "▶" : "‖" },
    { k: "✕", run: function() { if (box.engine) box.engine.setWidget("enabled", "off") }, tip: "close the widget" }
  ]
  clock: engine ? engine.time : -1

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

  Column {
    id: content
    width: parent.width
    spacing: box.ch * 0.7

    // 1. The cassette window: the spectrum is the tape you see through it, with
    // the two reels turning over it -- supply (left) empties into take-up
    // (right) as the song plays. Click the window to cycle the visualizer.
    Rectangle {
      width: parent.width
      height: Math.round(parent.width * 0.72)
      color: Qt.rgba(box.bg.r, box.bg.g, box.bg.b, 0.55)
      border.width: 1
      border.color: Tui.mix(box.dim, box.bg, 0.3)
      clip: true

      Viz {
        anchors.fill: parent
        anchors.margins: 1
        visible: box.live
        opacity: 0.72
        engine: box.engine
        styleName: box.engine ? box.engine.widgetViz : "prism"
        MouseArea {
          id: vizMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.PointingHandCursor
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

      Row {
        anchors.centerIn: parent
        spacing: box.cw * 5
        Canvas {
          id: reelL
          width: box.ch * 3; height: width
          anchors.verticalCenter: parent.verticalCenter
          onPaint: box.paintReel(getContext("2d"), width, 1 - box.frac, -box.spinAngle)
          Component.onCompleted: requestPaint()
          Connections { target: box; function onFracChanged() { reelL.requestPaint() }
                                      function onAccentChanged() { reelL.requestPaint() } }
        }
        Canvas {
          id: reelR
          width: box.ch * 3; height: width
          anchors.verticalCenter: parent.verticalCenter
          onPaint: box.paintReel(getContext("2d"), width, box.frac, -box.spinAngle)
          Component.onCompleted: requestPaint()
          Connections { target: box; function onFracChanged() { reelR.requestPaint() }
                                      function onAccentChanged() { reelR.requestPaint() } }
        }
      }
    }

    // 2. The label: a written-on sticker -- the track on two centred lines.
    // Clicking it opens the player, the way the album art used to.
    Rectangle {
      width: parent.width
      height: labelCol.implicitHeight + box.ch * 1.6
      color: Tui.alpha(Color.foreground, 0.05)
      border.width: 1
      border.color: Tui.mix(box.dim, box.bg, 0.5)
      Column {
        id: labelCol
        width: parent.width - box.cw * 3
        anchors.centerIn: parent
        ScrambleText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          textFormat: Text.PlainText
          animate: box.titleFx; key: box.trackKey
          target: box.player ? (box.player.trackTitle || "unknown track") : "nothing playing"
          font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; color: box.fg
        }
        ScrambleText {
          width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
          textFormat: Text.PlainText
          animate: box.titleFx; key: box.trackKey; duration: Tui.DECODE
          target: box.player ? (box.player.trackArtist || "") : "pick something in the player" + (box.libraryKey ? " · " + box.libraryKey : "")
          font.family: Style.font.family; font.pixelSize: Style.font.caption; color: box.dim
        }
      }
      MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: if (box.engine) box.engine.libraryOpen = true
                  TuiTip { text: "open the player" } }
    }

    // 4. Seek: a thin tape counter line with the elapsed time.
    GlowText {
      id: seek
      width: parent.width
      glow: box.player ? box.bloom * 0.35 : 0
      glowRadius: 6
      readonly property int cells: Math.max(6, Math.floor(width / box.cw) - 8)
      property bool scrubbing: false
      property real scrubFrac: 0
      readonly property real sfrac: scrubbing ? scrubFrac : box.frac
      textFormat: Text.StyledText
      text: Tui.meterRich(sfrac, cells, box.accent, Tui.mix(box.dim, box.bg, 0.4))
            + ' <font color="' + Tui.hex(box.dim) + '">' + box.clock(scrubbing ? scrubFrac * box.length : box.position) + '</font>'
      font.family: Style.font.family; font.pixelSize: Style.font.caption
      color: box.accent
      TextMetrics { id: seekLine; font: seek.font; text: Tui.meter(0, seek.cells, "━", "─", "╸") }
      MouseArea {
        id: seekMouse
        width: seekLine.advanceWidth; height: parent.height
        enabled: !!(box.player && box.player.canSeek) && box.length > 0
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        function fracAt(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))) }
        onPressed: function(m) { seek.scrubFrac = fracAt(m.x); seek.scrubbing = true }
        onPositionChanged: function(m) { if (pressed) seek.scrubFrac = fracAt(m.x) }
        onReleased: {
          if (!seek.scrubbing) return
          if (box.player) box.player.position = seek.scrubFrac * box.length
          seek.scrubbing = false
        }
        onCanceled: seek.scrubbing = false
        TuiTip {
          follow: true; force: seek.scrubbing
          at: Math.max(0, Math.min(seekMouse.width, seekMouse.mouseX))
          text: box.length > 0 ? box.clock((seek.scrubbing ? seek.scrubFrac : seekMouse.fracAt(seekMouse.mouseX)) * box.length) : ""
        }
      }
    }

    // 5. Controls, centred.
    Row {
      anchors.horizontalCenter: parent.horizontalCenter
      spacing: box.cw * 2.5
      topPadding: box.ch * 0.1
      Repeater {
        model: [
          { g: "󰒮", a: "previous", tip: "previous track" },
          { g: box.player && box.player.isPlaying ? "󰏤" : "󰐊", a: "toggle", tip: box.playing ? "pause" : "play" },
          { g: "󰒭", a: "next", tip: "next track" },
          { g: box.liked ? "󰋑" : "󰋕", a: "like", tip: box.liked ? "unlike" : "like" },
          { g: "󰺢", a: "stage", tip: "open or close the big visualizer" }
        ]
        GlowText {
          required property var modelData
          readonly property bool isPlay: modelData.a === "toggle"
          text: modelData.g
          font.family: Style.font.family; font.pixelSize: Tui.px("lead", Style.font.body)
          property real hot: cm.containsMouse ? 1 : 0
          Behavior on hot { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
          color: modelData.a === "like" && box.liked ? Color.accent
                 : Tui.mix(isPlay && box.playing ? Tui.mix(box.fg, Color.accent, 0.45 + 0.55 * box.beat) : box.fg, Color.accent, hot)
          scale: cm.pressed ? 0.86 : 1
          Behavior on scale { enabled: !cm.pressed; SpringAnimation { spring: Tui.SPRING.spring; damping: Tui.SPRING.damping } }
          glowLive: box.bloom > 0 && ((isPlay && box.playing) || (modelData.a === "like" && box.liked))
          glow: !glowLive ? 0 : isPlay ? box.bloom * (0.3 + 0.7 * box.beat) : box.bloom * 0.4
          visible: modelData.a !== "like" || box.orpheusTrack !== null
          MouseArea {
            id: cm
            anchors.fill: parent; anchors.margins: -5
            hoverEnabled: true; cursorShape: Qt.PointingHandCursor
            onClicked: {
              var p = box.player, a = parent.modelData.a
              if (a === "stage") { if (box.engine) box.engine.open = !box.engine.open; return }
              if (a === "like") { if (box.orpheusTrack) box.engine.api.toggleLike("track", box.orpheusTrack.id); return }
              if (!p) return
              if (a === "toggle") p.togglePlaying()
              else if (a === "next" && p.canGoNext) p.next()
              else if (a === "previous" && p.canGoPrevious) p.previous()
            }
            TuiTip { text: cm.parent.modelData.tip }
          }
        }
      }
    }
  }

  // Draw one reel: a tape pack whose radius grows with `fill` (0 empty .. 1
  // full, area-conserving so it reads as wound tape), a dark hub, and spokes
  // turned to `ang`. Terminal-flat -- flat fills, 1px rims, no gradients.
  function paintReel(ctx, size, fill, ang) {
    var cx = size / 2, cy = size / 2
    var rMax = size * 0.46
    var rHub = size * 0.17
    // area-conserving pack radius between hub and rim
    var f = Math.max(0, Math.min(1, fill))
    var rPack = Math.sqrt(rHub * rHub + (rMax * rMax - rHub * rHub) * f)

    var b = box.bg
    function rgba(c, a) { return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + a + ")" }

    ctx.reset()
    ctx.clearRect(0, 0, size, size)
    ctx.lineCap = "round"

    // a dark disc so the reel reads over the busy spectrum behind it
    ctx.beginPath(); ctx.arc(cx, cy, rMax + 1, 0, 2 * Math.PI)
    ctx.fillStyle = rgba(b, 0.7); ctx.fill()

    // reel well (the hole in the shell the reel sits in)
    ctx.beginPath(); ctx.arc(cx, cy, rMax, 0, 2 * Math.PI)
    ctx.strokeStyle = Tui.hex(Tui.mix(box.dim, box.bg, 0.4)); ctx.lineWidth = 1; ctx.stroke()

    // wound tape pack -- a filled ring whose edge grows with the tape
    if (rPack > rHub + 0.5) {
      ctx.beginPath(); ctx.arc(cx, cy, rPack, 0, 2 * Math.PI)
      ctx.fillStyle = rgba(b, 0.4); ctx.fill()
      ctx.beginPath(); ctx.arc(cx, cy, rPack, 0, 2 * Math.PI)
      ctx.strokeStyle = Tui.hex(Tui.mix(box.dim, box.accent, 0.3)); ctx.lineWidth = 1; ctx.stroke()
    }

    // hub -- six teeth around a ring, turned so the spin reads
    ctx.strokeStyle = Tui.hex(box.accent); ctx.lineWidth = 1.5
    for (var i = 0; i < 6; i++) {
      var a = ang + i * Math.PI / 3
      ctx.beginPath()
      ctx.moveTo(cx + Math.cos(a) * rHub, cy + Math.sin(a) * rHub)
      ctx.lineTo(cx + Math.cos(a) * (rHub + size * 0.08), cy + Math.sin(a) * (rHub + size * 0.08))
      ctx.stroke()
    }
    ctx.beginPath(); ctx.arc(cx, cy, rHub, 0, 2 * Math.PI)
    ctx.fillStyle = Tui.hex(box.bg); ctx.fill()
    ctx.strokeStyle = Tui.hex(box.accent); ctx.lineWidth = 1.5; ctx.stroke()
  }
}
