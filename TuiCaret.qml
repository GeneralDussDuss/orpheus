import QtQuick
import "Tui.js" as Tui

// The text cursor: one translucent accent cell that blinks on the shared clock (no Timer
// of its own ticks), and holds solid while you type so it never blinks out
// under your fingers.
//
//   TextInput { cursorDelegate: TuiCaret { host: win } }
//
// `host` lends `colW` (or `cw`), `accent` and `clock`; without a clock it
// just stays lit.
Rectangle {
  id: caret

  property var host: null
  property bool typing: false

  readonly property real clock: host && host.clock !== undefined ? host.clock : -1
  width: Math.max(2, host ? (host.colW || host.cw || 8) : 8)
  color: host && host.accent !== undefined ? host.accent : "white"
  // A cursorDelegate draws over the glyphs: light enough that the character
  // under a mid-text cursor stays readable, the way a terminal's block shows it.
  opacity: clock < 0 || typing || Math.floor(clock * 2) % 2 === 0 ? 0.45 : 0.18

  // The delegate moves with every keystroke: that is the typing signal.
  onXChanged: { typing = true; hold.restart() }
  Timer { id: hold; interval: 500; onTriggered: caret.typing = false }
}
