import QtQuick
import QtQuick.Window
import qs.Commons
import qs.Commons as Commons
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

  // The deck scales up with the window, so a big panel doesn't show a
  // corner-sized mechanism floating in empty space.
  readonly property real dscale: fill ? Math.max(1, Math.min(1.8, Math.min(width / (cw * 34), height / (ch * 40)))) : 1

  readonly property color baseBg: Commons.Color.background !== undefined ? Commons.Color.background : "#000000"
  readonly property color bg: Qt.rgba(baseBg.r, baseBg.g, baseBg.b, 1)
  readonly property color fg: Tui.ensure(Commons.Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Commons.Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Commons.Color.accent, bg, 3)
  readonly property real bloom: Tui.bloom(engine)
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property real beat: engine && playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0
  readonly property bool titleFx: !!engine && engine.titleFx && !engine.gameMode
  readonly property string trackKey: player ? (player.trackTitle || "") + " | " + (player.trackArtist || "") : ""

  // A block-char spectrum off the live audio bands (engine.levels, 0..1), for
  // the small TUI analyser on the deck. Recomputes whenever the bands move.
  readonly property string spectrum: {
    var lv = engine && engine.levels ? engine.levels : []
    var blocks = " ▁▂▃▄▅▆▇█"
    var s = ""
    for (var i = 0; i < 30; i++) {
      var v = Math.max(0, Math.min(1, (lv[i] || 0) * 1.4))
      s += blocks.charAt(Math.round(v * 8))
    }
    return s
  }

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

  implicitHeight: content.implicitHeight + ch * 2
  // A cassette reads as a solid object, so its shell is more opaque than the
  // horizontal card -- less desktop shows through the label and reels.
  background: Commons.Color.background !== undefined ? Qt.rgba(Commons.Color.background.r, Commons.Color.background.g, Commons.Color.background.b, fill ? (Commons.Color.glass === true ? 0 : 1) : 0.92) : "#000000"
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
      id: windowRect
      width: parent.width
      // Sized to the width in the corner; when filling a bigger window (float,
      // tile, desktop) it swallows the spare height so the tape window is the
      // part that grows. The deck below always keeps its seat: in a short or
      // landscape window the tape yields rather than pushing it off the edge.
      height: box.fill ? Math.max(box.ch * 5,
                                  box.height - box.ch * 2.4 - deck.height - content.spacing)
                       : Math.round(parent.width * 0.72)
      color: Qt.rgba(box.bg.r, box.bg.g, box.bg.b, 0.55)
      border.width: 1
      border.color: Tui.mix(box.dim, box.bg, 0.3)
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

    // 2. The deck: cover art and track, a block-char spectrum, the playbar, and
    // the transport. The window above fills the slack so this stays put.
    Column {
      id: deck
      width: parent.width
      spacing: box.ch * 0.55

      // The label sticker: cover art and the track riding on the cassette's
      // label, a tinted card so the deck has an anchor instead of loose rows.
      Rectangle {
        id: label
        anchors.horizontalCenter: parent.horizontalCenter
        width: labelCol.width + box.cw * 3
        height: labelCol.height + box.ch * 0.9
        radius: 3
        color: Tui.alpha(Commons.Color.accent, Tui.A.tint)
        border.width: 1; border.color: Tui.mix(box.dim, box.bg, 0.4)

        Column {
          id: labelCol
          anchors.centerIn: parent
          spacing: box.ch * 0.45
          width: Math.min(box.width - box.cw * 6, Math.round(box.cw * 30 * box.dscale))

          // cover art, centred
          Rectangle {
            id: art
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.round(box.ch * 6 * box.dscale); height: width
            color: Tui.alpha(Commons.Color.accent, Tui.A.tint)
            border.width: 1; border.color: Tui.mix(box.dim, box.bg, 0.4)
            Text {
              anchors.centerIn: parent; visible: !artImg.arrived
              text: "╱╱╱"; font.family: Style.font.family; font.pixelSize: Style.font.body; color: box.dim
            }
            Image {
              id: artImg
              anchors.fill: parent; anchors.margins: 1
              source: box.player && box.player.trackArtUrl ? box.player.trackArtUrl : ""
              fillMode: Image.PreserveAspectCrop; asynchronous: true
              sourceSize: Qt.size(art.width * 2, art.height * 2)
              property bool arrived: false
              onSourceChanged: arrived = false
              onStatusChanged: if (status === Image.Ready) arrived = true
              opacity: arrived ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
            }
            MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: if (box.engine) box.engine.libraryOpen = true
                        TuiTip { text: "open the player" } }
          }

          // title / artist, centred
          Column {
            width: parent.width
            ScrambleText {
              width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
              textFormat: Text.PlainText
              animate: box.titleFx; key: box.trackKey
              target: box.player ? (box.player.trackTitle || "unknown track") : "nothing playing"
              font.family: Style.font.family; font.pixelSize: Math.round(Style.font.body * box.dscale); font.bold: true; color: box.fg
            }
            ScrambleText {
              id: artistRow
              width: parent.width; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
              textFormat: Text.PlainText
              animate: box.titleFx; key: box.trackKey; duration: Tui.DECODE
              target: box.player ? (box.player.trackArtist || "") : "pick something in the player" + (box.libraryKey ? " · " + box.libraryKey : "")
              font.family: Style.font.family; font.pixelSize: Math.round(Style.font.caption * box.dscale); color: box.dim
            }
          }
        }
      }

      // a vibey block-char spectrum off the live bands
      GlowText {
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: box.spectrum
        font.family: Style.font.family; font.pixelSize: Math.round(Tui.px("lead", Style.font.body) * box.dscale)
        color: Tui.mix(box.accent, box.fg, 0.15)
        glowLive: box.bloom > 0 && box.playing
        glow: box.bloom * 0.5 * (0.5 + 0.5 * box.beat)
        glowRadius: 7
      }

      // the playbar -- a bold, full-width tape counter you can scrub
      GlowText {
        id: seek
        width: parent.width
        glow: box.player ? box.bloom * 0.4 : 0
        glowRadius: 6
        readonly property int cells: Math.max(8, Math.floor(width / box.cw) - 7)
        property bool scrubbing: false
        property real scrubFrac: 0
        readonly property real sfrac: scrubbing ? scrubFrac : box.frac
        textFormat: Text.StyledText
        text: Tui.meterRich(sfrac, cells, box.accent, Tui.mix(box.dim, box.bg, 0.3))
              + ' <font color="' + Tui.hex(box.fg) + '">' + box.clock(scrubbing ? scrubFrac * box.length : box.position) + '</font>'
        font.family: Style.font.family; font.pixelSize: Style.font.body
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

      // transport
      Row {
        id: controlsRow
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: box.cw * 2.5 * box.dscale
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
            font.family: Style.font.family; font.pixelSize: Math.round(Tui.px("lead", Style.font.body) * box.dscale * 1.15)
            property real hot: cm.containsMouse ? 1 : 0
            Behavior on hot { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
            color: modelData.a === "like" && box.liked ? Commons.Color.accent
                   : Tui.mix(isPlay && box.playing ? Tui.mix(box.fg, Commons.Color.accent, 0.45 + 0.55 * box.beat) : box.fg, Commons.Color.accent, hot)
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
  }

}
