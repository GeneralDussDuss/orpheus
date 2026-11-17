import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// The vertical widget -- "Reference" (orpheus · dr-1 reference). An eighties
// flagship hi-fi deck stood on end: a brushed aluminium faceplate (black
// anodised on a dark theme, silver on a light one, both tinted by the theme)
// with a diamond-cut edge and hex cap screws; an engraved model plate; a
// vacuum fluorescent display behind smoked glass (segmented spectrum with peak
// hold, L/R peak meters on a dB scale, annunciators, a dot-matrix title that
// steps along, seven-segment figures, a segmented progress bar you can scrub); the cover behind a
// chrome bezel; a big knurled position knob on an engraved dial (its light
// pipe shows where the track is, turning it scrubs); and a row of chrome piano
// keys with status LEDs.
//
// Drawing is split by how often it changes. The faceplate (reference_face) is
// one still frame, cached in a layer. The moving specular band
// (reference_sheen) is a cheap overlay that only moves while the music plays.
// The display (reference_vfd) reads the engine's bands straight into uniforms;
// its annunciators are QML text rendered into a texture only when they change. The knob and
// the keys are small shaders that redraw only when touched or when the
// position ticks. Every colour comes off the live theme (DeckCore).
Item {
  id: deck
  property var engine: null
  property bool full: true
  property bool fill: false
  property bool keys: false

  DeckCore { id: core; engine: deck.engine; keys: deck.keys }
  focus: keys
  Keys.onPressed: function(e) {
    core.key(e)
    if (!e.accepted || e.isAutoRepeat || (e.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) return
    var a = e.key === Qt.Key_Space ? "toggle" : e.text === "n" ? "next" : e.text === "p" ? "previous"
          : e.text === "F" ? "like" : e.text === "V" ? "stage" : ""
    if (a !== "") deck.keyTapped(a)
  }
  signal keyTapped(string a)

  // Fade up whenever the window shows (Widget.qml multiplies its own rest
  // dimming into this), as the other decks do.
  property real appear: 0
  opacity: appear
  NumberAnimation on appear { id: appearAnim; from: 0; to: 1; duration: Tui.STATE; easing.type: Easing.InOutCubic }
  Connections {
    target: deck.Window.window
    function onVisibleChanged() { if (deck.Window.window && deck.Window.window.visible) appearAnim.restart() }
  }
  // the scrub state, for whoever drives the deck from outside (the harness)
  property alias scrubbing: core.scrubbing
  property alias scrubFrac: core.scrubFrac

  // Only the live parts move, and only while the music does.
  readonly property bool anim: core.live && core.playing && !core.gameMode

  // --- the theme, as materials ---------------------------------------------------
  readonly property bool lt: core.light
  readonly property color black: "#000000"
  readonly property color white: "#ffffff"
  // the faceplate: black anodised (dark) or silver (light), tinted by the theme
  readonly property color metal: lt ? Tui.mix(Tui.mix(core.bg, core.fg, 0.22), black, 0.06)
                                    : Tui.mix(Tui.mix(core.bg, black, 0.22), core.fg, 0.05)
  readonly property color wellC: lt ? Tui.mix(core.fg, black, 0.55) : Tui.mix(core.bg, black, 0.72)
  readonly property color ink: lt ? Tui.mix(core.fg, black, 0.35) : Tui.mix(core.fg, metal, 0.10)
  readonly property color inkDim: lt ? Tui.mix(core.fg, black, 0.10) : Tui.mix(core.dim, metal, 0.10)
  readonly property color engrHi: lt ? Qt.rgba(1, 1, 1, 0.55) : Qt.rgba(1, 1, 1, 0.09)
  readonly property color glassC: lt ? Tui.mix(core.fg, black, 0.80) : Tui.mix(core.bg, black, 0.62)
  readonly property color phos: Tui.ensure(core.rawAccent, glassC, 6)
  readonly property color phosHot: Tui.ensure(core.hot, glassC, 4.5)
  readonly property color skirtC: lt ? Tui.mix(core.fg, black, 0.45) : Tui.mix(metal, white, 0.05)
  readonly property color capC: lt ? Tui.mix(Tui.mix(core.bg, core.fg, 0.30), white, 0.10) : Tui.mix(Tui.mix(core.fg, core.bg, 0.55), white, 0.05)
  readonly property color chromeTint: Tui.mix(core.bg, core.fg, 0.5)
  readonly property real bloomAmt: core.bloom

  // --- layout: one scale for the whole unit -----------------------------------------
  // Everything is drawn at `s` (1 = a 400 px wide unit). In a window the unit
  // fills what it is given and scales with it, so a big window is a bigger
  // component, not a small one in space; the spectrum takes the slack, and a
  // short window shrinks the scale so nothing overlaps.
  readonly property real fixedU: 494
  readonly property real specPrefU: 132
  readonly property real specMinU: 54
  readonly property real specMaxU: 200
  readonly property real ws: Math.max(0.5, width / 400)
  readonly property real s: fill ? Math.max(0.5, Math.min(ws, height / (fixedU + specMinU))) : ws
  implicitHeight: Math.round((fixedU + specPrefU) * ws)
  readonly property real devH: fill ? height : implicitHeight
  readonly property real spare: Math.max(specMinU * s, devH - fixedU * s)
  readonly property real specH: Math.round(Math.min(spare, specMaxU * s))
  readonly property real gx: (spare - specH) / 5
  readonly property real mx: Math.round(18 * s + Math.max(0, width - 400 * s) * 0.04)
  readonly property real cw: width - 2 * mx
  function px(v) { return Math.round(v * s) }
  function fpx(v) { return Math.max(7, Math.round(v * s)) }

  readonly property real plateY: Math.round(16 * s + gx * 0.5)
  readonly property real plateH: px(30)
  readonly property real vfdY: Math.round(plateY + plateH + 14 * s + gx)
  readonly property real vfdH: Math.round(154 * s + specH)
  readonly property real midY: Math.round(vfdY + vfdH + 14 * s + gx)
  readonly property real midH: px(156)
  readonly property real keysY: Math.round(midY + midH + 14 * s + gx)

  readonly property real artS: Math.round(Math.min(146 * s, cw * 0.44))
  readonly property real artX: mx + px(7)
  readonly property real artY: Math.round(midY + (midH - artS) * 0.5 - 2 * s)
  readonly property real rDial: px(64)
  readonly property real rKnob: px(44)
  readonly property real knobCx: Math.round((artX + artS + px(8) + width - mx) / 2)
  readonly property real knobCy: Math.round(midY + px(66))

  // the key row: like · prev · play · next · vis, play a little wider
  readonly property var keyW: [1, 1, 1.32, 1, 1]
  readonly property real keyGap: px(6)
  readonly property real slotPad: px(4)
  readonly property real keyUnit: (cw - 2 * slotPad - 4 * keyGap) / 5.32
  function keyX(i) { var x = mx + slotPad; for (var j = 0; j < i; j++) x += keyW[j] * keyUnit + keyGap; return x }
  readonly property real ledY: keysY + px(5)
  readonly property real ledR: Math.max(2, 2.6 * s)
  readonly property real slotY: keysY + px(13)
  readonly property real keyH: px(44)
  readonly property real slotH: keyH + 2 * slotPad

  // --- the faceplate ------------------------------------------------------------------
  ShaderEffect {
    id: face
    width: parent.width; height: deck.devH
    layer.enabled: true
    readonly property size res: Qt.size(width, height)
    readonly property real sc: deck.s
    readonly property real light: deck.lt ? 1 : 0
    readonly property color metal: deck.metal
    readonly property color ink: deck.ink
    readonly property color well: deck.wellC
    readonly property vector4d vfdR: Qt.vector4d(deck.mx - deck.px(4), deck.vfdY - deck.px(4), deck.cw + deck.px(8), deck.vfdH + deck.px(8))
    readonly property vector4d artR: Qt.vector4d(deck.artX, deck.artY, deck.artS, deck.artS)
    readonly property vector4d knobR: Qt.vector4d(deck.knobCx, deck.knobCy, deck.rKnob, deck.rDial)
    readonly property vector4d keysR: Qt.vector4d(deck.mx, deck.slotY, deck.cw, deck.slotH)
    readonly property vector4d plateR: Qt.vector4d(deck.mx, deck.plateY, deck.cw, deck.plateH)
    readonly property vector4d ledA: Qt.vector4d(deck.keyX(0) + deck.keyW[0] * deck.keyUnit / 2, deck.keyX(1) + deck.keyW[1] * deck.keyUnit / 2,
                                                 deck.keyX(2) + deck.keyW[2] * deck.keyUnit / 2, deck.keyX(3) + deck.keyW[3] * deck.keyUnit / 2)
    readonly property vector4d ledB: Qt.vector4d(deck.keyX(4) + deck.keyW[4] * deck.keyUnit / 2, deck.ledY, deck.ledR, 0)
    fragmentShader: Qt.resolvedUrl("shaders/reference_face.frag.qsb")
  }

  // The moving band of light on the brushing. It drifts while the music plays,
  // leans toward the pointer, and lifts a touch on each bar's downbeat.
  property real drift: 0
  NumberAnimation on drift { running: true; paused: !deck.anim; loops: Animation.Infinite; from: 0; to: 2 * Math.PI; duration: 48000 }
  property real lean: hoverAll.hovered ? (hoverAll.point.position.x / Math.max(1, width) - 0.5) : 0
  Behavior on lean { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
  HoverHandler { id: hoverAll }
  readonly property real bandX: width * (0.34 + 0.16 * Math.sin(drift) + 0.35 * lean)
  ShaderEffect {
    width: parent.width; height: deck.devH
    readonly property size res: Qt.size(width, height)
    readonly property real sc: deck.s
    readonly property real light: deck.lt ? 1 : 0
    readonly property real bandX: deck.bandX
    readonly property real bandW: width * 0.20
    readonly property real amt: deck.lt ? 0.9 : 1.0
    readonly property real lift: deck.engine && deck.anim ? (deck.engine.downbeat || 0) * 0.6 : 0
    readonly property color tint: Tui.mix(deck.white, deck.metal, 0.25)
    readonly property vector4d vfdR: face.vfdR
    readonly property vector4d artR: Qt.vector4d(deck.artX - deck.px(8), deck.artY - deck.px(8), deck.artS + deck.px(16), deck.artS + deck.px(16))
    readonly property vector4d knobR: face.knobR
    readonly property vector4d keysR: face.keysR
    readonly property vector4d plateR: face.plateR
    fragmentShader: Qt.resolvedUrl("shaders/reference_sheen.frag.qsb")
  }

  // Engraved, paint-filled type on the metal (the groove's lower lip catches
  // the light, so a hair of highlight sits under each stroke).
  component Engr: Text {
    font.family: core.fontFamily
    color: deck.ink
    style: Text.Raised
    styleColor: deck.engrHi
  }

  // --- the model plate ---------------------------------------------------------------
  Item {
    x: deck.mx; y: deck.plateY; width: deck.cw; height: deck.plateH
    Engr {
      id: brand
      anchors { left: parent.left; leftMargin: deck.px(10); verticalCenter: parent.verticalCenter }
      text: "orpheus"
      font.pixelSize: deck.fpx(15); font.bold: true; font.letterSpacing: 3.2 * deck.s
    }
    // close: an engraved ✕ at the plate's right end (the corner widget has no
    // other way to close)
    Engr {
      id: closeMark
      anchors { right: parent.right; rightMargin: deck.px(10); verticalCenter: parent.verticalCenter }
      text: "✕"
      font.pixelSize: deck.fpx(11)
      color: closeMouse.containsMouse ? Tui.ensure(core.rawAccent, deck.metal, 3) : deck.inkDim
      MouseArea {
        id: closeMouse
        anchors.fill: parent; anchors.margins: -4
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: if (deck.engine) deck.engine.setWidget("enabled", "off")
        TuiTip { text: "close the widget" }
      }
    }
    Rectangle {
      // a hairline engraved between the model name and the close mark
      anchors { right: closeMark.left; rightMargin: deck.px(8); verticalCenter: parent.verticalCenter }
      width: 1; height: Math.round(parent.height * 0.42)
      color: Tui.alpha(deck.ink, 0.28)
      Rectangle { x: 1; width: 1; height: parent.height; color: deck.engrHi }
    }
    Engr {
      id: model
      anchors { right: closeMark.left; rightMargin: deck.px(17); verticalCenter: parent.verticalCenter }
      text: "dr-1 reference"
      font.pixelSize: deck.fpx(10); font.letterSpacing: 1.6 * deck.s
      color: deck.inkDim
    }
    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      x: brand.x + brand.width + deck.px(10)
      width: Math.max(0, model.x - x - deck.px(10)); height: 1
      color: Tui.alpha(deck.ink, 0.28)
      Rectangle { y: 1; width: parent.width; height: 1; color: deck.engrHi }
    }
  }

  // --- the display -----------------------------------------------------------------------
  Item {
    id: vfd
    x: deck.mx; y: deck.vfdY; width: deck.cw; height: deck.vfdH
    readonly property real pad: deck.px(11)
    readonly property real iw: width - 2 * pad
    readonly property real statusY: deck.px(9)
    readonly property real statusH: deck.px(12)
    readonly property real specY: statusY + statusH + deck.px(7)
    readonly property real freqY: specY + deck.specH + deck.px(2)
    readonly property real meterY: specY + deck.specH + deck.px(16)
    readonly property real barH: Math.max(3, deck.px(5))
    readonly property real barGap: Math.max(2, deck.px(4))
    readonly property real labW: deck.px(14)
    readonly property real scaleY: meterY + 2 * barH + barGap + deck.px(2)
    readonly property real secY: scaleY + deck.px(14)
    readonly property real secH: deck.px(11)
    readonly property real dp: Math.max(2, Math.round(2.6 * deck.s))
    readonly property real titleY: secY + secH + deck.px(6)
    readonly property real titleH: dp * 9
    readonly property real timeY: titleY + titleH + deck.px(5)
    readonly property real timeH: Math.max(deck.px(20), height - deck.px(8) - timeY)
    // the figures are seven-segment digits (drawn by the shader): mm:ss
    readonly property real digH: Math.round(Math.min(timeH - deck.px(1), deck.px(19)))
    readonly property real digW: Math.round(digH * 0.54)
    readonly property real digGap: Math.max(2, Math.round(digH * 0.16))
    readonly property real colW: Math.round(digH * 0.30)
    readonly property real clockW: 4 * digW + 2 * digGap + 2 * colW
    readonly property real clockY: Math.round(timeY + (timeH - digH) / 2)
    readonly property real progX: pad + clockW + deck.px(12)
    readonly property real progW: Math.max(10, iw - 2 * clockW - deck.px(24))
    // segment masks (a b c d e f g = bits 0..6) for "mm:ss"; "--:--" without a length
    readonly property var segs: [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]
    function masks(str) {
      var d = str.replace(":", "")
      var m = []
      for (var i = 0; i < 4; i++) { var c = d.charAt(i); m.push(c >= "0" && c <= "9" ? segs[c.charCodeAt(0) - 48] : 0x40) }
      return Qt.vector4d(m[0], m[1], m[2], m[3])
    }

    readonly property color on: "#ff0000"
    readonly property color off: "#00ff00"
    readonly property color leg: "#0000ff"

    // The type, drawn as masks: red lit, green ghost, blue printed legend.
    Item {
      id: vfdType
      anchors.fill: parent
      // status annunciators
      Row {
        x: vfd.pad; y: vfd.statusY; height: vfd.statusH
        spacing: deck.px(10)
        Text { text: "▶ PLAY"; color: core.playing ? vfd.on : vfd.off; font.family: core.fontFamily; font.pixelSize: deck.fpx(10); anchors.verticalCenter: parent.verticalCenter }
        Text { text: "❚❚ PAUSE"; color: !core.playing && !!core.player ? vfd.on : vfd.off; font.family: core.fontFamily; font.pixelSize: deck.fpx(10); anchors.verticalCenter: parent.verticalCenter }
      }
      Row {
        anchors.right: parent.right; anchors.rightMargin: vfd.pad
        y: vfd.statusY; height: vfd.statusH
        spacing: deck.px(10)
        Text { text: core.qualityLabel !== "" ? core.qualityLabel : "──── ──/──"; color: core.qualityLabel !== "" ? vfd.on : vfd.off; font.family: core.fontFamily; font.pixelSize: deck.fpx(10); anchors.verticalCenter: parent.verticalCenter }
        Text { text: core.tempoLabel !== "" ? core.tempoLabel : "─── BPM"; color: core.tempoLabel !== "" ? vfd.on : vfd.off; font.family: core.fontFamily; font.pixelSize: deck.fpx(10); anchors.verticalCenter: parent.verticalCenter }
      }
      // the spectrum's frequency legend, printed on the glass
      Repeater {
        model: ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        Text {
          required property string modelData
          required property int index
          x: Math.round(vfd.pad + (index + 0.5) * vfd.iw / 10 - width / 2)
          y: vfd.freqY
          text: modelData
          color: vfd.leg
          font.family: core.fontFamily; font.pixelSize: deck.fpx(7.5)
        }
      }
      // meter channels and the dB scale
      Text { x: vfd.pad; y: vfd.meterY + vfd.barH / 2 - height / 2; text: "L"; color: vfd.leg; font.family: core.fontFamily; font.pixelSize: deck.fpx(8) }
      Text { x: vfd.pad; y: vfd.meterY + vfd.barH + vfd.barGap + vfd.barH / 2 - height / 2; text: "R"; color: vfd.leg; font.family: core.fontFamily; font.pixelSize: deck.fpx(8) }
      Repeater {
        model: [["-40", 0], ["-20", 0.30], ["-10", 0.50], ["-6", 0.62], ["-3", 0.74], ["0", 0.86], ["+3", 1.0]]
        Text {
          required property var modelData
          readonly property real at: vfd.pad + vfd.labW + modelData[1] * (vfd.iw - vfd.labW)
          x: Math.max(vfd.pad + vfd.labW - 2, Math.min(vfd.width - vfd.pad - width, at - width / 2))
          y: vfd.scaleY
          text: modelData[0]
          color: modelData[1] >= 0.86 ? vfd.on : vfd.leg
          opacity: modelData[1] >= 0.86 ? 0.55 : 1
          font.family: core.fontFamily; font.pixelSize: deck.fpx(7.5)
        }
      }
      Text { x: vfd.pad; y: vfd.scaleY; text: "dB"; color: vfd.leg; font.family: core.fontFamily; font.pixelSize: deck.fpx(7.5) }
      // section annunciators: the engine's reading lights its word
      Item {
        id: secRow
        x: vfd.pad; y: vfd.secY; width: vfd.iw; height: vfd.secH
        readonly property var names: ["intro", "build", "drop", "breakdown", "steady"]
        readonly property string cur: core.sectionLabel.toLowerCase()
        readonly property Item litItem: {
          for (var i = 0; i < secRep.count; i++) { var it = secRep.itemAt(i); if (it && it.isOn) return it }
          return null
        }
        Repeater {
          id: secRep
          model: secRow.names
          Text {
            required property string modelData
            required property int index
            readonly property bool isOn: secRow.cur === modelData
            x: Math.round(index * secRow.width / 5 + (secRow.width / 5 - width) / 2)
            anchors.verticalCenter: parent.verticalCenter
            text: modelData.toUpperCase()
            color: isOn ? vfd.on : vfd.off
            font.family: core.fontFamily; font.pixelSize: deck.fpx(8.5); font.letterSpacing: 0.6 * deck.s
          }
        }
      }
    }
    ShaderEffectSource { id: typeSrc; sourceItem: vfdType; hideSource: true; live: true; smooth: true }

    // The title, rendered once into its own strip; the display samples it on
    // its dot grid and steps it along whole dots.
    readonly property string titleStr: core.player
      ? ((core.title || "unknown track") + (core.artist ? "  •  " + core.artist : "") + (core.album ? "  •  " + core.album : "")).toUpperCase()
      : "NO SOURCE  •  PICK SOMETHING IN THE PLAYER"
    readonly property real titleW: Math.floor(iw / dp) * dp
    readonly property bool overflow: titleText.implicitWidth > titleW - 2 * dp
    Item {
      id: titleStrip
      width: Math.ceil(titleText.implicitWidth + (vfd.overflow ? vfd.dp * 12 : 0))
      height: vfd.titleH
      Text {
        id: titleText
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: Math.round(vfd.dp * 0.3)
        text: vfd.titleStr
        color: "#ff0000"
        font.family: core.fontFamily; font.pixelSize: Math.round(vfd.dp * 9.2); font.bold: true
      }
    }
    ShaderEffectSource { id: titleSrc; sourceItem: titleStrip; hideSource: true; live: true; smooth: true }
    property real scroll: 0
    // A stepper, as the real thing is: whole dots, eight-odd times a second,
    // resting on the start of the line between passes. Stops (and holds its
    // place) while the music does.
    Timer {
      id: marquee
      interval: Math.max(40, Math.round(1000 * vfd.dp / (24 * deck.s)))
      repeat: true
      running: deck.anim && vfd.overflow
      property int hold: Math.round(2200 / interval)
      onTriggered: {
        if (hold > 0) { hold--; return }
        vfd.scroll += vfd.dp
        if (vfd.scroll >= titleStrip.width) { vfd.scroll = 0; hold = Math.round(2200 / interval) }
      }
    }
    Connections { target: core; function onTrackKeyChanged() { vfd.scroll = 0; marquee.hold = Math.round(2200 / marquee.interval) } }

    ShaderEffect {
      id: vfdFx
      anchors.fill: parent
      readonly property size res: Qt.size(width, height)
      readonly property real sc: deck.s
      readonly property real light: deck.lt ? 1 : 0
      readonly property color phos: deck.phos
      readonly property color phosHot: deck.phosHot
      readonly property color glass: deck.glassC
      readonly property var e: deck.engine
      readonly property vector4d z4: Qt.vector4d(0, 0, 0, 0)
      readonly property vector4d b0: e ? e.b0 : z4
      readonly property vector4d b1: e ? e.b1 : z4
      readonly property vector4d b2: e ? e.b2 : z4
      readonly property vector4d b3: e ? e.b3 : z4
      readonly property vector4d b4: e ? e.b4 : z4
      readonly property vector4d b5: e ? e.b5 : z4
      readonly property vector4d b6: e ? e.b6 : z4
      readonly property vector4d b7: e ? e.b7 : z4
      readonly property vector4d p0: e ? e.p0 : z4
      readonly property vector4d p1: e ? e.p1 : z4
      readonly property vector4d p2: e ? e.p2 : z4
      readonly property vector4d p3: e ? e.p3 : z4
      readonly property vector4d p4: e ? e.p4 : z4
      readonly property vector4d p5: e ? e.p5 : z4
      readonly property vector4d p6: e ? e.p6 : z4
      readonly property vector4d p7: e ? e.p7 : z4
      readonly property vector4d specR: Qt.vector4d(vfd.pad, vfd.specY, vfd.iw, deck.specH)
      readonly property vector4d meterR: Qt.vector4d(vfd.pad + vfd.labW, vfd.meterY, vfd.iw - vfd.labW, 2 * vfd.barH + vfd.barGap)
      readonly property vector4d meterBar: Qt.vector4d(vfd.barH, vfd.barGap, 0, 0)
      readonly property vector4d progR: Qt.vector4d(vfd.progX, Math.round(vfd.timeY + vfd.timeH / 2 - deck.px(3.5)), vfd.progW, Math.max(4, deck.px(7)))
      readonly property vector4d titleR: Qt.vector4d(vfd.pad + Math.floor((vfd.iw - vfd.titleW) / 2), vfd.titleY, vfd.titleW, vfd.titleH)
      readonly property vector4d flashR: secRow.litItem ? Qt.vector4d(secRow.x + secRow.litItem.x - 2, secRow.y - 2, secRow.litItem.width + 4, secRow.height + 4) : z4
      readonly property vector4d dims: Qt.vector4d(Math.max(3, Math.round(4 * deck.s)), vfd.dp, Math.max(1, titleStrip.width),
                                                   vfd.overflow ? Math.floor(vfd.scroll / vfd.dp) * vfd.dp : -Math.floor((vfd.titleW - titleText.implicitWidth) / 2 / vfd.dp) * vfd.dp)
      readonly property real frac: core.sfrac
      readonly property real power: core.playing ? 1 : (core.player ? 0.72 : 0.5)
      readonly property real bloomAmt: deck.bloomAmt
      readonly property real flash: core.secFlash
      readonly property real wrapT: vfd.overflow ? 1 : 0
      readonly property real beat: core.beat
      readonly property real bandX: deck.bandX - vfd.x
      property real progHot: progMouse.containsMouse || progMouse.pressed ? 1 : 0
      Behavior on progHot { NumberAnimation { duration: Tui.HOVER } }
      readonly property vector4d clockL: Qt.vector4d(vfd.pad, vfd.clockY, vfd.digW, vfd.digH)
      readonly property vector4d clockR: Qt.vector4d(vfd.width - vfd.pad - vfd.clockW, vfd.clockY, vfd.digW, vfd.digH)
      readonly property vector4d clockG: Qt.vector4d(vfd.digGap, vfd.colW, !!core.player ? 1 : 0, core.length > 0 ? 1 : 0)
      readonly property vector4d segL: vfd.masks(core.clock2(core.shownPos))
      readonly property vector4d segR: core.length > 0 ? vfd.masks(core.clock2(core.length)) : vfd.masks("--:--")
      readonly property var txt: typeSrc
      readonly property var ttl: titleSrc
      fragmentShader: Qt.resolvedUrl("shaders/reference_vfd.frag.qsb")
    }

    // Click or drag the progress bar to seek.
    MouseArea {
      id: progMouse
      x: vfd.progX - deck.px(4); width: vfd.progW + deck.px(8)
      y: vfd.timeY; height: vfd.timeH
      enabled: !!(core.player && core.player.canSeek !== false) && core.length > 0
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      function fracAt(mx) { return Math.max(0, Math.min(1, (mx - deck.px(4)) / Math.max(1, vfd.progW))) }
      onPressed: function(m) { core.beginScrub(fracAt(m.x)) }
      onPositionChanged: function(m) { if (pressed) core.moveScrub(fracAt(m.x)) }
      onReleased: core.commitScrub()
      onCanceled: core.cancelScrub()
      TuiTip {
        follow: true; force: core.scrubbing && progMouse.pressed
        at: Math.max(0, Math.min(progMouse.width, progMouse.mouseX))
        text: core.length > 0 ? core.clock((progMouse.pressed ? core.scrubFrac : progMouse.fracAt(progMouse.mouseX)) * core.length) : ""
      }
    }
  }

  // --- the cover, behind a chrome bezel -------------------------------------------------
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
    x: deck.artX; y: deck.artY; width: deck.artS; height: deck.artS
    clip: true
    // Two layers trade roles (as in the Studio deck): a new cover loads into
    // the hidden one and fades in only once it is ready.
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
    // no cover: an empty bay, the slot marks engraved in its floor
    Rectangle {
      id: bay
      anchors.fill: parent
      readonly property color ink: Tui.ensure(core.dim, color, 3.5)
      color: Tui.mix(deck.wellC, deck.metal, 0.25)
      opacity: art.hasArt ? 0 : 1
      Behavior on opacity { NumberAnimation { duration: Tui.STATE; easing.type: Tui.EASE } }
      Column {
        anchors.centerIn: parent
        spacing: deck.px(4)
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "╱╱╱"; color: bay.ink; font.family: core.fontFamily; font.pixelSize: deck.fpx(14) }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "no cover"; color: bay.ink; font.family: core.fontFamily; font.pixelSize: deck.fpx(9); font.letterSpacing: 1.5 * deck.s }
      }
    }
    ArtLayer { id: layerA; owner: art }
    ArtLayer { id: layerB; owner: art }
    // the glass over it: the bezel's shadow at the top, a soft reflection
    Rectangle {
      anchors.fill: parent; z: 5
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.42) }
        GradientStop { position: 0.07; color: Qt.rgba(0, 0, 0, 0.0) }
        GradientStop { position: 0.92; color: Qt.rgba(0, 0, 0, 0.0) }
        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.18) }
      }
    }
    Rectangle {
      z: 5
      width: parent.width * 1.6; height: parent.height * 0.5
      x: -parent.width * 0.45; y: -parent.height * 0.18
      rotation: -28
      gradient: Gradient {
        GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.0) }
        GradientStop { position: 0.55; color: Qt.rgba(1, 1, 1, 0.075) }
        GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.0) }
      }
    }
    MouseArea {
      anchors.fill: parent; z: 6
      hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onClicked: if (deck.engine) deck.engine.libraryOpen = true
      TuiTip { text: "open the player" }
    }
  }

  // --- the position knob --------------------------------------------------------------
  readonly property real a0: -0.75 * Math.PI
  readonly property real span: 1.5 * Math.PI
  property real knobAngle: a0 + span * core.sfrac
  Behavior on knobAngle { enabled: !core.scrubbing; SmoothedAnimation { velocity: 7 } }
  Engr {
    text: "0:00"
    font.pixelSize: deck.fpx(8)
    color: deck.inkDim
    x: Math.round(deck.knobCx - Math.sin(Math.PI * 0.75) * (deck.rDial + deck.px(2)) - width)
    y: Math.round(deck.knobCy + Math.cos(Math.PI * 0.25) * (deck.rDial + deck.px(2)) - height * 0.2)
  }
  Engr {
    text: core.length > 0 ? core.clock(core.length) : "─:──"
    font.pixelSize: deck.fpx(8)
    color: deck.inkDim
    x: Math.round(deck.knobCx + Math.sin(Math.PI * 0.75) * (deck.rDial + deck.px(2)))
    y: Math.round(deck.knobCy + Math.cos(Math.PI * 0.25) * (deck.rDial + deck.px(2)) - height * 0.2)
  }
  Engr {
    text: "┤ POSITION ├"
    font.pixelSize: deck.fpx(9); font.letterSpacing: 1.2 * deck.s
    anchors.horizontalCenter: knob.horizontalCenter
    y: Math.round(deck.knobCy + deck.rDial + deck.px(5))
  }
  ShaderEffect {
    id: knob
    width: 2 * (deck.rKnob + deck.px(10)); height: width
    x: deck.knobCx - width / 2; y: deck.knobCy - height / 2
    readonly property size res: Qt.size(width, height)
    readonly property real sc: deck.s
    readonly property real light: deck.lt ? 1 : 0
    readonly property real angle: deck.knobAngle
    readonly property real rk: deck.rKnob
    readonly property real glowAmt: !core.player ? 0.25 : core.playing ? 0.85 + 0.15 * core.beat : 0.55
    property real hover: knobMouse.containsMouse ? 1 : 0
    Behavior on hover { NumberAnimation { duration: Tui.HOVER } }
    readonly property real grab: knobMouse.pressed ? 1 : 0
    readonly property real bloomAmt: deck.bloomAmt
    readonly property color skirt: deck.skirtC
    readonly property color cap: deck.capC
    readonly property color phos: deck.phos
    fragmentShader: Qt.resolvedUrl("shaders/reference_knob.frag.qsb")
    MouseArea {
      id: knobMouse
      // the knob, and the dial ring round it (click a tick to jump there)
      x: (knob.width - width) / 2; y: (knob.height - height) / 2
      width: 2 * (deck.rDial + deck.px(4)); height: width
      enabled: !!(core.player && core.player.canSeek !== false) && core.length > 0
      hoverEnabled: true; cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
      property real lastA: 0
      function angAt(m) { return Math.atan2(m.x - width / 2, -(m.y - height / 2)) }
      function fracOfAngle(a) { return (a - deck.a0) / deck.span }
      onPressed: function(m) {
        var r = Math.hypot(m.x - width / 2, m.y - height / 2)
        lastA = angAt(m)
        if (r > deck.rKnob + deck.px(2)) core.beginScrub(fracOfAngle(lastA))
        else core.beginScrub(core.frac)
      }
      onPositionChanged: function(m) {
        if (!pressed) return
        var a = angAt(m), d = a - lastA
        if (d > Math.PI) d -= 2 * Math.PI
        if (d < -Math.PI) d += 2 * Math.PI
        lastA = a
        core.moveScrub(core.scrubFrac + d / deck.span)
      }
      onReleased: core.commitScrub()
      onCanceled: core.cancelScrub()
      property real wheelAcc: 0
      onWheel: function(w) {
        var n = Tui.notches(knobMouse, w.angleDelta.y)
        if (!n || core.length <= 0) return
        core.beginScrub(core.frac + n * 5 / core.length)
        core.commitScrub()
      }
      TuiTip {
        force: core.scrubbing && knobMouse.pressed
        text: core.scrubbing && knobMouse.pressed ? core.clock(core.shownPos) + " / " + core.clock(core.length) : "turn to scrub · scroll ±5 s"
      }
    }
  }

  // --- the transport keys ------------------------------------------------------------------
  Repeater {
    model: [
      { a: "like", leg: "like", k: "F", tip: "like / unlike" },
      { a: "previous", leg: "prev", k: "p", tip: "previous track" },
      { a: "toggle", leg: "play", k: "space", tip: "play / pause" },
      { a: "next", leg: "next", k: "n", tip: "next track" },
      { a: "stage", leg: "vis", k: "V", tip: "open or close the big visualizer" }
    ]
    Item {
      id: keyItem
      required property var modelData
      required property int index
      readonly property string act: modelData.a
      readonly property bool usable: act !== "like" || core.canLike
      x: deck.keyX(index)
      y: deck.keysY
      width: deck.keyW[index] * deck.keyUnit
      height: deck.slotY + deck.slotPad + deck.keyH + deck.px(6) - deck.keysY
      property bool tapped: false
      Timer { id: tapT; interval: 140; onTriggered: keyItem.tapped = false }
      Connections { target: deck; function onKeyTapped(a) { if (a === keyItem.act) { keyItem.tapped = true; tapT.restart() } } }
      property real press: km.pressed || tapped ? 1 : 0
      Behavior on press { NumberAnimation { duration: keyItem.press > 0.5 ? 140 : 50; easing.type: Easing.OutCubic } }
      property real hov: km.containsMouse ? 1 : 0
      Behavior on hov { NumberAnimation { duration: Tui.HOVER } }
      readonly property real ledOn: act === "toggle" ? (core.playing ? 1 : 0)
                                  : act === "like" ? (core.liked ? 1 : 0)
                                  : act === "stage" ? (deck.engine && deck.engine.open ? 1 : 0)
                                  : (km.pressed || tapped ? 1 : 0)
      readonly property real keyTop: deck.slotY + deck.slotPad - deck.keysY
      ShaderEffect {
        id: keyFx
        anchors.fill: parent
        readonly property size res: Qt.size(width, height)
        readonly property real sc: deck.s
        readonly property real light: deck.lt ? 1 : 0
        readonly property real press: keyItem.press
        readonly property real hover: keyItem.hov
        readonly property real led: keyItem.ledOn
        readonly property real bloomAmt: deck.bloomAmt
        readonly property real keyTop: keyItem.keyTop
        readonly property real keyH: deck.keyH
        readonly property real travel: Math.max(2, deck.px(3))
        readonly property real ledR: deck.ledR
        readonly property vector4d ledC: Qt.vector4d(width / 2, deck.ledY - deck.keysY, 0, 0)
        readonly property color ledCol: keyItem.act === "like" ? Tui.ensure(core.hot, deck.metal, 2) : Tui.ensure(core.rawAccent, deck.metal, 2)
        readonly property color tint: deck.chromeTint
        fragmentShader: Qt.resolvedUrl("shaders/reference_key.frag.qsb")
      }
      // the legend on the key, engraved into the chrome
      Text {
        id: glyph
        anchors.horizontalCenter: parent.horizontalCenter
        y: keyItem.keyTop + keyFx.travel * keyItem.press + Math.round(deck.keyH * 0.36 - height / 2)
        text: keyItem.act === "toggle" ? (core.playing ? "󰏤" : "󰐊")
            : keyItem.act === "like" ? (core.liked ? "󰋑" : "󰋕")
            : keyItem.act === "previous" ? "󰒮" : keyItem.act === "next" ? "󰒭" : "󰺢"
        font.family: core.fontFamily; font.pixelSize: deck.fpx(16)
        color: Qt.rgba(0, 0, 0, keyItem.usable ? 0.72 : 0.3)
        style: Text.Raised; styleColor: Qt.rgba(1, 1, 1, 0.45)
      }
      Text {
        visible: deck.keys
        anchors.right: parent.right; anchors.rightMargin: deck.px(5)
        y: keyItem.keyTop + keyFx.travel * keyItem.press + deck.px(3)
        text: keyItem.modelData.k
        font.family: core.fontFamily; font.pixelSize: deck.fpx(8)
        color: Qt.rgba(0, 0, 0, 0.5)
      }
      Engr {
        anchors.horizontalCenter: parent.horizontalCenter
        y: deck.slotY + deck.slotH + deck.px(4) - deck.keysY
        text: keyItem.modelData.leg
        font.pixelSize: deck.fpx(9); font.letterSpacing: 1.2 * deck.s
        color: keyItem.usable ? deck.ink : deck.inkDim
      }
      MouseArea {
        id: km
        x: 0; y: keyItem.keyTop; width: parent.width; height: deck.keyH
        hoverEnabled: true; cursorShape: Qt.PointingHandCursor
        onClicked: core.act(keyItem.act)
        TuiTip {
          text: keyItem.act === "toggle" ? (core.playing ? "pause" : "play")
              : keyItem.act === "like" ? (core.liked ? "unlike" : "like") : keyItem.modelData.tip
          key: deck.keys ? keyItem.modelData.k : ""
        }
      }
    }
  }
}
