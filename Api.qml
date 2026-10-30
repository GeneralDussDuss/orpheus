import QtQuick
import Quickshell

// Talks to orpheusd on 127.0.0.1. Keeps `status` fresh with a long poll, and
// wraps the rest of the JSON API in small callback helpers.
QtObject {
  id: api

  // ORPHEUS_PORT, as the desktop app and the daemon read it, so a second
  // daemon (tests, a shot) can have its own UI.
  property int port: Number(Quickshell.env("ORPHEUS_PORT")) || 47837
  readonly property string base: "http://127.0.0.1:" + port
  property bool active: false          // poll only while some UI needs it
  property bool online: false
  property var status: ({})
  readonly property var login: status.login || ({ state: "offline" })
  readonly property var player: status.player || ({})
  readonly property var track: player.track || null
  readonly property bool signedIn: login.state === "signed-in"

  function request(method, path, body, done) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      var data = null
      try { data = xhr.responseText ? JSON.parse(xhr.responseText) : null } catch (e) { data = xhr.responseText }
      if (done) done(xhr.status >= 200 && xhr.status < 300, data, xhr.status)
    }
    xhr.open(method, base + path)
    if (body !== undefined && body !== null) {
      xhr.setRequestHeader("Content-Type", "application/json")
      xhr.send(JSON.stringify(body))
    } else {
      xhr.send()
    }
    return xhr
  }

  function get(path, done) { request("GET", path, null, done) }
  function post(path, body, done) {
    request("POST", path, body || {}, function(ok, data, code) {
      if (ok && data && data.player) api.status = data
      if (done) done(ok, data, code)
    })
  }

  // ---- likes: ids per kind, refreshed when the service's likedVersion moves ----
  property var liked: ({ track: {}, album: {}, artist: {}, playlist: {} })
  property int likedVersion: -1
  readonly property int serverLikedVersion: status.likedVersion === undefined ? -1 : status.likedVersion
  onServerLikedVersionChanged: if (serverLikedVersion !== likedVersion && signedIn) fetchLiked()
  function fetchLiked() {
    get("/liked", function(ok, d) {
      if (!ok || !d) return
      var next = {}
      var kinds = ["track", "album", "artist", "playlist"]
      for (var k = 0; k < kinds.length; k++) {
        var set = {}, ids = d[kinds[k]] || []
        for (var i = 0; i < ids.length; i++) set[ids[i]] = true
        next[kinds[k]] = set
      }
      api.liked = next
      api.likedVersion = d.version
    })
  }
  function isLiked(kind, id) { return !!(id && liked[kind] && liked[kind][String(id)]) }
  // Toggle a like; the heart flips immediately and settles to the service's answer.
  function toggleLike(kind, id) {
    if (!id) return
    id = String(id)
    var next = JSON.parse(JSON.stringify(liked))
    if (next[kind][id]) delete next[kind][id]; else next[kind][id] = true
    liked = next
    post("/favorite", { kind: kind, id: id }, function(ok, d) {
      if (!ok || !d) { fetchLiked(); return }
      var fixed = JSON.parse(JSON.stringify(api.liked))
      if (d.liked) fixed[kind][id] = true; else delete fixed[kind][id]
      api.liked = fixed
    })
  }

  // ---- listening: sleep timer, stats -----------------------------------
  readonly property var listening: status.listening || ({})
  readonly property var sleepState: listening.sleep || ({ active: false })
  function sleep(minutes) { post("/sleep", { minutes: minutes }) }
  function sleepAtEnd() { post("/sleep", { endOfTrack: true }) }
  function cancelSleep() { post("/sleep", { cancel: true }) }
  function stats(range, done) { get("/stats?range=" + (range || "week"), done) }

  // Convenience controls.
  function control(action, body) { post("/control/" + action, body) }
  function play(item, index, extra) {
    var b = { kind: item.kind, id: item.id, index: index || 0 }
    if (item.kind === "track") b.track = item
    if (extra) for (var k in extra) b[k] = extra[k]
    post("/play", b)
  }
  function playTracks(tracks, index, context) { post("/play", { tracks: tracks, index: index || 0, context: context || {} }) }
  function enqueue(item, next) { post("/enqueue", { kind: item.kind, id: item.id, track: item.kind === "track" ? item : undefined, next: !!next }) }

  // ---- the video section -----------------------------------------------
  //
  // Two verbs, because a video has two things you might want from it: `watch`
  // puts it in the video window, `listen` sends it through the music player
  // instead, where it arrives with the queue, the equaliser and the visualiser
  // already attached.
  readonly property var video: status.video || ({})
  readonly property var providers: status.providers || ({ youtube: true })

  function ytSearch(q, done, provider) {
    get("/yt/search?q=" + encodeURIComponent(q) + "&provider=" + (provider || "youtube"), done)
  }
  function animeSearch(q, done) { get("/anime/search?q=" + encodeURIComponent(q), done) }
  function animeEpisodes(q, i, done) {
    get("/anime/episodes?q=" + encodeURIComponent(q) + "&i=" + (i || 1), done)
  }

  function watch(item, done) {
    if (item.provider === "anime")
      post("/anime/watch", { query: item.query, index: item.index, ep: item.ep, title: item.title }, done)
    else
      post("/yt/play", { items: [item], index: 0, mode: "video" }, done)
  }
  function listen(items, index, context, done) {
    post("/yt/play", { items: items, index: index || 0, mode: "audio", context: context }, done)
  }
  function videoControl(action, body) { post("/video/" + action, body || {}) }
  function curd(resume, done) { post("/anime/curd", { resume: !!resume }, done) }

  // ---- long poll ----
  property int version: -1
  property bool polling: false
  property int failures: 0             // unanswered polls in a row
  property bool everOnline: false
  // The daemon went away after having answered: restarting, crashed (the
  // desktop app starts it again) or the machine slept. Say so; don't freeze.
  readonly property bool reconnecting: active && !online && everOnline
  // Not reached yet: it is still starting (a first launch takes a few seconds).
  readonly property bool connecting: active && !online && !everOnline && failures < 12
  property var pollXhr: null
  property int pollId: 0

  function poll() {
    if (!active || polling) return
    polling = true
    var id = ++pollId
    var path = "/status" + (version >= 0 && online ? "?since=" + version : "")
    pollXhr = request("GET", path, null, function(ok, data) {
      if (id !== api.pollId) return          // the watchdog gave up on this one
      api.polling = false
      api.pollXhr = null
      watchdog.stop()
      if (ok && data) {
        api.failures = 0
        api.online = true
        api.everOnline = true
        api.status = data
        api.version = data.version
        Qt.callLater(api.poll)
      } else {
        api.pollFailed()
      }
    })
    watchdog.restart()
  }

  function pollFailed() {
    online = false
    failures++
    // Quick at first (a daemon restart takes ~2 s), then every 5 s.
    retry.interval = Math.min(5000, 500 * Math.pow(2, failures - 1))
    retry.restart()
  }

  // The daemon holds a long poll for 25 s at most. Past 35 s it is hung, or
  // the connection died without a word (sleep, a network stack reset): drop
  // it and ask again rather than wait forever on stale data.
  property Timer watchdog: Timer {
    interval: 35000
    onTriggered: {
      var x = api.pollXhr
      api.pollId++
      api.polling = false
      api.pollXhr = null
      if (x) x.abort()
      api.pollFailed()
    }
  }

  // ---- position ----------------------------------------------------------
  // The daemon's figure is correct but only arrives about once a second, so
  // every surface that drew it straight showed a number up to a second old and
  // jumped when the next poll landed - and the player window, the widget and
  // the mini player could each be stale by a different amount, which is what
  // made them visibly disagree. Interpolate once, here, and let them all read
  // the same value.
  property real posBase: 0        // last figure the daemon reported
  property real posAt: 0          // ... and the local ms when it arrived
  property real position: 0

  function reanchor() {
    posBase = (player && player.position) || 0
    posAt = Date.now()
    position = posBase
  }
  onStatusChanged: reanchor()

  property Timer posTick: Timer {
    interval: 80
    repeat: true
    running: api.active && api.online && api.player.playing === true
    onTriggered: {
      var p = api.posBase + (Date.now() - api.posAt) / 1000
      var dur = api.player.duration || 0
      api.position = dur > 0 ? Math.min(p, dur) : p
    }
  }

  property Timer retry: Timer { interval: 500; onTriggered: api.poll() }
  // The long poll brings every change and the position is interpolated, so
  // this only corrects slow drift. It was every second: a second /status for
  // each open window, on top of the long poll.
  property Timer tick: Timer {
    interval: 10000
    repeat: true
    running: api.active && api.online && api.player.playing === true
    onTriggered: api.get("/status", function(ok, data) { if (ok && data) api.status = data })
  }

  onActiveChanged: if (active) poll()
}
