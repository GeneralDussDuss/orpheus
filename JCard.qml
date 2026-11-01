import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui
import "Cassette.js" as Deck

// The cassette deck's j-card: the queue as a tape, SIDE A over SIDE B, the
// playing row lit, a click on any row plays it.
//
//   ┌──┬──────────────────────────────────┐
//   │  │ ╱╱ late night drive · tape 1/3    │
//   │ m│ SIDE A                            │
//   │ i│  1  song  · artist           3:12 │
//   │ x│  ▸  song  · artist           4:01 │
//   │  │ SIDE B                            │
//   │╱╱│  4  song  · artist           2:58 │
//   │  │ side a · 3 tracks · 10:11 ╱╱ ...  │
//   └──┴──────────────────────────────────┘
//
// A "tape" is a page of the play order as many rows as fit on both sides
// (Cassette.js page()); the sides split it evenly. It fetches GET /queue only
// when the daemon's queueRev or the page changes, never on the status poll
// itself. Under anyone else's player (or offline) it is one block: what is
// playing, and no tracklist.
Item {
  id: card

  property var engine: null
  property var deck: null
  property real unit: 10

  readonly property color bg: deck ? deck.bg : "black"
  readonly property color fg: deck ? deck.fg : "white"
  readonly property color dim: deck ? deck.dim : "gray"
  readonly property color accent: deck ? deck.accent : "white"
  readonly property color accentText: deck ? deck.accentText : "white"
  readonly property color line: deck ? deck.line : "gray"
  readonly property string family: Style.font.family
  readonly property real capPx: Math.max(Style.font.caption, Math.round(unit * 0.42))
  readonly property real headPx: Math.max(Style.font.body, Math.round(unit * 0.52))
  FontMetrics { id: capM; font.family: card.family; font.pixelSize: card.capPx }
  FontMetrics { id: headM; font.family: card.family; font.pixelSize: card.headPx; font.bold: true }
  readonly property real cw: capM.advanceWidth("M")
  readonly property real rowH: Math.round(capM.height * 1.3)
  readonly property real pad: Math.round(cw * 1.2)

  // ---- what to list ---------------------------------------------------------------
  readonly property var st: deck ? deck.st : null
  readonly property bool ours: !!deck && deck.ours
  readonly property bool online: !!engine && !!engine.api && engine.api.online === true
  readonly property int rows: Math.max(1, Math.min(12, Math.floor((height - 4 * headM.height - 3 * capM.height) / rowH / 2)))
  readonly property var pg: Deck.page(st ? (st.queueIndex || 0) : 0, rows, st ? (st.queueLength || 0) : 0)
  readonly property string wantKey: (ours && online ? "o" : "x") + ":" + (st ? (st.queueRev || "") : "") + ":" + pg.first + ":" + (rows * 2)
  property var shown: null              // { first, split, pages, page, tracks, context } of the last answer
  property int fetches: 0               // for tests: how many times the queue was asked for
  onWantKeyChanged: fetchWait.restart()
  Component.onCompleted: fetchWait.restart()
  Timer {
    id: fetchWait
    interval: 150
    onTriggered: card.fetch()
  }
  function fetch() {
    if (!ours || !online || typeof engine.api.queue !== "function") { shown = null; return }
    var want = pg, n = rows * 2
    fetches++
    engine.api.queue(want.first, n, function(ok, d) {
      if (!ok || !d || !Array.isArray(d.tracks)) { card.shown = null; return }
      var p = Deck.page(d.index || 0, card.rows, d.length || 0)
      card.shown = { first: d.from || 0, split: Math.ceil(d.tracks.length / 2), pages: p.pages, page: Math.floor((d.from || 0) / Math.max(2, n)),
                     tracks: d.tracks, context: d.context || {} }
    })
  }
  readonly property bool listed: ours && online && !!shown && shown.tracks.length > 0
  readonly property var sideA: listed ? shown.tracks.slice(0, shown.split) : []
  readonly property var sideB: listed ? shown.tracks.slice(shown.split) : []
  readonly property int playingAt: st ? (st.queueIndex === undefined ? -1 : st.queueIndex) : -1
  readonly property string side: listed && playingAt >= shown.first && playingAt < shown.first + shown.tracks.length
                                 ? (playingAt - shown.first < shown.split ? "a" : "b") : "a"
  readonly property string tapeName: deck ? deck.tapeName : ""

  // Rows come in one after another when the deck powers on.
  property real intro: 1e6
  function stagger() { introAnim.restart() }
  NumberAnimation { id: introAnim; target: card; property: "intro"; from: 0; to: 220 + 14 * 24; duration: 220 + 14 * 24 }
  function rowIn(i) { return Math.max(0, Math.min(1, (intro - 14 * Math.min(i, 24)) / 220)) }

  // ---- the paper ------------------------------------------------------------------
  Rectangle {
    anchors.fill: parent
    color: Tui.alpha(Tui.mix(card.bg, card.fg, 0.03), card.deck && card.deck.glassy ? 0.5 : 0.9)
    border.width: 1
    border.color: card.line
    Rectangle {
      anchors.fill: parent
      anchors.margins: 3
      color: "transparent"
      border.width: 1
      border.color: Tui.alpha(card.line, 0.5)
    }
  }

  // The spine: the tape's name up the left edge.
  Item {
    id: spine
    x: 3; y: 3
    width: Math.round(card.cw * 3)
    height: card.height - 6
    Text {
      anchors.centerIn: parent
      width: parent.height - card.pad * 2
      height: parent.width
      rotation: -90
      verticalAlignment: Text.AlignVCenter
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: "╱╱  " + (card.deck && card.deck.hasTape ? card.tapeName : "no tape")
      font.family: card.family; font.pixelSize: card.capPx; font.bold: true
      font.letterSpacing: 2
      color: card.accentText
    }
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Tui.alpha(card.line, 0.5) }
  }

  Item {
    id: page
    x: spine.x + spine.width + card.pad
    y: card.pad * 0.8
    width: card.width - x - card.pad
    height: card.height - y - card.pad * 0.8

    // ---- no tape: nothing playing at all ----
    Column {
      visible: !!card.deck && !card.deck.hasTape
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      spacing: capM.height * 0.4
      Text {
        width: parent.width
        textFormat: Text.StyledText
        text: '<font color="' + Tui.hex(card.accentText) + '">╱╱</font> no tape'
        font.family: card.family; font.pixelSize: card.headPx; font.bold: true
        color: card.fg
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        text: "pick something in the player" + (card.libraryKey ? " · " + card.libraryKey : "")
        font.family: card.family; font.pixelSize: card.capPx
        color: card.dim
      }
    }

    // ---- someone else's player, or no answer: what is playing, no list ----
    Column {
      visible: !!card.deck && card.deck.hasTape && !card.listed
      width: parent.width
      spacing: capM.height * 0.3
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.StyledText
        text: '<font color="' + Tui.hex(card.accentText) + '">╱╱</font> ' + Tui.esc(card.tapeName)
        font.family: card.family; font.pixelSize: card.headPx; font.bold: true
        color: card.fg
      }
      Item { width: 1; height: capM.height * 0.4 }
      Repeater {
        model: card.deck ? [card.deck.title, card.deck.artist,
                            card.deck.player && !card.ours ? (card.deck.player.trackAlbum || "") : ""] : []
        Text {
          required property var modelData
          required property int index
          visible: !!modelData
          width: page.width
          elide: Text.ElideRight
          text: modelData
          font.family: card.family; font.pixelSize: card.capPx; font.bold: index === 0
          color: index === 0 ? card.fg : card.dim
        }
      }
      Item { width: 1; height: capM.height * 0.4 }
      Text {
        text: "no tracklist"
        font.family: card.family; font.pixelSize: card.capPx
        color: card.dim
      }
    }

    // ---- the tracklist ----
    Column {
      id: list
      visible: card.listed
      width: parent.width
      spacing: 0
      Text {
        width: parent.width
        height: headM.height * 1.3
        elide: Text.ElideRight
        textFormat: Text.StyledText
        text: '<font color="' + Tui.hex(card.accentText) + '">╱╱</font> ' + Tui.esc(card.tapeName)
              + (card.listed && card.shown.pages > 1 ? '<font color="' + Tui.hex(card.dim) + '"> · tape '
                 + (card.shown.page + 1) + "/" + card.shown.pages + '</font>' : "")
        font.family: card.family; font.pixelSize: card.headPx; font.bold: true
        color: card.fg
      }
      SideHead { label: "SIDE A"; lit: card.side === "a" }
      Repeater { model: card.sideA; Row_ {} }
      Item { width: 1; height: capM.height * 0.35 }
      SideHead { label: "SIDE B"; lit: card.side === "b"; visible: card.sideB.length > 0 }
      Repeater { model: card.sideB; Row_ {} }
    }

    Text {
      visible: card.listed
      anchors.bottom: parent.bottom
      width: parent.width
      elide: Text.ElideRight
      textFormat: Text.StyledText
      function sideText(n, list) { return "side " + n + " · " + list.length + (list.length === 1 ? " track · " : " tracks · ") + Deck.clock(Deck.sideTime(list)) }
      text: Tui.esc(sideText("a", card.sideA))
            + (card.sideB.length ? ' <font color="' + Tui.hex(card.accentText) + '">╱╱</font> ' + Tui.esc(sideText("b", card.sideB)) : "")
      font.family: card.family; font.pixelSize: card.capPx
      color: card.dim
    }
  }

  // The player window's global key (on Windows as the hotkeys actually bound it).
  readonly property string libraryKey: {
    if (typeof OrpheusKeys === "undefined") return "super+shift+m"
    var b = OrpheusKeys.bindings || []
    for (var i = 0; i < b.length; i++) if (b[i].action === "library" && b[i].combo) return String(b[i].combo).toLowerCase()
    return ""
  }

  component SideHead: Text {
    property string label: ""
    property bool lit: false
    height: headM.height * 1.25
    verticalAlignment: Text.AlignBottom
    text: label
    font.family: card.family; font.pixelSize: card.headPx; font.bold: true
    font.letterSpacing: card.cw * 0.15
    color: lit ? card.accentText : Tui.mix(card.dim, card.accentText, 0.35)
    Behavior on color { ColorAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
  }

  component Row_: Item {
    id: row
    required property var modelData
    readonly property int i: modelData.i
    readonly property bool now: i === card.playingAt
    readonly property bool past: i < card.playingAt
    readonly property real beat: card.engine && card.engine.pulseUi && card.deck && card.deck.playing
                                 ? Math.max(0, Math.min(1, card.engine.beat || 0)) : 0
    width: page.width
    height: card.rowH
    opacity: card.rowIn(i - (card.shown ? card.shown.first : 0))
    transform: Translate { x: (1 - row.opacity) * card.cw * 1.5 }
    Rectangle {
      x: -card.cw * 0.5
      width: parent.width + card.cw * 0.5
      height: parent.height
      color: row.now ? Tui.alpha(card.accent, 0.16) : rm.containsMouse ? Tui.alpha(card.fg, 0.07) : "transparent"
      Behavior on color { ColorAnimation { duration: Tui.HOVER } }
    }
    readonly property color ink: now ? card.accentText : past ? card.dim : Tui.mix(card.dim, card.fg, 0.45)
    Text {
      id: num
      width: card.cw * 3
      anchors.verticalCenter: parent.verticalCenter
      text: row.now ? " ▸" : Deck.lpad(row.i + 1, 2)
      font.family: card.family; font.pixelSize: card.capPx; font.bold: row.now
      color: row.now ? Tui.mix(card.accentText, card.fg, row.beat * 0.4) : row.ink
    }
    Text {
      anchors.left: num.right
      anchors.right: dur.left
      anchors.rightMargin: card.cw
      anchors.verticalCenter: parent.verticalCenter
      elide: Text.ElideRight
      textFormat: Text.StyledText
      text: (row.modelData.radio ? '<font color="' + Tui.hex(card.accent) + '">∞</font> ' : "")
            + Tui.esc(row.modelData.title || "") + "  · "
            + Tui.esc(Array.isArray(row.modelData.artists) ? row.modelData.artists.join(", ") : (row.modelData.artists || ""))
      font.family: card.family; font.pixelSize: card.capPx; font.bold: row.now
      color: rm.containsMouse && !row.now ? card.fg : row.ink
    }
    Text {
      id: dur
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: Deck.clock(row.modelData.duration)
      font.family: card.family; font.pixelSize: card.capPx
      color: card.dim
    }
    MouseArea {
      id: rm
      anchors.fill: parent
      enabled: card.ours
      hoverEnabled: true
      cursorShape: card.deck && card.deck.cursorHidden ? Qt.BlankCursor : Qt.PointingHandCursor
      onPositionChanged: if (card.deck) card.deck.moved()
      onClicked: { if (card.deck) card.deck.moved(); if (!row.now) card.engine.api.control("jump", { index: row.i }) }
      TuiTip { text: row.now ? "playing" : "play this now"; delay: 700 }
    }
  }
}
