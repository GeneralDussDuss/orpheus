import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// The widget's contents, shared by every mode (corner widget on a layer, or a
// tiled/floating window). With `fill`, the spectrum stretches to the space the
// box is given and the now-playing row stays at the bottom.
TuiBox {
  id: box

  property var engine: null
  property bool full: true
  property bool fill: false
  readonly property var player: engine ? engine.player : null
  // Hearts only make sense for Orpheus's own (TIDAL) track.
  readonly property var orpheusTrack: engine && engine.api && player && player.identity === "Orpheus" ? engine.api.track : null
  readonly property bool liked: !!orpheusTrack && engine.api.isLiked("track", orpheusTrack.id)

  // Position and length. MPRIS never broadcasts position -- the spec gives only
  // the Seeked signal, so a client is expected to extrapolate -- which left this
  // clock stale while the player window's kept moving, since that one reads the
  // daemon over HTTP. For our own track take the daemon's figure, the same
  // source the window uses, so the two can never disagree. For anyone else's
  // player, advance the last value we were given and re-sync whenever it moves.
  readonly property bool ours: !!player && player.identity === "Orpheus" && !!engine && !!engine.api
  readonly property var apiPlayer: ours && engine.api.player ? engine.api.player : null
  property real mprisBase: 0     // last position MPRIS actually reported
  property real mprisAt: 0       // wall clock (ms) when it reported it
  property real mprisPos: 0      // that, advanced to now

  readonly property real length: apiPlayer ? (apiPlayer.duration || 0)
                                           : (player && player.lengthSupported ? player.length : 0)
  readonly property real position: ours ? (engine.api.position || 0) : mprisPos

  onPlayerChanged: { mprisBase = 0; mprisAt = Date.now(); mprisPos = 0 }
  readonly property color fg: Tui.ensure(Color.foreground, Color.background, 7)
  readonly property color dim: Tui.muted(Color.foreground, Color.background, 4.5)
  // Glow on the accents only: the play key on the beat, a faint halo on the
  // seek line and a liked heart.
  readonly property real bloom: Tui.bloom(engine)
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property real beat: engine && playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0

  // The player window's global key (on Windows as the hotkeys actually bound it).
  readonly property string libraryKey: {
    if (typeof OrpheusKeys === "undefined") return "super+shift+m"
    var b = OrpheusKeys.bindings || []
    for (var i = 0; i < b.length; i++) if (b[i].action === "library" && b[i].combo) return String(b[i].combo).toLowerCase()
    return ""
  }

  // Fades up whenever its window shows (first open, back from game mode, a
  // track after silence) instead of popping in. Widget.qml multiplies its
  // hover dimming onto this.
  property real appear: 0
  opacity: appear
  NumberAnimation on appear { id: appearAnim; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.InOutCubic }
  Connections {
    target: box.Window.window
    function onVisibleChanged() { if (box.Window.window.visible) appearAnim.restart() }
  }

  function clock(s) {
    s = Math.max(0, Math.floor(s || 0))
    return Math.floor(s / 60) + ":" + (s % 60 < 10 ? "0" : "") + (s % 60)
  }

  implicitHeight: content.implicitHeight + ch * 2
  background: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, fill ? 1 : 0.82)
  title: full ? "orpheus · " + (engine ? (engine.styleLabels[engine.widgetViz] || "") : "").toLowerCase() : "now playing"
  keyHint: player && player.isPlaying ? "▶" : "‖"
  clock: engine ? engine.time : -1

  // MPRIS position doesn't tick by itself.
  Timer {
    interval: 1000
    repeat: true
    running: box.visible && !!box.player && box.player.isPlaying
    onTriggered: {
      box.player.positionChanged()
      if (box.apiPlayer) return          // the daemon is authoritative for our own track
      var p = box.player.positionSupported ? box.player.position : 0
      // A jump means the player really did report something new (seek, or a new
      // track): trust it and restart from there. Otherwise keep counting up.
      if (Math.abs(p - box.mprisBase) > 0.05) { box.mprisBase = p; box.mprisAt = Date.now() }
      box.mprisPos = box.mprisBase + (Date.now() - box.mprisAt) / 1000
    }
  }

  Column {
    id: content
    width: parent.width
    spacing: box.ch * 0.4

    Viz {
      visible: box.full
      width: parent.width
      height: box.fill ? Math.max(box.ch * 4, box.height - box.ch * 2.4 - nowRow.height - content.spacing) : box.ch * 9
      engine: box.engine
      styleName: box.engine ? box.engine.widgetViz : "prism"
      // Cycle styles right here: click forward, right-click back, the wheel
      // one style per notch -- the same as the player's rail and the stage.
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
        function onWidgetVizChanged() { if (box.full) vizLabel.flash(box.engine.styleLabels[box.engine.widgetViz] || box.engine.widgetViz) }
      }
    }

    Row {
      id: nowRow
      width: parent.width
      spacing: box.cw * 2

      Rectangle {
        id: art
        width: box.ch * 4.4
        height: width
        color: Tui.alpha(Color.accent, 0.12)
        Image {
          anchors.fill: parent
          source: box.player && box.player.trackArtUrl ? box.player.trackArtUrl : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          sourceSize: Qt.size(art.width * 2, art.height * 2)
        }
        MouseArea { anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: if (box.engine) box.engine.libraryOpen = true
                    TuiTip { text: "open the player" } }
      }

      Column {
        width: parent.width - art.width - box.cw * 2
        anchors.verticalCenter: parent.verticalCenter
        Text {
          width: parent.width; elide: Text.ElideRight
          text: box.player ? (box.player.trackTitle || "unknown track") : "nothing playing"
          font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true; color: box.fg
        }
        Text {
          width: parent.width; elide: Text.ElideRight
          text: box.player ? (box.player.trackArtist || "") : "pick something in the player" + (box.libraryKey ? " \u00b7 " + box.libraryKey : "")
          font.family: Style.font.family; font.pixelSize: Style.font.body; color: box.dim
        }
        GlowText {
          id: seek
          width: parent.width
          glow: box.player ? box.bloom * 0.35 : 0
          glowRadius: 6
          readonly property int cells: Math.max(6, Math.floor(width / box.cw) - 12)
          // drag to scrub: the line follows the pointer, the seek goes out on release
          property bool scrubbing: false
          property real scrubFrac: 0
          readonly property real frac: scrubbing ? scrubFrac : box.position / Math.max(1, box.length)
          text: Tui.meter(frac, cells, "━", "─", "●") + " " + box.clock(scrubbing ? scrubFrac * box.length : box.position)
          font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.accent
          // the line's own width, measured in its font (the old maths scaled the body cell)
          TextMetrics { id: seekLine; font: seek.font; text: Tui.meter(0, seek.cells, "━", "─", "●") }
          MouseArea {
            id: seekMouse
            width: seekLine.advanceWidth
            height: parent.height
            enabled: !!(box.player && box.player.canSeek) && box.length > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
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
              follow: true
              force: seek.scrubbing
              at: Math.max(0, Math.min(seekMouse.width, seekMouse.mouseX))
              text: box.length > 0 ? box.clock((seek.scrubbing ? seek.scrubFrac : seekMouse.fracAt(seekMouse.mouseX)) * box.length) : ""
            }
          }
        }
        Row {
          spacing: box.cw * 2.5
          topPadding: box.ch * 0.2
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
              font.family: Style.font.family; font.pixelSize: Style.font.body + 3
              color: (modelData.a === "like" && box.liked) || cm.containsMouse ? Color.accent
                     : isPlay && box.playing ? Tui.mix(box.fg, Color.accent, 0.45 + 0.55 * box.beat) : box.fg
              glowLive: box.bloom > 0 && ((isPlay && box.playing) || (modelData.a === "like" && box.liked))
              glow: !glowLive ? 0 : isPlay ? box.bloom * (0.3 + 0.7 * box.beat) : box.bloom * 0.4
              visible: modelData.a !== "like" || box.orpheusTrack !== null
              MouseArea {
                id: cm
                anchors.fill: parent
                anchors.margins: -5
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
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
}
