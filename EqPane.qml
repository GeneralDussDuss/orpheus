import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// The equalizer, drawn as a column of blocks per band.
//
// Keyboard first, like the rest of the window: h/l pick a band, j/k move it.
// The daemon is the authority on the curve, but typing must feel immediate, so
// edits land in `gains` straight away and are posted on a short debounce. Two
// reasons for the debounce rather than a post per keystroke: changing a gain
// rebuilds mpv's whole filter graph (af-command cannot reach into a lavfi graph
// on mpv 0.41), and holding a key down would otherwise queue dozens of them.
Rectangle {
  id: pane

  property var host: null
  readonly property var api: host ? host.api : null

  // Color.background carries alpha; binding it straight through makes the pane
  // translucent and whatever is behind the window reads through the bars.
  // Color.background can arrive as a string, and `.r`/`.g`/`.b` on a string are
  // undefined, so Qt.rgba() built from them yields a transparent fill and the
  // window behind reads straight through the pane. Declaring it as a `color`
  // property forces the coercion first, after which the components are real.
  readonly property color base: Color.background
  color: Qt.rgba(base.r, base.g, base.b, 1)
  focus: true

  // Declared before everything else, so the band hit-targets below sit above it.
  // Its job is to put keyboard focus back on the pane: without it a stray click
  // elsewhere left the keys going to the list underneath, which looks exactly
  // like a key that does not work.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: function(m) {
      pane.forceActiveFocus()
      if (m.button === Qt.RightButton) pane.toggleBypass()
      m.accepted = true
    }
  }

  // ---- model -------------------------------------------------------------

  property var bands: [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
  property var gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  property var presets: []
  property real limit: 12
  property real step: 0.5
  property bool eqOn: false
  property string presetId: ""
  property real preampShown: 0
  property int sel: 0
  property bool loaded: false
  property string note: ""

  readonly property string presetName: {
    for (var i = 0; i < presets.length; i++)
      if (presets[i].id === presetId) return presets[i].name
    return presetId ? presetId : "custom"
  }

  function load() {
    if (!api) return
    api.get("/eq", function(ok, d) {
      if (!ok || !d || !d.bands) return
      pane.bands = d.bands
      pane.limit = d.limit
      pane.step = d.step
      pane.presets = d.presets || []
      pane.apply(d.state)
      pane.loaded = true
    })
  }

  function apply(s) {
    if (!s) return
    if (s.gains) gains = s.gains
    eqOn = !!s.enabled
    presetId = s.preset || ""
    preampShown = s.preampEffective || 0
  }

  // ---- editing -----------------------------------------------------------

  Timer {
    id: push
    interval: 120
    onTriggered: {
      if (!pane.api) return
      pane.api.post("/eq", { gains: pane.gains, enabled: pane.eqOn },
                    function(ok, d) { if (ok) pane.apply(d) })
    }
  }

  function nudge(delta) {
    var g = gains.slice()
    var v = Math.max(-limit, Math.min(limit, g[sel] + delta))
    g[sel] = Math.round(v / step) * step
    gains = g
    presetId = ""
    // Touching a band implies you want to hear it.
    if (!eqOn && !flat()) eqOn = true
    preampShown = autoPreamp()
    push.restart()
  }

  function flat() {
    for (var i = 0; i < gains.length; i++) if (Math.abs(gains[i]) > 0.001) return false
    return true
  }

  // Mirrors the daemon's rule so the number does not lag the bars. The daemon
  // still computes the real one; this is only what we draw.
  function autoPreamp() {
    var peak = 0
    for (var i = 0; i < gains.length; i++) peak = Math.max(peak, gains[i])
    return -Math.round(peak * 2) / 2
  }

  function resetBand() {
    var g = gains.slice(); g[sel] = 0; gains = g
    presetId = ""; preampShown = autoPreamp(); push.restart()
  }

  function resetAll() {
    var g = []
    for (var i = 0; i < bands.length; i++) g.push(0)
    gains = g; presetId = "flat"; preampShown = 0; push.restart()
  }

  function cyclePreset(dir) {
    if (!presets.length) return
    var i = -1
    for (var k = 0; k < presets.length; k++) if (presets[k].id === presetId) { i = k; break }
    i = (i + dir + presets.length * 2) % presets.length
    var p = presets[i]
    note = p.note || ""
    if (!api) return
    api.post("/eq", { preset: p.id, enabled: true }, function(ok, d) { if (ok) pane.apply(d) })
  }

  // Ask for the opposite of what we are showing and let the reply set it. Doing
  // the flip locally first meant a disagreement with the daemon could leave the
  // two fighting, with the key appearing to do nothing.
  function toggleBypass() {
    if (!api) return
    api.post("/eq", { enabled: !eqOn }, function(ok, d) { if (ok) pane.apply(d) })
  }

  function setGainAt(i, frac) {
    var v = (1 - frac * 2) * limit                   // 0 at the top -> +limit
    var g = gains.slice()
    g[i] = Math.max(-limit, Math.min(limit, Math.round(v / step) * step))
    gains = g
    sel = i
    presetId = ""
    if (!eqOn && !flat()) eqOn = true
    preampShown = autoPreamp()
    push.restart()
  }

  Component.onCompleted: load()

  // ---- geometry ----------------------------------------------------------

  readonly property int rows: 21                      // odd, so one row is exactly 0 dB
  readonly property int mid: Math.floor(rows / 2)
  readonly property real perRow: limit / mid          // dB covered by one row
  readonly property real colW: host ? host.cw * 5 : 40
  // the dB scale down the left; the label rows below reuse it so the bars
  // line up with their own frequencies
  readonly property real gutter: host ? host.cw * 5 : 40

  function column(i) {
    var g = gains[i] || 0
    var out = []
    for (var r = 0; r < rows; r++) {
      var db = (mid - r) * perRow
      if (r === mid) out.push("─────")
      else if (g > 0 && db > 0 && db <= g + 0.001) out.push(" ███ ")
      else if (g < 0 && db < 0 && db >= g - 0.001) out.push(" ███ ")
      else out.push("  ·  ")
    }
    return out.join("\n")
  }

  function label(hz) {
    return hz >= 1000 ? (hz / 1000) + "k" : String(hz)
  }

  // ---- keys --------------------------------------------------------------

  Keys.onPressed: function(e) {
    var t = e.text, k = e.key
    if (k === Qt.Key_Left || t === "h") { sel = (sel + bands.length - 1) % bands.length; e.accepted = true }
    else if (k === Qt.Key_Right || t === "l") { sel = (sel + 1) % bands.length; e.accepted = true }
    else if (k === Qt.Key_Up || t === "j") { nudge(step); e.accepted = true }
    else if (k === Qt.Key_Down || t === "k") { nudge(-step); e.accepted = true }
    else if (t === "J") { nudge(step * 6); e.accepted = true }
    else if (t === "K") { nudge(-step * 6); e.accepted = true }
    else if (t === "0") { resetBand(); e.accepted = true }
    else if (t === "z") { resetAll(); e.accepted = true }
    else if (t === "p") { cyclePreset(1); e.accepted = true }
    else if (t === "P") { cyclePreset(-1); e.accepted = true }
    else if (t === "b") { toggleBypass(); e.accepted = true }
    else if (k === Qt.Key_Escape || t === "q") { e.accepted = host.handleKey(e) }
    else e.accepted = host.handleKey(e)
  }

  // ---- drawing -----------------------------------------------------------

  Column {
    anchors.centerIn: parent
    spacing: host ? host.ch * 0.5 : 8

    // ╱╱ EQUALIZER ───────────
    Text {
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> EQUALIZER '
            + '<font color="' + Tui.hex(Tui.mix(host.dim, host.bg, 0.35)) + '">' + "─".repeat(60) + '</font>'
      width: pane.colW * pane.bands.length
      clip: true
      font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
      color: host.dim
    }

    // state line
    Text {
      textFormat: Text.StyledText
      text: {
        var on = pane.eqOn && !pane.flat()
        var dot = on ? '<font color="' + Tui.hex(host.accentText) + '">●</font>'
                     : '<font color="' + Tui.hex(host.dim) + '">○</font>'
        return dot + '  ' + (on ? "active" : "bypassed")
             + '   <font color="' + Tui.hex(host.dim) + '">preset</font> ' + Tui.esc(pane.presetName)
             + '   <font color="' + Tui.hex(host.dim) + '">preamp</font> '
             + (pane.preampShown <= -0.05 ? pane.preampShown.toFixed(1) : "0.0") + ' dB'
      }
      font.family: host.family; font.pixelSize: Style.font.body
      color: host.fg
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { pane.forceActiveFocus(); pane.toggleBypass() }
      }
    }

    Item { width: 1; height: host.ch * 0.4 }

    // the bars, with a dB scale down the left
    Row {
      spacing: 0

      Column {
        spacing: 0
        Repeater {
          model: pane.rows
          Text {
            required property int index
            // only label the top, middle and bottom of the scale
            text: index === 0 ? "+" + pane.limit.toFixed(0)
                : index === pane.mid ? "0"
                : index === pane.rows - 1 ? "-" + pane.limit.toFixed(0) : ""
            width: pane.gutter
            rightPadding: host.cw
            horizontalAlignment: Text.AlignRight
            font.family: host.family; font.pixelSize: Style.font.caption
            color: host.dim
          }
        }
      }

      Repeater {
        model: pane.bands.length
        Item {
          required property int index
          width: pane.colW
          height: bar.implicitHeight
          Text {
            id: bar
            anchors.fill: parent
            readonly property bool isSel: parent.index === pane.sel
            text: pane.column(parent.index)
            horizontalAlignment: Text.AlignHCenter
            font.family: host.family; font.pixelSize: Style.font.caption
            color: !pane.eqOn || pane.flat() ? host.dim
                 : isSel ? host.accentText
                 : Tui.mix(host.fg, host.bg, 0.25)
          }
          // The volume meter below is clickable and scrollable; an equalizer that
          // only answered the keyboard would teach two different lessons in one
          // window.
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.SizeVerCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            onPressed: function(m) {
              pane.forceActiveFocus()
              if (m.button === Qt.MiddleButton) { pane.sel = parent.index; pane.resetBand() }
              else pane.setGainAt(parent.index, m.y / height)
            }
            onPositionChanged: function(m) {
              if (pressed) pane.setGainAt(parent.index, Math.max(0, Math.min(1, m.y / height)))
            }
            onWheel: function(w) {
              pane.sel = parent.index
              pane.nudge(w.angleDelta.y > 0 ? pane.step : -pane.step)
            }
          }
        }
      }
    }

    // frequency labels, cursor under the selected band
    Row {
      spacing: 0
      Item { width: pane.gutter; height: 1 }
      Repeater {
        model: pane.bands.length
        Text {
          required property int index
          text: pane.label(pane.bands[index])
          width: pane.colW
          horizontalAlignment: Text.AlignHCenter
          font.family: host.family; font.pixelSize: Style.font.caption
          color: index === pane.sel ? host.accentText : host.dim
        }
      }
    }

    // gain readout per band
    Row {
      spacing: 0
      Item { width: pane.gutter; height: 1 }
      Repeater {
        model: pane.bands.length
        Text {
          required property int index
          readonly property real g: pane.gains[index] || 0
          text: g === 0 ? "·" : (g > 0 ? "+" : "") + g.toFixed(1)
          width: pane.colW
          horizontalAlignment: Text.AlignHCenter
          font.family: host.family; font.pixelSize: Style.font.caption
          color: index === pane.sel ? host.accentText
               : g === 0 ? host.dim : Tui.mix(host.fg, host.bg, 0.25)
        }
      }
    }

    Item { width: 1; height: host.ch * 0.4 }

    Text {
      visible: pane.note !== ""
      text: pane.note
      width: pane.colW * pane.bands.length
      wrapMode: Text.WordWrap
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }

    Text {
      text: "[h/l] band   [j/k] ±" + pane.step.toFixed(1) + "   [J/K] coarse   "
            + "[0] zero band   [z] zero all   [p] preset   [b] bypass   [esc] back"
            + "      drag or scroll a band · right click to bypass"
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }

    Text {
      visible: !pane.loaded
      text: "waiting for the player service…"
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }
  }
}
