import QtQuick
import QtQuick.Window
import qs.Commons

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
  property int duration: 520

  property real progress: 1
  property int seed: 0
  property var lastKey: undefined
  property string lastTarget: ""
  property bool born: false

  // ASCII and the CP437 shades: in every monospace face, one cell each.
  readonly property string glyphs: "!<>-_\\/[]{}=+*^?#%&$@01░▒▓"
  readonly property bool live: animate && !!s.Window.window && s.Window.window.visible
                               && s.Window.window.visibility !== Window.Minimized

  function wide(code) {
    // CJK, Hangul, fullwidth forms, emoji: two cells, left as they are
    return code >= 0x1100 && (code <= 0x115f || (code >= 0x2e80 && code <= 0xa4cf) || (code >= 0xac00 && code <= 0xd7a3)
                              || (code >= 0xf900 && code <= 0xfaff) || (code >= 0xfe30 && code <= 0xfe4f)
                              || (code >= 0xff00 && code <= 0xff60) || (code >= 0xffe0 && code <= 0xffe6) || code >= 0x1f000)
  }
  function decoded(t, p, sd) {
    if (p >= 1) return t
    // A short all-noise beat first, then the settle sweeps left to right.
    var settled = Math.floor(t.length * Math.max(0, (p - 0.18) / 0.82))
    var out = t.slice(0, settled)
    for (var i = settled; i < t.length; i++) {
      var c = t.charAt(i), code = t.charCodeAt(i)
      if (c === " " || wide(code) || (code >= 0xd800 && code <= 0xdfff)) { out += c; continue }
      out += glyphs.charAt(Math.floor(Math.abs(Math.sin((i + 1) * 12.9898 + sd * 78.233) * 43758.5453)) % glyphs.length)
    }
    return out
  }

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
