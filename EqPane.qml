import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui
import "Eq.js" as Eq

// The equalizer, drawn as a column of blocks per band.
//
// Keyboard first, like the rest of the window: h/l pick a band, k/j raise and
// lower it (up is up, as in every list in the player).
// The daemon is the authority on the curve, but typing must feel immediate, so
// edits land in `gains` straight away and are posted on a short debounce. Two
// reasons for the debounce rather than a post per keystroke: changing a gain
// rebuilds mpv's whole filter graph (af-command cannot reach into a lavfi graph
// on mpv 0.41), and holding a key down would otherwise queue dozens of them.
//
// Under the bars sits an optional headphone correction from AutoEq: `A` opens
// a picker that searches AutoEq's index on the daemon, ⏎ applies one, `x`
// switches it on and off and `X` forgets it. The correction plays in front of
// the ten bands in the same mpv graph, and its curve is drawn beneath them on
// the same dB scale, so the bars read as "on top of my headphones".
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
  // like a key that does not work. In the picker the prompt keeps the keys.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onPressed: function(m) {
      if (pane.picking) { aeInput.forceActiveFocus(); m.accepted = true; return }
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
  property bool preampManual: false
  property int sel: 0
  property bool loaded: false
  property string note: ""

  // the headphone correction: the full {path, name, source, rig, form, preamp,
  // filters} from the daemon, and whether it is switched on
  property var autoeq: null
  property bool autoeqOn: false
  property string aeAttribution: ""
  readonly property bool aeLive: autoeqOn && autoeq !== null

  // the picker
  property bool picking: false
  property var aeResults: []
  property int aeCur: 0
  property int aeTop: 0
  property string aeState: ""        // ready | fetching | offline
  property string aeMsg: ""          // offline explanation
  property string aeErr: ""          // a failed apply, in the accent
  property string aeBusy: ""         // the name being downloaded
  property bool aeRefreshing: false
  property bool aeWantApply: false   // ⏎ landed before the newest search did
  property int aeCount: 0
  property int aeAge: 0
  property int aeSeq: 0
  property int aeLanded: 0           // the newest search whose reply (or failure) is in
  readonly property int aeVis: 14

  // less headroom than the biggest boost needs
  readonly property bool clipping: preampShown > autoPre + 0.01
  // With a correction live this is a 250-point response of the whole cascade:
  // a binding, so it is worked out once per change and not by every reader.
  readonly property real autoPre: Eq.autoPreamp(gains, autoeq ? autoeq.filters : [], aeLive)

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
      pane.aeAttribution = d.autoeqAttribution || ""
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
    preampManual = s.preamp !== null && s.preamp !== undefined
    // Replies to /eq and /autoeq/* carry the full correction. A summary (no
    // filters, the /status form) says nothing new about the curve, so it only
    // ever clears one, never replaces it.
    if (!s.autoeq) autoeq = null
    else if (s.autoeq.filters) autoeq = s.autoeq
    autoeqOn = !!s.autoeqOn
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
    if (!preampManual) preampShown = autoPreamp()
    push.restart()
  }

  function flat() {
    for (var i = 0; i < gains.length; i++) if (Math.abs(gains[i]) > 0.001) return false
    return true
  }

  // Mirrors the daemon's rule so the number does not lag the bars. The daemon
  // still computes the real one; this is only what we draw. With a correction
  // live it is the measured peak of the whole cascade (Eq.js, tested against
  // eq.py), otherwise the biggest boost.
  function autoPreamp() { return autoPre }

  // Boosting cannot make anything louder - there is nothing above full scale -
  // so the automatic headroom pulls everything down by the largest boost. That
  // is correct and it is also why "more bass" can land as "quieter". Let the
  // listener take it back, and show them which mode they are in.
  function setPreamp(v) {
    if (!api) return
    var clamped = Math.max(-24, Math.min(0, Math.round(v * 2) / 2))
    preampShown = clamped
    preampManual = true
    api.post("/eq", { preamp: clamped }, function(ok, d) { if (ok) pane.apply(d) })
  }

  function autoHeadroom() {
    if (!api) return
    preampManual = false
    api.post("/eq", { preamp: null }, function(ok, d) { if (ok) pane.apply(d) })
  }

  function resetBand() {
    var g = gains.slice(); g[sel] = 0; gains = g
    presetId = ""; preampShown = autoPreamp(); push.restart()
  }

  function resetAll() {
    var g = []
    for (var i = 0; i < bands.length; i++) g.push(0)
    gains = g; presetId = "flat"; preampShown = autoPreamp(); push.restart()
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
    var q = Math.max(-limit, Math.min(limit, Math.round(v / step) * step))
    sel = i
    if (Math.abs(q - gains[i]) < 1e-6) return        // a drag inside one step: nothing to redo or repaint
    var g = gains.slice()
    g[i] = q
    gains = g
    presetId = ""
    if (!eqOn && !flat()) eqOn = true
    preampShown = autoPreamp()
    push.restart()
  }

  // ---- AutoEQ ------------------------------------------------------------

  // Nothing chosen yet: the toggle is the way in. Switching it on also takes
  // the EQ off bypass, the same "you want to hear it" rule a band edit follows.
  function toggleAutoeq() {
    if (!autoeq) { openPicker(); return }
    if (!api) return
    var body = { autoeqOn: !autoeqOn }
    if (!autoeqOn) body.enabled = true
    api.post("/eq", body, function(ok, d) { if (ok) pane.apply(d) })
  }

  function clearAutoeq() {
    if (!api || !autoeq) return
    api.post("/autoeq/clear", {}, function(ok, d) { if (ok) { pane.apply(d); pane.note = "" } })
  }

  function openPicker() {
    picking = true
    aeInput.text = ""
    aeCur = 0; aeTop = 0
    aeMsg = ""; aeErr = ""; aeBusy = ""; aeWantApply = false
    aeSearch()
    aeInput.forceActiveFocus()
  }

  function closePicker() {
    picking = false
    aeBusy = ""
    aeWantApply = false
    pane.forceActiveFocus()
  }

  // Replies can land out of order while typing; only the newest one counts.
  function aeSearch() {
    if (!api) return
    var seq = ++aeSeq
    api.get("/autoeq/search?q=" + encodeURIComponent(aeInput.text) + "&limit=50", function(ok, d) {
      if (seq !== pane.aeSeq || !pane.picking) return
      pane.aeLanded = seq
      if (!ok || !d) {
        pane.aeState = "offline"
        pane.aeMsg = "the player service didn't answer"
        pane.aeWantApply = false             // never apply a later reply nobody confirmed
        return
      }
      pane.aeResults = d.results || []
      pane.aeState = d.state || ""
      pane.aeMsg = d.error || ""
      pane.aeCount = d.count || 0
      pane.aeAge = d.age || 0
      pane.aeRefreshing = !!d.refreshing
      pane.moveCur(0)
      if (pane.aeWantApply) { pane.aeWantApply = false; pane.aeApply() }
    })
  }

  // Clamp the cursor and scroll the window so it stays in view.
  function moveCur(delta) {
    var n = aeResults.length
    aeCur = n ? Math.max(0, Math.min(n - 1, aeCur + delta)) : 0
    if (aeCur < aeTop) aeTop = aeCur
    else if (aeCur >= aeTop + aeVis) aeTop = aeCur - aeVis + 1
    aeTop = Math.max(0, Math.min(aeTop, Math.max(0, n - aeVis)))
  }

  function aeApply() {
    if (!api || aeBusy !== "" || !aeResults.length) return
    var r = aeResults[aeCur]
    aeBusy = r.name; aeErr = ""
    api.post("/autoeq/apply", { path: r.path }, function(ok, d) {
      pane.aeBusy = ""
      if (ok && d) {
        pane.apply(d)
        pane.note = (d.warnings || []).join(" · ")
        pane.closePicker()
      } else {
        pane.aeErr = typeof d === "string" && d ? d : "couldn't apply that correction"
      }
    })
  }

  function aeRefresh() {
    if (!api) return
    api.post("/autoeq/refresh", {}, function(ok, d) {
      if (!ok || !d) return
      pane.aeRefreshing = !!d.refreshing
      if (d.state === "fetching") pane.aeState = "fetching"
      pane.aeSearch()
    })
  }

  Timer { id: aeDebounce; interval: 150; onTriggered: { pane.aeCur = 0; pane.aeTop = 0; pane.aeSearch() } }
  // fill the list in when the index lands (first use, or a ctrl+r refresh)
  Timer {
    interval: 1500; repeat: true
    running: pane.picking && (pane.aeState === "fetching" || pane.aeRefreshing)
    onTriggered: pane.aeSearch()
  }

  // `pick` asks for the picker once: the page object stays in the library's
  // history, and going back to it later must not open the picker again.
  function takePick() {
    if (!host || !host.page || host.page.pick !== true) return false
    host.page.pick = false
    return true
  }
  Component.onCompleted: {
    load()
    if (takePick()) Qt.callLater(openPicker)
  }
  // the palette or settings asking for the picker while the pane is already up
  Connections {
    target: pane.host
    ignoreUnknownSignals: true
    function onPageChanged() { if (pane.takePick() && !pane.picking) Qt.callLater(pane.openPicker) }
    // A change made elsewhere (the palette's autoeq toggle or clear, another
    // client): /status carries only a summary, so fetch the full state.
    function onEqStateChanged() { if (pane.loaded && pane.eqDiffers()) eqFollow.restart() }
  }
  function eqDiffers() {
    var s = host ? host.eqState : null
    if (!s || s.enabled === undefined) return false
    return !!s.enabled !== eqOn || !!s.autoeqOn !== autoeqOn
           || (s.autoeq ? s.autoeq.name : "") !== (autoeq ? autoeq.name : "")
  }
  // settle first: a local edit not yet pushed (or its reply) would read as a difference
  Timer { id: eqFollow; interval: 400; onTriggered: if (!push.running && pane.eqDiffers()) pane.load() }
  // Not loaded after a few seconds: keep trying, and say so plainly.
  property bool waited: false
  Timer { interval: 3000; repeat: true; running: !pane.loaded; onTriggered: { pane.waited = true; pane.load() } }

  onGainsChanged: curve.requestPaint()
  onAutoeqChanged: curve.requestPaint()
  onAutoeqOnChanged: curve.requestPaint()
  onEqOnChanged: curve.requestPaint()
  onWidthChanged: curve.requestPaint()

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

  function dimTag(s) { return '<font color="' + Tui.hex(host.dim) + '">' + s + '</font>' }
  function accTag(s) { return '<font color="' + Tui.hex(host.accentText) + '">' + s + '</font>' }

  // ---- keys --------------------------------------------------------------

  Keys.onPressed: function(e) {
    // The picker's prompt has the keys; anything it lets through stops here
    // rather than reaching the player (typing "n" must not skip the track).
    if (picking) { e.accepted = true; return }
    var t = e.text, k = e.key
    if (k === Qt.Key_Left || t === "h") { sel = (sel + bands.length - 1) % bands.length; e.accepted = true }
    else if (k === Qt.Key_Right || t === "l") { sel = (sel + 1) % bands.length; e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { nudge(step); e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { nudge(-step); e.accepted = true }
    else if (t === "K") { nudge(step * 6); e.accepted = true }
    else if (t === "J") { nudge(-step * 6); e.accepted = true }
    else if (t === "0") { resetBand(); e.accepted = true }
    else if (t === "z") { resetAll(); e.accepted = true }
    else if (t === "p") { cyclePreset(1); e.accepted = true }
    else if (t === "P") { cyclePreset(-1); e.accepted = true }
    else if (t === "b") { toggleBypass(); e.accepted = true }
    else if (t === "[") { setPreamp(preampShown - 0.5); e.accepted = true }
    else if (t === "]") { setPreamp(preampShown + 0.5); e.accepted = true }
    else if (t === "\\") { autoHeadroom(); e.accepted = true }
    else if (t === "A") { openPicker(); e.accepted = true }
    else if (t === "x") { toggleAutoeq(); e.accepted = true }
    else if (t === "X") { clearAutoeq(); e.accepted = true }
    else e.accepted = host.handleKey(e)
  }

  // ---- drawing -----------------------------------------------------------

  Column {
    anchors.centerIn: parent
    spacing: host ? host.ch * 0.5 : 8

    // ╱╱ EQUALIZER ─────────── (or AUTOEQ while picking)
    Text {
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(host.accent) + '">╱╱</font> ' + (pane.picking ? "AUTOEQ " : "EQUALIZER ")
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
        var on = pane.eqOn && (!pane.flat() || pane.aeLive)
        var dot = on ? pane.accTag("●") : pane.dimTag("○")
        return dot + '  ' + (on ? "on" : pane.eqOn ? "on · flat, nothing to do" : "bypassed")
             + '   ' + pane.dimTag("preset") + ' ' + Tui.esc(pane.presetName)
             + '   ' + pane.dimTag("preamp") + ' '
             + '<font color="' + Tui.hex(pane.clipping ? host.accentText : host.fg) + '">'
             + (pane.preampShown <= -0.05 ? pane.preampShown.toFixed(1) : "0.0") + ' dB</font>'
             + ' ' + pane.dimTag(pane.preampManual ? "manual" : "auto")
             + (pane.clipping ? '  ' + pane.accTag("may clip") : '')
      }
      font.family: host.family; font.pixelSize: Style.font.body
      color: host.fg
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: { pane.forceActiveFocus(); pane.toggleBypass() }
      }
    }

    // AutoEQ: Sennheiser HD 600 (oratory1990)  on
    Text {
      id: aeLine
      width: pane.colW * pane.bands.length + pane.gutter
      elide: Text.ElideRight
      textFormat: Text.StyledText
      text: {
        var a = pane.autoeq
        if (!a) return pane.dimTag("AutoEQ: none · ") + pane.accTag("A") + pane.dimTag(" finds your headphones")
        var where = Tui.esc(a.source) + (a.rig ? " · " + Tui.esc(a.rig) : "")
        var live = pane.aeLive && pane.eqOn
        return (pane.aeLive ? pane.accTag("●") : pane.dimTag("○")) + '  AutoEQ: ' + Tui.esc(a.name)
             + ' ' + pane.dimTag("(" + where + ")") + "&nbsp;&nbsp;"
             + (live ? "on" : pane.aeLive ? pane.dimTag("on · bypassed") : pane.dimTag("off"))
      }
      font.family: host.family; font.pixelSize: Style.font.body
      color: host.fg
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: { if (!pane.picking) { pane.forceActiveFocus(); pane.toggleAutoeq() } }
        TuiTip { text: pane.aeAttribution; key: pane.autoeq ? "x" : "A" }
      }
    }

    Item { width: 1; height: host.ch * 0.4 }

    // the bars, with a dB scale down the left
    Row {
      spacing: 0
      visible: !pane.picking

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

      Item {
        width: pane.colW * pane.bands.length
        height: barRow.height

        // The response the bars stand for, under the glyphs on their own dB
        // scale: the headphone correction alone (accent), and the total with
        // the bands on top (dashed). With no correction, the bands' true
        // curve, which is smoother than ten columns can say. Canvas only: no
        // layer and no ShaderEffectSource, so resizing is free.
        Canvas {
          id: curve
          anchors.fill: parent
          z: -1
          visible: !pane.picking
          opacity: pane.eqOn ? 1 : 0.45
          renderStrategy: Canvas.Cooperative
          onVisibleChanged: if (visible) requestPaint()
          onHeightChanged: requestPaint()

          // the bars' own row scale: row r is (mid - r) * perRow dB, centred
          function yOf(db) { return (pane.mid - db / pane.perRow + 0.5) / pane.rows * height }

          function drawLine(ctx, xs, db, colour, lw, dashed) {
            ctx.strokeStyle = colour
            ctx.fillStyle = colour
            ctx.lineWidth = lw
            ctx.beginPath()
            var open = false
            for (var i = 0; i < xs.length; i++) {
              var y = yOf(db[i])
              // dashes: every other run of four samples
              if (dashed && Math.floor(i / 4) % 2 === 1) { open = false; continue }
              var cy = Math.max(lw / 2, Math.min(height - lw / 2, y))
              if (!open) { ctx.moveTo(xs[i], cy); open = true } else ctx.lineTo(xs[i], cy)
            }
            ctx.stroke()
            // past the scale: a 2 px tick on the edge so it is not silently flat
            for (var j = 0; j < xs.length; j += 3) {
              var yy = yOf(db[j])
              if (yy < 0) ctx.fillRect(xs[j] - 0.5, 0, 1, 2)
              else if (yy > height) ctx.fillRect(xs[j] - 0.5, height - 2, 1, 2)
            }
          }

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            if (!host || width <= 0 || height <= 0) return
            var ae = pane.aeLive ? Eq.stagesFromAutoeq(pane.autoeq) : []
            var bandsSt = Eq.bandStages(pane.bands, pane.gains, Eq.PEAK_Q, Eq.SHELF_Q)
            if (!ae.length && !bandsSt.length) return
            var n = Math.max(2, Math.min(400, Math.round(width * 2)))
            var xs = [], fs = []
            for (var i = 0; i < n; i++) {
              var x = i * width / (n - 1)
              xs.push(x)
              fs.push(Eq.freqOfX(x, pane.bands, pane.colW))
            }
            if (ae.length)
              drawLine(ctx, xs, Eq.responseDb(ae, fs, 48000), Tui.hex(Tui.mix(host.accent, host.bg, 0.35)),
                     Math.max(1, host.ch * 0.08), false)
            if (bandsSt.length)
              drawLine(ctx, xs, Eq.responseDb(bandsSt.concat(ae), fs, 48000), Tui.hex(Tui.mix(host.fg, host.bg, 0.55)),
                     1, ae.length > 0)
          }
        }

        Row {
          id: barRow
          spacing: 0
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
                color: !pane.eqOn ? host.dim
                     : isSel ? host.accentText
                     : Tui.mix(host.fg, host.bg, 0.25)
                Behavior on color { ColorAnimation { duration: 180; easing.type: Easing.InOutCubic } }
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
      }
    }

    // frequency labels, cursor under the selected band
    Row {
      spacing: 0
      visible: !pane.picking
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
      visible: !pane.picking
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

    // ---- the picker: a prompt over AutoEq's index, in place of the bars ----
    Column {
      id: picker
      visible: pane.picking
      width: pane.colW * pane.bands.length + pane.gutter
      spacing: host ? host.ch * 0.35 : 6
      readonly property real rowH: host ? host.ch * 1.2 : 18

      Row {
        width: parent.width
        Text { text: "❯ "; font.family: host.family; font.pixelSize: Style.font.body; color: host.accentText; font.bold: true }
        TextInput {
          id: aeInput
          width: pane.colW * pane.bands.length
          font.family: host.family; font.pixelSize: Style.font.body
          color: host.fg
          selectionColor: Tui.mix(host.accent, host.bg, 0.5)
          cursorDelegate: Rectangle { width: host.cw; color: host.accent; opacity: 0.7 }
          onTextEdited: aeDebounce.restart()
          Keys.onPressed: function(e) {
            var k = e.key, ctrl = e.modifiers & Qt.ControlModifier
            if (k === Qt.Key_Escape) { pane.closePicker(); e.accepted = true }
            else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
              // a query typed faster than the debounce, or one still on its way:
              // apply what the newest search finds, not the list on screen
              if (aeDebounce.running) { aeDebounce.stop(); pane.aeCur = 0; pane.aeTop = 0; pane.aeWantApply = true; pane.aeSearch() }
              else if (pane.aeLanded !== pane.aeSeq) pane.aeWantApply = true
              else pane.aeApply()
              e.accepted = true
            }
            // (no ctrl+j/k: the window's ctrl+k palette shortcut takes it first)
            else if (k === Qt.Key_Up) { pane.moveCur(-1); e.accepted = true }
            else if (k === Qt.Key_Down) { pane.moveCur(1); e.accepted = true }
            else if (k === Qt.Key_PageUp) { pane.moveCur(-pane.aeVis); e.accepted = true }
            else if (k === Qt.Key_PageDown) { pane.moveCur(pane.aeVis); e.accepted = true }
            else if (ctrl && k === Qt.Key_R) { pane.aeRefresh(); e.accepted = true }
          }
          Text {
            visible: !parent.text
            text: "type a headphone · oratory1990 · crinacle…"
            font: parent.font
            color: host.dim
          }
        }
      }

      // what the index is doing, or what went wrong
      Text {
        width: parent.width
        elide: Text.ElideRight
        textFormat: Text.StyledText
        text: {
          if (pane.aeBusy) return pane.dimTag("downloading " + Tui.esc(pane.aeBusy) + "…")
          if (pane.aeErr) return pane.accTag(Tui.esc(pane.aeErr))
          if (pane.aeState === "fetching") return pane.dimTag("fetching the AutoEq index…")
          if (pane.aeState === "offline") return pane.dimTag(Tui.esc(pane.aeMsg || "offline"))
          if (pane.aeState !== "ready") return pane.dimTag("asking the player service…")
          return pane.dimTag(pane.aeCount + " headphones · "
                             + (pane.aeRefreshing ? "refreshing the index"
                                : pane.aeAge > 0 ? "index " + pane.aeAge + " d old" : "index from today")
                             + (aeInput.text ? "" : " · used before") + " · ⏎ applies · esc back")
        }
        font.family: host.family; font.pixelSize: Style.font.caption
        color: host.dim
      }

      // the list: a window of aeVis rows that follows the cursor
      Item {
        width: parent.width
        height: picker.rowH * pane.aeVis
        clip: true

        Column {
          width: parent.width
          Repeater {
            model: Math.max(0, Math.min(pane.aeVis, pane.aeResults.length - pane.aeTop))
            Text {
              id: aeRow
              required property int index
              readonly property int i: pane.aeTop + index
              readonly property var r: pane.aeResults[i] || ({})
              readonly property bool cur: i === pane.aeCur
              width: picker.width
              height: picker.rowH
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
              textFormat: Text.StyledText
              text: (cur ? pane.accTag("▸&nbsp;") : "&nbsp;&nbsp;")
                    + '<font color="' + Tui.hex(cur ? host.accentText : host.fg) + '">' + Tui.esc(r.name || "") + '</font>'
                    + "&nbsp;&nbsp;" + pane.dimTag(Tui.esc(r.source || "") + (r.rig ? " · " + Tui.esc(r.rig) : "")
                                         + (r.form ? " · " + Tui.esc(r.form) : ""))
                    + (pane.autoeq && r.path === pane.autoeq.path ? pane.accTag(" ●") : "")
              font.family: host.family; font.pixelSize: Style.font.body
              color: host.fg
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: { pane.aeCur = aeRow.i; aeInput.forceActiveFocus(); pane.aeApply() }
              }
            }
          }
        }

        Text {
          visible: pane.aeResults.length === 0 && pane.aeState === "ready"
          y: picker.rowH * 0.2
          text: aeInput.text ? "no match · try fewer words"
                             : "start typing · headphones you've used show up here"
          font.family: host.family; font.pixelSize: Style.font.caption
          color: host.dim
        }

        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.NoButton
          onWheel: function(w) { pane.moveCur(w.angleDelta.y > 0 ? -3 : 3) }
        }
      }

      HintBar {
        keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
        items: [{ k: "⏎", l: "apply", run: function() { pane.aeApply() }, tip: "use this correction" },
                { k: "↑↓", l: "move", run: function() { pane.moveCur(1) }, tip: "next headphone", tipKey: "↓" },
                { k: "ctrl+r", l: "refresh index", run: function() { pane.aeRefresh() }, tip: "fetch AutoEq's index again" },
                { k: "esc", l: "back to bars", run: function() { pane.closePicker() } }]
      }
    }

    Item { width: 1; height: host.ch * 0.4; visible: !pane.picking }

    Text {
      visible: pane.note !== "" && !pane.picking
      text: pane.note
      width: pane.colW * pane.bands.length
      wrapMode: Text.WordWrap
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }

    // Bypassed: say so where the eye is, with the way back on.
    Text {
      visible: pane.loaded && !pane.eqOn && !pane.picking
      textFormat: Text.StyledText
      text: pane.dimTag("bypassed, the music plays untouched · ") + pane.accTag("b") + pane.dimTag(" turns it on")
      font.family: host.family; font.pixelSize: Style.font.caption
    }

    // every key, each one a button too; three short lines so they fit the bars' width
    HintBar {
      visible: !pane.picking
      keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
      items: [{ k: "h/l", l: "band", run: function() { pane.sel = (pane.sel + 1) % pane.bands.length }, tip: "next band", tipKey: "l" },
              { k: "k/j", l: "±" + pane.step.toFixed(1), run: function() { pane.nudge(pane.step) }, tip: "raise the band", tipKey: "k" },
              { k: "K/J", l: "coarse" },
              { k: "0", l: "zero", run: function() { pane.resetBand() }, tip: "zero this band" },
              { k: "z", l: "all", run: function() { pane.resetAll() }, tip: "zero every band" }]
    }
    HintBar {
      visible: !pane.picking
      keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
      items: [{ k: "p", l: "preset", run: function() { pane.cyclePreset(1) }, tip: "next preset" },
              { k: "b", l: pane.eqOn ? "bypass" : "turn on", run: function() { pane.toggleBypass() } },
              { k: "]/[", l: "preamp", run: function() { pane.setPreamp(pane.preampShown + 0.5) }, tip: "preamp up", tipKey: "]" },
              { k: "\\", l: "auto", run: function() { pane.autoHeadroom() }, tip: "automatic headroom" },
              { k: "esc", l: "back", run: function() { host.back() } }]
    }
    HintBar {
      visible: !pane.picking
      keyColor: host.accentText; labelColor: host.dim; hoverColor: host.accentText
      items: [{ k: "A", l: "autoeq", run: function() { pane.openPicker() }, tip: "find your headphones" },
              { k: "x", l: pane.aeLive ? "autoeq off" : "autoeq on", run: function() { pane.toggleAutoeq() } },
              { k: "X", l: "clear", run: function() { pane.clearAutoeq() }, tip: "forget the headphone correction" }]
    }
    Text {
      visible: !pane.picking
      text: "drag or scroll a band · middle-click zeroes it · right-click bypasses"
      font.family: host.family; font.pixelSize: Style.font.caption
      color: Tui.mix(host.dim, host.bg, 0.2)
    }

    Text {
      visible: !pane.loaded
      text: pane.waited ? "the player service isn't answering · esc goes back" : "waiting for the player service…"
      font.family: host.family; font.pixelSize: Style.font.caption
      color: host.dim
    }
  }
}
