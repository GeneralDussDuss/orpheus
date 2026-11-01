import QtQuick
import QtQuick.Effects
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// Ambient: the visualizer, small, slow, blurred and dim, behind a window's
// text, so the page moves a little with the music without ever competing
// with what is written on it.
//
// Cheap by construction. The Viz shades a plane 1/8 of the window across (1/64
// of the pixels), with no bloom, trails or drop effects, and it does not see
// the engine directly: a stand-in copies the engine's uniforms 20 times a
// second, so it redraws (and the blur re-runs) at 20 fps, not every frame. Its
// clock runs at 0.6x, which reads as slow light, not lag. While the window is
// hidden or minimized, a game has the screen, or nothing is sounding, the
// copy stops and the picture holds: nothing in here changes, so nothing draws.
// Off, or on a light theme, nothing is loaded at all.
Item {
  id: amb

  property var engine: null
  property string styleName: "prism"
  property string level: "subtle"     // off | subtle | vivid

  // What the caller may lean on to keep text readable: the strongest the
  // light gets, as a fraction of the visualizer's own colours.
  readonly property bool on: !!engine && level !== "off" && !engine.lightTheme
  readonly property real strength: !on ? 0 : level === "vivid" ? 0.5 : 0.28

  readonly property bool shown: !!amb.Window.window && amb.Window.window.visible
                                && amb.Window.window.visibility !== Window.Minimized
  readonly property bool running: on && shown && !engine.gameMode
                                  && (engine.playing || engine.energy > 0.001)

  Loader {
    anchors.fill: parent
    active: amb.on
    sourceComponent: Item {
      // The engine as the Viz reads it, frozen between copies.
      QtObject {
        id: feed
        property real time: 0
        property vector4d b0; property vector4d b1; property vector4d b2; property vector4d b3
        property vector4d b4; property vector4d b5; property vector4d b6; property vector4d b7
        property vector4d p0; property vector4d p1; property vector4d p2; property vector4d p3
        property vector4d p4; property vector4d p5; property vector4d p6; property vector4d p7
        property color c1: "white"; property color c2: "white"; property color c3: "white"
        property color bg: "black"; property color fg: "white"
        property real bass; property real energy; property real beat; property real travel
        property real paceBpm: 120
        property real kick; property real snap; property real swell; property real kicks
        property vector4d kickAge: Qt.vector4d(8, 8, 8, 0)
        property real beatPhase; property real barPhase; property real downbeat; property real beatConfidence
        property real build; property real drop; property real sectionCode: 4
        property real anticipate; property real dropMapped
        readonly property bool lightTheme: false
        readonly property string bloom: "off"
        readonly property string feedback: "off"
        readonly property bool dropFx: false
        readonly property int fps: 20
      }
      readonly property var keys: ["b0", "b1", "b2", "b3", "b4", "b5", "b6", "b7", "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7",
                                   "c1", "c2", "c3", "bg", "fg", "bass", "energy", "beat", "paceBpm", "kick", "snap", "swell",
                                   "kicks", "kickAge", "beatPhase", "barPhase", "downbeat", "beatConfidence", "build", "drop", "sectionCode"]
      function copy() {
        var e = amb.engine
        if (!e) return
        for (var i = 0; i < keys.length; i++) feed[keys[i]] = e[keys[i]]
        // The drop map's two (an engine without them reads as no map).
        feed.anticipate = e.anticipate || 0
        feed.dropMapped = e.dropMapped || 0
        feed.time = e.time * 0.6
        feed.travel = e.travel * 0.6
      }
      Component.onCompleted: copy()
      Timer {
        interval: 50
        repeat: true
        running: amb.running
        triggeredOnStart: true
        onTriggered: parent.copy()
      }
      // The palette follows a theme glide even while the music is stopped.
      Connections {
        target: amb.running ? null : amb.engine
        function onC1Changed() { feed.c1 = amb.engine.c1 }
        function onC2Changed() { feed.c2 = amb.engine.c2 }
        function onC3Changed() { feed.c3 = amb.engine.c3 }
        function onBgChanged() { feed.bg = amb.engine.bg }
        function onFgChanged() { feed.fg = amb.engine.fg }
      }

      Viz {
        id: small
        visible: false        // drawn only through the blur below
        width: Math.max(64, Math.round(amb.width / 8))
        height: Math.max(48, Math.round(amb.height / 8))
        engine: feed
        styleName: amb.styleName
      }
      MultiEffect {
        source: small
        anchors.fill: parent
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 1
        blurMax: 24
        blurMultiplier: 0.5
        saturation: amb.level === "vivid" ? 0 : -0.25
        opacity: amb.strength
        Behavior on opacity { NumberAnimation { duration: Tui.PAGE; easing.type: Easing.InOutCubic } }
      }
    }
  }
}
