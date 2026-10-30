import QtQuick
import qs.Commons
import "Tui.js" as Tui

// Now-playing strip under the big visualizer, terminal style:
//   [art]  Title
//          Artist · Album
//          1:23 ━━━━━━━━●───────── 4:56     ⏮ ⏸ ⏭
// Art is the only pixels; everything else is text in the shell font.
Item {
  id: root

  property var engine: null
  readonly property var player: engine ? engine.player : null
  // For our own track read the daemon, the same interpolated value the player
  // window and the widget use, so the three clocks cannot drift apart. MPRIS
  // never broadcasts Position, so anyone else's player is extrapolated by
  // Quickshell and is the best we can do for them.
  readonly property bool ours: !!player && player.identity === "Orpheus" && !!engine && !!engine.api
  readonly property real length: ours ? (engine.api.player.duration || 0)
                                      : (player && player.lengthSupported ? player.length : 0)
  readonly property real position: ours ? (engine.api.position || 0)
                                        : (player && player.positionSupported ? player.position : 0)

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height
  // Opaque reference surface for every contrast guard (Color.background carries alpha).
  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Color.accent, bg, 3)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property color line: Tui.ensure(Tui.mix(Color.foreground, bg, 0.72), bg, 1.6)
  readonly property real clk: engine ? engine.time : -1          // the shared heartbeat
  readonly property bool playing: !!(player && player.isPlaying)
  readonly property real beat: engine && playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0
  readonly property real breath: clk >= 0 ? 0.5 + 0.5 * Math.sin(clk * 1.6) : 1
  readonly property real bloom: Tui.bloom(engine)
  readonly property string title: player ? (player.trackTitle || "unknown track") : "nothing playing"

  // The title decodes in whenever the track changes.
  property real decodeProgress: 1
  NumberAnimation on decodeProgress { id: decodeAnim; from: 0; to: 1; duration: 350; running: false }
  onTitleChanged: decodeAnim.restart()

  // The player window's global key (on Windows as the hotkeys actually bound it).
  readonly property string libraryKey: {
    if (typeof OrpheusKeys === "undefined") return "super+shift+m"
    var b = OrpheusKeys.bindings || []
    for (var i = 0; i < b.length; i++) if (b[i].action === "library" && b[i].combo) return String(b[i].combo).toLowerCase()
    return ""
  }

  implicitHeight: ch * 3.4
  height: implicitHeight

  function clock(s) {
    s = Math.max(0, Math.floor(s || 0))
    var m = Math.floor(s / 60), r = s % 60
    return m + ":" + (r < 10 ? "0" : "") + r
  }

  // Art is the only pixels. Its 1px frame is a membrane: it warms toward the accent
  // on the heartbeat while playing and goes quiet when paused.
  Rectangle {
    id: art
    width: root.height
    height: root.height
    color: Tui.alpha(Color.accent, 0.12)
    border.width: 1
    border.color: root.playing ? Tui.mix(root.line, root.accent, 0.35 + 0.4 * root.breath) : root.line
    Behavior on border.color { ColorAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
    Text {
      anchors.centerIn: parent
      visible: artImage.status !== Image.Ready
      text: "╱╱╱\n╱╱╱"
      horizontalAlignment: Text.AlignHCenter
      font.family: Style.font.family; font.pixelSize: Style.font.body
      color: Tui.mix(root.dim, root.bg, 0.4)
    }
    Image {
      id: artImage
      anchors.fill: parent
      anchors.margins: 1
      source: root.player && root.player.trackArtUrl ? root.player.trackArtUrl : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      sourceSize: Qt.size(art.width * 2, art.height * 2)
    }
  }

  Column {
    anchors.left: art.right
    anchors.leftMargin: root.cw * 2
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter

    Text {
      width: parent.width
      elide: Text.ElideRight
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(root.playing ? root.accent : root.dim) + '">'
            + (root.playing ? Tui.eq(root.clk, 1) : "‖‖‖") + '</font>&nbsp;&nbsp;'
            + Tui.esc(Tui.decode(root.title, root.decodeProgress, 5))
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      color: root.fg
    }
    Text {
      width: parent.width
      elide: Text.ElideRight
      text: root.player ? [root.player.trackArtist, root.player.trackAlbum].filter(function(s) { return !!s }).join(" · ")
                        : "start something in Orpheus" + (root.libraryKey ? " · " + root.libraryKey : "")
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      color: root.dim
    }
    Row {
      spacing: root.cw
      Text {
        text: root.clock(meter.scrubbing ? meter.scrubFrac * root.length : root.position)
        font.family: Style.font.family; font.pixelSize: Style.font.body; color: root.dim
      }
      Text {
        id: meter
        readonly property int cells: Math.max(8, Math.floor((root.width - art.width) / root.cw) - 26)
        // drag to scrub: the bar follows the pointer, the seek goes out on release
        property bool scrubbing: false
        property real scrubFrac: 0
        readonly property real frac: scrubbing ? scrubFrac : Math.max(0, Math.min(1, root.position / Math.max(1, root.length)))
        textFormat: Text.StyledText
        text: Tui.meterRich(frac, cells, root.accent, Tui.mix(root.dim, root.bg, 0.4))
        font.family: Style.font.family; font.pixelSize: Style.font.body
        MouseArea {
          id: meterMouse
          anchors.fill: parent
          anchors.topMargin: -root.ch * 0.25; anchors.bottomMargin: -root.ch * 0.25
          enabled: !!(root.player && root.player.canSeek) && root.length > 0
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          function fracAt(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))) }
          onPressed: function(m) { meter.scrubFrac = fracAt(m.x); meter.scrubbing = true }
          onPositionChanged: function(m) { if (pressed) meter.scrubFrac = fracAt(m.x) }
          onReleased: {
            if (!meter.scrubbing) return
            if (root.player) root.player.position = meter.scrubFrac * root.length
            meter.scrubbing = false
          }
          onCanceled: meter.scrubbing = false
          TuiTip {
            follow: true
            force: meter.scrubbing
            at: Math.max(0, Math.min(meterMouse.width, meterMouse.mouseX))
            text: root.length > 0 ? root.clock((meter.scrubbing ? meter.scrubFrac : meterMouse.fracAt(meterMouse.mouseX)) * root.length) : ""
          }
        }
      }
      Text {
        text: root.clock(root.length)
        font.family: Style.font.family; font.pixelSize: Style.font.body; color: root.dim
      }
      Item { width: root.cw; height: 1 }
      Repeater {
        model: [
          { glyph: "󰒮", action: "previous", tip: "previous track", key: "" },
          { glyph: root.player && root.player.isPlaying ? "󰏤" : "󰐊", action: "toggle", tip: root.playing ? "pause" : "play", key: "space" },
          { glyph: "󰒭", action: "next", tip: "next track", key: "" }
        ]
        GlowText {
          required property var modelData
          text: modelData.glyph
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          // Play breathes with the beat while music runs; hover lights any key.
          readonly property bool isPlay: modelData.action === "toggle"
          color: hover.containsMouse ? root.accentText
                 : (isPlay && root.playing ? Tui.mix(root.fg, root.accentText, 0.45 + 0.55 * root.beat) : root.fg)
          Behavior on color { ColorAnimation { duration: 120 } }
          // ... and its halo pulses with the same beat.
          glowLive: isPlay && root.playing && root.bloom > 0
          glow: glowLive ? root.bloom * (0.3 + 0.7 * root.beat) : 0
          opacity: root.player ? 1 : 0.4
          MouseArea {
            id: hover
            anchors.fill: parent
            anchors.margins: -4
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              var p = root.player
              if (!p) return
              if (parent.modelData.action === "toggle") p.togglePlaying()
              else if (parent.modelData.action === "next" && p.canGoNext) p.next()
              else if (parent.modelData.action === "previous" && p.canGoPrevious) p.previous()
            }
            TuiTip { text: hover.parent.modelData.tip; key: hover.parent.modelData.key }
          }
        }
      }
    }
  }
}
