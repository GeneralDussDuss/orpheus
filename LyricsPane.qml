import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// Lyrics, following the track.
//
// The daemon refreshes position about once a second, which is far too coarse to
// land a line on its own beat, so this extrapolates from the last known value
// against a local clock and only re-anchors when the daemon disagrees. Nothing
// extra is asked of the network: the same status poll drives it.
Rectangle {
  id: pane

  property var host: null
  readonly property var api: host ? host.api : null
  readonly property var track: host ? host.track : null
  readonly property var st: host ? host.st : ({})

  // Color.background can arrive as a string, and `.r` on a string is undefined,
  // which makes Qt.rgba() transparent. Coerce first.
  readonly property color base: Color.background
  color: Qt.rgba(base.r, base.g, base.b, 1)
  focus: true

  // ---- model -------------------------------------------------------------

  property var lines: []
  property string plain: ""
  property string source: ""
  property bool synced: false
  property bool loading: false
  property bool instrumental: false
  property string loadedFor: ""
  property real offset: 0          // listener's own nudge, seconds

  // ---- position ----------------------------------------------------------

  property real anchorPos: 0       // last position the daemon reported
  property real anchorAt: 0        // ... and the local time we heard it
  readonly property bool playing: st && st.playing === true

  function now() { return Date.now() / 1000 }

  // Re-anchor whenever the daemon's number moves, which also covers seeking.
  onStChanged: {
    var p = (st && st.position) || 0
    if (Math.abs(p - projected()) > 0.35 || !playing) {
      anchorPos = p
      anchorAt = now()
    }
  }

  function projected() {
    if (!playing) return anchorPos
    return anchorPos + (now() - anchorAt)
  }

  property real clockPos: 0
  Timer {
    interval: 100            // 10 Hz is plenty to land a line on its beat
    repeat: true
    running: pane.visible
    onTriggered: pane.clockPos = pane.projected()
  }

  readonly property int activeLine: {
    var p = clockPos - offset
    if (!lines || !lines.length) return -1
    // binary search for the last line at or before now
    var lo = 0, hi = lines.length - 1, found = -1
    while (lo <= hi) {
      var mid = (lo + hi) >> 1
      if (lines[mid].t <= p) { found = mid; lo = mid + 1 } else { hi = mid - 1 }
    }
    return found
  }

  onActiveLineChanged: if (activeLine >= 0) list.positionViewAtIndex(activeLine, ListView.Center)

  // ---- loading -----------------------------------------------------------

  function load() {
    if (!api || !track || !track.id) { lines = []; plain = ""; source = ""; return }
    if (loadedFor === String(track.id)) return
    loadedFor = String(track.id)
    loading = true
    lines = []; plain = ""; source = ""; instrumental = false; offset = 0
    api.get("/lyrics/" + track.id, function(ok, d) {
      pane.loading = false
      if (!ok || !d) { pane.source = "none"; return }
      pane.lines = d.lines || []
      pane.plain = d.plain || ""
      pane.synced = d.synced === true
      pane.source = d.source || "none"
      pane.instrumental = d.instrumental === true
      pane.offset = -(d.offset || 0)
    })
  }

  Component.onCompleted: load()
  onTrackChanged: load()

  // ---- keys --------------------------------------------------------------

  Keys.onPressed: function(e) {
    var t = e.text, k = e.key
    // the sync nudge: plenty of community LRC files run a little early or late
    if (t === "[") { offset -= 0.25; e.accepted = true }
    else if (t === "]") { offset += 0.25; e.accepted = true }
    else if (t === "\\") { offset = 0; e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { list.flick(0, -600); e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { list.flick(0, 600); e.accepted = true }
    else e.accepted = host.handleKey(e)
  }

  MouseArea {
    anchors.fill: parent
    onPressed: function(m) { pane.forceActiveFocus(); m.accepted = false }
  }

  // ---- drawing -----------------------------------------------------------

  Column {
    id: header
    x: host ? host.cw * 3 : 12
    y: host ? host.ch : 10
    spacing: host ? host.ch * 0.2 : 4
    width: parent.width - (host ? host.cw * 6 : 24)

    Text {
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> LYRICS '
            + '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
      width: parent.width
      clip: true
      font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
      color: host.dim
    }
    Text {
      text: {
        if (pane.loading) return "looking…"
        if (pane.instrumental) return "instrumental"
        if (!pane.lines.length && !pane.plain) return "nothing found for this track"
        var via = pane.source === "lrclib" ? "lrclib" : pane.source
        return (pane.synced ? "synced · " : "unsynced · ") + via
             + (Math.abs(pane.offset) > 0.01
                ? "   offset " + (pane.offset > 0 ? "+" : "") + pane.offset.toFixed(2) + "s" : "")
      }
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }
  }

  // synced: a scrolling list that keeps the current line centred
  ListView {
    id: list
    visible: pane.lines.length > 0
    anchors.fill: parent
    anchors.topMargin: header.height + (host ? host.ch * 2 : 20)
    anchors.bottomMargin: host ? host.ch * 3 : 30
    anchors.leftMargin: host ? host.cw * 3 : 12
    anchors.rightMargin: host ? host.cw * 3 : 12
    model: pane.lines
    clip: true
    interactive: true
    preferredHighlightBegin: height / 2 - (host ? host.ch : 10)
    preferredHighlightEnd: height / 2 + (host ? host.ch : 10)
    highlightRangeMode: ListView.ApplyRange
    currentIndex: pane.activeLine

    delegate: Text {
      required property var modelData
      required property int index
      readonly property bool isNow: index === pane.activeLine
      readonly property bool isPast: index < pane.activeLine
      width: ListView.view.width
      wrapMode: Text.WordWrap
      // an empty timed line is an instrumental gap; give it air, not a blank row
      text: modelData.text === "" ? "·" : modelData.text
      font.family: host.family
      font.pixelSize: isNow ? Style.font.body + 2 : Style.font.body
      font.bold: isNow
      color: isNow ? host.accentText
           : isPast ? Tui.mix(host.dim, host.bg, 0.3)
           : Tui.mix(host.fg, host.bg, 0.35)
      topPadding: host ? host.ch * 0.22 : 2
      bottomPadding: host ? host.ch * 0.22 : 2
      Behavior on color { ColorAnimation { duration: 180 } }
    }
  }

  // unsynced: just the words
  Flickable {
    visible: !pane.lines.length && pane.plain !== ""
    anchors.fill: parent
    anchors.topMargin: header.height + (host ? host.ch * 2 : 20)
    anchors.bottomMargin: host ? host.ch * 3 : 30
    anchors.leftMargin: host ? host.cw * 3 : 12
    anchors.rightMargin: host ? host.cw * 3 : 12
    contentHeight: body.height
    clip: true
    Text {
      id: body
      width: parent.width
      text: pane.plain
      wrapMode: Text.WordWrap
      font.family: host.family; font.pixelSize: Style.font.body
      color: Tui.mix(host.fg, host.bg, 0.2)
      lineHeight: 1.35
    }
  }

  Text {
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: host ? host.ch : 10
    text: pane.synced ? "[ and ] nudge sync   [\\] reset   [esc] back"
                      : "[esc] back"
    font.family: host.family; font.pixelSize: Style.font.caption
    color: host.dim
  }
}
