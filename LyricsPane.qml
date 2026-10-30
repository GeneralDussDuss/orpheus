import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// Lyrics, following the track, lit word by word.
//
// Providers put <mm:ss.xx> tags inside a line when they know which syllable is
// being sung, and the daemon keeps them, so a line can fill in as it is sung
// rather than switching colour all at once. Tracks without those tags get the
// same treatment from character-weighted timings spread between this line and
// the next, which is close enough that you only notice if you go looking.
//
// Each line also makes an entrance: its words arrive in sequence rather than
// appearing as a block.
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

  // Fetching and timing live in LyricsSource, shared with the stage.
  LyricsSource { id: src; api: pane.api; track: pane.track }
  property alias lines: src.lines
  property alias plain: src.plain
  property alias source: src.source
  property alias synced: src.synced
  property alias loading: src.loading
  property alias instrumental: src.instrumental
  property alias offset: src.offset  // listener's own nudge, seconds

  // An LRC timestamp marks when a line STARTS being sung, so landing exactly on
  // it reads as late: you have not had time to look at the line yet. Karaoke
  // has always run slightly ahead for the same reason.
  readonly property real lead: 0.45

  // The fill front inside a line wants a much smaller head start than the line
  // itself. The line arrives early so you can read it; the words light up as
  // they are sung, and borrowing the line's 0.45 s here ran the fill most of a
  // word ahead of the voice.
  readonly property real fillLead: 0.12

  // ---- position ----------------------------------------------------------

  property real anchorPos: 0       // last position the daemon reported
  property real anchorAt: 0        // ... and the local time we heard it
  readonly property bool playing: st && st.playing === true

  function now() { return Date.now() / 1000 }

  // Re-anchor whenever the daemon's number moves, which also covers seeking.
  onStChanged: {
    var p = (st && st.position) || 0
    if (Math.abs(p - projected()) > 0.2 || !playing) {
      anchorPos = p
      anchorAt = now()
    }
  }

  // Api.qml interpolates position for everything now, so read that rather than
  // keeping a second copy of the same arithmetic here - two extrapolations
  // drifting apart is exactly what made the clocks disagree.
  function projected() {
    if (api) return api.position || 0
    if (!playing) return anchorPos
    return anchorPos + (now() - anchorAt)
  }

  property real clockPos: 0
  Timer {
    interval: 50             // the fill front advances on this tick
    repeat: true
    running: pane.visible
    onTriggered: pane.clockPos = pane.projected()
  }

  readonly property real head: clockPos + lead - offset           // which line
  readonly property real fillHead: clockPos + fillLead - offset   // how far into it

  readonly property int activeLine: lines && lines.length ? src.lineAt(head) : -1

  // ---- words -------------------------------------------------------------

  function tokenize(s) { return src.tokenize(s) }
  function wordSpans(idx) { return src.wordSpans(idx) }

  property var activeWords: []

  // ---- the entrance ------------------------------------------------------
  //
  // 0 wave  - words rise into place, left to right
  // 1 rain  - they fall in out of noise
  // 2 plain - no entrance, just the fill
  property int style: 0
  readonly property var styleNames: ["wave", "rain", "plain"]
  readonly property int stagger: style === 1 ? 50 : 34

  property bool entering: false
  property int shuffle: 0

  Timer { id: settle; onTriggered: pane.entering = false }
  // only the rain style shows unresolved glyphs, so only it needs reshuffling
  Timer { interval: 45; repeat: true; running: pane.entering && pane.style === 1
          onTriggered: pane.shuffle++ }

  onActiveLineChanged: {
    activeWords = activeLine >= 0 ? wordSpans(activeLine) : []
    if (activeLine >= 0) list.positionViewAtIndex(activeLine, ListView.Center)
    if (activeWords.length && style !== 2) {
      entering = true
      settle.interval = 500 + stagger * Math.min(activeWords.length, 12)
      settle.restart()
    } else {
      entering = false
    }
  }

  // ---- keys --------------------------------------------------------------

  Keys.onPressed: function(e) {
    var t = e.text, k = e.key
    // the sync nudge: plenty of community LRC files run a little early or late
    if (t === "[") { offset -= 0.25; e.accepted = true }
    else if (t === "]") { offset += 0.25; e.accepted = true }
    else if (t === "\\") { offset = 0; e.accepted = true }
    // not "v": the player uses that to cycle the visualiser everywhere else,
    // and a page that quietly means something different by a key is worse than
    // no shortcut at all
    else if (t === "m") { style = (style + 1) % 3; e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { list.flick(0, -600); e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { list.flick(0, 600); e.accepted = true }
    else e.accepted = host.handleKey(e)
  }

  MouseArea {
    anchors.fill: parent
    onPressed: function(m) { pane.forceActiveFocus(); m.accepted = false }
  }

  // ---- drawing -----------------------------------------------------------

  // The words are laid out as separate items, so one space of the body font is
  // the gap between them.
  FontMetrics {
    id: fm
    font.family: host ? host.family : "monospace"
    font.pixelSize: Style.font.body
  }
  readonly property real spaceW: fm.advanceWidth(" ")

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
        var wordLevel = pane.lines.length && pane.lines[0].words !== undefined
        return (pane.synced ? (wordLevel ? "synced · word level · " : "synced · ") : "unsynced · ") + via
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
    currentIndex: pane.activeLine
    // positionViewAtIndex sets contentY outright; the Behavior turns that jump
    // into a glide. Using preferredHighlightBegin/End as well would be a second
    // mechanism aiming at the same thing, and the two fight.
    Behavior on contentY { NumberAnimation { duration: 340; easing.type: Easing.OutCubic } }

    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property bool isNow: index === pane.activeLine
      readonly property bool isPast: index < pane.activeLine
      // how far ahead this line is, so the ones coming up sit brighter than the
      // far future and the page has some depth to it
      readonly property int ahead: index - pane.activeLine
      // an empty timed line is an instrumental gap: give it air, not a blank row
      readonly property bool gap: (modelData.text || "") === ""
      readonly property var toks: gap ? [{ text: "· · ·", a: 0, b: 5 }]
                                      : pane.tokenize(modelData.text || "")
      readonly property real pad: host ? host.ch * 0.22 : 2

      width: ListView.view.width
      height: flow.implicitHeight + pad * 2

      Flow {
        id: flow
        y: row.pad
        width: parent.width
        spacing: pane.spaceW

        Repeater {
          model: row.toks.length

          // Font size deliberately does not change with state. The words are
          // separate items, so resizing them reflows the line - and the list
          // under it - on every frame of the animation, which shows up as the
          // whole page breathing. Weight, colour and a small lift carry the
          // emphasis instead.
          delegate: Text {
            id: word
            required property int index

            readonly property string raw: row.toks[index].text
            readonly property var span: row.isNow && pane.activeWords.length > index
                                        ? pane.activeWords[index] : null
            // how much of this word has been sung
            readonly property real fill: span
                ? Math.max(0, Math.min(1, (pane.fillHead - span.t) / Math.max(0.12, span.end - span.t)))
                : 0
            readonly property bool onIt: span !== null && pane.fillHead >= span.t && pane.fillHead < span.end
            readonly property bool live: row.isNow

            property real res: 1       // resolved out of noise, 0..1
            property real rise: 0      // entrance offset, px
            property real fade: 1

            text: res >= 1 ? raw : Tui.decode(raw, res, word.index * 3 + pane.shuffle)
            font.family: host.family
            font.pixelSize: Style.font.body
            font.bold: row.isNow
            font.letterSpacing: onIt ? 0.6 : 0
            color: row.isNow ? Tui.mix(host.accentText, host.bg, 0.52 * (1 - fill))
                 : row.isPast ? Tui.mix(host.dim, host.bg, 0.45)
                 : Tui.mix(host.fg, host.bg, row.ahead <= 2 ? 0.3 : 0.55)
            opacity: (row.isNow ? 1 : (row.isPast ? 0.75 : 0.9)) * fade

            // The fill front moves every 50 ms; smoothing it as well would just
            // make the words light up late. Only the line's own change of state
            // is worth easing.
            Behavior on color { enabled: !row.isNow; ColorAnimation { duration: 200 } }
            Behavior on font.letterSpacing { NumberAnimation { duration: 160 } }

            transform: [
              Translate { y: word.rise },
              Translate { y: word.onIt ? -2 : 0
                Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } } }
            ]

            SequentialAnimation {
              id: entrance
              PauseAnimation { duration: Math.min(word.index, 12) * pane.stagger }
              ParallelAnimation {
                NumberAnimation { target: word; property: "rise"; to: 0; duration: 360
                                  easing.type: pane.style === 1 ? Easing.OutBack : Easing.OutCubic }
                NumberAnimation { target: word; property: "fade"; to: 1; duration: 260 }
                NumberAnimation { target: word; property: "res"; to: 1; duration: 320
                                  easing.type: Easing.OutCubic }
              }
            }

            // an instrumental gap breathes instead of arriving
            SequentialAnimation {
              id: breathe
              running: row.gap && row.isNow
              loops: Animation.Infinite
              NumberAnimation { target: word; property: "fade"; to: 1; duration: 700
                                easing.type: Easing.InOutSine }
              NumberAnimation { target: word; property: "fade"; to: 0.3; duration: 900
                                easing.type: Easing.InOutSine }
            }

            function arrive() {
              entrance.stop()
              if (!row.isNow || row.gap || pane.style === 2) {
                rise = 0; res = 1
                if (!breathe.running) fade = 1
                return
              }
              rise = pane.style === 1 ? -15 : 10
              res = pane.style === 1 ? 0 : 1
              fade = pane.style === 1 ? 0.25 : 0.15
              entrance.restart()
            }

            onLiveChanged: arrive()
            Component.onCompleted: arrive()
          }
        }
      }
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
    textFormat: Text.StyledText
    text: pane.synced
          ? Tui.hints([["[ ]", "nudge sync"], ["\\", "reset"],
                       ["m", pane.styleNames[pane.style]], ["esc", "back"]],
                      host.accent, host.dim)
          : Tui.hints([["esc", "back"]], host.accent, host.dim)
    font.family: host.family; font.pixelSize: Style.font.caption
    color: host.dim
  }
}
