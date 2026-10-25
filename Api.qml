import QtQuick

// Talks to orpheusd on 127.0.0.1. Keeps `status` fresh with a long poll, and
// wraps the rest of the JSON API in small callback helpers.
QtObject {
  id: api

  property int port: 47837
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

  // ---- long poll ----
  property int version: -1
  property bool polling: false

  function poll() {
    if (!active || polling) return
    polling = true
    var path = "/status" + (version >= 0 && online ? "?since=" + version : "")
    request("GET", path, null, function(ok, data) {
      polling = false
      if (ok && data) {
        api.online = true
        api.status = data
        api.version = data.version
        Qt.callLater(api.poll)
      } else {
        api.online = false
        retry.restart()
      }
    })
  }

  property Timer retry: Timer { interval: 2000; onTriggered: api.poll() }
  // The interpolated position moves between status pushes; refresh it gently.
  property Timer tick: Timer {
    interval: 1000
    repeat: true
    running: api.active && api.online && api.player.playing === true
    onTriggered: api.get("/status", function(ok, data) { if (ok && data) api.status = data })
  }

  onActiveChanged: if (active) poll()
}
