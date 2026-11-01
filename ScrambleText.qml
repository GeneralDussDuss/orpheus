import QtQuick
import QtQuick.Window
import qs.Commons
import "Tui.js" as Tui

// Text that decodes into a new value, like a terminal: on a change every
// character churns through noise glyphs, then they settle left to right into
// the new string (~0.5 s). One glyph per character and spaces kept, so in the
// monospace face the line never changes width while it resolves, and elision
// lands where it will end up.
//
// Set `target`, not `text`. Only a real change decodes: the first value, an
// equal value written again, an empty one, or anything while `animate` is off
// or the window is hidden lands at once. With `key` set (say a track id) only
// a change of key decodes, so a re-render that rewrites the same title, or a
// placeholder, never scrambles.
//
// A GlowText, so callers keep the accent halo where they had one.
GlowText {
  id: s

  property string target: ""
  property var key: undefined
  property bool animate: true
  property int duration: Tui.DECODE

  property real progress: 1
  property int seed: 0
  property var lastKey: undefined
  property string lastTarget: ""
  property bool born: false

  readonly property bool live: animate && !!s.Window.window && s.Window.window.visible
                               && s.Window.window.visibility !== Window.Minimized

  // The glyph set, the noise beat and the wide-char guard live in Tui.decode
  // (shared with TuiBox titles and the boot screen).
  function decoded(t, p, sd) { return Tui.decode(t, p, sd) }

  text: progress >= 1 ? target : decoded(target, progress, seed)

  // key and target usually change in the same binding pass, in either order:
  // decide once both have landed.
  onTargetChanged: Qt.callLater(settle)
  onKeyChanged: Qt.callLater(settle)
  Component.onCompleted: { lastKey = key; lastTarget = target; born = true }
  function settle() {
    if (!born) return
    var changed = key !== undefined ? key !== lastKey : target !== lastTarget
    lastKey = key
    var was = lastTarget
    lastTarget = target
    if (!changed || target === "" || target === was || !live) { anim.stop(); progress = 1; return }
    anim.restart()
  }
  NumberAnimation { id: anim; target: s; property: "progress"; from: 0; to: 1; duration: s.duration; easing.type: Easing.Linear }
  // The noise churns at ~22 Hz, not every frame: it reads as decoding, not static.
  onProgressChanged: if (progress < 1) seed = Math.floor(progress * duration / 45)
  onLiveChanged: if (!live && anim.running) { anim.stop(); progress = 1 }
}
