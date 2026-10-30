import QtQuick
import QtQuick.Window
import qs.Commons
import "../../.."
import "../../../Tui.js" as Tui

// The in-game HUD (Windows desktop app only): a small now-playing card that
// slides in over a game for a few seconds on a track change, or on demand
// (hotkey hud:show). It must never get in the game's way, so the window is
// see-through to the mouse, never takes focus and has no taskbar entry; hud.py
// places it in a corner of the game's monitor, adds WS_EX_NOACTIVATE |
// WS_EX_TRANSPARENT | WS_EX_LAYERED | WS_EX_TOOLWINDOW and shows it with
// SW_SHOWNOACTIVATE. Between appearances the window is hidden, not just
// transparent: an idle topmost window over a game can still cost it the
// direct-flip fast path.
Window {
  id: hud

  property var engine: null
  property bool shown: false               // hud.py flips this; the card slides
  property string corner: "top-left"
  readonly property bool atLeft: corner.indexOf("left") >= 0
  readonly property var player: engine ? engine.player : null

  readonly property int pad: 14            // room for the shadow and the glow
  readonly property int cardW: 380
  readonly property int cardH: 92

  title: "Orpheus HUD"
  color: "transparent"
  flags: Qt.FramelessWindowHint | Qt.Tool | Qt.WindowStaysOnTopHint
         | Qt.WindowTransparentForInput | Qt.WindowDoesNotAcceptFocus
  width: cardW + pad * 2
  height: cardH + pad * 2
  visible: false
  transientParent: null

  // While the card is out it wants live levels: count as a visualizer on screen.
  property bool counted: false
  onShownChanged: setCounted(shown)
  function setCounted(on) {
    if (!engine || on === counted) return
    counted = on
    engine.barWidgets += on ? 1 : -1
  }
  Component.onDestruction: setCounted(false)

  readonly property color bg: Qt.rgba(Color.background.r, Color.background.g, Color.background.b, 1)
  readonly property color fg: Color.foreground
  readonly property color c1: engine ? engine.c1 : Color.accent
  readonly property color c2: engine ? engine.c2 : Color.accent
  readonly property color c3: engine ? engine.c3 : Color.foreground
  readonly property real glow: engine ? Tui.bloom(engine) : 0

  Item {
    id: slot
    x: hud.pad; y: hud.pad
    width: hud.cardW; height: hud.cardH
    clip: false

    Rectangle {
      id: card
      width: parent.width; height: parent.height
      radius: 10
      color: Qt.rgba(hud.bg.r, hud.bg.g, hud.bg.b, 0.86)
      border.width: 1
      border.color: Qt.rgba(hud.c1.r, hud.c1.g, hud.c1.b, 0.55)
      x: hud.shown ? 0 : (hud.atLeft ? -1 : 1) * (hud.cardW * 0.6)
      opacity: hud.shown ? 1 : 0
      Behavior on x { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
      Behavior on opacity { NumberAnimation { duration: 220 } }

      Rectangle {   // the cover, or a block of the accent while it loads
        id: coverBox
        x: 10; y: 10
        width: card.height - 20; height: width
        radius: 6
        color: Qt.rgba(hud.c1.r, hud.c1.g, hud.c1.b, 0.25)
        clip: true
        Image {
          anchors.fill: parent
          source: hud.player ? hud.player.trackArtUrl : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: true
          sourceSize.width: 160; sourceSize.height: 160
        }
      }

      Column {
        x: coverBox.x + coverBox.width + 12
        y: 12
        width: card.width - x - 12
        spacing: 2

        GlowText {
          width: parent.width
          text: hud.player ? hud.player.trackTitle : ""
          color: Tui.ensure(hud.c1, hud.bg, 4.5)
          font.family: Style.font.family
          font.pixelSize: 15
          font.bold: true
          elide: Text.ElideRight
          glow: hud.shown ? hud.glow * 0.7 : 0
          glowColor: hud.c1
        }
        Text {
          width: parent.width
          text: hud.player ? hud.player.trackArtist : ""
          color: Tui.muted(hud.fg, hud.bg, 4.5)
          font.family: Style.font.family
          font.pixelSize: 12
          elide: Text.ElideRight
        }
      }

      // A mini spectrum in the theme's three colours, on the engine's levels.
      Row {
        id: bars
        readonly property int n: 28
        x: coverBox.x + coverBox.width + 12
        width: card.width - x - 12
        height: 26
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 10
        spacing: 2
        Repeater {
          model: bars.n
          Rectangle {
            readonly property real t: index / (bars.n - 1)
            readonly property real lv: {
              if (!hud.shown || !hud.engine || !hud.engine.levels) return 0
              var lv = hud.engine.levels, i = Math.floor(t * (lv.length - 1))
              return Math.max(0, Math.min(1, lv[i] || 0))
            }
            width: (bars.width - bars.spacing * (bars.n - 1)) / bars.n
            height: Math.max(2, bars.height * lv)
            anchors.bottom: parent.bottom
            radius: 1
            color: t < 0.5 ? Tui.mix(hud.c1, hud.c2, t * 2) : Tui.mix(hud.c2, hud.c3, (t - 0.5) * 2)
            opacity: 0.55 + 0.45 * lv
          }
        }
      }
    }
  }
}
