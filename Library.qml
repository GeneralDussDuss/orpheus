import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import "Tui.js" as Tui

// Orpheus: the TIDAL player window, built as a terminal app. Text panes in
// box borders, keys on everything, pixels only for album art and the live
// spectrum. Keyboard first; the mouse works too.
FloatingWindow {
  id: win

  property var engine: null
  readonly property var api: engine ? engine.api : null
  readonly property var st: api ? api.player : ({})
  readonly property var eqState: (api && api.status && api.status.eq) || ({})
  readonly property bool eqActive: eqState.active === true

  // The curve as eight block glyphs, for the transport bar. Not a readout you
  // can set anything from -- it is there to answer "is something shaping this,
  // and roughly what" at a glance, and to be a target to click.
  function eqSpark() {
    // Bypassed reads as a flat line rather than a flat row of blocks: the
    // difference between "off" and "on but flat" should be obvious at a glance.
    var g = eqState.gains
    if (!eqActive || !g || !g.length) return "────────"
    var blocks = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    var out = ""
    // ten bands into eight glyphs, averaging the pairs that collide
    for (var i = 0; i < 8; i++) {
      var a = Math.floor(i * g.length / 8), b = Math.floor((i + 1) * g.length / 8)
      var sum = 0, n = 0
      for (var k = a; k < Math.max(a + 1, b); k++) { sum += g[k] || 0; n++ }
      var v = n ? sum / n : 0
      var idx = Math.round((v + 12) / 24 * 7)
      out += blocks[Math.max(0, Math.min(7, idx))]
    }
    return out
  }
  readonly property var track: api ? api.track : null
  readonly property real clock: engine ? engine.time : -1

  title: "Orpheus"
  // Force full alpha: some themes carry a translucent background, which let
  // whatever sits behind the window bleed through the player. The Hyprland
  // rule already asks for opacity 1, but that cannot fix a surface whose own
  // colour has alpha.
  //
  // The coercion through `baseBg` is the part that matters. Color.background
  // can arrive as a STRING, and `.r`/`.g`/`.b` on a string are undefined, so
  // Qt.rgba() built straight from them returns a fully transparent colour --
  // which made the whole window see-through on exactly the themes this guard
  // was written for. Declaring it as a `color` property forces the conversion
  // first, after which the components are real numbers.
  readonly property color baseBg: Color.background
  color: Qt.rgba(baseBg.r, baseBg.g, baseBg.b, 1)
  onVisibleChanged: if (!visible && engine) engine.libraryOpen = false

  // ---- fit the monitor we're on ---------------------------------------------
  // Monitors differ a lot here (3440x1440 @1 vs a rotated GPD panel @1.33), so the
  // window caps itself to whichever monitor Hyprland says it's on, and refits
  // (shrink + center) when it lands on one that's too small.
  readonly property var toplevel: {
    var list = Hyprland.toplevels.values
    for (var i = 0; i < list.length; i++)
      if (list[i].title === "Orpheus" && list[i].lastIpcObject && list[i].lastIpcObject.class === "org.quickshell") return list[i]
    return null
  }
  readonly property var monitor: toplevel && toplevel.monitor ? toplevel.monitor : Hyprland.focusedMonitor
  readonly property size room: {
    var m = monitor
    if (!m) return Qt.size(1600, 900)
    var rotated = m.lastIpcObject && (m.lastIpcObject.transform % 2) === 1
    var w = (rotated ? m.height : m.width) / (m.scale || 1)
    var h = (rotated ? m.width : m.height) / (m.scale || 1)
    return Qt.size(Math.floor(w * 0.96), Math.floor(h * 0.92))
  }
  maximumSize: room
  minimumSize: Qt.size(Math.min(Math.round(cw * 90), room.width), Math.min(Math.round(ch * 26), room.height))
  implicitWidth: Math.min(Math.round(cw * 150), room.width)
  implicitHeight: Math.min(Math.round(ch * 44), room.height)

  // Refit only when *our* window moves monitor or a monitor comes/goes, and only
  // when the room actually changed: comparing values, not the size object,
  // which re-creates on every evaluation and once fed a refresh/refit loop.
  property string roomKey: ""
  onRoomChanged: {
    var key = room.width + "x" + room.height
    if (key === roomKey) return
    roomKey = key
    refit.restart()
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var mine = win.toplevel && win.toplevel.lastIpcObject && event.data
                 && event.data.indexOf(String(win.toplevel.lastIpcObject.address).replace(/^0x/, "")) === 0
      if ((event.name === "movewindowv2" && mine) || event.name === "monitoradded" || event.name === "monitorremoved")
        refit.restart()
    }
  }
  Timer {
    id: refit
    interval: 300
    onTriggered: {
      var o = win.toplevel ? win.toplevel.lastIpcObject : null
      if (!o || !o.size || !o.floating) return
      if (o.size[0] <= win.room.width && o.size[1] <= win.room.height) return
      var w = Math.min(o.size[0], win.room.width), h = Math.min(o.size[1], win.room.height)
      Quickshell.execDetached(["hyprctl", "--batch",
        "dispatch hl.dsp.window.resize({ x = " + w + ", y = " + h + ", window = \"address:" + o.address + "\" }) ; "
        + "dispatch hl.dsp.window.center({ window = \"address:" + o.address + "\" })"])
    }
  }

  // ---- grid & colour -------------------------------------------------------
  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }

  // ♥ toggles beside the song, artist and album.
  component Heart: Text {
    property string kind: ""
    property string itemId: ""
    readonly property bool on: !!win.api && win.api.isLiked(kind, itemId)
    visible: itemId !== ""
    text: on ? "󰋑" : "󰋕"
    font.family: win.family; font.pixelSize: Style.font.body + 2
    color: on ? win.accentText : (hm.containsMouse ? win.fg : win.dim)
    scale: hm.pressed ? 0.85 : 1
    Behavior on scale { SpringAnimation { spring: 6; damping: 0.4 } }
    MouseArea { id: hm; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                onClicked: win.api.toggleLike(parent.kind, parent.itemId)
                TuiTip { text: (on ? "unlike" : "like") + " this " + kind; key: kind === "track" ? "F" : "" } }
  }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height
  readonly property string family: Style.font.family
  readonly property color bg: Color.background
  readonly property color fg: Tui.ensure(Color.foreground, bg, 7)
  readonly property color dim: Tui.muted(Color.foreground, bg, 4.5)
  readonly property color accent: Tui.ensure(Color.accent, bg, 3)
  readonly property color accentText: Tui.ensure(Color.accent, bg, 4.5)
  readonly property color cursorFill: Tui.alpha(Color.accent, 0.16)
  // Glow, only where light means something: the play key on the beat, the
  // playhead, the playing row, the focused pane, and the cover's own light.
  readonly property real bloom: Tui.bloom(engine)
  readonly property real beat: engine && st.playing ? Math.max(0, Math.min(1, engine.beat || 0)) : 0

  function clockText(s) {
    s = Math.max(0, Math.floor(s || 0))
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), r = s % 60
    return (h ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (r < 10 ? "0" : "") + r
  }
  function pad(s, n) {
    s = String(s || "")
    if (s.length > n) return s.slice(0, Math.max(0, n - 1)) + "…"
    while (s.length < n) s += " "
    return s
  }
  function lpad(s, n) { s = String(s || ""); while (s.length < n) s = " " + s; return s }
  function artists(a) { return (a || []).join(", ") }

  // Track table columns, shared by the header row and every track row.
  function trackCols(cols) {
    var rest = cols - 4 - 10
    var showAlbum = page.kind !== "album" && rest > 60
    var tw = Math.floor(rest * (showAlbum ? 0.45 : 0.6))
    var aw = Math.floor(rest * (showAlbum ? 0.3 : 0.4))
    return { tw: tw, aw: aw, bw: rest - tw - aw, album: showAlbum }
  }
  function trackLine(it, num, cols) {
    var c = trackCols(cols)
    var heart = api && api.isLiked("track", it.id) ? "󰋑 " : "  "
    return num + " " + heart + pad((it.explicit ? "🅴 " : "") + it.title, c.tw - 2) + pad(artists(it.artists), c.aw)
         + pad(c.album ? it.album : "", c.bw) + (it.hires ? " HR " : "    ") + lpad(clockText(it.duration), 6)
  }
  function headerLine(cols) {
    var c = trackCols(cols)
    return "  # " + "  " + pad("TITLE", c.tw - 2) + pad("ARTIST", c.aw) + pad(c.album ? "ALBUM" : "", c.bw) + "    " + lpad("TIME", 6)
  }
  // How many people watched, or listened, in as few characters as possible.
  function viewText(n, unit) {
    n = Number(n || 0)
    unit = " " + (unit || "views")
    if (!n) return ""
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B" + unit
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M" + unit
    if (n >= 1e3) return Math.round(n / 1e3) + "K" + unit
    return n + unit
  }

  // How long ago, in the fewest characters that stay true. The date behind
  // this is YouTube's own "3 weeks ago" read back through yt-dlp, so it is
  // only ever accurate to the unit it is printed in - which is exactly what an
  // age says, and what an exact date would quietly lie about.
  function ageText(ts) {
    if (!ts) return ""
    var d = (Date.now() / 1000 - ts) / 86400
    if (d < 0.5) return "today"
    if (d < 7) return Math.round(d) + "d ago"
    if (d < 31) return Math.round(d / 7) + "w ago"
    if (d < 345) return Math.round(d / 30.4) + "mo ago"
    return Math.round(d / 365) + "y ago"
  }

  // A video row. The same line serves a YouTube result, a series and an
  // episode, because the section never learns which provider answered.
  function mediaLine(it, cols) {
    var glyph = it.kind === "show" ? "❖" : (it.live ? "◉" : "▶")
    var right = it.kind === "show" ? (it.episodes ? it.episodes + " episodes" : "series")
              : it.live ? "LIVE" : clockText(it.duration)
    var sub = it.kind === "show" ? "" : (artists(it.artists) || (it.ep ? "episode " + it.ep : ""))
    var wide = cols - 4 - 8
    var tw = sub ? Math.floor(wide * 0.52) : wide
    // a cut column ends in "…" right at its edge, so each keeps a gutter
    var line = " " + glyph + "  " + pad(it.title, tw - 2) + "  "
    if (sub) line += pad(sub, wide - tw - 23) + "  " + pad(viewText(it.views, it.provider === "soundcloud" ? "plays" : "views"), 12) + pad(ageText(it.published), 9)
    return line + lpad(right, 8)
  }

  readonly property bool hasTrackTable: pageTracks.length > 0 && page.type !== "search" && page.type !== "video"
  property real loadedAt: 0

  // Where the sound actually goes, for the status line.
  property string outputName: ""
  Process {
    id: sinkProc
    command: ["sh", "-c", "wpctl inspect @DEFAULT_AUDIO_SINK@ | sed -n 's/.*node.description = \"\\(.*\\)\"/\\1/p' | head -1"]
    stdout: StdioCollector { onStreamFinished: win.outputName = text.trim() }
  }
  // wpctl names the output on Linux; Windows has no equivalent here yet.
  Timer { interval: 5000; repeat: true; triggeredOnStart: true; running: win.visible && Qt.platform.os !== "windows"; onTriggered: sinkProc.running = true }
  function qualityText(s) {
    if (!s || !s.quality) return ""
    // Lossless shows its nominal PCM rate (bits x rate x 2 channels): FLAC's real
    // bitrate wanders with the music, and this is the figure people compare.
    var lossy = { HIGH: 320, LOW: 96 }[s.quality]
    var kbps = lossy || (s.bitDepth && s.sampleRate ? Math.round(s.bitDepth * s.sampleRate * 2 / 1000) : 0)
    var fmt = s.codec || (lossy ? "AAC" : "")
    var res = !lossy && s.bitDepth && s.sampleRate ? " " + s.bitDepth + "/" + (s.sampleRate / 1000) : ""
    return (fmt + res + (kbps ? " · " + kbps + " kbps" : "")).trim()
  }

  // ---- navigation ------------------------------------------------------------
  readonly property var navItems: [
    { key: "1", label: "home", page: { type: "home", title: "home" } },
    { key: "2", label: "search", page: { type: "search", title: "search" } },
    { key: "3", label: "mixes", page: { type: "collection", what: "mixes", title: "mixes" } },
    { key: "4", label: "playlists", page: { type: "collection", what: "playlists", title: "playlists" } },
    { key: "5", label: "albums", page: { type: "collection", what: "albums", title: "albums" } },
    { key: "6", label: "tracks", page: { type: "collection", what: "tracks", title: "liked tracks" } },
    { key: "7", label: "artists", page: { type: "collection", what: "artists", title: "artists" } },
    { key: "8", label: "video", page: { type: "video", title: "video" } },
    { key: "9", label: "stats", page: { type: "stats", title: "stats" } },
    { key: ",", label: "settings", page: { type: "settings", title: "settings" } }
  ]
  property var page: navItems[0].page
  property var history: []
  property var rows: []          // [{ header } | { item, trackIndex }]
  property var pageData: null    // detail payload (album/playlist/mix/artist)
  property var pageTracks: []    // tracks on this page, in play order
  property bool loading: false
  property string query: ""

  // ---- the video section -----------------------------------------------------
  //
  // One section, two providers, and nothing in the page that knows which one it
  // is talking to: a provider answers with rows, a row knows how to play
  // itself. `page.show` is set on the episode list of one series.
  property string vprovider: "youtube"
  property string vquery: ""
  readonly property bool videoPage: page.type === "video"
  readonly property bool searching: page.type === "search" || (videoPage && !page.show)
  readonly property var videoState: (api && api.video) || ({})
  readonly property bool watching: videoState.running === true
  readonly property var providers: (api && api.providers) || ({ youtube: true })
  readonly property var vproviders: [
    { id: "youtube", label: "youtube", by: "yt-dlp" },
    { id: "soundcloud", label: "soundcloud", by: "yt-dlp" },
    { id: "anime", label: "anime", by: providers.anime || !providers.curd ? "ani-cli" : "curd" }
  ]
  onVproviderChanged: if (videoPage && !page.show) load()

  // A daemon error arrives as plain text; it is already a sentence.
  function errText(d, fallback) {
    return (typeof d === "string" && d.trim()) ? d.trim().toLowerCase() : fallback
  }

  // The account line sits in every screenshot of this window, so never render a
  // contactable address: mask the local part and keep just enough to tell which
  // account is signed in.
  function maskAccount(u) {
    if (!u) return "tidal"
    var at = u.indexOf("@")
    if (at < 1) return u.length > 4 ? u.slice(0, 2) + "…" : u
    return u.slice(0, 2) + "…" + u.slice(at)
  }

  function go(p) { history = history.concat([page]); page = p }
  function back() {
    if (searchInput.activeFocus) { list.forceActiveFocus(); return }
    if (!history.length) return
    page = history[history.length - 1]
    history = history.slice(0, -1)
  }

  onPageChanged: load()

  // `omarchy-shell orpheus login` (Ctrl+Shift+O) lands here on the sign-in page.
  function showLogin() {
    if (page.type !== "login") go({ type: "login", title: "sign in" })
  }
  function showEq() {
    if (page.type !== "eq") go({ type: "eq", title: "equalizer" })
  }
  function showLyrics() {
    if (page.type !== "lyrics") go({ type: "lyrics", title: "lyrics" })
  }
  function showSettings() {
    if (page.type !== "settings") go({ type: "settings", title: "settings" })
  }
  Connections {
    target: win.engine
    function onLoginRequestsChanged() { win.engine.loginHandled = win.engine.loginRequests; win.showLogin() }
    function onEqRequestsChanged() { win.engine.eqHandled = win.engine.eqRequests; win.showEq() }
    function onLyricsRequestsChanged() { win.engine.lyricsHandled = win.engine.lyricsRequests; win.showLyrics() }
    function onSettingsRequestsChanged() { win.engine.settingsHandled = win.engine.settingsRequests; win.showSettings() }
  }
  Connections {
    target: win.api
    function onSignedInChanged() { if (win.api.signedIn) win.load() }
  }

  function section(title, items) {
    var out = []
    if (!items || !items.length) return out
    if (title) out.push({ header: title })
    for (var i = 0; i < items.length; i++) out.push({ item: items[i] })
    return out
  }
  function setRows(r, tracks) {
    var ti = 0
    for (var i = 0; i < r.length; i++) if (r[i].item && r[i].item.kind === "track") r[i].trackIndex = ti++
    pageTracks = tracks || r.filter(function(x) { return x.item && x.item.kind === "track" }).map(function(x) { return x.item })
    rows = r
    loadedAt = Date.now()
    loading = false
    list.currentIndex = firstItemRow()
  }
  function firstItemRow() {
    for (var i = 0; i < rows.length; i++) if (rows[i].item) return i
    return -1
  }

  function load() {
    // Settings need no TIDAL session and nothing loaded behind them.
    if (page.type === "settings" || page.type === "stats") { rows = []; loading = false; return }
    // The video section needs no TIDAL session: YouTube and ani-cli are not
    // TIDAL, and making someone sign in to watch something would be a lie.
    if (!api || (!api.signedIn && page.type !== "video")) return
    rows = []; pageData = null; pageTracks = []; loading = true
    var p = page
    if (p.type === "home") {
      var got = {}
      var done = function() {
        if (got.mixes === undefined || got.playlists === undefined || got.albums === undefined || page !== p) return
        setRows(section("mixes", got.mixes.slice(0, 8)).concat(section("playlists", got.playlists.slice(0, 8)), section("albums", got.albums.slice(0, 10))))
      }
      var kinds = ["mixes", "playlists", "albums"]
      for (var k = 0; k < kinds.length; k++) {
        (function(w) {
          api.get("/collection/" + w, function(ok, d) { got[w] = ok && Array.isArray(d) ? d : []; done() })
        })(kinds[k])
      }
    } else if (p.type === "search") {
      runSearch()
      searchInput.forceActiveFocus()
    } else if (p.type === "collection") {
      api.get("/collection/" + p.what, function(ok, d) { if (page === p) setRows(section("", ok ? d : [])) })
    } else if (p.type === "video") {
      loadVideo(p)
    } else if (p.type === "detail") {
      api.get("/" + p.kind + "/" + p.id, function(ok, d) {
        if (page !== p) return
        pageData = ok ? d : { title: "couldn't load this", items: [] }
        var r = section(p.kind === "artist" ? "top tracks" : "", pageData.items || [])
        if (p.kind === "artist") r = r.concat(section("albums", pageData.albums), section("singles & eps", pageData.singles))
        setRows(r)
      })
    }
  }

  function loadVideo(p) {
    if (p.show) {
      api.animeEpisodes(p.show.query, p.show.index, function(ok, d) {
        if (page !== p) return
        if (!ok) { setRows([]); say(errText(d, "couldn't list the episodes")); return }
        setRows(section(p.show.title, (d && d.results) || []))
      })
      return
    }
    searchInput.forceActiveFocus()
    var q = vquery.trim()
    if (!q) { setRows([]); return }
    var prov = vprovider
    var answer = function(ok, d) {
      if (page !== p || prov !== vprovider || q !== vquery.trim()) return
      if (!ok) { setRows([]); say(errText(d, "that search went nowhere")); return }
      setRows(section(prov, (d && d.results) || []))
    }
    // Without ani-cli (Windows) anime is Curd's alone; the empty page says so.
    if (prov === "anime" && !providers.anime) { setRows([]); return }
    if (prov === "anime") api.animeSearch(q, answer)
    else api.ytSearch(q, answer, prov)
  }

  // Typing goes to whichever search the page is showing.
  function searchNow() { if (videoPage) load(); else runSearch() }

  // ⏎ on a video row. A series opens, a SoundCloud row has nothing to watch so
  // it is listened to, and everything else plays in the window.
  function videoActivate(it) {
    if (it.kind === "show") { go({ type: "video", show: it, title: it.title }); return }
    if (it.provider === "soundcloud") { listenHere(); return }
    say("opening ╱╱ " + it.title)
    api.watch(it, function(ok, d) { if (!ok) say(errText(d, "couldn't play that")) })
  }

  // The other half of a yt-dlp row: the sound of it, through the music player,
  // with the rest of the results behind it as a queue.
  function listenHere() {
    var r = rows[list.currentIndex]
    var prov = r && r.item ? r.item.provider : ""
    if (prov !== "youtube" && prov !== "soundcloud") { say("only youtube and soundcloud rows can be listened to"); return }
    api.listen(pageTracks, r.trackIndex || 0, { kind: prov, title: prov + " · " + vquery.trim() })
    say("listening ╱╱ " + r.item.title)
  }

  function runSearch() {
    var q = query.trim()
    if (!q) { setRows([]); return }
    loading = true
    var p = page
    api.get("/search?q=" + encodeURIComponent(q), function(ok, d) {
      if (page !== p || q !== query.trim()) return
      if (!ok) { setRows([]); return }
      setRows(section("top", d.top ? [d.top] : []).concat(
        section("tracks", d.tracks.slice(0, 10)), section("albums", d.albums.slice(0, 8)),
        section("artists", d.artists.slice(0, 6)), section("playlists", d.playlists.slice(0, 6))))
    })
  }

  // Enter on a row.
  function activate(index) {
    var r = rows[index]
    if (!r || !r.item) return
    var it = r.item
    if (page.type === "video") { videoActivate(it); return }
    if (it.kind !== "track") { go({ type: "detail", kind: it.kind, id: it.id, title: it.title }); return }
    var p = page
    if (p.type === "detail" && p.kind !== "artist") api.play({ kind: p.kind, id: p.id }, r.trackIndex)
    else if (p.type === "search") api.play(it)
    else api.playTracks(pageTracks, r.trackIndex, { kind: p.type, id: p.id || p.what, title: p.title })
  }
  function playPage(shuffle) {
    if (!pageTracks.length) return
    if (shuffle) api.control("shuffle", { on: true })
    var start = shuffle ? Math.floor(Math.random() * pageTracks.length) : 0
    if (page.type === "detail" && page.kind !== "artist") api.play({ kind: page.kind, id: page.id }, start)
    else api.playTracks(pageTracks, start, { kind: page.type, id: page.id || page.what, title: page.title })
  }

  // ---- sharing ----------------------------------------------------------------
  //
  // What you want to send someone is almost never what is playing: it is the
  // row you are looking at. So the target is the cursor first, the page second,
  // and the playing track only as a last resort.
  function shareTarget() {
    var r = rows[list.currentIndex]
    if (r && r.item) return r.item
    if (page.type === "detail" && page.id) return { kind: page.kind, id: page.id }
    if (track) return { kind: "track", id: track.id }
    return null
  }

  function share(universal) { return shareItem(shareTarget(), universal) }
  function shareItem(it, universal) {
    if (!it) { say("nothing to share"); return true }
    if (!engine) return true
    var url = engine.shareUrl(it.kind, it.id, universal)
    if (!url) { say("a " + it.kind + " has no link to share"); return true }
    // asked for a universal link and got the TIDAL one back: say so, rather
    // than letting someone paste a TIDAL link thinking it is portable
    var note = universal && !engine.universalUrl(it.kind, it.id) ? "tidal only · " : ""
    Quickshell.clipboardText = url
    say("copied · " + note + url)
    return true
  }

  // Copying is invisible otherwise: nothing moves, and a working shortcut looks
  // exactly like a dead one.
  property string flash: ""
  Timer { id: flashOff; interval: 2800; onTriggered: win.flash = "" }
  function say(msg) { flash = msg; flashOff.restart() }
  function dismissHint() { if (engine) engine.updateConfig(function(c) { c.playerHint = false }) }

  // ---- the context menu ----------------------------------------------------------
  //
  // Right-click on anything that is a track, album, artist or playlist. Every
  // entry is something a key already does (the key is printed beside it), plus
  // the few that had no key: add to the end of the queue, radio, go to.
  // `play` is how this particular row plays (a row on a page plays the page
  // from there; a queue row jumps to it).
  function menuFor(it, play) {
    var m = [], a = api, e = engine
    if (!it || !a) return m
    function add(label, key, run) { m.push({ label: label, key: key || "", run: run }) }
    function sep() { if (m.length && !m[m.length - 1].sep) m.push({ sep: true }) }
    var kind = it.kind
    if (videoPage || kind === "video" || kind === "show") {
      add(kind === "show" ? "open" : "watch", "⏎", play)
      if (it.provider === "youtube" || it.provider === "soundcloud") add("listen in the player", "a", listenHere)
      return m
    }
    if (kind === "track") {
      if (play) add("play", "⏎", play)
      add("play next", "a", function() { queueItem(it, true) })
      add("add to the end of the queue", "", function() { queueItem(it, false) })
      add("start radio from this track", "", function() { a.play(it); say("radio ╱╱ " + it.title) })
    } else {
      add("open", "⏎", function() { go({ type: "detail", kind: kind, id: it.id, title: it.title }) })
      if (kind !== "artist") {
        add("play", "", function() { a.play({ kind: kind, id: it.id }, 0) })
        add("play next", "a", function() { queueItem(it, true) })
        add("add to the end of the queue", "", function() { queueItem(it, false) })
      }
    }
    sep()
    if (kind !== "mix") {
      var liked = a.isLiked(kind, it.id)
      add(liked ? "unlike" : "like", "f", function() { a.toggleLike(kind, it.id); say((liked ? "unliked ╱╱ " : "liked ╱╱ ") + it.title) })
    }
    if (kind === "track" && it.albumId)
      add("go to the album", "", function() { go({ type: "detail", kind: "album", id: it.albumId, title: it.album || "album" }) })
    if ((kind === "track" || kind === "album") && it.artistId)
      add("go to the artist", "", function() { go({ type: "detail", kind: "artist", id: it.artistId, title: artists(it.artists) || "artist" }) })
    if (e && e.shareUrl(kind, it.id, false)) {
      sep()
      add("copy link", "y", function() { shareItem(it, false) })
      if (e.universalUrl(kind, it.id)) add("copy universal link", "Y", function() { shareItem(it, true) })
    }
    return m
  }
  function rowMenu(index, from, x, y) {
    var r = rows[index]
    if (!r || !r.item) return
    list.currentIndex = index
    var label = r.item.kind === "track" || videoPage ? (videoPage ? "video" : "track") : r.item.kind
    ctxMenu.popup(from, x, y, label, menuFor(r.item, function() { list.forceActiveFocus(); activate(index) }))
  }
  function trackMenu(t, from, x, y, play) {
    // the keys beside the entries act on the cursor's row, not on this one
    if (t) ctxMenu.popup(from, x, y, "track", menuFor(t, play || null).map(function(e) { return e.sep ? e : { label: e.label, run: e.run } }))
  }

  // ---- the player rail's visualizer ----------------------------------------------
  function railName(v) { return v === "off" ? "album art" : (engine && engine.styleLabels[v] ? engine.styleLabels[v].toLowerCase() : v) }
  function railMenu(from, x, y) {
    var e = engine, m = []
    if (!e) return
    for (var i = 0; i < e.styles.length; i++)
      (function(s) { m.push({ label: railName(s), on: e.railViz === s, run: function() { e.setRailViz(s) } }) })(e.styles[i])
    m.push({ sep: true })
    m.push({ label: "album art", on: e.railViz === "off", run: function() { e.setRailViz("off") } })
    m.push({ sep: true })
    m.push({ label: (e.open ? "close" : "open") + " the big visualizer", key: "V", run: function() { e.open = !e.open } })
    ctxMenu.popup(from, x, y, "visualizer", m)
  }

  // ---- keys -------------------------------------------------------------------
  function videoKey(e) {
    var k = e.key, t = e.text
    if (k === Qt.Key_Tab || t === "\t") { nextProvider(); return true }
    if (t === "a") { listenHere(); return true }
    if (t === "c") { openCurd(); return true }
    if (!watching) return false
    var pos = videoState.position || 0
    if (k === Qt.Key_Space) { api.videoControl("toggle"); return true }
    if (k === Qt.Key_Right || t === "l") { api.videoControl("seek", { position: pos + 10 }); return true }
    if (k === Qt.Key_Left || t === "h") { api.videoControl("seek", { position: Math.max(0, pos - 10) }); return true }
    if (t === "F") { api.videoControl("fullscreen"); return true }
    if (t === "x") { api.videoControl("close"); say("closed the video window"); return true }
    return false
  }
  readonly property int providerIndex: {
    for (var i = 0; i < vproviders.length; i++) if (vproviders[i].id === vprovider) return i
    return 0
  }

  // ---- row actions (keys, hint buttons and the context menu share these) ------
  function cursorItem() { var r = rows[list.currentIndex]; return r && r.item ? r.item : null }
  function queueItem(it, next) {
    if (!it || !api) return
    api.enqueue(it, next)
    // queueing was silent before: nothing on screen moved until the next track
    say((next ? "playing next ╱╱ " : "added to the queue ╱╱ ") + (it.title || it.kind))
  }
  function likeCursor() {
    // Like/unlike what's under the cursor; on a detail page with no row, the page itself.
    var it = cursorItem()
    if (it && it.kind !== "mix") api.toggleLike(it.kind, it.id)
    else if (page.type === "detail" && page.kind !== "mix") api.toggleLike(page.kind, page.id)
  }
  function nextProvider() { vprovider = vproviders[(providerIndex + 1) % vproviders.length].id }
  function openCurd() {
    if (!providers.curd) { say("curd is not installed"); return }
    say("handing over to curd · it owns the player from here")
    api.curd(true, function(ok, d) { if (!ok) say(errText(d, "couldn't start curd")) })
  }

  function handleKey(e) {
    var k = e.key, t = e.text
    if (k === Qt.Key_Escape || k === Qt.Key_Backspace) { back(); return true }
    if (t === "q" || (k === Qt.Key_W && (e.modifiers & Qt.ControlModifier))) { engine.libraryOpen = false; return true }
    if (t === "/") { go({ type: "search", title: "search" }); return true }
    if (t === "e") { go({ type: "eq", title: "equalizer" }); return true }
    if (t === "L") { go({ type: "lyrics", title: "lyrics" }); return true }
    if (t === ",") { showSettings(); return true }
    if (t === "?") { keysSheet.open(); return true }
    if (t >= "1" && t <= "9") { go(navItems[Number(t) - 1].page); return true }
    // On the video page the transport reaches the video window instead: it is
    // the thing you are looking at, and the music is paused behind it anyway.
    if (videoPage && videoKey(e)) return true
    if (k === Qt.Key_Space) { api.control("toggle"); return true }
    if (t === "n") { api.control("next"); return true }
    if (t === "p") { api.control("previous"); return true }
    if (k === Qt.Key_Right || t === "l") { api.control("seek", { position: (api.position || 0) + 10 }); return true }
    if (k === Qt.Key_Left || t === "h") { api.control("seek", { position: Math.max(0, (api.position || 0) - 10) }); return true }
    if (t === "+" || t === "=") { volMeter.setVolume(volMeter.shown + 5); return true }
    if (t === "-") { volMeter.setVolume(volMeter.shown - 5); return true }
    if (t === "s") { api.control("shuffle"); return true }
    if (t === "r") { api.control("repeat"); return true }
    if (t === "v") { engine.cycleRailViz(1); return true }
    if (t === "V") { engine.open = !engine.open; return true }
    if (t === "P") { playPage(false); return true }
    if (t === "S") { playPage(true); return true }
    if (t === "a") { queueItem(cursorItem(), true); return true }
    if (t === "f") { likeCursor(); return true }
    if (t === "F") { if (track) api.toggleLike("track", track.id); return true }
    if (t === "y") return share(false)
    if (t === "Y") return share(true)
    return false
  }

  Item {
    anchors.fill: parent
    anchors.margins: win.cw

    // ── status line (btop-style): brand · now playing · signal path · close ──
    Item {
      id: statusLine
      width: parent.width
      height: win.ch * 1.4
      Text {
        id: brand
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.StyledText
        text: '<font color="' + Tui.hex(win.accent) + '">╱╱╱</font> <b>ORPHEUS</b>'
        font.family: win.family; font.pixelSize: Style.font.body; font.letterSpacing: 2
        color: win.fg
      }
      // First runs: one line naming the few things nothing else on screen
      // says, until it is dismissed (remembered in config as playerHint: false).
      Row {
        id: firstHint
        visible: !!win.engine && win.engine.config.playerHint !== false
        anchors.left: brand.right; anchors.leftMargin: win.cw * 3
        anchors.verticalCenter: parent.verticalCenter
        spacing: win.cw * 1.5
        Text {
          text: "tip ╱╱"
          font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
          color: win.accentText
          anchors.verticalCenter: parent.verticalCenter
        }
        HintBar {
          anchors.verticalCenter: parent.verticalCenter
          keyColor: win.accentText; labelColor: win.fg; hoverColor: win.accentText
          items: [{ k: "v", l: "viz", run: function() { win.engine.cycleRailViz(1) }, tip: "cycle the visualizer by the art" },
                  { k: "^K", l: "commands", run: function() { cmdPalette.open() }, tip: "every action, by name" },
                  { k: "?", l: "keys", run: function() { keysSheet.open() }, tip: "every key and mouse gesture" },
                  { k: "right-click", l: "for more" },
                  { k: "✕", l: "", run: function() { win.dismissHint() }, tip: "got it, don't show this again", tipKey: "" }]
        }
      }
      Text {
        visible: !firstHint.visible
        anchors.left: brand.right; anchors.leftMargin: win.cw * 3
        anchors.right: chain.left; anchors.rightMargin: win.cw * 3
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: win.track ? (win.st.playing ? Tui.eq(win.clock, 1) : "‖‖‖") + "  " + win.track.title + "  ·  " + win.artists(win.track.artists) : ""
        font.family: win.family; font.pixelSize: Style.font.body
        color: win.st.playing ? win.fg : win.dim
      }
      Text {
        id: chain
        // the first-run tip takes the room first; the signal path comes back after
        visible: !firstHint.visible
                 || statusLine.width > brand.width + firstHint.width + implicitWidth + closeBtn.width + win.cw * 9
        anchors.right: closeBtn.left; anchors.rightMargin: win.cw * 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.StyledText
        text: {
          var q = win.qualityText(win.st.stream)
          return (q ? '<font color="' + Tui.hex(win.accentText) + '"><b>' + Tui.esc(q) + '</b></font>' : "")
               + (win.outputName ? '<font color="' + Tui.hex(win.dim) + '">  →  ' + Tui.esc(win.outputName) + '</font>' : "")
        }
        font.family: win.family; font.pixelSize: Style.font.caption
      }
      // Each hint is its own button now, rather than one line split by where
      // the click happened to land.
      HintBar {
        id: closeBtn
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        keyColor: win.accentText; labelColor: win.dim; hoverColor: win.accentText
        items: [{ k: "^K", l: "commands", run: function() { cmdPalette.open() }, tip: "every action, by name" },
                { k: "?", l: "keys", run: function() { keysSheet.open() }, tip: "every key and mouse gesture" },
                { k: "q", l: "close", run: function() { win.engine.libraryOpen = false }, tip: "close the player (music keeps playing)" }]
      }
    }

    // ┌─ orpheus ─┐ navigation + account
    TuiBox {
      id: nav
      x: 0; y: statusLine.height
      width: Math.round(win.cw * Math.max(16, Math.min(22, Math.floor(parent.width / win.cw * 0.15))))
      height: transport.y - y - win.ch * 0.2
      title: "library"
      keyHint: Tui.hints([["1-9", ""]], win.accentText, win.dim)
      clock: win.clock
      Column {
        width: parent.width
        Repeater {
          model: win.navItems
          // A section: lit when it is the page, and under the pointer it takes
          // the cursor's fill and a ▸ of its own, so it reads as a button.
          Text {
            required property var modelData
            readonly property bool on: win.page.type === modelData.page.type && (win.page.what || "") === (modelData.page.what || "")
            readonly property bool hot: navMouse.containsMouse
            width: parent.width
            text: (on || hot ? "▸ " : "  ") + modelData.label
            rightPadding: win.cw
            font.family: win.family
            font.pixelSize: Style.font.body
            font.bold: on
            color: on || hot ? win.accentText : win.dim
            Rectangle {
              z: -1
              visible: parent.hot && !parent.on
              anchors.fill: parent
              anchors.leftMargin: -win.cw * 0.5
              color: win.cursorFill
            }
            Text {
              anchors.right: parent.right
              text: modelData.key
              font.family: win.family
              font.pixelSize: Style.font.caption
              color: parent.on || parent.hot ? win.accentText : win.dim
              anchors.verticalCenter: parent.verticalCenter
            }
            MouseArea { id: navMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.go(modelData.page) }
          }
        }
      }
      Column {
        anchors.bottom: parent.bottom
        width: parent.width
        // What is actually streaming, not a picker: the daemon always takes the best
        // the sign-in allows. A device-link sign-in tops out at lossless, so that
        // case links to the hi-res sign-in.
        Text {
          readonly property bool capped: !!(win.api && win.api.signedIn && !win.api.login.hires)
          text: (win.qualityText(win.st.stream) || "—").toLowerCase() + (capped ? "  · get hi-res" : "")
          font.family: win.family; font.pixelSize: Style.font.caption
          color: capped && qm.containsMouse ? win.accentText : win.dim
          font.underline: capped && qm.containsMouse
          MouseArea { id: qm; anchors.fill: parent; hoverEnabled: true; enabled: parent.capped
                      cursorShape: Qt.PointingHandCursor
                      onClicked: win.go({ type: "login", title: "sign in", hires: true })
                      TuiTip { text: "this sign-in tops out at lossless: sign in again for hi-res" } }
        }
        Item { width: 1; height: win.ch * 0.5 }
        Text {
          width: parent.width
          elide: Text.ElideRight
          text: !win.api || !win.api.online ? "● service offline"
              : win.api.signedIn ? "● " + win.maskAccount(win.api.login.user) + (win.api.login.hires ? " · hi-res" : "")
              : "○ signed out"
          font.family: win.family; font.pixelSize: Style.font.caption
          color: acct.containsMouse ? win.accentText : win.api && win.api.signedIn ? win.dim : Color.urgent
          MouseArea { id: acct; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.go({ type: "login", title: "sign in" })
                      TuiTip { text: "account and sign-in" } }
        }
      }
    }

    // ┌─ page ─┐ the list
    TuiBox {
      id: mainBox
      x: nav.width + win.cw
      y: statusLine.height
      width: (side.visible ? side.x - win.cw : parent.width) - x
      height: nav.height
      title: win.page.type === "detail" ? win.page.kind + " · " + (win.pageData ? win.pageData.title : win.page.title || "")
           : (win.page.title || win.page.type)
      hintItems: {
        function h(k, l, run, tip) { return { k: k, l: l, run: run, tip: tip } }
        var act = function() { list.forceActiveFocus(); win.activate(list.currentIndex) }
        if (win.videoPage)
          return win.page.show ? [h("⏎", "watch", act), h("esc", "back", win.back)]
               : win.vprovider === "soundcloud" ? [h("⇥", "provider", win.nextProvider, "next provider"), h("⏎", "listen", act)]
               : [h("⇥", "provider", win.nextProvider, "next provider"), h("⏎", "watch", act),
                  h("a", "listen", win.listenHere, "play the sound through the music player"), h("c", "curd", win.openCurd, "hand over to curd")]
        if (win.page.type === "settings") return [h("⇥", "section"), h("h/l", "change"), h("⏎", "set")]
        if (win.page.type === "stats") return [h("⇥", "range"), h("w", "wrapped")]
        if (win.page.type === "search") return [h("/", "search", function() { searchInput.forceActiveFocus() }), h("⏎", "play", act)]
        return [h("⏎", "open", act, "open or play the row"), h("a", "next", function() { win.queueItem(win.cursorItem(), true) }, "play the row next"),
                h("f", "♥ like", win.likeCursor, "like the row"), h("P", "play all", function() { win.playPage(false) }, "play this page")]
      }
      footer: win.history.length ? "esc back" : ""
      focused: list.activeFocus || searchInput.activeFocus || (settingsLoader.item && settingsLoader.item.activeFocus)
               || (statsLoader.item && statsLoader.item.activeFocus) || false
      clock: win.clock
      glow: win.bloom

      // Detail header: art + title + actions.
      Item {
        id: header
        visible: win.page.type === "detail" || win.page.type === "search" || win.videoPage
        width: parent.width
        height: win.page.type === "detail" ? win.ch * 9
              : win.page.type === "search" ? win.ch * 2
              : win.videoPage ? (win.page.show ? 0 : win.ch * 3.4) + (win.watching ? win.ch * 2.1 : 0)
              : 0

        Row {
          visible: win.page.type === "detail"
          spacing: win.cw * 2
          Rectangle {
            width: win.ch * 8; height: width
            color: Tui.alpha(Color.accent, 0.12)
            Image {
              anchors.fill: parent
              source: win.pageData ? (win.pageData.art || "") : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize: Qt.size(width * 2, height * 2)
            }
          }
          Column {
            anchors.bottom: parent.bottom
            spacing: win.ch * 0.2
            Text {
              text: (win.page.kind || "").toUpperCase()
              font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 2; color: win.dim
            }
            Text {
              text: Tui.decode(win.pageData ? win.pageData.title : (win.page.title || ""), win.pageData ? 1 : 0.2, 3)
              font.family: win.family; font.pixelSize: Style.font.body + 8; font.bold: true; color: win.fg
              width: mainBox.width - win.ch * 8 - win.cw * 8
              elide: Text.ElideRight
            }
            Text {
              color: win.dim
              font.family: win.family; font.pixelSize: Style.font.body
              text: !win.pageData ? "loading…"
                : win.page.kind === "album" ? win.artists(win.pageData.artists) + (win.pageData.year ? " · " + win.pageData.year : "") + " · " + (win.pageData.items || []).length + " tracks · " + win.clockText(win.pageData.duration)
                : win.page.kind === "artist" ? "artist"
                : (win.pageData.subtitle ? win.pageData.subtitle + " · " : "") + (win.pageData.items || []).length + " tracks"
            }
            Item { width: 1; height: win.ch * 0.2 }
            HintBar {
              keyColor: win.accentText; labelColor: win.fg; hoverColor: win.accentText
              readonly property bool liked: !!win.api && win.api.isLiked(win.page.kind, win.page.id)
              items: [{ k: "P", l: "play", run: function() { win.playPage(false) }, tip: "play from the top" },
                      { k: "S", l: "shuffle", run: function() { win.playPage(true) }, tip: "shuffle all of it" }]
                     // Not "f": with the cursor on a row, f likes the row, and the
                     // header used to promise it would like the whole album.
                     .concat(win.page.kind === "mix" ? [] : [{ k: liked ? "♥" : "♡", l: liked ? "liked" : "like",
                                                              run: function() { win.api.toggleLike(win.page.kind, win.page.id) },
                                                              tip: "like this " + win.page.kind + " (f likes the selected row)", tipKey: "" }])
            }
          }
        }

        // ╱╱ which service answers. Tab moves between them; a provider that is
        // not installed says so rather than failing when you press ⏎.
        Row {
          visible: win.videoPage && !win.page.show
          spacing: win.cw * 2
          Text {
            text: "╱╱ ⇥"
            font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            color: win.accent
          }
          Repeater {
            model: win.vproviders
            Text {
              required property var modelData
              readonly property bool on: modelData.id === win.vprovider
              readonly property bool ready: win.providers[modelData.id] !== false
              textFormat: Text.StyledText
              text: '<font color="' + Tui.hex(on || pm.containsMouse ? win.accentText : win.dim) + '">'
                    + (on ? "▰ " : "▱ ") + Tui.esc(modelData.label) + '</font>'
                    + ' <font color="' + Tui.hex(Tui.mix(win.dim, win.bg, 0.3)) + '">'
                    + Tui.esc(ready ? modelData.by : "not installed") + '</font>'
              font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
              Behavior on opacity { NumberAnimation { duration: 160 } }
              opacity: ready ? 1 : 0.55
              MouseArea {
                id: pm
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { win.vprovider = parent.modelData.id; list.forceActiveFocus() }
              }
            }
          }
        }

        // Search prompt.
        Row {
          y: win.videoPage ? win.ch * 1.7 : 0
          visible: win.searching
          Text { text: "❯ "; font.family: win.family; font.pixelSize: Style.font.body; color: win.accentText; font.bold: true }
          TextInput {
            id: searchInput
            width: mainBox.width - win.cw * 8
            font.family: win.family
            font.pixelSize: Style.font.body
            color: win.fg
            selectionColor: Tui.alpha(Color.accent, 0.35)
            cursorDelegate: Rectangle { width: win.cw; color: win.accent; opacity: 0.7 }
            text: win.videoPage ? win.vquery : win.query
            onTextEdited: {
              if (win.videoPage) win.vquery = text; else win.query = text
              searchTimer.restart()
            }
            Keys.onDownPressed: list.forceActiveFocus()
            Keys.onReturnPressed: { list.forceActiveFocus(); win.activate(list.currentIndex) }
            Keys.onEscapePressed: list.forceActiveFocus()
            Keys.onTabPressed: if (win.videoPage) win.vprovider = win.vproviders[(win.providerIndex + 1) % win.vproviders.length].id
            // The video page opens with the cursor here, so `c` would only type a c.
            // An empty anime search has nothing to lose: hand over to Curd, which
            // has its own search.
            Keys.onPressed: function(e) {
              if (win.videoPage && win.vprovider === "anime" && !text && e.text === "c" && !(e.modifiers & Qt.ControlModifier)) {
                win.videoKey(e); e.accepted = true
              }
            }
            Text {
              visible: !parent.text
              text: win.videoPage ? (win.vprovider === "anime" ? "a series, by name"
                                   : win.vprovider === "soundcloud" ? "tracks and mixes, or paste a soundcloud link"
                                                             : "videos, or paste a youtube link")
                                : "artists, albums, tracks, playlists"
              font: parent.font
              color: win.dim
            }
          }
          Timer { id: searchTimer; interval: 300; onTriggered: win.searchNow() }
        }

        // What is on the other screen. Only here, because this is the only page
        // where the video window is the thing you are driving.
        Item {
          id: watchStrip
          visible: win.videoPage && win.watching
          y: win.page.show ? 0 : win.ch * 3.4
          width: parent.width
          height: win.ch * 2.1

          readonly property var entry: win.videoState.entry || ({})
          readonly property real progress: win.videoState.duration > 0
                                         ? win.videoState.position / win.videoState.duration : 0

          Text {
            width: parent.width
            clip: true
            textFormat: Text.StyledText
            text: '<font color="' + Tui.hex(win.accent) + '">'
                  + (win.videoState.paused ? "‖‖" : "▶ ") + '</font> '
                  + '<font color="' + Tui.hex(win.fg) + '">' + Tui.esc(watchStrip.entry.title || "video") + '</font>'
            font.family: win.family; font.pixelSize: Style.font.body
          }
          Row {
            y: win.ch * 1.1
            spacing: win.cw
            Text {
              textFormat: Text.StyledText
              text: Tui.meterRich(watchStrip.progress, Math.max(8, Math.floor((watchStrip.width / win.cw) * 0.4)),
                                  win.accent, Tui.mix(win.dim, win.bg, 0.4))
              font.family: win.family; font.pixelSize: Style.font.caption
            }
            Text {
              text: win.clockText(win.videoState.position) + " ╱ " + win.clockText(win.videoState.duration)
              font.family: win.family; font.pixelSize: Style.font.caption
              color: win.dim
            }
            HintBar {
              keyColor: win.accentText; labelColor: Tui.mix(win.dim, win.bg, 0.25); hoverColor: win.accentText
              items: [{ k: "␣", l: "⏯", run: function() { win.api.videoControl("toggle") }, tip: "pause / play the video", tipKey: "space" },
                      { k: "h l", l: "seek" },
                      { k: "F", l: "full", run: function() { win.api.videoControl("fullscreen") }, tip: "fullscreen the video" },
                      { k: "x", l: "close", run: function() { win.api.videoControl("close"); win.say("closed the video window") }, tip: "close the video window" }]
            }
          }
        }
      }

      ListView {
        id: list
        anchors.top: header.visible ? header.bottom : parent.top
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        focus: true
        model: win.rows
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        highlightFollowsCurrentItem: false

        // Cursor: slides between rows on a spring (spatial motion may overshoot).
        highlight: Rectangle {
          width: list.width
          height: list.currentItem ? list.currentItem.height : 0
          y: list.currentItem ? list.currentItem.y : 0
          visible: !!list.currentItem && !!win.rows[list.currentIndex] && !!win.rows[list.currentIndex].item
          color: win.cursorFill
          Behavior on y { SpringAnimation { spring: 6; damping: 0.45; epsilon: 0.3 } }
          Rectangle { width: Math.max(2, win.cw * 0.3); height: parent.height; color: win.accent }
        }

        header: Text {
          visible: win.hasTrackTable
          height: visible ? win.ch * 1.4 : 0
          width: list.width
          x: win.cw
          verticalAlignment: Text.AlignVCenter
          text: win.hasTrackTable ? win.headerLine(Math.floor((list.width - win.cw * 2) / win.cw)) : ""
          font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
          color: win.dim
        }

        Keys.onPressed: function(e) {
          var t = e.text
          if (e.key === Qt.Key_Down || t === "j") { move(1); e.accepted = true }
          else if (e.key === Qt.Key_Up || t === "k") { if (!move(-1) && win.searching) searchInput.forceActiveFocus(); e.accepted = true }
          else if (e.key === Qt.Key_PageDown) { move(10); e.accepted = true }
          else if (e.key === Qt.Key_PageUp) { move(-10); e.accepted = true }
          else if (t === "g") { currentIndex = win.firstItemRow(); e.accepted = true }
          else if (t === "G") { currentIndex = count - 1; e.accepted = true }
          else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { win.activate(currentIndex); e.accepted = true }
          else e.accepted = win.handleKey(e)
        }
        function move(d) {
          var i = currentIndex
          do { i += d > 0 ? 1 : -1 } while (i >= 0 && i < count && !win.rows[i].item)
          if (Math.abs(d) > 1) i = Math.max(0, Math.min(count - 1, currentIndex + d))
          if (i < 0 || i >= count) return false
          currentIndex = i
          return true
        }

        delegate: Item {
          id: rowItem
          required property var modelData
          required property int index
          readonly property var it: modelData.item
          readonly property bool isCursor: ListView.isCurrentItem
          readonly property bool isPlaying: !!(it && it.kind === "track" && (
            (win.track && it.id === win.track.id)
            || (win.videoPage && win.watching && (win.videoState.entry || {}).id === it.id)))
          width: ListView.view.width
          height: win.ch * (modelData.header ? 1.7 : 1.3)

          // Rows print in when a page loads (staggered decode), not when scrolling.
          property real reveal: Date.now() - win.loadedAt < 700 ? 0 : 1
          SequentialAnimation on reveal {
            running: rowItem.reveal < 1
            PauseAnimation { duration: Math.min(rowItem.index, 24) * 14 }
            NumberAnimation { from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
          }

          // ╱╱ section ─────
          Text {
            visible: !!rowItem.modelData.header
            anchors.bottom: parent.bottom
            anchors.bottomMargin: win.ch * 0.1
            textFormat: Text.StyledText
            text: '<font color="' + Tui.hex(win.accent) + '">╱╱</font> ' + Tui.esc(rowItem.modelData.header || "")
                  + ' <font color="' + Tui.hex(Tui.mix(win.dim, win.bg, 0.35)) + '">' + "─".repeat(200) + '</font>'
            width: parent.width
            clip: true
            font.family: win.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
            color: win.dim
          }

          GlowText {
            visible: !!rowItem.it
            glow: rowItem.isPlaying ? win.bloom * 0.3 : 0
            glowRadius: 6
            anchors.verticalCenter: parent.verticalCenter
            x: win.cw
            width: parent.width - win.cw * 2
            clip: true
            textFormat: Text.PlainText
            font.family: win.family
            font.pixelSize: Style.font.body
            font.bold: rowItem.isPlaying
            color: rowItem.isPlaying ? win.accentText : (rowItem.isCursor ? win.fg : Tui.mix(win.fg, win.dim, 0.35))
            text: {
              var it = rowItem.it
              if (!it) return ""
              var cols = Math.floor(width / win.cw)
              var line
              // A YouTube result is a track - that is how it reaches the music
              // player - so the page, not the kind, decides how it is drawn.
              if (win.videoPage || it.kind === "show" || it.kind === "video") {
                line = win.mediaLine(it, cols)
                return rowItem.reveal < 1 ? Tui.decode(line, rowItem.reveal, rowItem.index) : line
              }
              if (it.kind === "track") {
                var num = rowItem.isPlaying ? (win.st.playing ? Tui.eq(win.clock, rowItem.index) : "‖‖‖")
                                            : win.lpad(String((rowItem.modelData.trackIndex || 0) + 1), 3)
                line = win.trackLine(it, num, cols)
                return rowItem.reveal < 1 ? Tui.decode(line, rowItem.reveal, rowItem.index) : line
              }
              var glyph = { album: "◉", playlist: "≡", mix: "∿", artist: "☺" }[it.kind] || "·"
              var sub = it.kind === "album" ? win.artists(it.artists) + (it.year ? " · " + it.year : "")
                      : it.kind === "artist" ? "artist"
                      : (it.subtitle || "") + (it.tracks ? (it.subtitle ? " · " : "") + it.tracks + " tracks" : "")
              var w = Math.floor((cols - 4) * 0.55)
              line = " " + glyph + "  " + win.pad(it.title, w) + win.pad(sub, cols - 4 - w)
              return rowItem.reveal < 1 ? Tui.decode(line, rowItem.reveal, rowItem.index) : line
            }
          }

          // Under the pointer a row takes a faint fill; the cursor's own fill
          // and bar stay the stronger mark of where the keys are.
          Rectangle {
            z: -1
            anchors.fill: parent
            visible: rowMouse.containsMouse && !rowItem.isCursor && !!rowItem.it
            color: Tui.alpha(Color.accent, 0.07)
          }

          // Click selects, double-click plays (or opens), right-click is the menu.
          MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: !!rowItem.it
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: function(m) {
              list.currentIndex = rowItem.index
              list.forceActiveFocus()
              if (m.button === Qt.RightButton) win.rowMenu(rowItem.index, rowMouse, m.x, m.y)
            }
            onDoubleClicked: function(m) { if (m.button === Qt.LeftButton) win.activate(rowItem.index) }
          }
        }

        Text {
          anchors.centerIn: parent
          visible: win.loading || (!win.rows.length && win.page.type !== "login")
          text: win.loading ? Tui.decode("loading", (win.clock * 2) % 1, Math.floor(win.clock * 8))
              : win.videoPage ? (win.page.show ? "no episodes"
                             : win.vprovider === "anime" && !win.providers.anime
                               ? (win.providers.curd ? "c opens curd · search, watch and track there" : "anime needs ani-cli or curd")
                             : win.vquery ? "nothing found on " + win.vprovider
                             : "type to search " + win.vprovider + (win.vprovider === "soundcloud" ? " · ⏎ listen"
                                                                 : win.vprovider === "anime" ? " · ⏎ watch · or c for curd" : " · ⏎ watch · a listen"))
              : win.page.type === "search" ? (win.query ? "no results" : "type to search · ⏎ play · esc back")
              : "nothing here yet"
          font.family: win.family; font.pixelSize: Style.font.body
          color: win.dim
        }
      }

      // Equalizer cover. Above the list, below the sign-in cover: there is
      // nothing to equalize if we are not signed in.
      Loader {
        id: eqLoader
        anchors.fill: parent
        active: win.page.type === "eq"
        sourceComponent: EqPane { host: win }
        onLoaded: item.forceActiveFocus()
      }

      Loader {
        id: lyricsLoader
        anchors.fill: parent
        active: win.page.type === "lyrics"
        sourceComponent: LyricsPane { host: win }
        onLoaded: item.forceActiveFocus()
      }

      // Settings: above everything, the sign-in cover included, since nothing
      // here needs TIDAL (quality just waits for the service).
      Loader {
        id: settingsLoader
        anchors.fill: parent
        z: 2
        active: win.page.type === "settings"
        sourceComponent: SettingsPane { host: win }
        onLoaded: item.forceActiveFocus()
      }

      // Listening stats: the daemon's own history, so no TIDAL session needed.
      Loader {
        id: statsLoader
        anchors.fill: parent
        z: 2
        active: win.page.type === "stats"
        sourceComponent: StatsPane { host: win }
        onLoaded: item.forceActiveFocus()
      }

      // Sign-in / offline cover.
      Loader {
        anchors.fill: parent
        // The video section is not TIDAL's, so it stays reachable signed out.
        active: (!win.api || !win.api.online || win.page.type === "login"
             || (!win.api.signedIn && !win.videoPage)) && win.page.type !== "settings" && win.page.type !== "stats"
        sourceComponent: LoginPane { host: win }
      }
    }

    // Right column: now playing + queue
    Item {
      id: side
      x: parent.width - width
      y: statusLine.height
      readonly property real cols: parent.width / win.cw
      visible: cols >= 96
      width: !visible ? 0 : Math.round(win.cw * Math.max(28, Math.min(44, Math.floor(cols * 0.28))))
      height: nav.height

      TuiBox {
        id: nowBox
        width: parent.width
        height: Math.min(parent.height * 0.7, parent.width - win.cw * 3 + win.ch * 10)
        title: "now"
        // ‹ prism ›  on the top edge: the arrows step, the name lists them all.
        titleExtra: Component {
          Row {
            readonly property string name: win.railName(win.engine ? win.engine.railViz : "off")
            Text {
              text: "‹"
              font.family: win.family; font.pixelSize: Style.font.body; font.bold: true
              color: prevMouse.containsMouse ? win.accentText : win.dim
              leftPadding: win.cw * 0.3; rightPadding: win.cw * 0.5
              MouseArea { id: prevMouse; anchors.fill: parent; anchors.margins: -2; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                          onClicked: win.engine.cycleRailViz(-1)
                          TuiTip { text: "previous visualizer · or right-click the picture" } }
            }
            Text {
              id: railNameText
              text: parent.name
              font.family: win.family; font.pixelSize: Style.font.body
              font.underline: nameMouse.containsMouse
              color: win.accentText
              MouseArea { id: nameMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                          acceptedButtons: Qt.LeftButton | Qt.RightButton
                          onClicked: win.railMenu(railNameText, 0, railNameText.height)
                          TuiTip { text: "pick a visualizer, or album art" } }
            }
            Text {
              text: "›"
              font.family: win.family; font.pixelSize: Style.font.body; font.bold: true
              color: nextMouse.containsMouse ? win.accentText : win.dim
              leftPadding: win.cw * 0.5; rightPadding: win.cw * 0.3
              MouseArea { id: nextMouse; anchors.fill: parent; anchors.margins: -2; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                          onClicked: win.engine.cycleRailViz(1)
                          TuiTip { text: "next visualizer · or click the picture"; key: "v" } }
            }
          }
        }
        // `y` copies the selected row; this button copies what is playing, which
        // is what a button beside the now-playing art can only mean.
        hintItems: {
          var h = [{ k: "V", l: "stage", run: function() { win.engine.open = !win.engine.open }, tip: "open or close the big visualizer" }]
          if (width / win.cw >= 36)
            h.push({ k: "y", l: "share", run: function() { if (win.track) win.shareItem(win.track, false); else win.say("nothing playing") },
                     tip: "copy the playing track's link (y copies the selected row)", tipKey: "" })
          return h
        }
        clock: win.clock
        // Ambient light: the cover, blurred and a little larger, behind itself,
        // so it spills its own colour into the panel. Two layers, so a new cover
        // crossfades in over the old one once it has loaded. A tiny decode
        // blurred once per track; after the fade it is a static texture.
        Item {
          id: ambient
          readonly property real level: plane.showViz ? 0 : win.bloom
          readonly property string art: win.track ? (win.track.art || "") : ""
          property int front: 0
          visible: level > 0
          width: plane.width
          height: plane.height
          // Load the new cover into the back layer; it takes the front once ready.
          function load() {
            var back = front ? amb0 : amb1
            if (String(back.source) !== art) back.source = art
            else if (back.status === Image.Ready) front = 1 - front
          }
          function ready(i) { if (front !== i) front = i }
          onArtChanged: load()
          onVisibleChanged: if (visible) load()
          Component.onCompleted: load()

          Image {
            id: amb0
            anchors.fill: parent
            visible: false
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize: Qt.size(48, 48)
            onStatusChanged: if (status === Image.Ready) ambient.ready(0)
          }
          Image {
            id: amb1
            anchors.fill: parent
            visible: false
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize: Qt.size(48, 48)
            onStatusChanged: if (status === Image.Ready) ambient.ready(1)
          }
          MultiEffect {
            source: amb0
            anchors.fill: parent
            scale: 1.14
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1
            blurMax: 64
            saturation: 0.25
            visible: opacity > 0.005
            opacity: ambient.visible && ambient.art !== "" && amb0.status === Image.Ready && ambient.front === 0 ? ambient.level * 0.7 : 0
            Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutSine } }
          }
          MultiEffect {
            source: amb1
            anchors.fill: parent
            scale: 1.14
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1
            blurMax: 64
            saturation: 0.25
            visible: opacity > 0.005
            opacity: ambient.visible && ambient.art !== "" && amb1.status === Image.Ready && ambient.front === 1 ? ambient.level * 0.7 : 0
            Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutSine } }
          }
        }
        Column {
          width: parent.width
          spacing: win.ch * 0.2
          // One plane: album art, or the visualizer in its place. `v` cycles it
          // inline (art -> styles -> art), so choosing a visualizer never opens
          // a popout and never needs a window of its own. Landscape while it is
          // a visualizer, square while it is art.
          Rectangle {
            id: plane
            readonly property bool showViz: !!win.engine && win.engine.railViz !== "off"
            width: parent.width
            // As art it stays square. As a visualizer it takes whatever the box
            // has left over once the info, chip and spectrum have their rows, so
            // the plane grows instead of leaving a hole above the queue.
            height: showViz
                    ? Math.max(win.ch * 8, nowBox.height - infoRow.height - qualityChip.height
                                           - spectrumText.height - win.ch * 2.2)
                    : width
            color: Tui.alpha(Color.accent, 0.1)
            Behavior on height { NumberAnimation { duration: 180; easing.type: Easing.InOutCubic } }
            clip: true
            Image {
              anchors.fill: parent
              visible: !plane.showViz
              source: win.track ? (win.track.art || "") : ""
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              sourceSize: Qt.size(width * 2, height * 2)
            }
            Viz {
              anchors.fill: parent
              visible: plane.showViz
              engine: win.engine
              styleName: plane.showViz ? win.engine.railViz : "prism"
            }
            // Click: the next visualizer; right-click: the one before; the wheel
            // steps either way. The same as the stage and the widget. (This
            // used to open the stage, which left no way to change it by mouse.)
            MouseArea {
              id: planeMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.RightButton
              property real wheelAcc: 0
              onClicked: function(m) { win.engine.cycleRailViz(m.button === Qt.RightButton ? -1 : 1) }
              onWheel: function(w) { var n = Tui.notches(planeMouse, w.angleDelta.y); if (n) win.engine.cycleRailViz(-n) }
              TuiTip { text: "click: next visualizer · right-click: back · scroll"; key: "v"; delay: 900 }
            }
            VizLabel { id: railLabel; anchors.fill: parent }
            Connections {
              target: win.engine
              function onRailVizChanged() { railLabel.flash(win.railName(win.engine.railViz)) }
            }
          }
          // The visualizer took the big plane, so the art keeps its own tile
          // here beside the track info -- small, but pixels where they earn it.
          // When the plane is showing art already there is nothing to restate,
          // so the tile folds away.
          Row {
            id: infoRow
            width: parent.width
            spacing: win.cw
            Rectangle {
              id: artTile
              visible: plane.showViz && !!win.track
              width: visible ? win.ch * 7 : 0
              height: visible ? width : 0
              color: Tui.alpha(Color.accent, 0.1)
              Image {
                anchors.fill: parent
                source: win.track ? (win.track.art || "") : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                sourceSize: Qt.size(width * 2, height * 2)
              }
              MouseArea {
                id: tileMouse
                anchors.fill: parent
                enabled: !!win.track
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(m) {
                  if (m.button === Qt.RightButton) win.trackMenu(win.track, tileMouse, m.x, m.y)
                  else if (win.track.albumId) win.go({ type: "detail", kind: "album", id: win.track.albumId, title: win.track.album })
                }
                TuiTip { text: "go to the album · right-click for more" }
              }
            }
            Column {
              width: parent.width - (artTile.visible ? artTile.width + win.cw : 0)
              spacing: win.ch * 0.2
              Row {
                width: parent.width
                spacing: win.cw
                Text {
                  width: parent.width - win.cw * 3
                  elide: Text.ElideRight
                  text: win.track ? win.track.title : "nothing playing"
                  font.family: win.family; font.pixelSize: Style.font.body + 2; font.bold: true; color: win.fg
                  MouseArea { id: titleMouse; anchors.fill: parent; enabled: !!win.track; acceptedButtons: Qt.RightButton
                              onClicked: function(m) { win.trackMenu(win.track, titleMouse, m.x, m.y) } }
                }
                Heart { kind: "track"; itemId: win.track ? win.track.id : "" }
              }
              Row {
               width: parent.width
               spacing: win.cw
               Text {
                width: parent.width - win.cw * 3; elide: Text.ElideRight
                text: win.track ? win.artists(win.track.artists) : "pick something · ⏎"
                font.family: win.family; font.pixelSize: Style.font.body
                color: artistMouse.containsMouse && !!(win.track && win.track.artistId) ? win.accentText : win.dim
                MouseArea {
                  id: artistMouse
                  anchors.fill: parent
                  enabled: !!win.track
                  hoverEnabled: true
                  cursorShape: win.track && win.track.artistId ? Qt.PointingHandCursor : Qt.ArrowCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function(m) {
                    if (m.button === Qt.RightButton) win.trackMenu(win.track, artistMouse, m.x, m.y)
                    else if (win.track.artistId) win.go({ type: "detail", kind: "artist", id: win.track.artistId, title: win.track.artists[0] })
                  }
                }
               }
               Heart { kind: "artist"; itemId: win.track ? (win.track.artistId || "") : "" }
              }
              Text {
                width: parent.width; elide: Text.ElideRight
                text: win.track ? win.track.album : ""
                font.family: win.family; font.pixelSize: Style.font.caption
                color: albumMouse.containsMouse && !!(win.track && win.track.albumId) ? win.accentText : win.dim
                MouseArea {
                  id: albumMouse
                  anchors.fill: parent
                  enabled: !!win.track
                  hoverEnabled: true
                  cursorShape: win.track && win.track.albumId ? Qt.PointingHandCursor : Qt.ArrowCursor
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  onClicked: function(m) {
                    if (m.button === Qt.RightButton) win.trackMenu(win.track, albumMouse, m.x, m.y)
                    else if (win.track.albumId) win.go({ type: "detail", kind: "album", id: win.track.albumId, title: win.track.album })
                  }
                }
              }
            }
          }
          // Quality chip (inverse), only when we know the stream.
          Rectangle {
            id: qualityChip
            visible: chipText.text !== ""
            width: chipText.implicitWidth + win.cw * 2
            height: chipText.implicitHeight + win.ch * 0.2
            color: win.accent
            Text {
              id: chipText
              anchors.centerIn: parent
              text: win.qualityText(win.st.stream)
              font.family: win.family; font.pixelSize: Style.font.caption; font.bold: true; font.letterSpacing: 1
              color: Tui.ensure(win.bg, win.accent, 4.5)
            }
          }
          // Live braille spectrum: text, not pixels.
          Text {
            id: spectrumText
            width: parent.width
            topPadding: win.ch * 0.3
            lineHeight: 0.95
            text: Tui.braille(win.engine ? win.engine.levels : [], Math.max(8, Math.floor(width / win.cw)), 3)
            font.family: win.family; font.pixelSize: Style.font.body
            color: win.accent
          }
        }
      }

      TuiBox {
        id: queueBox
        y: nowBox.height + win.ch * 0.2
        width: parent.width
        height: parent.height - y
        title: "up next"
        keyHint: win.st.context && win.st.context.title ? win.st.context.title : ""
        clock: win.clock
        ListView {
          id: upNextList
          anchors.fill: parent
          clip: true
          model: win.st.upNext || []
          // Where the queue gives way to endless radio, a line says so.
          delegate: Item {
            id: upRow
            required property var modelData
            required property int index
            readonly property bool radioStart: !!modelData.radio
                && (index === 0 || !(win.st.upNext[index - 1] || {}).radio)
            width: ListView.view.width
            height: win.ch * (radioStart ? 2.4 : 1.2)
            Text {
              visible: upRow.radioStart
              width: parent.width
              height: win.ch * 1.2
              elide: Text.ElideRight
              verticalAlignment: Text.AlignBottom
              textFormat: Text.StyledText
              text: '<font color="' + Tui.hex(win.accent) + '">∞</font> radio · from '
                    + Tui.esc(upRow.modelData.radio ? upRow.modelData.radio.from || "" : "")
              font.family: win.family; font.pixelSize: Style.font.caption
              color: win.accentText
            }
            Text {
              y: upRow.radioStart ? win.ch * 1.2 : 0
              width: parent.width
              height: win.ch * 1.2
              elide: Text.ElideRight
              text: win.lpad(String(upRow.index + 1), 2) + "  " + upRow.modelData.title + "  · " + win.artists(upRow.modelData.artists)
              font.family: win.family; font.pixelSize: Style.font.caption
              color: qm.containsMouse ? win.fg : win.dim
              MouseArea {
                id: qm
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                function jump() { win.api.control("jump", { index: win.st.queueIndex + 1 + upRow.index }) }
                onClicked: function(m) {
                  if (m.button === Qt.RightButton) win.trackMenu(upRow.modelData, qm, m.x, m.y, jump)
                  else jump()
                }
                TuiTip { text: "play this now · right-click for more" }
              }
            }
          }
          // The end of the queue, with endless play on: what happens next.
          footer: Text {
            visible: !!win.track && !(win.st.upNext || []).length && !!win.api && (win.api.listening || {}).endless === true
                     && win.st.repeat === "off"
            width: upNextList.width
            height: visible ? win.ch * 1.4 : 0
            elide: Text.ElideRight
            verticalAlignment: Text.AlignBottom
            textFormat: Text.StyledText
            text: '<font color="' + Tui.hex(win.accent) + '">∞</font> radio continues from ' + Tui.esc(win.track ? win.track.title : "")
            font.family: win.family; font.pixelSize: Style.font.caption
            color: win.dim
          }
        }
      }
    }

    // A line that says what just happened, over the page and above the
    // transport, then gets out of the way.
    Rectangle {
      id: flashBox
      visible: opacity > 0.01
      opacity: win.flash ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 180 } }
      anchors.horizontalCenter: parent.horizontalCenter
      y: transport.y - height - win.ch * 0.8
      width: Math.min(parent.width - win.cw * 2, flashLine.implicitWidth + win.cw * 4)
      height: win.ch * 2.2
      color: Qt.rgba(win.baseBg.r, win.baseBg.g, win.baseBg.b, 0.97)
      border.width: 1
      border.color: win.accent
      Text {
        id: flashLine
        anchors.centerIn: parent
        width: Math.min(implicitWidth, flashBox.width - win.cw * 3)
        elide: Text.ElideMiddle
        text: win.flash
        font.family: win.family; font.pixelSize: Style.font.caption
        color: win.accentText
      }
      MouseArea { anchors.fill: parent; onClicked: win.flash = "" }
    }

    // └─ transport ─┘
    TuiBox {
      id: transport
      x: 0
      y: parent.height - height
      width: parent.width
      height: win.ch * 4
      title: win.st.playing ? "playing" : "paused"
      hintItems: {
        var a = win.api
        if (width / win.cw < 120)
          return [{ k: "space", l: "play", run: function() { a.control("toggle") } }, { k: "n/p", l: "skip" }, { k: "h/l", l: "seek" }]
        return [{ k: "space", l: win.st.playing ? "pause" : "play", run: function() { a.control("toggle") } },
                { k: "n", l: "next", run: function() { a.control("next") } },
                { k: "p", l: "prev", run: function() { a.control("previous") } },
                { k: "h/l", l: "seek" }, { k: "+/-", l: "vol" },
                { k: "s", l: "shuffle", run: function() { a.control("shuffle") } },
                { k: "r", l: "repeat", run: function() { a.control("repeat") } }]
      }
      clock: win.clock

      Row {
        id: tline
        anchors.verticalCenter: parent.verticalCenter
        spacing: win.cw * 2

        Repeater {
          model: [
            { t: "󰒮", a: "previous", tip: "previous track", key: "p" },
            { t: win.st.playing ? "󰏤" : "󰐊", a: "toggle", tip: win.st.playing ? "pause" : "play", key: "space" },
            { t: "󰒭", a: "next", tip: "next track", key: "n" }
          ]
          GlowText {
            required property var modelData
            readonly property bool isPlay: modelData.a === "toggle"
            text: modelData.t
            font.family: win.family; font.pixelSize: Style.font.body + 2
            // Play breathes toward the accent with the beat, and its halo with it.
            color: tm.containsMouse ? win.accentText
                   : (isPlay && win.st.playing ? Tui.mix(win.fg, win.accentText, 0.45 + 0.55 * win.beat) : win.fg)
            glowLive: isPlay && win.st.playing === true && win.bloom > 0
            glow: glowLive ? win.bloom * (0.3 + 0.7 * win.beat) : 0
            MouseArea { id: tm; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.api.control(modelData.a)
                        TuiTip { text: modelData.tip; key: modelData.key } }
          }
        }

        Text {
          readonly property bool on: !!win.track && !!win.api && win.api.isLiked("track", win.track.id)
          text: on ? "󰋑" : "󰋕"
          font.family: win.family; font.pixelSize: Style.font.body + 2
          color: on || thm.containsMouse ? win.accentText : win.dim
          opacity: win.track ? 1 : 0.3
          MouseArea { id: thm; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: if (win.track) win.api.toggleLike("track", win.track.id)
                      TuiTip { text: thm.parent.on ? "unlike what is playing" : "like what is playing"; key: "F" } }
        }
        // Below 96 columns the side rail is gone and nothing else says what is
        // playing, so the transport picks it up. Wide windows leave it to the
        // rail rather than printing it twice.
        Text {
          id: nowText
          visible: !side.visible && !!win.track
          width: visible ? Math.min(win.cw * 34, transport.width * 0.3) : 0
          elide: Text.ElideRight
          text: win.track ? win.track.title + "  · " + win.artists(win.track.artists) : ""
          font.family: win.family; font.pixelSize: Style.font.caption; color: win.dim
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          id: posText
          text: win.lpad(win.clockText(seekMeter.scrubbing ? seekMeter.scrubFrac * seekMeter.dur : (win.api ? win.api.position : 0)), 6)
          font.family: win.family; font.pixelSize: Style.font.body; color: win.dim
        }
        Text {
          id: seekMeter
          readonly property int cells: Math.max(10, Math.floor(
              (transport.width - win.cw * 62 - (nowText.visible ? nowText.width + win.cw * 2 : 0)) / win.cw))
          // While a drag is under way the bar shows where it will land, not
          // where the music is; the seek goes out once, on release.
          property bool scrubbing: false
          property real scrubFrac: 0
          readonly property real dur: win.st.duration || 0
          readonly property real frac: scrubbing ? scrubFrac
                                     : Math.max(0, Math.min(1, (win.api ? win.api.position : 0) / Math.max(1, dur || 1)))
          textFormat: Text.StyledText
          text: Tui.meterRich(frac, cells, win.accent, Tui.mix(win.dim, win.bg, 0.4))
          font.family: win.family; font.pixelSize: Style.font.body
          // The playhead carries a halo: the one cell of the bar that is "now".
          TextMetrics { id: seekCell; font: seekMeter.font; text: "━" }
          GlowText {
            visible: !!win.track && win.bloom > 0
            x: Math.round(seekMeter.frac * (seekMeter.cells - 1)) * seekCell.advanceWidth
            text: "╸"
            font: seekMeter.font
            color: win.accent
            glow: win.bloom * (win.st.playing ? 0.9 : 0.45)
            glowRadius: 8
          }
          MouseArea {
            id: seekMouse
            anchors.fill: parent
            anchors.topMargin: -win.ch * 0.3; anchors.bottomMargin: -win.ch * 0.3   // an easier target than one text line
            enabled: seekMeter.dur > 0
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            function fracAt(x) { return Math.max(0, Math.min(1, x / Math.max(1, width))) }
            onPressed: function(m) { seekMeter.scrubFrac = fracAt(m.x); seekMeter.scrubbing = true }
            onPositionChanged: function(m) { if (pressed) seekMeter.scrubFrac = fracAt(m.x) }
            onReleased: {
              if (!seekMeter.scrubbing) return
              var to = seekMeter.scrubFrac * seekMeter.dur
              win.api.control("seek", { position: to })
              // land the clock there now rather than when the next status arrives
              win.api.posBase = to; win.api.posAt = Date.now(); win.api.position = to
              seekMeter.scrubbing = false
            }
            onCanceled: seekMeter.scrubbing = false
            TuiTip {
              follow: true
              force: seekMeter.scrubbing
              at: Math.max(0, Math.min(seekMouse.width, seekMouse.mouseX))
              text: seekMeter.dur > 0 ? win.clockText((seekMeter.scrubbing ? seekMeter.scrubFrac : seekMouse.fracAt(seekMouse.mouseX)) * seekMeter.dur) : ""
            }
          }
        }
        Text {
          text: win.clockText(win.st.duration)
          font.family: win.family; font.pixelSize: Style.font.body; color: win.dim
        }
        Text {
          text: "⇄ shuf"
          font.family: win.family; font.pixelSize: Style.font.caption; font.bold: win.st.shuffle === true
          color: win.st.shuffle || shufMouse.containsMouse ? win.accentText : win.dim
          font.underline: shufMouse.containsMouse
          anchors.verticalCenter: parent.verticalCenter
          MouseArea { id: shufMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.api.control("shuffle")
                      TuiTip { text: "shuffle " + (win.st.shuffle ? "off" : "on"); key: "s" } }
        }
        Text {
          text: "↻ " + (win.st.repeat || "off")
          font.family: win.family; font.pixelSize: Style.font.caption; font.bold: !!win.st.repeat && win.st.repeat !== "off"
          color: (win.st.repeat && win.st.repeat !== "off") || repMouse.containsMouse ? win.accentText : win.dim
          font.underline: repMouse.containsMouse
          anchors.verticalCenter: parent.verticalCenter
          MouseArea { id: repMouse; anchors.fill: parent; anchors.margins: -3; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: win.api.control("repeat")
                      TuiTip { text: "repeat: off, all or one (now " + (win.st.repeat || "off") + ")"; key: "r" } }
        }
        Text {
          id: volMeter
          // The level we last asked for, shown and stepped from until the daemon's
          // status catches up, so quick scrolls and repeated +/- don't all start
          // from the same stale value.
          property int pending: -1
          readonly property int shown: pending >= 0 ? pending : Math.round(win.st.volume || 0)
          function setVolume(v) {
            v = Math.max(0, Math.min(100, Math.round(v)))
            pending = v
            settle.restart()
            win.api.control("volume", { volume: v })
          }
          Timer { id: settle; interval: 800; onTriggered: volMeter.pending = -1 }
          text: "vol " + Tui.meter(shown / 100, 8, "▰", "▱", "") + " " + win.lpad(String(shown), 3)
          font.family: win.family; font.pixelSize: Style.font.caption
          color: volMouse.containsMouse ? win.accentText : win.dim
          anchors.verticalCenter: parent.verticalCenter
          // Measured in this text's own font: the bar's glyphs need not be as wide
          // as the body font's cells, which is what the old click maths assumed.
          TextMetrics { id: volHead; font: volMeter.font; text: "vol " }
          TextMetrics { id: volBar; font: volMeter.font; text: "vol " + Tui.meter(1, 8, "▰", "▱", "") }
          MouseArea {
            id: volMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            TuiTip { text: "volume: click, drag or scroll"; key: "+ -" }
            property real wheel: 0
            // A notch is 120; touchpads send it in small pieces. Step 5% per notch.
            onWheel: function(w) {
              wheel += w.angleDelta.y
              var notches = wheel > 0 ? Math.floor(wheel / 120) : Math.ceil(wheel / 120)
              if (notches !== 0) { wheel -= notches * 120; volMeter.setVolume(volMeter.shown + notches * 5) }
            }
            function at(x) {
              var x0 = volHead.advanceWidth, x1 = volBar.advanceWidth
              return (x - x0) / Math.max(1, x1 - x0) * 100
            }
            // Click or drag along the bar; a click past either end pins 0 or 100.
            onPressed: function(m) { volMeter.setVolume(at(m.x)) }
            onPositionChanged: function(m) { if (pressed) volMeter.setVolume(at(m.x)) }
          }
        }
        Text {
          id: sleepMini
          readonly property var sl: win.api ? win.api.sleepState : ({ active: false })
          visible: sl.active === true
          // counts down by itself from the daemon's wall-clock deadline
          property real now: Date.now()
          Timer { interval: 1000; repeat: true; running: sleepMini.visible && !sleepMini.sl.endOfTrack; onTriggered: sleepMini.now = Date.now() }
          text: "☾ " + (sl.endOfTrack ? "end of track" : Math.max(0, Math.ceil(((sl.at || 0) * 1000 - now) / 60000)) + "m")
          font.family: win.family; font.pixelSize: Style.font.caption; font.bold: true
          color: sl.fading ? Tui.mix(win.accentText, win.dim, 0.5) : win.accentText
          anchors.verticalCenter: parent.verticalCenter
          font.underline: sleepMouse.containsMouse
          MouseArea { id: sleepMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: { win.api.cancelSleep(); win.say("sleep timer off") }
                      TuiTip { text: "cancel the sleep timer" } }
        }
        Text {
          id: eqMini
          text: "eq " + win.eqSpark()
          font.family: win.family; font.pixelSize: Style.font.caption
          font.bold: win.eqActive
          color: win.eqActive || eqMouse.containsMouse ? win.accentText : win.dim
          anchors.verticalCenter: parent.verticalCenter
          MouseArea {
            id: eqMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            TuiTip { text: "equalizer · right-click to " + (win.eqActive ? "bypass it" : "turn it on"); key: "e" }
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            // left opens the full equalizer, right toggles bypass without leaving
            // the page -- the same "no popout, no detour" rule as the widget
            onClicked: function(m) {
              if (m.button === Qt.RightButton) {
                win.api.post("/eq", { enabled: !win.eqActive }, function() {})
              } else {
                win.showEq()
              }
            }
          }
        }
      }
    }
  }

  // ---- command palette, cheat sheet ---------------------------------------------
  //
  // Ctrl+K reaches every action by name; `?` lists every key. The palette's
  // list is built here, where the actions live, and rebuilt on each open so a
  // toggle offers the opposite of what it is now.
  function commands() {
    var c = [], e = engine, a = api
    function add(group, label, key, run) { c.push({ group: group, label: label, key: key || "", run: run }) }
    function onOff(v) { return v ? "turn off" : "turn on" }
    if (a) {
      add("playback", st.playing ? "pause" : "play", "space", function() { a.control("toggle") })
      add("playback", "next track", "n", function() { a.control("next") })
      add("playback", "previous track", "p", function() { a.control("previous") })
      add("playback", "shuffle " + (st.shuffle ? "off" : "on"), "s", function() { a.control("shuffle") })
      add("playback", "repeat: cycle (now " + (st.repeat || "off") + ")", "r", function() { a.control("repeat") })
      add("playback", "volume up", "+", function() { volMeter.setVolume(volMeter.shown + 5) })
      add("playback", "volume down", "-", function() { volMeter.setVolume(volMeter.shown - 5) })
      if (track) add("playback", "like / unlike what is playing", "F", function() { a.toggleLike("track", track.id) })
      if (pageTracks.length) {
        add("playback", "play this page", "P", function() { playPage(false) })
        add("playback", "shuffle this page", "S", function() { playPage(true) })
      }
      add("share", "copy link", "y", function() { share(false) })
      add("share", "copy universal link", "Y", function() { share(true) })
    }
    for (var n = 0; n < navItems.length; n++)
      (function(it) { add("go", it.label, it.key, function() { go(it.page) }) })(navItems[n])
    add("go", "equalizer", "e", showEq)
    add("go", "lyrics", "L", showLyrics)
    add("go", "sign in", "", showLogin)
    add("go", "keys cheat sheet", "?", function() { keysSheet.open() })
    add("go", "close the player", "q", function() { e.libraryOpen = false })
    if (e) {
      add("visualizer", (e.open ? "close" : "open") + " the visualizer", "V", function() { e.open = !e.open })
      add("visualizer", "next style", "", function() { e.nextStyle(1) })
      for (var i = 0; i < e.styles.length; i++)
        (function(s) {
          add("visualizer", "style · " + e.styleLabels[s] + (e.style === s ? "  (now)" : ""), "", function() { e.setStyle(s) })
          add("rail", "player rail · " + e.styleLabels[s] + (e.railViz === s ? "  (now)" : ""), "", function() { e.setRailViz(s) })
        })(e.styles[i])
      add("rail", "player rail · album art" + (e.railViz === "off" ? "  (now)" : ""), "", function() { e.setRailViz("off") })
      add("rail", "player rail · next", "v", function() { e.cycleRailViz(1) })
      var fpsList = [30, 60, 120]
      for (var f = 0; f < fpsList.length; f++)
        (function(v) { add("visualizer", "frame rate · " + v + " fps" + (e.fps === v ? "  (now)" : ""), "", function() { e.updateConfig(function(cf) { cf.fps = v }) }) })(fpsList[f])
      add("visualizer", "widget follows the visualizer · " + onOff(e.syncViz), "", function() { var v = !e.syncViz; e.updateConfig(function(cf) { cf.syncViz = v }) })
      var w = e.widget
      add("widget", (w.enabled !== false ? "hide" : "show") + " the widget", "", function() { e.setWidget("enabled", "toggle") })
      add("widget", "widget style · " + (w.style === "full" ? "compact" : "full"), "", function() { e.setWidget("style", w.style === "full" ? "compact" : "full") })
      var corners = ["top-left", "top-right", "bottom-left", "bottom-right"]
      for (var k = 0; k < corners.length; k++)
        (function(cn) { add("widget", "widget corner · " + cn + (w.corner === cn ? "  (now)" : ""), "", function() { e.setWidget("corner", cn) }) })(corners[k])
      add("widget", "mini player · " + onOff(e.miniPlayer), "", function() { e.setMiniPlayer(e.miniPlayer ? "off" : "on") })
      var places = e.placements || ["overlay", "desktop"], placeNames = { overlay: "window on top", desktop: "wallpaper", fullscreen: "fullscreen show" }
      for (var pl = 0; pl < places.length; pl++)
        (function(p) { add("show", "visualizer as · " + (placeNames[p] || p) + (e.placement === p ? "  (now)" : ""), "", function() { e.setPlacement(p) }) })(places[pl])
      var flags = [["autoStyle", "switch styles on drops"], ["trackTitle", "track title fades in"],
                   ["lyricsOverViz", "lyrics over the visualizer"], ["autoQuality", "lower resolution when fps drops"],
                   ["showFps", "show the frame rate"]]
      for (var g = 0; g < flags.length; g++)
        (function(fl) {
          var on = typeof e[fl[0]] === "boolean" ? e[fl[0]] : e.config[fl[0]] === true
          add("show", fl[1] + " · " + onOff(on), "", function() { e.updateConfig(function(cf) { cf[fl[0]] = !on }) })
        })(flags[g])
    }
    if (a) {
      var qs = [["high", "320k"], ["lossless", "lossless"], ["hires", "hi-res"]]
      for (var q = 0; q < qs.length; q++)
        (function(x) {
          add("quality", x[1] + (a.status && a.status.quality === x[0] ? "  (now)" : ""), "", function() {
            if (x[0] === "hires" && !(a.login && a.login.hires)) go({ type: "login", title: "sign in", hires: true })
            else a.post("/quality", { quality: x[0] })
          })
        })(qs[q])
      add("equalizer", "equalizer · " + (eqActive ? "bypass" : "turn on"), "", function() { a.post("/eq", { enabled: !eqActive }, function() {}) })
    }
    if (typeof Color.themeList !== "undefined" && Color.themeList) {
      add("theme", "theme builder…", "", function() { Color.openBuilder() })
      add("theme", "next theme", "", function() { Color.cycle(1) })
      var tl = Color.themeList
      for (var t = 0; t < tl.length; t++)
        (function(th) { add("theme", th.label + (Color.name === th.name ? "  (now)" : ""), "", function() { Color.setTheme(th.name); say("theme ╱╱ " + th.label) }) })(tl[t])
    }
    add("settings", "settings", ",", showSettings)
    if (typeof OrpheusKeys !== "undefined" && OrpheusKeys.windows)
      add("settings", "start with Windows · " + onOff(OrpheusKeys.startWithWindows), "", function() { OrpheusKeys.setStartWithWindows(!OrpheusKeys.startWithWindows) })
    return c
  }

  // Where the keys go once an overlay closes: the pane on screen, else the list.
  function refocus() {
    var l = page.type === "settings" ? settingsLoader : page.type === "stats" ? statsLoader
          : page.type === "eq" ? eqLoader : page.type === "lyrics" ? lyricsLoader : null
    if (l && l.item) l.item.forceActiveFocus()
    else list.forceActiveFocus()
  }

  Shortcut {
    sequences: ["Ctrl+K"]
    onActivated: cmdPalette.shown ? cmdPalette.close() : cmdPalette.open()
  }

  CommandPalette { id: cmdPalette; host: win }
  TuiMenu { id: ctxMenu; onClosed: win.refocus() }
  KeysSheet { id: keysSheet; host: win }

  Component.onCompleted: {
    list.forceActiveFocus()
    if (engine && engine.loginRequests > 0 && engine.loginRequests !== engine.loginHandled) { engine.loginHandled = engine.loginRequests; showLogin() }
    else if (engine && engine.eqRequests > 0 && engine.eqRequests !== engine.eqHandled) { engine.eqHandled = engine.eqRequests; load(); showEq() }
    else if (engine && engine.lyricsRequests > 0 && engine.lyricsRequests !== engine.lyricsHandled) { engine.lyricsHandled = engine.lyricsRequests; load(); showLyrics() }
    else if (engine && engine.settingsRequests > 0 && engine.settingsRequests !== engine.settingsHandled) { engine.settingsHandled = engine.settingsRequests; load(); showSettings() }
    else load()
  }
}
