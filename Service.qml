import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris
import qs.Commons

// Orpheus: music visualizers that look like the rest of Omarchy.
//
// Runs cava only while something is playing and a visualizer is on screen,
// turns its output into 32 bands (+ falling peaks), and hands them to the
// bar widget and the big stage. Colors come from the active Omarchy theme,
// fonts from the shell's font (which follows `omarchy font set`).
Item {
  id: root

  // Host injection (optional for a third-party service).
  property string omarchyPath: ""
  property var shell: null
  property var manifest: null

  // orpheus-desktop runs this same file on Windows; the few Linux tools it calls
  // have Windows stand-ins or are skipped there.
  readonly property bool windows: Qt.platform.os === "windows"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/orpheus"
  readonly property string configPath: configDir + "/config.json"
  readonly property string stateDir: home + "/.local/state/orpheus"
  readonly property string cavaConfigPath: stateDir + "/cava.conf"
  readonly property string themeRoot: home + "/.local/state/omarchy/current"

  readonly property var styles: ["prism", "skyline", "horizon", "orb", "tunnel", "halo", "scope", "nova"]
  readonly property var styleLabels: ({ prism: "Prism", skyline: "Skyline", horizon: "Horizon", orb: "Orb", tunnel: "Tunnel",
                                       halo: "Halo", scope: "Scope", nova: "Nova" })
  // railViz: the visualizer plane inside the player window. "off" shows album
  // art there instead. Prism is the default because it measured as the cheapest
  // style by a wide margin (+0.7% shell CPU, against +13 to +20 for the others).
  readonly property var defaults: ({ style: "prism", railViz: "prism", miniPlayer: true, placement: "overlay", fps: 60, syncViz: true,
                                     widget: { enabled: true, style: "full", corner: "bottom-right", monitor: "", viz: "prism", layer: "top" } })

  // ---- Config ------------------------------------------------------------
  property var config: defaults
  readonly property string style: styles.indexOf(config.style) >= 0 ? config.style : "skyline"
  readonly property bool miniPlayer: config.miniPlayer !== false
  readonly property string placement: config.placement === "desktop" ? "desktop" : "overlay"
  readonly property int fps: Math.max(20, Math.min(120, config.fps || 60))
  readonly property var widget: {
    var w = {}
    for (var k in defaults.widget) w[k] = defaults.widget[k]
    var c = config.widget || {}
    for (var j in c) w[j] = c[j]
    return w
  }
  // With syncViz on (the default) the widget shows whatever the visualizer shows,
  // and choosing a style from either one changes both.
  readonly property bool syncViz: config.syncViz !== false
  readonly property string widgetViz: syncViz ? style : (styles.indexOf(widget.viz) >= 0 ? widget.viz : "prism")
  readonly property string railViz: config.railViz === "off" ? "off"
                                    : (styles.indexOf(config.railViz) >= 0 ? config.railViz : "prism")

  function applyConfig(raw) {
    var parsed = {}
    try { parsed = raw ? JSON.parse(raw) : {} } catch (e) { console.warn("orpheus: bad config.json:", e) }
    var merged = {}
    for (var k in defaults) merged[k] = defaults[k]
    for (var j in parsed) merged[j] = parsed[j]
    config = merged
  }

  function updateConfig(mutator) {
    var copy = JSON.parse(JSON.stringify(config))
    mutator(copy)
    config = copy
    configFile.setText(JSON.stringify(copy, null, 2) + "\n")
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyConfig(text())
    onLoadFailed: root.updateConfig(function() {})
  }

  Process {
    // On Windows FileView.setText makes the folders itself.
    command: root.windows ? ["cmd", "/c", "exit 0"] : ["mkdir", "-p", root.configDir, root.stateDir]
    running: true
    onExited: cavaConfigFile.setText(root.cavaConfig())
  }

  // ---- Theme palette -----------------------------------------------------
  // Live from the shell (same frame as the bar): accent, then the Hyprland
  // active-border gradient stops, then colors.toml's palette only to fill gaps.
  property var filePalette: ({})
  readonly property var borderStops: {
    var raw = Color.shellValues["hyprland.active-border"] || ""
    var out = []
    var parts = String(raw).split(/\s+/)
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i] || /deg$/.test(parts[i])) continue
      var c = Color.flatColor(parts[i], "")
      if (c !== "") out.push(c)
    }
    return out
  }
  function distinct(a, b) {
    var x = Qt.color(a), y = Qt.color(b)
    return Math.abs(x.r - y.r) + Math.abs(x.g - y.g) + Math.abs(x.b - y.b) > 0.12
  }
  function pickAfter(candidates, avoid) {
    for (var i = 0; i < candidates.length; i++) {
      var c = candidates[i]
      if (!c) continue
      var ok = true
      for (var j = 0; j < avoid.length; j++) if (!distinct(c, avoid[j])) ok = false
      if (ok) return c
    }
    return avoid[avoid.length - 1]
  }
  readonly property color liveC1: Color.accent
  readonly property color liveC2: pickAfter(borderStops.concat([filePalette.magenta, filePalette.blue, filePalette.bright_magenta]), [liveC1])
  readonly property color liveC3: pickAfter(borderStops.slice(1).concat([filePalette.cyan, filePalette.bright_cyan, filePalette.green, Color.foreground]), [liveC1, liveC2])

  property color c1: liveC1
  property color c2: liveC2
  property color c3: liveC3
  property color bg: Color.background
  property color fg: Color.foreground
  readonly property bool lightTheme: (0.2126 * Color.background.r + 0.7152 * Color.background.g + 0.0722 * Color.background.b) > 0.5

  // Locked to the shell's 420 ms wallpaper reveal; retargets mid-flight.
  Behavior on c1 { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on c2 { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on c3 { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on bg { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on fg { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }

  // Fallback palette for themes whose accent/border don't give three colours.
  FileView {
    id: colorsFile
    path: root.themeRoot + "/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var t = {}
      var lines = text().split("\n")
      for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"([^"]*)"/)
        if (m) t[m[1]] = m[2]
      }
      root.filePalette = t
    }
  }

  // ---- Player ------------------------------------------------------------
  readonly property var players: Mpris.players ? Mpris.players.values : []
  readonly property var player: {
    var best = null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || !(p.trackTitle || p.trackArtist)) continue
      if (p.isPlaying) return p
      if (!best) best = p
    }
    return best
  }
  readonly property bool playing: player !== null && player.isPlaying

  // MPRIS position doesn't tick on its own; nudge it while the mini player shows.
  Timer {
    interval: 500
    repeat: true
    running: root.open && root.playing && root.miniPlayer
    onTriggered: if (root.player) root.player.positionChanged()
  }

  // ---- Visibility --------------------------------------------------------
  property bool open: false
  property bool libraryOpen: false
  property int loginRequests: 0      // bumps to send the open library to the sign-in page
  property int eqRequests: 0         // ... and the same for the equalizer
  property int eqHandled: 0
  property int lyricsRequests: 0     // ... and the lyrics
  property int lyricsHandled: 0
  property int loginHandled: 0
  property int barWidgets: 0           // bar widgets register themselves
  readonly property bool widgetShown: widget.enabled !== false && (player !== null || widgetIsWindow)
  readonly property bool wanted: open || libraryOpen || barWidgets > 0 || widgetShown

  // ---- Player service (orpheusd) -----------------------------------------
  Api { id: apiClient; active: root.libraryOpen || root.open || root.widgetShown }
  readonly property var api: apiClient

  // ---- Audio (cava) ------------------------------------------------------
  property bool hasCava: false
  readonly property bool listening: hasCava && wanted && playing

  Process {
    id: cavaCheck
    command: root.windows ? ["where", "cava"] : ["sh", "-c", "command -v cava"]
    running: true
    onExited: function(code) { root.hasCava = code === 0 }
  }
  // Recheck occasionally so installing cava later just works.
  Timer { interval: 15000; repeat: true; running: !root.hasCava; onTriggered: cavaCheck.running = true }

  // Small visualizers (bar, widget) get 30 Hz; the big stage gets the full rate.
  readonly property int audioFps: open ? fps : 30
  onAudioFpsChanged: if (cava.running) { cavaConfigFile.setText(cavaConfig()); cava.running = false; cavaRestart.restart() }
  Timer { id: cavaRestart; interval: 50; onTriggered: if (root.listening) cava.running = true }

  function cavaConfig() {
    return "[general]\nbars = 32\nframerate = " + audioFps + "\nautosens = 1\n\n"
      + (windows ? "" : "[input]\nmethod = pipewire\nsource = " + (sinkMonitor || "auto") + "\n\n")
      + "[output]\nmethod = raw\nraw_target = /dev/stdout\ndata_format = ascii\nascii_max_range = 1000\n"
      + "bar_delimiter = 59\nframe_delimiter = 10\nchannels = mono\nmono_option = average\n\n"
      + "[smoothing]\nnoise_reduction = 70\n"
  }

  // ---- Output device ------------------------------------------------------
  // cava's `source = auto` resolves a monitor once, when it starts, and then
  // keeps reading that one device. Change the default sink afterwards -- connect
  // Bluetooth headphones, wake the USB DAC -- and cava carries on listening to a
  // monitor that has gone silent, so the visualizer flatlines while music is
  // plainly playing. Nothing errors and cava never exits, so the restart timer
  // below never fires either. Resolve the default sink ourselves, pin cava to
  // its monitor, and follow it when it moves.
  property string sinkMonitor: ""

  // Windows cava captures the default output by itself.
  function probeSink() { if (hasCava && !windows) sinkProbe.running = true }

  Process {
    id: sinkProbe
    command: ["pactl", "get-default-sink"]
    stdout: SplitParser {
      onRead: function(line) {
        var name = String(line).trim()
        // pactl prints this placeholder when no default is set yet
        if (name && name !== "@DEFAULT_SINK@") root.sinkMonitor = name + ".monitor"
      }
    }
  }

  onHasCavaChanged: probeSink()

  // pactl reports a change on the server object when the default sink moves.
  // One long-lived subscriber beats polling: device changes are rare, and this
  // costs nothing between them.
  Process {
    id: sinkWatch
    command: ["pactl", "subscribe"]
    stdout: SplitParser {
      onRead: function(line) { if (/on (server|sink)\b/.test(String(line))) sinkSettle.restart() }
    }
  }

  // Switching devices emits a burst of events; re-probe once it settles.
  Timer { id: sinkSettle; interval: 250; onTriggered: root.probeSink() }

  // Keep the subscriber alive across a pipewire restart.
  Timer {
    interval: 5000
    repeat: true
    running: root.hasCava && !root.windows && !sinkWatch.running
    onTriggered: { sinkWatch.running = true; root.probeSink() }
  }

  onSinkMonitorChanged: {
    cavaConfigFile.setText(cavaConfig())
    if (cava.running) { cava.running = false; cavaRestart.restart() }
  }

  FileView { id: cavaConfigFile; path: root.cavaConfigPath; printErrors: false }

  Process {
    id: cava
    running: root.listening
    command: ["cava", "-p", root.cavaConfigPath]
    stdout: SplitParser {
      onRead: function(line) { root.ingest(line) }
    }
    onExited: function(code) { if (code !== 0 && root.listening) console.warn("orpheus: cava exited with", code) }
  }

  // If cava dies while we still want audio (device change, config race), bring it back.
  Timer {
    interval: 2000
    repeat: true
    running: root.listening && !cava.running
    onTriggered: { cavaConfigFile.setText(root.cavaConfig()); cava.running = true }
  }
  onFpsChanged: if (configFile.loaded) cavaConfigFile.setText(cavaConfig())

  // ---- Levels ------------------------------------------------------------
  property var levels: []
  property var peaks: []
  property vector4d b0; property vector4d b1; property vector4d b2; property vector4d b3
  property vector4d b4; property vector4d b5; property vector4d b6; property vector4d b7
  property vector4d p0; property vector4d p1; property vector4d p2; property vector4d p3
  property vector4d p4; property vector4d p5; property vector4d p6; property vector4d p7
  property real bass: 0
  property real energy: 0
  // ---- Flux (the pace signal; see the Pace section) ----
  property var prevLv: []
  property real fluxRate: 0      // positive spectral change per second
  // Beat: a kick transient (bass jumping above its own slow average, or the
  // low end climbing faster than it usually does); snaps up, decays fast.
  property real beat: 0
  property real slowBass: 0
  // ---- Onsets (shader uniforms kick, snap, swell, kicks) ----
  // Transients come from positive flux, normalised against the track's own
  // recent flux so compressed masters (where the bass level barely moves under
  // autosens) still fire. Attack is instant; release is exponential in wall
  // time, so 30 Hz and 60 Hz cava decay alike.
  property real kick: 0          // 0..1 low end (bands 0-5) onset, ~0.22 s release
  property real snap: 0          // 0..1 mid/high (bands 12-31) onset, ~0.12 s release
  property real swell: 0         // 0..1 loudness envelope: ~0.2 s attack, ~1.4 s release
  property real kicks: 0         // kick counter (whole steps, wraps at 1024) for per-kick variety
  property real lowFluxAvg: 0
  property real lowFluxPk: 0
  property real hiFluxAvg: 0
  property real hiFluxPk: 0
  property real lastPublishMs: 0
  property real lastKickMs: 0
  // When the last three kicks landed (clock seconds, newest first) and how hard
  // the newest one hit. Viz turns these into kickAge, so a shader can keep
  // several kicks' effects alive at once instead of restarting on each one.
  property var kickTimes: [-1e4, -1e4, -1e4]
  property real kickStrength: 0
  // Seconds since each of the last three kicks (newest first, capped at 8),
  // w = the newest kick's strength. Refreshed every clock tick.
  property vector4d kickAge: Qt.vector4d(8, 8, 8, 0)

  // Onset strength 0..1 of `f` against its running average and peak.
  function onsetOf(f, avg, pk) {
    var thr = avg * 1.6 + 0.003
    return Math.max(0, Math.min(1, (f - thr) / Math.max(pk - thr, 0.015)))
  }

  function pack(a, i) { return Qt.vector4d(a[i] || 0, a[i + 1] || 0, a[i + 2] || 0, a[i + 3] || 0) }

  function publish(lv) {
    var pk = peaks.length === 32 ? peaks : []
    var sum = 0
    for (var i = 0; i < 32; i++) {
      var v = lv[i] || 0
      pk[i] = Math.max(v, (pk[i] || 0) - 0.012)
      sum += v
    }
    peaks = pk
    levels = lv
    b0 = pack(lv, 0); b1 = pack(lv, 4); b2 = pack(lv, 8); b3 = pack(lv, 12)
    b4 = pack(lv, 16); b5 = pack(lv, 20); b6 = pack(lv, 24); b7 = pack(lv, 28)
    p0 = pack(pk, 0); p1 = pack(pk, 4); p2 = pack(pk, 8); p3 = pack(pk, 12)
    p4 = pack(pk, 16); p5 = pack(pk, 20); p6 = pack(pk, 24); p7 = pack(pk, 28)
    bass = ((lv[0] || 0) + (lv[1] || 0) + (lv[2] || 0) + (lv[3] || 0)) / 4
    energy = sum / 32
    // Spectral flux: how much the spectrum climbed since the last frame. This
    // is the onset signal, in place of a bass-transient test -- relative bass
    // transients vanish on heavily compressed music (dense drum'n'bass reads
    // as having no onsets at all), while flux survives it.
    var fx = 0, lowF = 0, hiF = 0
    for (var k = 0; k < 32; k++) {
      var d = Math.max(0, (lv[k] || 0) - (prevLv[k] || 0))
      fx += d
      if (k < 6) lowF += d
      else if (k >= 12) hiF += d
    }
    lowF /= 6; hiF /= 20
    prevLv = lv
    var nowMs = Date.now()
    fluxRate = fx * (listening ? fps : 60)
    feedEnvelope(fluxRate, nowMs)
    var dt = Math.max(0.004, Math.min(0.1, (nowMs - (lastPublishMs || nowMs - 16)) / 1000))
    lastPublishMs = nowMs
    function ease(tau) { return 1 - Math.exp(-dt / tau) }
    function hold(tau) { return Math.exp(-dt / tau) }
    if (lv.length === 0) { beat = 0; kick = 0; snap = 0; swell = 0; return }
    // Strength is measured before the averages take this frame in.
    var lowOn = onsetOf(lowF, lowFluxAvg, lowFluxPk)
    var hiOn = onsetOf(hiF, hiFluxAvg, hiFluxPk)
    lowFluxAvg += (lowF - lowFluxAvg) * ease(1.2)
    hiFluxAvg += (hiF - hiFluxAvg) * ease(1.2)
    lowFluxPk = Math.max(lowF, lowFluxPk * hold(2.5))
    hiFluxPk = Math.max(hiF, hiFluxPk * hold(2.5))
    slowBass += (bass - slowBass) * ease(0.27)
    var lift = Math.max(0, Math.min(1, (bass - slowBass * 1.15) * 4))
    if (lowOn > 0.25 && nowMs - lastKickMs > 110) {
      kicks = (kicks + 1) % 1024; lastKickMs = nowMs
      kickTimes = [(nowMs - startedAt) / 1000, kickTimes[0], kickTimes[1]]
      kickStrength = 0.35 + 0.65 * lowOn
    }
    // A shaped hit: weak onsets stay small, real kicks slam to near full.
    var hit = Math.max(lift, lowOn > 0.12 ? 0.35 + 0.65 * lowOn : lowOn)
    beat = Math.max(hit, beat * hold(0.085))
    kick = Math.max(hit, kick * hold(0.22))
    snap = Math.max(hiOn > 0.12 ? 0.3 + 0.7 * hiOn : hiOn, snap * hold(0.12))
    swell += (energy - swell) * ease(energy > swell ? 0.2 : 1.4)
  }

  // ---- Pace --------------------------------------------------------------
  // Tempo by autocorrelation of the spectral-flux envelope. Counting kicks
  // fails on compressed music, so instead the flux (fluxRate) is resampled to a
  // steady 50 Hz ring buffer (6 s), mean-removed, and autocorrelated over the
  // lags for 60..200 BPM. Recomputed at most once a second; the published BPM
  // eases toward each new estimate.
  readonly property int envRate: 50
  readonly property int envSize: 300
  readonly property int lagMin: 15           // 200 BPM at 50 Hz
  readonly property int lagMax: 50           // 60 BPM at 50 Hz
  readonly property real restBpm: 104        // calm pace the motion falls back to
  property var envBuf: new Array(envSize).fill(0)
  property int envHead: 0                    // next write index
  property int envCount: 0
  property real envAcc: 0
  property int envAccN: 0
  property real envClock: 0                  // ms time of the next buffer tick
  property real lastEstimate: 0
  property real tempo: 0                     // eased BPM
  property real tempoConfidence: 0           // eased, 0..1
  property int peakLag: 0                    // raw estimate, for inspection
  property real peakCorr: 0
  property real onsetRate: 0                 // onsets per second in the window
  property real densityBpm: 0                // octave-preference target from onsetRate
  property var candLags: []                  // raw octave candidates, for inspection
  property real lastFrameMs: 0               // wall time of the last real cava frame
  readonly property real onsetK: 1.0         // onset must exceed onsetK * rms
  readonly property real onsetsPerBeat: 2
  readonly property real onsetMinRate: 1.5   // below this the density is not trusted
  readonly property real onsetsPerBeatMax: 3.5 // above this a candidate is not a real beat

  // Called per cava frame: accumulate, and on each 20 ms boundary emit the mean
  // of what arrived since the last tick (held if a tick has no new frame), so
  // 30 Hz and 60 Hz cava give the same envelope.
  function feedEnvelope(v, nowMs) {
    if (envClock === 0 || nowMs - envClock > 1000) { envClock = nowMs + 1000 / envRate; envAcc = 0; envAccN = 0 }
    envAcc += v; envAccN++
    if (nowMs < envClock) return
    var m = envAcc / envAccN
    envAcc = 0; envAccN = 0
    while (envClock <= nowMs) {
      envBuf[envHead] = m
      envHead = (envHead + 1) % envSize
      if (envCount < envSize) envCount++
      envClock += 1000 / envRate
    }
    if (nowMs - lastEstimate >= 1000) { lastEstimate = nowMs; estimateTempo() }
  }

  function estimateTempo() {
    if (envCount < envSize) return
    var x = new Array(envSize), mean = 0, i
    for (i = 0; i < envSize; i++) { x[i] = envBuf[(envHead + i) % envSize]; mean += x[i] }
    mean /= envSize
    var v0 = 0
    for (i = 0; i < envSize; i++) { x[i] -= mean; v0 += x[i] * x[i] }
    v0 /= envSize
    // Onset density: local maxima above onsetK * rms, 2-sample refractory.
    var onsets = 0, lastOn = -10, thr = onsetK * Math.sqrt(v0)
    for (i = 1; i < envSize - 1; i++) {
      if (x[i] > x[i - 1] && x[i] >= x[i + 1] && x[i] > thr && i - lastOn >= 2) { onsets++; lastOn = i }
    }
    onsetRate = onsets / (envSize / envRate)
    densityBpm = Math.max(60, Math.min(200, 60 * onsetRate / onsetsPerBeat))
    if (v0 < 1e-6) { tempoConfidence *= 0.7; return }     // silence: no estimate
    var c = new Array(lagMax + 2).fill(0), sumPos = 0, best = lagMin
    for (var L = lagMin; L <= lagMax; L++) {
      var s = 0, n = envSize - L
      for (i = 0; i < n; i++) s += x[i] * x[i + L]
      c[L] = s / n / v0                                   // per overlapping sample
      sumPos += Math.max(0, c[L])
      if (c[L] > c[best]) best = L
    }
    var meanC = sumPos / (lagMax - lagMin + 1)
    // Octave rule: take the strongest lag L, and consider L/2 and 2L when in
    // range (each refined to the local max within +-1). Among these related
    // candidates prefer the BPM closest to the onset-density target (120 when
    // the material is too sparse to trust), unless some other candidate's
    // correlation is more than 15% higher than the preferred one's.
    var cands = [best], h = Math.round(best / 2), d = best * 2
    function peakNear(l) {
      var q = l
      for (var j = Math.max(lagMin, l - 1); j <= Math.min(lagMax, l + 1); j++) if (c[j] > c[q]) q = j
      return q
    }
    // Is the tempo this lag implies physically playable? Onsets per beat is
    // onsetRate / beatsPerSecond, i.e. onsetRate * lag / envRate. Drum & bass
    // heard at half-time would need ~5 onsets per beat, which no kit plays;
    // doom at its true 89 BPM needs ~1.9.
    function plausibleLag(l) {
      if (onsetRate < onsetMinRate) return true
      return onsetRate * l / envRate <= onsetsPerBeatMax
    }
    if (h >= lagMin) cands.push(peakNear(h))
    if (d <= lagMax) cands.push(peakNear(d))
    candLags = cands.slice()
    var target = onsetRate >= onsetMinRate ? densityBpm : 120
    var pref = cands[0], strong = cands[0]
    for (i = 1; i < cands.length; i++) {
      if (Math.abs(60 * envRate / cands[i] - target) < Math.abs(60 * envRate / pref - target)) pref = cands[i]
      if (c[cands[i]] > c[strong]) strong = cands[i]
    }
    // A sharper peak may still override the density target, but only where the
    // tempo it implies is plausible. In dense music the half-time peak genuinely
    // IS the stronger one, so without this veto it wins back every time and
    // drum & bass renders slower than rest pace.
    var pick = (c[strong] > c[pref] * 1.15 && plausibleLag(strong)) ? strong : pref
    // Parabolic refinement of the lag for sub-sample BPM.
    var lag = pick
    if (pick > lagMin && pick < lagMax) {
      var a = c[pick - 1], b = c[pick], g = c[pick + 1], den = a - 2 * b + g
      if (den < 0) lag = pick + 0.5 * (a - g) / den
    }
    var est = 60 * envRate / lag
    var conf = meanC > 1e-6 ? Math.max(0, Math.min(1, (c[pick] / meanC - 1) / 4)) : 0
    peakLag = pick
    peakCorr = c[pick]
    if (tempo === 0) { tempo = est; tempoConfidence = conf }
    else { tempo += (est - tempo) * 0.35; tempoConfidence += (conf - tempoConfidence) * 0.35 }
  }

  function ingest(line) {
    var parts = line.split(";")
    var lv = []
    for (var i = 0; i < 32; i++) lv.push((parseInt(parts[i], 10) || 0) / 1000)
    lastFrameMs = Date.now()
    publish(lv)
  }

  // When playback stops, let the bars fall instead of freezing mid-air. Also
  // eases tempoConfidence to 0 (x0.7/s) once no cava frame has arrived for
  // 1.5 s, since estimateTempo only runs from frames.
  Timer {
    id: decay
    interval: 16
    repeat: true
    running: (!root.listening && root.energy > 0.001) || root.tempoConfidence > 0.005
    onTriggered: {
      if (root.tempoConfidence > 0.005 && Date.now() - root.lastFrameMs > 1500)
        root.tempoConfidence *= Math.pow(0.7, interval / 1000)
      if (!root.listening && root.energy > 0.001) {
        var lv = []
        for (var i = 0; i < 32; i++) lv.push((root.levels[i] || 0) * 0.86)
        root.publish(lv)
        if (root.energy <= 0.001) root.publish([])
      }
    }
  }

  // ---- Clock -------------------------------------------------------------
  property real time: 0
  readonly property real startedAt: Date.now()
  // How fast the world comes at you, in world units per second: pace leads,
  // loudness adds a little urgency. The 0.45 exponent compresses the range so
  // fast music reads as more urgent rather than comically sped up.
  property real flow: 1
  // Confidence-weighted BPM: a doubtful estimate falls back toward restBpm.
  readonly property real paceBpm: root.restBpm + (root.tempo > 0 ? root.tempo - root.restBpm : 0) * root.tempoConfidence
  readonly property real flowTarget: Math.max(0.55, Math.min(1.7,
      Math.pow(root.paceBpm / root.restBpm, 0.45))) * (0.85 + root.energy * 0.5)
  // Distance travelled. The shaders read this instead of multiplying time by a
  // speed, so a tempo change bends the motion instead of teleporting the world.
  property real travel: 0
  property real lastTick: Date.now()
  Timer {
    interval: Math.round(1000 / (root.open ? root.fps : 30))
    repeat: true
    // Redraw only while something moves: music, falling bars, or an open window.
    running: root.open || root.libraryOpen || (root.wanted && (root.listening || decay.running))
    onRunningChanged: if (running) root.lastTick = Date.now()
    onTriggered: {
      var now = Date.now()
      var dt = Math.min(0.1, (now - root.lastTick) / 1000)
      root.lastTick = now
      root.time = ((now - root.startedAt) / 1000) % 4000
      // Ease the pace the tempo implies, then integrate.
      root.flow += (root.flowTarget - root.flow) * Math.min(1, dt * 1.8)
      root.travel = (root.travel + dt * root.flow) % 4096
      var t = (now - root.startedAt) / 1000, kt = root.kickTimes
      function ageOf(x) { return Math.max(0, Math.min(8, t - x)) }
      root.kickAge = Qt.vector4d(ageOf(kt[0]), ageOf(kt[1]), ageOf(kt[2]), root.kickStrength)
    }
  }

  // ---- Stage -------------------------------------------------------------
  Loader {
    active: root.open
    sourceComponent: Stage { engine: root }
  }

  // Widget: a corner widget on a layer (top/reserve/desktop), or a real
  // window that tiles into the layout (tile) or floats (float).
  readonly property bool widgetIsWindow: widget.layer === "tile" || widget.layer === "float"
  Loader {
    active: root.widget.enabled !== false && !root.widgetIsWindow
    sourceComponent: Widget { engine: root }
  }
  // Separate loaders so switching tile <-> float opens a fresh window; Hyprland
  // applies window rules only when a window opens.
  Loader {
    active: root.widget.enabled !== false && root.widget.layer === "tile"
    sourceComponent: WidgetWindow { engine: root; floating: false; visible: true }
  }
  Loader {
    active: root.widget.enabled !== false && root.widget.layer === "float"
    sourceComponent: WidgetWindow { engine: root; floating: true; visible: true }
  }

  Loader {
    active: root.libraryOpen
    sourceComponent: Library { engine: root; visible: true }
  }

  // ---- Controls ----------------------------------------------------------
  function setStyle(name) {
    if (styles.indexOf(name) < 0) return "unknown style: " + name + " (" + styles.join("|") + ")"
    updateConfig(function(c) { c.style = name })
    return statusText()
  }
  function nextStyle(step) {
    var i = styles.indexOf(style)
    return setStyle(styles[(i + (step || 1) + styles.length) % styles.length])
  }
  function setRailViz(name) {
    if (name !== "off" && styles.indexOf(name) < 0) return "unknown viz: " + name + " (off|" + styles.join("|") + ")"
    updateConfig(function(c) { c.railViz = name })
    return statusText()
  }
  // Cycles art -> each style -> back to art, in place. The player never opens a
  // popout to choose a visualizer; the plane just becomes the next one.
  function cycleRailViz(step) {
    var ring = ["off"].concat(styles)
    var i = ring.indexOf(railViz)
    return setRailViz(ring[(i + (step || 1) + ring.length) % ring.length])
  }
  function cycleWidgetViz(step) {
    var i = styles.indexOf(widgetViz)
    return setWidget("viz", styles[(i + (step || 1) + styles.length) % styles.length])
  }

  function setMiniPlayer(on) {
    var v = on === true || on === "on" || on === "true" || on === "1"
    updateConfig(function(c) { c.miniPlayer = v })
    return statusText()
  }
  function setPlacement(where) {
    if (where !== "overlay" && where !== "desktop") return "unknown placement: " + where + " (overlay|desktop)"
    updateConfig(function(c) { c.placement = where })
    return statusText()
  }
  function setWidget(key, value) {
    if (key === "viz" && syncViz && styles.indexOf(value) >= 0) return setStyle(value)
    var allowed = { enabled: ["on", "off", "toggle"], style: ["compact", "full"], corner: ["top-left", "top-right", "bottom-left", "bottom-right"],
                    layer: ["top", "reserve", "desktop", "tile", "float"] }
    if (key === "viz" && styles.indexOf(value) < 0) return "unknown viz: " + value + " (" + styles.join("|") + ")"
    if (allowed[key] && allowed[key].indexOf(value) < 0) return "unknown " + key + ": " + value + " (" + allowed[key].join("|") + ")"
    if (!allowed[key] && key !== "viz" && key !== "monitor") return "unknown setting: " + key + " (enabled|style|corner|layer|monitor|viz)"
    updateConfig(function(c) {
      c.widget = c.widget || {}
      // `toggle` exists so a keybind can be one command rather than two
      c.widget[key] = key === "enabled"
        ? (value === "toggle" ? !c.widget.enabled : value === "on")
        : value
    })
    return statusText()
  }

  // ---- links ------------------------------------------------------------
  //
  // The engine owns these rather than the window, so a link can be copied from
  // a keybind with nothing open.
  function tidalUrl(kind, id) {
    if (!id) return ""
    // A mix is assembled for one account and its id means nothing to anyone
    // else, so there is deliberately no link for one.
    var kinds = { track: "track", album: "album", artist: "artist", playlist: "playlist" }
    return kinds[kind] ? "https://tidal.com/" + kinds[kind] + "/" + id : ""
  }

  // song.link takes a TIDAL id directly and sends whoever opens it to the
  // service they actually use - which is the point, since a bare TIDAL link is
  // useless to a friend on Spotify. Their API wants a key now; this URL form
  // does not, and it costs us no request at all.
  function universalUrl(kind, id) {
    if (!id) return ""
    if (kind === "track") return "https://song.link/t/" + id
    if (kind === "album") return "https://album.link/t/" + id
    return ""
  }

  function shareUrl(kind, id, universal) {
    return (universal ? universalUrl(kind, id) : "") || tidalUrl(kind, id)
  }

  function copyShare(kind, id, universal) {
    var url = shareUrl(kind, id, universal)
    if (url) Quickshell.clipboardText = url
    return url
  }

  function statusText() {
    return JSON.stringify({ open: open, library: libraryOpen, widget: widget, style: style, railViz: railViz, miniPlayer: miniPlayer, placement: placement,
                            cava: hasCava, listening: listening,
                            energy: Math.round(energy * 1000) / 1000, bass: Math.round(bass * 1000) / 1000,
                            beat: Math.round(beat * 1000) / 1000, kick: Math.round(kick * 1000) / 1000,
                            snap: Math.round(snap * 1000) / 1000, swell: Math.round(swell * 1000) / 1000, kicks: kicks,
                            tempo: Math.round(tempo), tempoConfidence: Math.round(tempoConfidence * 100) / 100,
                            peakLag: peakLag, peakCorr: Math.round(peakCorr * 100) / 100,
                            onsetRate: Math.round(onsetRate * 100) / 100, densityBpm: Math.round(densityBpm * 100) / 100,
                            candLags: candLags,
                            flowTarget: Math.round(flowTarget * 100) / 100, flow: Math.round(flow * 100) / 100,
                            player: player ? (player.identity || "") : "" })
  }

  IpcHandler {
    id: ipc
    target: "orpheus"
    function status(): string { return root.statusText() }
    function toggle(): string { root.open = !root.open; return root.statusText() }
    function show(): string { root.open = true; return root.statusText() }
    function hide(): string { root.open = false; return root.statusText() }
    function library(): string { root.libraryOpen = !root.libraryOpen; return root.statusText() }
    function login(): string { root.libraryOpen = true; root.loginRequests++; return root.statusText() }
    function eq(): string { root.libraryOpen = true; root.eqRequests++; return root.statusText() }
    function lyrics(): string { root.libraryOpen = true; root.lyricsRequests++; return root.statusText() }
    function style(name: string): string { return root.setStyle(name) }
    function railViz(name: string): string { return root.setRailViz(name) }
    function nextRailViz(): string { return root.cycleRailViz(1) }
    function nextStyle(): string { return root.nextStyle(1) }
    function miniPlayer(on: string): string { return root.setMiniPlayer(on) }
    function placement(where: string): string { return root.setPlacement(where) }
    function widget(key: string, value: string): string { return root.setWidget(key, value) }
  }

  // Nothing tears this plugin down for us. Disabling it at runtime left the
  // IpcHandler registered against the "orpheus" target and every Timer and
  // Process still live, so re-enabling added a second set and the shell locked
  // up. Stock Omarchy has no convention to copy here -- Bar.qml:335 is the
  // closest thing -- so release it by hand: drop the IPC registration first so
  // nothing can call back into a half-dead object graph, then stop everything
  // non-visual that has a `running` switch (Timers, Processes), whether or not
  // it has an id.
  Component.onDestruction: {
    // When the whole engine goes down (app quit) the handler may already be gone.
    if (ipc) ipc.enabled = false
    for (var i = 0; i < root.data.length; i++) {
      var o = root.data[i]
      if (o && o.running !== undefined) o.running = false
    }
    if (apiClient) apiClient.active = false
  }
}
