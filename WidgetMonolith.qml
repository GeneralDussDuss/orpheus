import QtQuick
import QtQuick.Window
import QtQuick.Effects
import qs.Commons
import "Tui.js" as Tui

// The vertical widget -- "Monolith" (or-1). One solid block of bead-blasted
// aluminium, anodised in the theme: a deep tone pulled toward the accent on a
// dark theme, pale silver with an accent tint on a light one. Top to bottom:
// an engraved header with the tempo and section and a status LED that
// breathes with the beat; a dot-matrix visualizer behind smoked glass; the art
// in a recessed well beside the title and a backlit display strip; a machined
// seek slot with a sliding puck; soft-touch rubber keys; a speaker grille when
// the window is tall; and a knurled wheel on the right edge (roll it to seek).
//
// The block, its openings and the grille are one static shader, layer-cached:
// it redraws on a resize or a theme change only. Per frame, and only while the
// music runs and the window is on screen, three small things move: the
// visualizer, the status LED and the play key's LED ring. The seek puck moves
// once a second. Everything else is still.
//
// Scale: the deck is drawn at `s` x a 400 px design. In a window it scales up
// with the window (a big window is a bigger device) and down for a short one
// (nothing overlaps); spare height goes first to the visualizer, then to the
// grille. In the corner the width sets the scale and the deck its own height.
Item {
  id: deck

  property var engine: null
  property bool full: true           // unused here; Widget.qml sets it on every body
  property bool fill: false
  property bool keys: false

  DeckCore { id: core; engine: deck.engine; keys: deck.keys }
  // the harness (and anything else) can drive a scrub from outside
  property alias scrubbing: core.scrubbing
  property alias scrubFrac: core.scrubFrac

  focus: keys
  Keys.onPressed: function(e) { core.key(e) }

  // ---- motion gates --------------------------------------------------------
  // `feed`: the visualizer takes new bands (paused: they fall, then hold).
  // `anim`: the lights pulse with the beat.
  readonly property bool feed: core.live && !core.gameMode
  readonly property bool anim: core.live && core.playing && !core.gameMode
  readonly property real pulse: anim ? core.beat : 0

  // Fade up whenever the window shows.
  property real appear: 0
  opacity: appear
  NumberAnimation on appear { id: appearAnim; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.InOutCubic }
  Connections {
    target: deck.Window.window
    function onVisibleChanged() { if (deck.Window.window && deck.Window.window.visible) appearAnim.restart() }
  }

  // ---- materials, all from the theme ----------------------------------------
  readonly property bool light: core.light
  readonly property color black: Qt.rgba(0, 0, 0, 1)
  readonly property color white: Qt.rgba(1, 1, 1, 1)
  // the anodised tone
  readonly property color metal: light
      ? Tui.mix(Tui.mix(core.bg, core.fg, 0.13), core.accent, 0.10)
      : Tui.mix(Tui.mix(core.bg, core.accent, 0.30), core.fg, 0.05)
  // printed ink on the face (the title), and its quieter twin
  readonly property color ink: Tui.ensure(light ? core.fg : Tui.mix(core.fg, white, 0.2), metal, 7)
  readonly property color inkDim: Tui.ensure(Tui.mix(ink, metal, 0.38), metal, 3.6)
  // laser etching: anodising burnt back to bare metal (pale on dark, grey on silver)
  readonly property color etch: light ? Tui.ensure(Tui.mix(metal, core.fg, 0.62), metal, 4.5)
                                      : Tui.ensure(Tui.mix(metal, white, 0.52), metal, 3.6)
  readonly property color etchHi: light ? Tui.alpha(white, 0.75) : Tui.alpha(white, 0.10)
  // the soft-touch rubber
  readonly property color rubber: light ? Tui.mix(Tui.mix(core.bg, core.fg, 0.30), core.accent, 0.04)
                                        : Tui.mix(Tui.mix(core.bg, metal, 0.55), black, 0.18)
  readonly property color legend: light ? Tui.ensure(Tui.mix(core.fg, rubber, 0.1), rubber, 5)
                                        : Tui.ensure(Tui.mix(core.fg, rubber, 0.18), rubber, 6)
  readonly property color playRubber: core.accent
  readonly property color playLegend: Tui.ensure(Tui.mix(core.bg, black, light ? 0 : 0.3), core.accent, 4.5)
  readonly property color ringLight: Tui.mix(core.accent, white, 0.72)
  // the smoked glass and the emitters behind it
  readonly property color glass: Tui.mix(black, light ? core.fg : core.bg, 0.22)
  readonly property color peakTint: Tui.mix(core.accent, core.fg, 0.55)
  // the display strip: negative and glowing on dark, a positive backlit LCD on light
  readonly property color lcdBg: light ? Tui.mix(Tui.mix(core.bg, core.accent, 0.20), core.fg, 0.04)
                                       : Tui.mix(black, core.accent, 0.10)
  readonly property color lcdInk: light ? Tui.ensure(Tui.mix(core.fg, core.accent, 0.25), lcdBg, 6)
                                        : Tui.mix(core.accent, white, 0.30)
  readonly property color lcdDim: light ? Tui.mix(lcdInk, lcdBg, 0.45) : Tui.mix(lcdInk, lcdBg, 0.55)

  // ---- layout -----------------------------------------------------------------
  // The design, at s = 1 (400 px wide). Margins round the block leave room for
  // the wheel standing proud on the right and the shadow underneath.
  readonly property real mL: 3
  readonly property real mR: 9
  readonly property real mT: 3
  readonly property real mB: 20
  readonly property real pad: 18
  readonly property real headD: 18
  readonly property real seekD: 18
  readonly property real keyD: 52
  readonly property real legD: keys ? 17 : 0
  readonly property real gHead: 12
  readonly property real gViz: 15
  readonly property real gArt: 18
  readonly property real gSeek: 15
  readonly property real innerD: 400 - mL - mR - 2 * pad          // 352
  readonly property real artD: Math.round(innerD * 0.42)          // 148
  readonly property real fixedD: mT + pad + headD + gHead + gViz + artD + gArt + seekD + gSeek + keyD + legD + pad + mB
  readonly property real vizMinD: 96

  readonly property real s: fill ? Math.max(0.6, Math.min(2.4, Math.min(width / 400, height / (fixedD + vizMinD))))
                                 : Math.max(0.6, width / 400)
  readonly property real innerW: Math.max(0, width - (mL + mR + 2 * pad) * s)
  readonly property real art: Math.round(artD * s)
  readonly property real spare: fill ? height - fixedD * s : 0
  readonly property real vizMax: Math.round(innerW * 0.64)
  // in a tall window the visualizer stops growing and a grille takes the rest
  readonly property real grilleH: fill && spare - vizMax >= 40 * s ? Math.floor(spare - vizMax - 12 * s) : 0
  readonly property real vizH: Math.round(fill ? (grilleH > 0 ? vizMax : Math.max(vizMinD * s * 0.6, spare)) : innerW * 0.46)
  implicitHeight: Math.round(fixedD * s + vizH)

  readonly property real lip: 1.8 * s
  // in the corner the deck draws at its own height, whatever it is given
  readonly property real deckH: fill ? height : implicitHeight
  readonly property rect body: Qt.rect(mL * s, mT * s, width - (mL + mR) * s, deckH - (mT + mB) * s)
  readonly property real x0: body.x + pad * s
  readonly property real yHead: body.y + pad * s - 3 * s
  readonly property real yViz: body.y + (pad + headD + gHead) * s
  readonly property real yArt: yViz + vizH + gViz * s
  readonly property real ySeek: yArt + art + gArt * s
  readonly property real yKeys: ySeek + (seekD + gSeek) * s
  readonly property real yGrille: yKeys + (keyD + legD + 12) * s

  readonly property rect rViz: Qt.rect(x0, yViz, innerW, vizH)
  readonly property rect rArt: Qt.rect(x0, yArt, art, art)
  readonly property real colX: x0 + art + 15 * s
  readonly property real colW: Math.max(0, x0 + innerW - colX)
  readonly property real lcdH: Math.round(42 * s)
  readonly property rect rLcd: Qt.rect(colX, yArt + art - lcdH, colW, lcdH)
  readonly property rect rSlot: Qt.rect(x0 + 13 * s, ySeek + (seekD * 0.5 - 3) * s, innerW - 26 * s, 6 * s)
  // keys: a small round key each end, three big ones between
  readonly property real smallD: Math.round(40 * s)
  readonly property real keyGap: Math.round(11 * s)
  readonly property real bigW: Math.floor((innerW - 2 * smallD - 4 * keyGap) / 3)
  readonly property real bigH: Math.round(keyD * s)
  readonly property real bigR: Math.round(11 * s)
  readonly property real holeGap: Math.max(1.5, 2.2 * s)
  function keyRect(i) {
    var xs = [x0, x0 + smallD + keyGap, x0 + smallD + keyGap + bigW + keyGap,
              x0 + smallD + keyGap + 2 * (bigW + keyGap), x0 + innerW - smallD]
    var small = i === 0 || i === 4
    var w = small ? smallD : bigW, h = small ? smallD : bigH
    return Qt.rect(Math.round(xs[i]), Math.round(yKeys + (bigH - h) / 2), w, h)
  }
  function grow(r, g) { return Qt.rect(r.x - g, r.y - g, r.width + 2 * g, r.height + 2 * g) }
  // the wheel stands proud of the right edge, beside the art row
  readonly property real wheelW: Math.round(11 * s)
  readonly property real wheelH: Math.round(Math.min(art * 0.72, 96 * s))
  readonly property rect rWheel: Qt.rect(body.x + body.width - 5.5 * s, yArt + (art - wheelH) / 2, wheelW, wheelH)
  readonly property real ledR: 3.3 * s

  // ---- the block -----------------------------------------------------------------
  ShaderEffect {
    id: block
    anchors.fill: parent
    layer.enabled: true
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property color metal: deck.metal
    property color accent: core.accent
    property rect rBody: deck.body
    property rect rViz: deck.rViz
    property rect rArt: deck.rArt
    property rect rLcd: deck.rLcd
    property rect rSeek: deck.rSlot
    property rect rK0: deck.grow(deck.keyRect(0), deck.holeGap)
    property rect rK1: deck.grow(deck.keyRect(1), deck.holeGap)
    property rect rK2: deck.grow(deck.keyRect(2), deck.holeGap)
    property rect rK3: deck.grow(deck.keyRect(3), deck.holeGap)
    property rect rK4: deck.grow(deck.keyRect(4), deck.holeGap)
    property rect rWheel: Qt.rect(deck.rWheel.x - 2.5 * deck.s, deck.rWheel.y - 3 * deck.s, deck.wheelW + 12 * deck.s, deck.wheelH + 6 * deck.s)
    property rect rLed: Qt.rect(led.x + led.width / 2 - deck.ledR - 1.4 * deck.s, led.y + led.height / 2 - deck.ledR - 1.4 * deck.s,
                                2 * (deck.ledR + 1.4 * deck.s), 2 * (deck.ledR + 1.4 * deck.s))
    property rect rGrille: deck.grilleH > 0 ? Qt.rect(deck.x0 + 4 * deck.s, deck.yGrille, deck.innerW - 8 * deck.s, deck.grilleH) : Qt.rect(0, 0, 0, 0)
    property vector4d radA: Qt.vector4d(15 * deck.s, 7 * deck.s, 7 * deck.s, 5 * deck.s)
    property vector4d radB: Qt.vector4d(3 * deck.s, deck.bigR + deck.holeGap, deck.smallD / 2 + deck.holeGap, 3 * deck.s)
    fragmentShader: Qt.resolvedUrl("shaders/monolith_body.frag.qsb")
  }

  // ---- text on the metal ------------------------------------------------------
  // Laser etched: the mark sits a hair below the face, so its lower edge
  // catches the light.
  component Etch: Item {
    id: et
    property alias text: etT.text
    property real size: 10
    property bool bold: false
    property real spacing: 0
    property color ink: deck.etch
    implicitWidth: etT.implicitWidth
    implicitHeight: etT.implicitHeight
    width: implicitWidth; height: implicitHeight
    Text {
      x: 0; y: Math.max(1, Math.round(deck.s * 0.8))
      text: etT.text; font: etT.font; color: deck.etchHi
    }
    Text {
      id: etT
      font.family: core.fontFamily; font.pixelSize: Math.max(7, Math.round(et.size)); font.bold: et.bold
      font.letterSpacing: et.spacing
      color: et.ink
    }
  }

  // 1. The header: the name, etched; the tempo and section; the LED.
  Item {
    id: header
    x: deck.x0; y: deck.yHead
    width: deck.innerW; height: deck.headD * deck.s
    Row {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Math.round(5 * deck.s)
      Etch { anchors.verticalCenter: parent.verticalCenter; text: "orpheus"; size: 12.5 * deck.s; bold: true; spacing: 0.3 * deck.s; ink: Tui.mix(deck.etch, deck.ink, 0.35) }
      Etch { anchors.verticalCenter: parent.verticalCenter; text: "· or-1"; size: 10.5 * deck.s; spacing: 1.0 * deck.s }
    }
    Row {
      id: headRight
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      spacing: Math.round(5 * deck.s)
      Etch {
        anchors.verticalCenter: parent.verticalCenter
        visible: core.tempoOk
        text: core.tempoOk ? Math.round(core.engine.tempo) + " bpm" : ""
        size: 10 * deck.s; spacing: 1.2 * deck.s
      }
      Etch {
        anchors.verticalCenter: parent.verticalCenter
        visible: core.tempoOk && core.sectionOk
        text: "·"
        size: 10 * deck.s
      }
      Etch {
        anchors.verticalCenter: parent.verticalCenter
        visible: core.sectionOk
        text: core.sectionOk ? String(core.engine.section).toLowerCase() : ""
        size: 10 * deck.s; spacing: 1.2 * deck.s
        ink: Tui.mix(deck.etch, core.accent, core.secFlash)
      }
      Item {
        id: ledSlot
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(deck.ledR * 2 + 8 * deck.s); height: width
      }
      Text {
        id: closeMark
        anchors.verticalCenter: parent.verticalCenter
        text: "✕"
        font.family: core.fontFamily; font.pixelSize: Math.round(10 * deck.s)
        color: closeMouse.containsMouse ? core.accent : Tui.mix(deck.etch, deck.metal, 0.35)
        MouseArea {
          id: closeMouse
          anchors.fill: parent; anchors.margins: -4
          hoverEnabled: true; cursorShape: Qt.PointingHandCursor
          onClicked: if (deck.engine) deck.engine.setWidget("enabled", "off")
          TuiTip { text: "close the widget" }
        }
      }
    }
  }

  // The status LED: breathes with the beat while playing, dark when paused.
  ShaderEffect {
    id: led
    readonly property real padPx: Math.round(10 * deck.s)
    x: Math.round(header.x + headRight.x + ledSlot.x + ledSlot.width / 2 - width / 2)
    y: Math.round(header.y + headRight.y + ledSlot.y + ledSlot.height / 2 - height / 2)
    width: Math.round(deck.ledR * 2 + 2 * padPx); height: width
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property real bloomAmt: core.bloom
    property real lens: deck.ledR
    property real on: core.playing ? 1 : 0
    Behavior on on { NumberAnimation { duration: Tui.PAGE; easing.type: Easing.OutCubic } }
    property real level: on * (0.55 + 0.45 * deck.pulse)
    property color accent: core.accent
    property color metal: deck.metal
    fragmentShader: Qt.resolvedUrl("shaders/monolith_led.frag.qsb")
  }

  // 2. The visualizer: a dot matrix behind smoked glass.
  ShaderEffect {
    id: viz
    x: deck.rViz.x + deck.lip; y: deck.rViz.y + deck.lip
    width: deck.rViz.width - 2 * deck.lip; height: deck.rViz.height - 2 * deck.lip
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property real bloomAmt: core.bloom
    property real beat: deck.pulse
    property real energy: deck.feed ? core.energy : 0
    property real rad: 5.5 * deck.s
    property color lit: core.accent
    property color peak: deck.peakTint
    property color glass: deck.glass
    property vector4d b0; property vector4d b1; property vector4d b2; property vector4d b3
    property vector4d b4; property vector4d b5; property vector4d b6; property vector4d b7
    property vector4d p0; property vector4d p1; property vector4d p2; property vector4d p3
    property vector4d p4; property vector4d p5; property vector4d p6; property vector4d p7
    fragmentShader: Qt.resolvedUrl("shaders/monolith_viz.frag.qsb")
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: core.act("stage")
      TuiTip { text: "open the big visualizer"; key: deck.keys ? core.keyLabels.stage : ""; delay: 900 }
    }
  }
  // The bands go in only while the deck is fed; otherwise the last frame holds.
  readonly property vector4d zero4: Qt.vector4d(0, 0, 0, 0)
  Binding { target: viz; property: "b0"; value: deck.engine ? deck.engine.b0 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b1"; value: deck.engine ? deck.engine.b1 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b2"; value: deck.engine ? deck.engine.b2 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b3"; value: deck.engine ? deck.engine.b3 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b4"; value: deck.engine ? deck.engine.b4 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b5"; value: deck.engine ? deck.engine.b5 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b6"; value: deck.engine ? deck.engine.b6 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "b7"; value: deck.engine ? deck.engine.b7 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p0"; value: deck.engine ? deck.engine.p0 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p1"; value: deck.engine ? deck.engine.p1 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p2"; value: deck.engine ? deck.engine.p2 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p3"; value: deck.engine ? deck.engine.p3 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p4"; value: deck.engine ? deck.engine.p4 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p5"; value: deck.engine ? deck.engine.p5 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p6"; value: deck.engine ? deck.engine.p6 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }
  Binding { target: viz; property: "p7"; value: deck.engine ? deck.engine.p7 : deck.zero4; when: deck.feed; restoreMode: Binding.RestoreNone }

  // 3. The art, in its well under glass. Two layers trade roles: a new cover
  // loads into the hidden one and fades in only once it is Ready; the old one
  // is then emptied. No art (or a failed load) fades both out to the floor.
  component ArtLayer: Image {
    property bool shown: false
    property bool pending: false
    property real w: shown ? 1 : 0
    Behavior on w { NumberAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
    visible: false
    fillMode: Image.PreserveAspectCrop; asynchronous: true
    width: artFx.width; height: artFx.height
    sourceSize: Qt.size(Math.round(artFx.width * 2), Math.round(artFx.height * 2))
    onStatusChanged: artFx.layerStatus(this)
  }
  ArtLayer { id: layerA }
  ArtLayer { id: layerB }
  ShaderEffect {
    id: artFx
    x: deck.rArt.x + deck.lip; y: deck.rArt.y + deck.lip
    width: deck.rArt.width - 2 * deck.lip; height: width
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property real rad: 5.5 * deck.s
    property real wA: layerA.w
    property real wB: layerB.w
    property var srcA: layerA
    property var srcB: layerB
    property color metal: deck.metal
    property color accent: core.accent
    fragmentShader: Qt.resolvedUrl("shaders/monolith_art.frag.qsb")

    property Item front: layerA
    property bool hasArt: false
    readonly property string url: core.artUrl
    onUrlChanged: show(url)
    Component.onCompleted: show(url)
    function show(u) {
      if (u === "") { clear(); return }
      var h = front === layerA ? layerB : layerA
      h.pending = true
      h.source = u
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
        o.shown = false
        l.shown = true
        front = l
        hasArt = true
        wipe.restart()
      } else if (l.status === Image.Error) {
        clear()
      }
    }
    Timer {
      id: wipe
      interval: Tui.STATE + 40
      onTriggered: {
        var ls = [layerA, layerB]
        for (var i = 0; i < 2; i++)
          if (!ls[i].pending && (ls[i] !== artFx.front || !artFx.hasArt)) { ls[i].shown = false; ls[i].source = "" }
      }
    }
    MouseArea {
      anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: if (deck.engine) deck.engine.libraryOpen = true
      TuiTip { text: "open the player" }
    }
  }

  // The track: the title printed large, the artist small and spaced.
  Item {
    id: meta
    x: deck.colX; y: deck.yArt + Math.round(1 * deck.s)
    width: deck.colW; height: deck.rLcd.y - y - 6 * deck.s
    property real swap: 1
    NumberAnimation on swap { id: swapAnim; running: false; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.OutCubic }
    Connections { target: core; function onTrackKeyChanged() { swapAnim.restart() } }
    Column {
      x: (1 - meta.swap) * 6 * deck.s
      width: parent.width
      opacity: 0.25 + 0.75 * meta.swap
      spacing: Math.round(5 * deck.s)
      ScrambleText {
        id: titleTxt
        width: parent.width
        elide: Text.ElideRight; wrapMode: Text.Wrap; maximumLineCount: 2
        textFormat: Text.PlainText
        lineHeight: 0.96
        animate: core.titleFx; key: core.trackKey
        target: core.player ? (core.title || "unknown track") : "nothing playing"
        font.family: core.fontFamily; font.pixelSize: Math.round(18 * deck.s); font.bold: true
        font.letterSpacing: -0.2 * deck.s
        color: deck.ink
      }
      ScrambleText {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.PlainText
        animate: core.titleFx; key: core.trackKey; duration: Tui.DECODE
        target: core.player ? core.artist : "pick something in the player"
        font.family: core.fontFamily; font.pixelSize: Math.round(9.5 * deck.s)
        font.capitalization: Font.AllUppercase; font.letterSpacing: 2.2 * deck.s
        color: deck.inkDim
      }
      Text {
        visible: core.album !== "" && meta.height - titleTxt.height - 30 * deck.s > 0
        width: parent.width
        elide: Text.ElideRight
        text: core.album
        font.family: core.fontFamily; font.pixelSize: Math.round(9.5 * deck.s); font.italic: true
        color: Tui.mix(deck.inkDim, deck.metal, 0.3)
      }
    }
  }

  // The display strip: backlit, monochrome; elapsed and remaining, the
  // stream's quality and the transport state.
  Item {
    id: lcd
    x: deck.rLcd.x + deck.lip; y: deck.rLcd.y + deck.lip
    width: deck.rLcd.width - 2 * deck.lip; height: deck.rLcd.height - 2 * deck.lip
    clip: true
    // the backlight: brightest in the middle, falling to the ends
    Rectangle {
      anchors.fill: parent
      radius: 3.5 * deck.s
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: Tui.mix(deck.lcdBg, deck.black, deck.light ? 0.08 : 0.35) }
        GradientStop { position: 0.5; color: deck.lcdBg }
        GradientStop { position: 1; color: Tui.mix(deck.lcdBg, deck.black, deck.light ? 0.08 : 0.35) }
      }
    }
    Item {
      id: lcdText
      anchors.fill: parent
      anchors.leftMargin: Math.round(7 * deck.s); anchors.rightMargin: Math.round(7 * deck.s)
      layer.enabled: !deck.light && core.bloom > 0
      layer.effect: MultiEffect {
        autoPaddingEnabled: true
        shadowEnabled: true
        shadowColor: deck.lcdInk
        shadowOpacity: 0.55 * core.bloom
        shadowBlur: 0.6
        blurMax: 12
        shadowHorizontalOffset: 0; shadowVerticalOffset: 0
      }
      Text {
        id: lcdTime
        anchors { left: parent.left; top: parent.top; topMargin: Math.round(4 * deck.s) }
        text: core.clock2(core.shownPos)
        font.family: core.fontFamily; font.pixelSize: Math.round(16 * deck.s); font.bold: true
        font.features: { "tnum": 1 }
        color: deck.lcdInk
      }
      Text {
        anchors { right: parent.right; baseline: lcdTime.baseline }
        text: core.length > 0 ? "−" + core.clock2(core.length - core.shownPos) : "−−:−−"
        font.family: core.fontFamily; font.pixelSize: Math.round(11 * deck.s)
        font.features: { "tnum": 1 }
        color: deck.lcdDim
      }
      Text {
        anchors { left: parent.left; bottom: parent.bottom; bottomMargin: Math.round(3 * deck.s) }
        width: parent.width * 0.75
        elide: Text.ElideRight
        text: core.qualityLabel !== "" ? core.qualityLabel.toLowerCase() : "──── ─────"
        font.family: core.fontFamily; font.pixelSize: Math.round(8.5 * deck.s); font.letterSpacing: 1.2 * deck.s
        color: core.qualityLabel !== "" ? deck.lcdInk : deck.lcdDim
      }
      Text {
        anchors { right: parent.right; bottom: parent.bottom; bottomMargin: Math.round(3 * deck.s) }
        text: core.playing ? "▶" : "❚❚"
        font.family: core.fontFamily; font.pixelSize: Math.round(8 * deck.s)
        color: core.playing ? deck.lcdInk : deck.lcdDim
      }
    }
    // the glass over it: a soft sheen across the top half
    Rectangle {
      anchors.fill: parent
      radius: 3.5 * deck.s
      gradient: Gradient {
        GradientStop { position: 0; color: Tui.alpha(deck.white, deck.light ? 0.22 : 0.07) }
        GradientStop { position: 0.45; color: Tui.alpha(deck.white, 0.0) }
        GradientStop { position: 1; color: Tui.alpha(deck.black, deck.light ? 0.04 : 0.15) }
      }
    }
  }

  // 4. Seek: the slot, the light pipe in it, the puck riding along.
  ShaderEffect {
    id: seek
    readonly property real padX: 16 * deck.s
    readonly property real padY: 9 * deck.s
    x: deck.rSlot.x - padX; y: deck.rSlot.y - padY
    width: deck.rSlot.width + 2 * padX; height: deck.rSlot.height + 2 * padY
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property real bloomAmt: core.bloom
    property real frac: core.sfrac
    property real hot: seekMouse.containsMouse || core.scrubbing ? 1 : 0
    Behavior on hot { NumberAnimation { duration: Tui.HOVER; easing.type: Easing.InOutCubic } }
    property real on: core.length > 0 ? 1 : 0
    property rect slot: Qt.rect(padX + deck.lip, padY + deck.lip, deck.rSlot.width - 2 * deck.lip, deck.rSlot.height - 2 * deck.lip)
    property color metal: deck.metal
    property color accent: core.accent
    fragmentShader: Qt.resolvedUrl("shaders/monolith_seek.frag.qsb")
    MouseArea {
      id: seekMouse
      anchors.fill: parent
      enabled: !!(core.player && core.player.canSeek !== false) && core.length > 0
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      function fracAt(x) { return Math.max(0, Math.min(1, (x - seek.slot.x - seek.slot.height / 2) / Math.max(1, seek.slot.width - seek.slot.height))) }
      onPressed: function(m) { core.beginScrub(fracAt(m.x)) }
      onPositionChanged: function(m) { if (pressed) core.moveScrub(fracAt(m.x)) }
      onReleased: core.commitScrub()
      onCanceled: core.cancelScrub()
      TuiTip {
        follow: true; force: core.scrubbing
        at: Math.max(0, Math.min(seekMouse.width, seekMouse.mouseX))
        text: core.length > 0 ? core.clock((core.scrubbing ? core.scrubFrac : seekMouse.fracAt(seekMouse.mouseX)) * core.length) : ""
      }
    }
  }

  // 5. The keys: soft-touch rubber, printed legends; each travels on a press.
  Repeater {
    model: [
      { a: "like", g: "󰋕", tip: "like / unlike" },
      { a: "previous", g: "󰒮", tip: "previous track" },
      { a: "toggle", g: "󰐊", tip: "play / pause" },
      { a: "next", g: "󰒭", tip: "next track" },
      { a: "stage", g: "󰺢", tip: "open or close the big visualizer" }
    ]
    Item {
      id: kc
      required property var modelData
      required property int index
      readonly property rect r: deck.keyRect(index)
      readonly property bool small: index === 0 || index === 4
      readonly property bool isPlay: modelData.a === "toggle"
      readonly property bool isLike: modelData.a === "like"
      readonly property bool isStage: modelData.a === "stage"
      readonly property bool enabledKey: !isLike || core.canLike
      readonly property real padPx: Math.round(9 * deck.s)
      x: r.x - padPx; y: r.y - padPx
      width: r.width + 2 * padPx; height: r.height + 2 * padPx

      property real press: km.pressed ? 1 : 0
      Behavior on press { NumberAnimation { duration: km.pressed ? 60 : 160; easing.type: km.pressed ? Easing.OutQuad : Easing.OutBack } }
      property real hover: km.containsMouse ? 1 : 0
      Behavior on hover { NumberAnimation { duration: Tui.HOVER; easing.type: Easing.InOutCubic } }
      property real ringOn: isPlay && core.playing ? 1 : 0
      Behavior on ringOn { NumberAnimation { duration: Tui.PAGE; easing.type: Easing.OutCubic } }

      ShaderEffect {
        anchors.fill: parent
        property vector2d res: Qt.vector2d(width, height)
        property real sc: deck.s
        property real light: deck.light ? 1 : 0
        property real bloomAmt: core.bloom
        property real rad: kc.small ? kc.r.width / 2 : deck.bigR
        property real press: kc.press
        property real hover: kc.hover
        property real ring: kc.isPlay ? 1 + kc.ringOn * (0.5 + 0.5 * deck.pulse) : 0
        property rect cap: Qt.rect(kc.padPx, kc.padPx, kc.r.width, kc.r.height)
        property color rubber: kc.isPlay ? deck.playRubber : deck.rubber
        property color glowC: deck.ringLight
        fragmentShader: Qt.resolvedUrl("shaders/monolith_key.frag.qsb")
      }
      // the printed legend, riding the cap
      Text {
        x: kc.padPx; y: kc.padPx + kc.press * 2.4 * deck.s
        width: kc.r.width; height: kc.r.height
        horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
        text: kc.isPlay ? (core.playing ? "󰏤" : "󰐊") : kc.isLike ? (core.liked ? "󰋑" : "󰋕") : kc.modelData.g
        font.family: core.fontFamily
        font.pixelSize: Math.round((kc.small ? 15 : 19) * deck.s)
        color: kc.isPlay ? Tui.mix(deck.playLegend, deck.black, 0.25 * kc.hover)
             : kc.isLike && core.liked ? core.hot
             : kc.isStage && deck.engine && deck.engine.open ? core.accent
             : Tui.mix(deck.legend, core.accent, kc.hover)
        opacity: kc.enabledKey ? 1 : 0.4
      }
      MouseArea {
        id: km
        x: kc.padPx; y: kc.padPx; width: kc.r.width; height: kc.r.height
        enabled: kc.enabledKey
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: core.act(kc.modelData.a)
        TuiTip {
          text: kc.isPlay ? (core.playing ? "pause" : "play") : kc.isLike ? (core.liked ? "unlike" : "like") : kc.modelData.tip
          key: deck.keys ? core.keyLabels[kc.modelData.a] : ""
        }
      }
    }
  }
  // the key letters, etched under the keys (only where the keys work)
  Repeater {
    model: deck.keys ? 5 : 0
    Etch {
      required property int index
      readonly property rect r: deck.keyRect(index)
      readonly property string a: ["like", "previous", "toggle", "next", "stage"][index]
      x: Math.round(r.x + r.width / 2 - width / 2)
      y: Math.round(deck.yKeys + deck.bigH + 4 * deck.s)
      text: core.keyLabels[a]
      size: 9 * deck.s; spacing: 1.4 * deck.s
    }
  }

  // 6. The wheel on the right edge: roll it (or drag it) to seek.
  ShaderEffect {
    id: wheel
    x: deck.rWheel.x; y: deck.rWheel.y
    width: deck.wheelW; height: deck.wheelH
    property vector2d res: Qt.vector2d(width, height)
    property real sc: deck.s
    property real light: deck.light ? 1 : 0
    property real turn: 0
    Behavior on turn { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    property real hot: wheelMouse.containsMouse ? 1 : 0
    property color metal: deck.metal
    fragmentShader: Qt.resolvedUrl("shaders/monolith_wheel.frag.qsb")
    function nudge(n) {
      turn -= n * 0.35
      core.seekBy(n * 5)
    }
    MouseArea {
      id: wheelMouse
      anchors.fill: parent; anchors.margins: -3 * deck.s
      hoverEnabled: true; cursorShape: Qt.SizeVerCursor
      property real wheelAcc: 0
      property real lastY: 0
      property real dragAcc: 0
      onWheel: function(w) { var n = Tui.notches(wheelMouse, w.angleDelta.y); if (n) wheel.nudge(n) }
      onPressed: function(m) { lastY = m.y; dragAcc = 0 }
      onPositionChanged: function(m) {
        if (!pressed) return
        dragAcc += lastY - m.y; lastY = m.y
        var step = 12 * deck.s
        while (Math.abs(dragAcc) >= step) { var n = dragAcc > 0 ? 1 : -1; wheel.nudge(n); dragAcc -= n * step }
      }
      TuiTip { text: "roll to seek · 5 s a notch" }
    }
  }
}
