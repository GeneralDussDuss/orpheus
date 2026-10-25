import QtQuick
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
      // Cycle styles right here: click/scroll forward, right-click back.
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function(m) { if (box.engine) box.engine.cycleWidgetViz(m.button === Qt.RightButton ? -1 : 1) }
        onWheel: function(w) { if (box.engine) box.engine.cycleWidgetViz(w.angleDelta.y > 0 ? -1 : 1) }
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
        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: if (box.engine) box.engine.libraryOpen = true }
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
          text: box.player ? (box.player.trackArtist || "") : "super+shift+m to pick something"
          font.family: Style.font.family; font.pixelSize: Style.font.body; color: box.dim
        }
        Text {
          id: seek
          width: parent.width
          readonly property int cells: Math.max(6, Math.floor(width / box.cw) - 12)
          text: Tui.meter(box.position / Math.max(1, box.length), cells, "━", "─", "●") + " " + box.clock(box.position)
          font.family: Style.font.family; font.pixelSize: Style.font.caption; color: Color.accent
          MouseArea {
            width: seek.cells * box.cw * (Style.font.caption / Style.font.body)
            height: parent.height
            enabled: !!(box.player && box.player.canSeek)
            cursorShape: Qt.PointingHandCursor
            onClicked: function(m) { box.player.position = (m.x / width) * box.length }
          }
        }
        Row {
          spacing: box.cw * 2.5
          topPadding: box.ch * 0.2
          Repeater {
            model: [
              { g: "󰒮", a: "previous" },
              { g: box.player && box.player.isPlaying ? "󰏤" : "󰐊", a: "toggle" },
              { g: "󰒭", a: "next" },
              { g: box.liked ? "󰋑" : "󰋕", a: "like" },
              { g: "󰺢", a: "stage" }
            ]
            Text {
              required property var modelData
              text: modelData.g
              font.family: Style.font.family; font.pixelSize: Style.font.body + 3
              color: (modelData.a === "like" && box.liked) || cm.containsMouse ? Color.accent : box.fg
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
              }
            }
          }
        }
      }
    }
  }
}
