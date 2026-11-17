import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// The vertical widget -- "Field". A machined field recorder stood on end: a
// satin steel face with linear machining marks between two pebble-grain hide
// rails, a backlit modulation meter whose needle rides the music on a damped
// spring, an anodised nameplate, the art under a bevelled sapphire window on
// four screws, a rolling drum counter, a tape-position scale with a hot cursor
// (click or drag to seek), and a control bay: a knurled push-to-play knob in a
// lit well, prev/next lever keys, and LIKE / VIS bat-handle toggles with lamps.
//
// Every colour is mixed from the live theme (DeckCore), so a theme switch
// re-machines the whole thing: the steel takes the foreground's cast, the dial
// card the light end of the palette, lamps the accent and the urgent colour.
// All type is the shell's monospace face, printed or engraved.
//
// Cost: the chassis (shaders/field_body.frag), the dial card and the art's
// glass are static and cached in layers; only the needle pass, the knob's
// light-pipe and the lamps redraw while music plays, and a FrameAnimation runs
// the needle only while it is live and moving. Paused, the deck settles to a
// still frame.
Item {
  id: deck

  property var engine: null
  property bool full: true
  property bool fill: false
  property bool keys: false
  // the harness (and anything else) can drive a scrub through the deck
  property alias scrubbing: core.scrubbing
  property alias scrubFrac: core.scrubFrac

  DeckCore { id: core; engine: deck.engine; keys: deck.keys }
  focus: keys
  Keys.onPressed: function(e) { core.key(e) }

  implicitHeight: Math.round(lay.total)

  // ---- materials, from the theme ----------------------------------------------
  function desat(c, t) {
    var l = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    return Qt.rgba(c.r + (l - c.r) * t, c.g + (l - c.g) * t, c.b + (l - c.b) * t, 1)
  }
  // a colour moved toward white or black until its luminance reaches `target`
  function lift(c, target) {
    var to = Tui.lum(c) < target ? white : black
    for (var t = 0; t <= 1.0001; t += 0.05) {
      var m = Tui.mix(c, to, t)
      if ((to === white) === (Tui.lum(m) >= target)) return m
    }
    return to
  }
  readonly property bool fgLight: Tui.lum(core.fg) >= Tui.lum(core.bg)
  readonly property color hiC: fgLight ? core.fg : core.bg
  readonly property color loC: fgLight ? core.bg : core.fg
  readonly property color black: Qt.rgba(0, 0, 0, 1)
  readonly property color white: Qt.rgba(1, 1, 1, 1)
  // satin steel: the light end of the palette, greyed, a breath of accent,
  // brought to the same brightness on every theme
  readonly property color steel: lift(Tui.mix(desat(hiC, 0.55), core.accent, 0.06), core.light ? 0.40 : 0.42)
  // engraving fill and black anodising: the dark end, a touch of accent
  readonly property color ink: Tui.mix(Tui.mix(loC, black, core.light ? 0.5 : 0.25), core.accent, 0.05)
  readonly property color hideC: Tui.mix(Tui.mix(loC, black, 0.30), core.accent, 0.05)
  // the dial card: the light end warmed toward the urgent colour, lifted to paper
  readonly property color paper: lift(desat(Tui.mix(hiC, core.hot, 0.10), 0.3), 0.74)
  // printed type on the steel, and the engraving's lit lip
  readonly property color inkP: Tui.mix(ink, black, 0.35)
  readonly property color inkP2: Tui.mix(ink, steel, 0.08)
  readonly property color lip: Tui.alpha(white, 0.22)
  readonly property real bloomAmt: core.bloom
  readonly property string family: core.fontFamily

  // ---- layout: from the room we are given ----------------------------------------
  // Design units at u = 1 (392 px wide). The meter and the art flex; when a
  // window is too short for their minimums the whole deck scales down instead.
  readonly property var lay: {
    var W = width
    var k = keys ? 1 : 0
    var u = fill ? Math.min(W / 392, 1.9) : W / 392
    function fixedH(u) { return u * (2 + 9 + 16 + 10 + 20 + 10 + 14 + 38 + 12 + 140 + 14 * k + 14) }
    if (fill && height > 0) {
      var need = fixedH(u) + u * (100 + 112)
      if (need > height) u = Math.max(0.55, u * height / need)
    }
    var m = 2 * u
    var railW = 17 * u
    var faceW = W - 2 * m - 2 * railW
    var cw = faceW - 32 * u
    var mN = cw * 0.56, aN = cw * 0.42
    var mMin = 100 * u, aMin = 112 * u
    var meterH = mN, artS = aN, spare = 0
    if (fill && height > 0) {
      var avail = height - fixedH(u)
      if (avail >= mN + aN) {
        meterH = Math.min(cw * 0.70, mN + (avail - mN - aN) * 0.55)
        spare = avail - meterH - aN
      } else {
        var t = Math.max(0, (avail - mMin - aMin) / Math.max(1, (mN - mMin) + (aN - aMin)))
        meterH = mMin + (mN - mMin) * t
        artS = aMin + (aN - aMin) * t
      }
    }
    var g = spare / 6
    var devH = fill ? height - 11 * u : fixedH(u) + meterH + artS - 11 * u
    var face = { x: m + railW, y: m, w: faceW, h: devH }
    var x0 = face.x + 16 * u
    var y = face.y + 16 * u + g * 0.5
    var meter = { x: x0, y: y, w: cw, h: meterH }; y += meterH + 10 * u + g
    var plate = { y: y, h: 20 * u }; y += 20 * u + 10 * u + g
    var art = { x: x0, y: y, s: artS }; y += artS + 14 * u + g
    var scale = { x: x0 + 8 * u, y: y, w: cw - 16 * u, h: 38 * u }; y += 38 * u + 12 * u + g
    var kr = 40 * u, wr = 46 * u
    var knob = { x: face.x + face.w / 2, y: y + wr + 14 * u, r: kr, w: wr }
    var side = (cw - 2 * (wr + 14 * u)) / 2
    var colL = x0 + side / 2, colR = x0 + cw - side / 2
    // the monitor speaker's grille, in whatever the bay has spare under the knob
    var gTop = knob.y + wr + 13 * u + 11 * u + (k ? 15 * u : 0) + 8 * u
    var gBot = face.y + devH - 14 * u - 8 * u
    var gH = Math.min(24 * u, gBot - gTop)
    var gW = Math.min(cw * 0.56, 190 * u)
    var grille = gH >= 13 * u ? { x: face.x + (faceW - gW) / 2, y: gTop + (gBot - gTop - gH) / 2, w: gW, h: gH }
                              : { x: 0, y: 0, w: 0, h: 0 }
    return {
      grille: grille,
      u: u, k: k, total: fixedH(u) + meterH + artS,
      dev: { x: m, y: m, w: W - 2 * m, h: devH }, railW: railW, face: face, cw: cw, x0: x0,
      meter: meter, plate: plate, art: art, scale: scale, knob: knob, side: side, colL: colL, colR: colR,
      lev: { w: Math.min(64 * u, side * 0.74), h: 32 * u, y: knob.y - 52 * u },
      tog: { y: knob.y + 33 * u }
    }
  }
  readonly property real u: lay.u

  // ---- motion: the needle -----------------------------------------------------------
  // A damped spring chasing the programme level: loudness and low end set the
  // target, the kick shoves it, and it bounces off the end stops. It sinks to
  // rest on pause, then the animation stops.
  readonly property bool moving: core.live && !core.gameMode
  property real needle: 0
  property real needleV: 0
  property real peak: 0
  property real peakHold: 0
  FrameAnimation {
    running: deck.moving && (core.playing || deck.needle > 0.001 || Math.abs(deck.needleV) > 0.001 || deck.peak > 0.002)
    onTriggered: {
      var dt = Math.min(0.05, Math.max(0.001, frameTime))
      // programme level on the VU law (as the Studio deck reads it), the low
      // end and the kick riding on top
      var base = Math.pow(Math.max(0, Math.min(1, (core.energy - 0.05) / 0.75)), 0.8)
      var target = core.playing ? Math.min(1.1, base * 1.0 + 0.10 * core.bass + 0.30 * core.kick) : 0
      var kk = 150, c = 2 * Math.sqrt(kk) * 0.45
      var a = kk * (target - deck.needle) - c * deck.needleV
      var v = deck.needleV + a * dt
      var n = deck.needle + v * dt
      if (n > 1.07) { n = 1.07; v = -Math.abs(v) * 0.35 }
      if (n < 0) { n = 0; v = Math.abs(v) * 0.25; if (v < 0.02) v = 0 }
      deck.needleV = v
      deck.needle = n
      if (n > 0.86 && core.playing) { deck.peak = 1; deck.peakHold = 0.3 }
      else if (deck.peakHold > 0) deck.peakHold -= dt
      else deck.peak = Math.max(0, deck.peak - dt * 3.2)
    }
  }
  // the dial's lamp warms up and cools off rather than switching
  property real lamp: core.playing ? 1 : 0
  Behavior on lamp { NumberAnimation { duration: 700; easing.type: Easing.InOutCubic } }

  // ---- the chassis ---------------------------------------------------------------------
  function v4(r) { return Qt.vector4d(r.x, r.y, r.w, r.h) }
  ShaderEffect {
    id: body
    anchors.fill: parent
    fragmentShader: Qt.resolvedUrl("shaders/field_body.frag.qsb")
    property vector2d res: Qt.vector2d(width, height)
    property real u: deck.u
    property real light: core.light ? 1 : 0
    property vector4d dev: deck.v4(deck.lay.dev)
    property vector4d face: deck.v4(deck.lay.face)
    property vector4d meterR: deck.v4(deck.lay.meter)
    property vector4d plateR: Qt.vector4d(plate.x, plate.y, plate.width, plate.height)
    property vector4d artR: Qt.vector4d(deck.lay.art.x, deck.lay.art.y, deck.lay.art.s, deck.lay.art.s)
    property vector4d cntR: Qt.vector4d(info.x + counter.x, info.y + counter.y, counter.width, counter.height)
    property vector4d scaleR: deck.v4(deck.lay.scale)
    property vector4d knob: Qt.vector4d(deck.lay.knob.x, deck.lay.knob.y, deck.lay.knob.r, deck.lay.knob.w)
    property vector4d levL: Qt.vector4d(prevKey.x + prevKey.pad - 3 * deck.u, prevKey.y + prevKey.pad - 3 * deck.u, prevKey.width - 2 * prevKey.pad + 6 * deck.u, prevKey.height - 2 * prevKey.pad + 6 * deck.u)
    property vector4d levR: Qt.vector4d(nextKey.x + nextKey.pad - 3 * deck.u, nextKey.y + nextKey.pad - 3 * deck.u, nextKey.width - 2 * nextKey.pad + 6 * deck.u, nextKey.height - 2 * nextKey.pad + 6 * deck.u)
    property vector4d togL: Qt.vector4d(likeSw.x + likeSw.width / 2, likeSw.y + likeSw.height / 2, 12 * deck.u, 0)
    property vector4d togR: Qt.vector4d(visSw.x + visSw.width / 2, visSw.y + visSw.height / 2, 12 * deck.u, 0)
    property vector4d grilleR: deck.v4(deck.lay.grille)
    property color steel: deck.steel
    property color ink: deck.ink
    property color hide: deck.hideC
    property color accent: core.accent
    layer.enabled: true
  }

  // ---- the meter ---------------------------------------------------------------------------
  Item {
    id: dial
    x: deck.lay.meter.x + 7 * deck.u; y: deck.lay.meter.y + 7 * deck.u
    width: deck.lay.meter.w - 14 * deck.u; height: deck.lay.meter.h - 14 * deck.u
    readonly property real span: 0.80
    // the arc's radius comes from the width; a short dial pushes the pivot
    // further down so the arc flattens instead of shrinking
    readonly property real arcR: Math.min((width / 2 - 26 * deck.u) / Math.sin(span),
                                          (height - 46 * deck.u) / (1 - Math.cos(span)))
    readonly property real pivY: Math.max(height * 1.10, arcR + 30 * deck.u)
    // the per-cent scale and the legend only where the dial is deep enough
    readonly property bool roomy: pivY - arcR * Math.cos(span) + 52 * deck.u < height
    function pt(pos, off) {
      var a = -span + 2 * span * pos
      return Qt.point(width / 2 + Math.sin(a) * (arcR + off), pivY - Math.cos(a) * (arcR + off))
    }
    function vu(db) { return Math.pow(10, (db - 3) / 20) }

    ShaderEffect {
      anchors.fill: parent
      fragmentShader: Qt.resolvedUrl("shaders/field_meter.frag.qsb")
      property vector2d res: Qt.vector2d(width, height)
      property real u: deck.u
      property real mode: 0
      property vector4d geo: Qt.vector4d(dial.width / 2, dial.pivY, dial.arcR, dial.span)
      property real minor: dial.roomy ? 1 : 0
      property real lamp: deck.lamp
      property real needle: 0
      property real peak: 0
      property real light: core.light ? 1 : 0
      property real bloomAmt: deck.bloomAmt
      property color paper: deck.paper
      property color ink: deck.ink
      property color hot: core.hot
      property color accent: core.accent
      layer.enabled: true
    }
    // the printed scale: dB on the VU law over the arc, per cent under it
    Repeater {
      model: [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
      Text {
        required property var modelData
        readonly property point at: dial.pt(dial.vu(modelData), 15 * deck.u)
        x: at.x - width / 2; y: at.y - height / 2
        text: modelData > 0 ? "+" + modelData : modelData < 0 ? String(-modelData) : "0"
        font.family: deck.family; font.pixelSize: Math.round(9.5 * deck.u); font.bold: modelData === 0
        color: modelData > 0 ? core.hot : deck.ink
        opacity: 0.88
      }
    }
    Repeater {
      model: dial.roomy ? [0, 50, 100] : []
      Text {
        required property var modelData
        readonly property point at: dial.pt(modelData / 100, -29 * deck.u)
        x: at.x - width / 2; y: at.y - height / 2
        text: modelData
        font.family: deck.family; font.pixelSize: Math.round(7.5 * deck.u)
        color: deck.ink; opacity: 0.7
      }
    }
    Text {
      readonly property point at: dial.pt(dial.vu(-20), 15 * deck.u)
      x: at.x - width - 6 * deck.u; y: at.y - height / 2
      text: "−"
      font.family: deck.family; font.pixelSize: Math.round(9.5 * deck.u)
      color: deck.ink; opacity: 0.8
    }
    Column {
      visible: dial.roomy
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.min(dial.pivY - dial.arcR + 44 * deck.u, dial.height - 24 * deck.u - height)
      spacing: 1 * deck.u
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "vu"
        font.family: deck.family; font.pixelSize: Math.round(19 * deck.u); font.bold: true
        color: deck.ink; opacity: 0.85
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "┤ mod · db ├"
        font.family: deck.family; font.pixelSize: Math.round(7.5 * deck.u); font.letterSpacing: 1 * deck.u
        color: deck.ink; opacity: 0.6
      }
    }
    Text {
      x: dial.width - 23 * deck.u - width; y: 14 * deck.u - height / 2
      text: "peak"
      font.family: deck.family; font.pixelSize: Math.round(7.5 * deck.u); font.letterSpacing: 0.6 * deck.u
      color: deck.ink; opacity: 0.7
    }
    Text {
      x: 10 * deck.u; y: 14 * deck.u - height / 2
      text: "orpheus · l+r"
      font.family: deck.family; font.pixelSize: Math.round(7.5 * deck.u); font.letterSpacing: 0.6 * deck.u
      color: deck.ink; opacity: 0.6
    }
    ShaderEffect {
      anchors.fill: parent
      fragmentShader: Qt.resolvedUrl("shaders/field_meter.frag.qsb")
      property vector2d res: Qt.vector2d(width, height)
      property real u: deck.u
      property real mode: 1
      property vector4d geo: Qt.vector4d(dial.width / 2, dial.pivY, dial.arcR, dial.span)
      property real minor: dial.roomy ? 1 : 0
      property real lamp: deck.lamp
      property real needle: deck.needle
      property real peak: deck.peak
      property real light: core.light ? 1 : 0
      property real bloomAmt: deck.bloomAmt
      property color paper: deck.paper
      property color ink: deck.ink
      property color hot: core.hot
      property color accent: core.accent
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: core.act("stage")
      TuiTip { text: "open or close the big visualizer"; key: deck.keys ? "V" : "" ; delay: 900 }
    }
  }

  // ---- engraved type ------------------------------------------------------------------------
  // Cut into the steel: dark fill, the lip under it catching the key light.
  component Engr: Text {
    font.family: deck.family
    color: deck.inkP
    style: Text.Raised
    styleColor: deck.lip
  }
  // A keycap outline cut into the plate, printing the real key.
  component KeyCap: Item {
    id: kc
    property string label: ""
    visible: deck.keys
    implicitWidth: Math.max(kcText.implicitWidth + 7 * deck.u, 13 * deck.u)
    implicitHeight: 12 * deck.u
    Rectangle { anchors.fill: parent; anchors.topMargin: 1; color: "transparent"; radius: 2 * deck.u; border.width: 1; border.color: deck.lip }
    Rectangle { anchors.fill: parent; anchors.bottomMargin: 1; color: "transparent"; radius: 2 * deck.u; border.width: 1; border.color: Tui.alpha(deck.ink, 0.65) }
    Engr { id: kcText; anchors.centerIn: parent; text: kc.label; font.pixelSize: Math.round(8 * deck.u); font.bold: true }
  }

  // ---- the nameplate ---------------------------------------------------------------------------
  TextMetrics { id: plateTm; font.family: deck.family; font.pixelSize: Math.round(11 * deck.u); font.bold: true; font.letterSpacing: 2.4 * deck.u; text: "orpheus · field f2" }
  Item {
    id: plate
    width: Math.round(plateTm.advanceWidth + 34 * deck.u); height: Math.round(deck.lay.plate.h)
    x: Math.round(deck.lay.face.x + (deck.lay.face.w - width) / 2); y: Math.round(deck.lay.plate.y)
    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 0.5
      text: "orpheus · field f2"
      font.family: deck.family; font.pixelSize: Math.round(11 * deck.u); font.bold: true; font.letterSpacing: 2.4 * deck.u
      // cut through the anodising to bright metal
      color: Tui.mix(deck.steel, deck.white, 0.25)
      style: Text.Sunken; styleColor: Tui.alpha(deck.black, 0.6)
    }
  }

  // ---- the art, under sapphire ---------------------------------------------------------------------
  component ArtLayer: Image {
    property Item owner: null
    property bool shown: false
    property bool pending: false
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop; asynchronous: true
    sourceSize: owner ? Qt.size(owner.width * 2, owner.height * 2) : Qt.size(0, 0)
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
    onStatusChanged: if (owner) owner.layerStatus(this)
  }
  Item {
    id: art
    x: deck.lay.art.x + 10 * deck.u; y: deck.lay.art.y + 10 * deck.u
    width: deck.lay.art.s - 20 * deck.u; height: width
    clip: true
    // Two layers trade roles (as in the Studio deck): a new cover loads into
    // the hidden one and fades in only once Ready; no art fades both out.
    readonly property string url: core.artUrl
    property Item front: layerA
    property bool hasArt: false
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
        o.z = 1; l.z = 2
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
          if (!ls[i].pending && (ls[i] !== art.front || !art.hasArt)) { ls[i].shown = false; ls[i].source = "" }
      }
    }
    // no art: a blank card with the house's hatching
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0; color: Tui.mix(deck.ink, core.accent, 0.18) }
        GradientStop { position: 1; color: Tui.mix(deck.ink, deck.black, 0.4) }
      }
      Text {
        anchors.centerIn: parent
        text: "╱╱╱\n no art"
        horizontalAlignment: Text.AlignHCenter
        font.family: deck.family; font.pixelSize: Math.round(10 * deck.u)
        color: Tui.mix(deck.steel, deck.ink, 0.45)
      }
      opacity: art.hasArt ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
    }
    ArtLayer { id: layerA; owner: art }
    ArtLayer { id: layerB; owner: art }
    ShaderEffect {
      anchors.fill: parent
      z: 5
      fragmentShader: Qt.resolvedUrl("shaders/field_parts.frag.qsb")
      property vector2d res: Qt.vector2d(width, height)
      property real u: deck.u
      property real part: 5
      property real press: 0; property real hover: 0; property real val: 0; property real on: 0; property real beat: 0
      property real light: core.light ? 1 : 0
      property real bloomAmt: deck.bloomAmt
      property real icon: 0
      property vector4d dims: Qt.vector4d(0, 0, 0, 0)
      property color steel: deck.steel; property color ink: deck.ink
      property color lampC: core.accent; property color hot: core.hot
      layer.enabled: true
    }
    MouseArea {
      anchors.fill: parent; z: 6
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: if (deck.engine) deck.engine.libraryOpen = true
      TuiTip { text: "open the player" }
    }
  }

  // ---- the track: printed title, spaced artist, the counter, the tags ---------------------------
  Item {
    id: info
    x: deck.lay.art.x + deck.lay.art.s + 14 * deck.u
    y: deck.lay.art.y + 1 * deck.u
    width: deck.lay.x0 + deck.lay.cw - x
    height: deck.lay.art.s - 1 * deck.u
    // title (two lines at most), artist, album, then the counter and the tags
    readonly property bool roomForAlbum: titleText.height + artistText.height + albumLine.implicitHeight + 8 * deck.u
                                         + counter.height + tags.height + 14 * deck.u <= height
    property real swap: 1
    NumberAnimation on swap { id: swapAnim; running: false; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.OutCubic }
    Connections { target: core; function onTrackKeyChanged() { swapAnim.restart() } }

    Column {
      width: parent.width
      spacing: 4 * deck.u
      opacity: 0.25 + 0.75 * info.swap
      ScrambleText {
        id: titleText
        width: parent.width; elide: Text.ElideRight; wrapMode: Text.Wrap; maximumLineCount: 2
        textFormat: Text.PlainText
        lineHeight: 0.92
        animate: core.titleFx; key: core.trackKey
        target: core.title !== "" ? core.title : (core.player ? "unknown track" : "nothing playing")
        font.family: deck.family; font.pixelSize: Math.round(15.5 * deck.u); font.bold: true
        color: deck.inkP
        style: Text.Raised; styleColor: Tui.alpha(deck.white, 0.28)
      }
      ScrambleText {
        id: artistText
        width: parent.width; elide: Text.ElideRight
        textFormat: Text.PlainText
        animate: core.titleFx; key: core.trackKey; duration: Tui.DECODE
        target: core.artist !== "" ? core.artist : (core.player ? "" : "pick something in the player")
        font.family: deck.family; font.pixelSize: Math.round(9.5 * deck.u)
        font.capitalization: Font.AllUppercase; font.letterSpacing: 2.2 * deck.u
        color: deck.inkP2
      }
      // the album, small, where the column has the room
      Text {
        id: albumLine
        width: parent.width; elide: Text.ElideRight
        visible: core.album !== "" && info.roomForAlbum
        text: "┄ " + core.album.toLowerCase()
        font.family: deck.family; font.pixelSize: Math.round(8.5 * deck.u); font.italic: true
        color: deck.inkP2; opacity: 0.8
      }
    }

    // the drum counter: elapsed mm:ss on four rolling wheels
    Item {
      id: counter
      readonly property real dw: 17 * deck.u
      readonly property real dh: 26 * deck.u
      readonly property real gap: 2 * deck.u
      x: 0; y: tags.y - height - 8 * deck.u
      width: 4 * dw + 3 * gap + 10 * deck.u + 6 * deck.u
      height: dh + 6 * deck.u
      readonly property string t: core.clock2(core.shownPos)
      Row {
        x: 3 * deck.u; y: 3 * deck.u
        spacing: counter.gap
        Drum { digit: Number(counter.t.charAt(0)); base: 10 }
        Drum { digit: Number(counter.t.charAt(1)); base: 10 }
        Item {
          width: 10 * deck.u - 2 * counter.gap; height: counter.dh
          Text {
            anchors.centerIn: parent; anchors.verticalCenterOffset: -1 * deck.u
            text: ":"; font.family: deck.family; font.pixelSize: Math.round(15 * deck.u); font.bold: true
            color: Tui.mix(deck.steel, deck.white, 0.2); opacity: core.playing ? 0.9 : 0.5
          }
        }
        Drum { digit: Number(counter.t.charAt(3)); base: 6 }
        Drum { digit: Number(counter.t.charAt(4)); base: 10 }
      }
      // a sliver of glass over the wheels
      Rectangle {
        anchors.fill: parent; anchors.margins: 1
        radius: 2 * deck.u
        gradient: Gradient {
          GradientStop { position: 0.0; color: Tui.alpha(deck.white, 0.16) }
          GradientStop { position: 0.18; color: Tui.alpha(deck.white, 0.05) }
          GradientStop { position: 0.5; color: Tui.alpha(deck.white, 0.0) }
        }
      }
    }
    Engr {
      anchors { left: counter.right; leftMargin: 6 * deck.u; verticalCenter: counter.verticalCenter }
      text: "min\nsec"
      lineHeight: 0.9
      font.pixelSize: Math.round(7.5 * deck.u); font.letterSpacing: 0.8 * deck.u
      color: deck.inkP2
      visible: info.width - counter.width > 30 * deck.u
    }

    Row {
      id: tags
      anchors.bottom: parent.bottom
      spacing: 5 * deck.u
      Tag { id: tagQ; label: core.qualityLabel !== "" ? core.qualityLabel : "─ ─"; dimmed: core.qualityLabel === ""; maxW: info.width }
      Tag {
        id: tagT
        label: core.tempoLabel !== "" ? core.tempoLabel.replace(" BPM", "") + " bpm" : "─ ─"
        dimmed: core.tempoLabel === ""
        maxW: info.width - tagQ.width - 5 * deck.u
      }
      Tag {
        visible: core.sectionLabel !== "" && implicitWidth <= info.width - tagQ.width - tagT.width - 10 * deck.u
        label: core.sectionLabel.toLowerCase()
        flash: core.secFlash
      }
    }
  }

  // A wheel of the drum counter: digits printed round a cylinder, rolling
  // forward a face at a time (and the shortest way when you scrub).
  component Drum: Item {
    id: dr
    property int digit: 0
    property int base: 10
    property real v: 0
    property bool ready: false
    width: counter.dw; height: counter.dh
    clip: true
    Component.onCompleted: { v = digit; ready = true }
    onDigitChanged: {
      if (!ready) return
      var cur = ((Math.round(v) % base) + base) % base
      var d = digit - cur
      if (d > base / 2) d -= base
      if (d < -base / 2) d += base
      if (d === -base / 2) d += base
      rollAnim.stop()
      v = Math.round(v)
      rollAnim.to = v + d
      rollAnim.start()
    }
    NumberAnimation on v { id: rollAnim; running: false; duration: 240; easing.type: Easing.OutBack; easing.overshoot: 1.3 }
    readonly property real face: 1.0
    readonly property real rad: height * 0.6
    Rectangle {
      anchors.fill: parent
      color: Tui.mix(deck.ink, deck.black, 0.35)
    }
    Repeater {
      model: 4
      Text {
        required property int index
        readonly property int k: Math.floor(dr.v) - 1 + index
        readonly property real a: (k - dr.v) * dr.face
        visible: Math.abs(a) < 1.45
        text: String(((k % dr.base) + dr.base) % dr.base)
        font.family: deck.family; font.pixelSize: Math.round(17 * deck.u); font.bold: true
        color: Tui.mix(deck.steel, deck.white, 0.35)
        opacity: Math.max(0, Math.cos(a))
        x: (dr.width - width) / 2
        y: dr.height / 2 + Math.sin(a) * dr.rad - height / 2
        transform: Scale { origin.x: width / 2; origin.y: height / 2; yScale: Math.max(0.05, Math.cos(a)) }
      }
    }
    // the cylinder's shading: dark at the lips, a soft line of light above centre
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        GradientStop { position: 0.0; color: Tui.alpha(deck.black, 0.92) }
        GradientStop { position: 0.22; color: Tui.alpha(deck.black, 0.30) }
        GradientStop { position: 0.38; color: Tui.alpha(deck.white, 0.07) }
        GradientStop { position: 0.55; color: Tui.alpha(deck.black, 0.0) }
        GradientStop { position: 0.80; color: Tui.alpha(deck.black, 0.40) }
        GradientStop { position: 1.0; color: Tui.alpha(deck.black, 0.95) }
      }
    }
  }

  // An engraved tag: a cut outline with its lip, the value printed inside.
  component Tag: Item {
    id: tg
    property string label: ""
    property bool dimmed: false
    property real flash: 0
    property real maxW: 1e6
    implicitWidth: tgText.implicitWidth + 9 * deck.u
    implicitHeight: 15 * deck.u
    width: Math.min(implicitWidth, maxW); height: implicitHeight
    Rectangle { anchors.fill: parent; anchors.topMargin: 1; color: "transparent"; radius: 2 * deck.u; border.width: 1; border.color: deck.lip }
    Rectangle { anchors.fill: parent; anchors.bottomMargin: 1; color: "transparent"; radius: 2 * deck.u; border.width: 1; border.color: Tui.alpha(deck.ink, 0.6) }
    Text {
      id: tgText
      anchors.centerIn: parent
      width: Math.min(implicitWidth, tg.maxW - 9 * deck.u)
      elide: Text.ElideRight
      text: tg.label
      font.family: deck.family; font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 0.8 * deck.u; font.bold: !tg.dimmed
      color: Tui.mix(tg.dimmed ? deck.inkP2 : deck.inkP, core.hot, tg.flash)
    }
  }

  // ---- the tape scale --------------------------------------------------------------------------------
  Item {
    id: tapeScale
    x: deck.lay.scale.x; y: deck.lay.scale.y; width: deck.lay.scale.w; height: deck.lay.scale.h
    Repeater {
      model: 5
      Item {
        id: lab
        required property int index
        readonly property real f: index / 4
        Engr {
          x: Math.max(-4 * deck.u, Math.min(tapeScale.width - width + 4 * deck.u, lab.f * tapeScale.width - width / 2))
          y: tapeScale.height * 0.70
          text: core.length > 0 ? core.clock(core.length * lab.f) : ["0", "¼", "½", "¾", "1"][lab.index]
          font.pixelSize: Math.round(8 * deck.u); font.features: { "tnum": 1 }
          color: deck.inkP2
        }
      }
    }
    ShaderEffect {
      id: pointer
      readonly property real fx: core.sfrac
      width: 26 * deck.u; height: tapeScale.height
      x: fx * tapeScale.width - width / 2
      fragmentShader: Qt.resolvedUrl("shaders/field_parts.frag.qsb")
      property vector2d res: Qt.vector2d(width, height)
      property real u: deck.u
      property real part: 4
      property real press: 0
      property real hover: seekMouse.containsMouse || core.scrubbing ? 1 : 0
      property real val: hover
      Behavior on val { NumberAnimation { duration: Tui.HOVER; easing.type: Tui.EASE } }
      property real on: 0; property real beat: 0
      property real light: core.light ? 1 : 0
      property real bloomAmt: deck.bloomAmt
      property real icon: 0
      property vector4d dims: Qt.vector4d(tapeScale.height * 0.04, tapeScale.height * 0.34, 0, 0)
      property color steel: deck.steel; property color ink: deck.ink
      property color lampC: core.hot; property color hot: core.hot
    }
    MouseArea {
      id: seekMouse
      anchors.fill: parent; anchors.leftMargin: -6 * deck.u; anchors.rightMargin: -6 * deck.u
      enabled: core.length > 0
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      function fracAt(x) { return Math.max(0, Math.min(1, (x - 6 * deck.u) / Math.max(1, tapeScale.width))) }
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

  // ---- the control bay -----------------------------------------------------------------------------------
  component Part: ShaderEffect {
    fragmentShader: Qt.resolvedUrl("shaders/field_parts.frag.qsb")
    property vector2d res: Qt.vector2d(width, height)
    property real u: deck.u
    property real part: 0
    property real press: 0
    property real hover: 0
    property real val: 0
    property real on: 0
    property real beat: 0
    property real light: core.light ? 1 : 0
    property real bloomAmt: deck.bloomAmt
    property real icon: 0
    property vector4d dims: Qt.vector4d(0, 0, 0, 0)
    property color steel: deck.steel
    property color ink: deck.ink
    property color lampC: core.accent
    property color hot: core.hot
  }

  // the knob: push to play
  Part {
    id: knobFx
    readonly property real pad: 10 * deck.u
    width: 2 * (deck.lay.knob.w + pad); height: width
    x: deck.lay.knob.x - width / 2; y: deck.lay.knob.y - height / 2
    part: 0
    press: knobMouse.pressed ? 1 : 0
    Behavior on press { NumberAnimation { duration: 70 } }
    hover: knobMouse.containsMouse ? 1 : 0
    Behavior on hover { NumberAnimation { duration: Tui.HOVER } }
    val: core.playing ? 0.62 : 0
    Behavior on val { SpringAnimation { spring: 4; damping: 0.32; epsilon: 0.002 } }
    on: core.playing ? 1 : 0
    Behavior on on { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
    beat: deck.moving ? core.beat : 0
    icon: core.playing ? 2 : 1
    dims: Qt.vector4d(deck.lay.knob.r, deck.lay.knob.w, pad, 0)
    MouseArea {
      id: knobMouse
      anchors.centerIn: parent
      width: 2 * deck.lay.knob.r; height: width
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: core.act("toggle")
      TuiTip { text: core.playing ? "pause" : "play"; key: deck.keys ? "space" : "" }
    }
  }
  Column {
    anchors.horizontalCenter: knobFx.horizontalCenter
    y: deck.lay.knob.y + deck.lay.knob.w + 13 * deck.u
    spacing: 3 * deck.u
    Engr {
      anchors.horizontalCenter: parent.horizontalCenter
      text: core.playing ? "push · pause" : "push · play"
      font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 1.6 * deck.u; font.bold: true
    }
    KeyCap { anchors.horizontalCenter: parent.horizontalCenter; label: "space" }
  }

  // lever keys
  component Lever: Part {
    id: lv
    property string action: ""
    property string tip: ""
    readonly property real pad: 6 * deck.u
    part: 1
    width: deck.lay.lev.w + 2 * pad; height: deck.lay.lev.h + 2 * pad
    press: lvMouse.pressed ? 1 : 0
    Behavior on press { NumberAnimation { duration: 60 } }
    hover: lvMouse.containsMouse ? 1 : 0
    Behavior on hover { NumberAnimation { duration: Tui.HOVER } }
    dims: Qt.vector4d(pad, 5 * deck.u, 0, 0)
    MouseArea {
      id: lvMouse
      anchors.fill: parent; anchors.margins: lv.pad
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: core.act(lv.action)
      TuiTip { text: lv.tip; key: deck.keys ? core.keyLabels[lv.action] : "" }
    }
  }
  Lever {
    id: prevKey
    action: "previous"; tip: "previous track"; icon: 3
    x: deck.lay.colL - width / 2; y: deck.lay.lev.y
  }
  Lever {
    id: nextKey
    action: "next"; tip: "next track"; icon: 4
    x: deck.lay.colR - width / 2; y: deck.lay.lev.y
  }
  Row {
    anchors.horizontalCenter: prevKey.horizontalCenter
    y: prevKey.y + prevKey.height - 1 * deck.u
    spacing: 5 * deck.u
    Engr { anchors.verticalCenter: parent.verticalCenter; text: "prev"; font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 1.6 * deck.u; font.bold: true }
    KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "p" }
  }
  Row {
    anchors.horizontalCenter: nextKey.horizontalCenter
    y: nextKey.y + nextKey.height - 1 * deck.u
    spacing: 5 * deck.u
    Engr { anchors.verticalCenter: parent.verticalCenter; text: "next"; font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 1.6 * deck.u; font.bold: true }
    KeyCap { anchors.verticalCenter: parent.verticalCenter; label: "n" }
  }

  // bat-handle toggles with lamps
  component Toggle: Part {
    id: tgl
    property bool state: false
    property bool enabledSw: true
    property string action: ""
    property string tip: ""
    part: 2
    width: 46 * deck.u; height: 66 * deck.u
    val: state ? 1 : -1
    Behavior on val { SpringAnimation { spring: 5; damping: 0.26; epsilon: 0.004 } }
    hover: tgMouse.containsMouse ? 1 : 0
    Behavior on hover { NumberAnimation { duration: Tui.HOVER } }
    MouseArea {
      id: tgMouse
      anchors.fill: parent; anchors.margins: 5 * deck.u
      enabled: tgl.enabledSw
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: core.act(tgl.action)
      TuiTip { text: tgl.tip; key: deck.keys ? core.keyLabels[tgl.action] : "" }
    }
  }
  component Lamp: Part {
    part: 3
    width: 22 * deck.u; height: width
    dims: Qt.vector4d(3.6 * deck.u, 0, 0, 0)
    Behavior on on { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
  }
  readonly property bool visOn: !!engine && !!engine.open
  Toggle {
    id: likeSw
    state: core.liked; enabledSw: core.canLike
    action: "like"; tip: core.liked ? "unlike" : "like"
    x: deck.lay.colL - 28 * deck.u - width / 2; y: deck.lay.tog.y - height / 2
  }
  Lamp {
    id: likeLamp
    x: deck.lay.colL - 4 * deck.u - width / 2; y: deck.lay.tog.y - 6 * deck.u - height / 2
    lampC: core.hot; on: core.liked ? 1 : 0
  }
  Column {
    x: deck.lay.colL + 6 * deck.u; y: likeLamp.y + likeLamp.height / 2 - 6 * deck.u
    spacing: 3 * deck.u
    Engr { text: "like"; font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 1.6 * deck.u; font.bold: true; opacity: core.canLike ? 1 : 0.5 }
    KeyCap { label: "F" }
  }

  Toggle {
    id: visSw
    state: deck.visOn
    action: "stage"; tip: "open or close the big visualizer"
    x: deck.lay.colR + 28 * deck.u - width / 2; y: deck.lay.tog.y - height / 2
  }
  Lamp {
    id: visLamp
    x: deck.lay.colR + 4 * deck.u - width / 2; y: deck.lay.tog.y - 6 * deck.u - height / 2
    lampC: core.accent; on: deck.visOn ? 1 : 0
  }
  Column {
    x: deck.lay.colR - 6 * deck.u - width; y: visLamp.y + visLamp.height / 2 - 6 * deck.u
    spacing: 3 * deck.u
    Engr { anchors.right: parent.right; text: "vis"; font.pixelSize: Math.round(8.5 * deck.u); font.letterSpacing: 1.6 * deck.u; font.bold: true }
    KeyCap { anchors.right: parent.right; label: "V" }
  }
}
