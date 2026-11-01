import QtQuick

// The drop map for the playing track, from orpheusd's /analysis: beats, bars,
// builds, drops and sections the daemon worked out ahead of time (see
// orpheusd/analysis.py). Service hands `map` to the Director; the seek bars
// draw its drops. The daemon bumps /status.analysis.version whenever a job
// lands, which is the cue to fetch again while the map is still pending.
QtObject {
  id: src

  property var api: null
  property var track: null
  property bool enabled: true

  property var map: null            // the map when ready (and of this edition of the track), else null
  property string state: ""         // "" | pending | ready | none | failed
  property string loadedFor: ""     // key
  property int seenVersion: -1

  // orpheusd/analysis.py key_of(): provider, id, whole seconds
  function keyOf(t) { return t && t.id && t.duration ? (t.provider || "tidal") + "_" + String(t.id) + "_" + Math.floor(t.duration) : "" }

  function load(force) {
    var key = keyOf(track)
    if (!api || !enabled || !key) { map = null; state = ""; loadedFor = ""; return }
    if (!force && loadedFor === key) return
    loadedFor = key
    if (!force) { map = null; state = "pending" }
    var t = track
    api.get("/analysis/" + encodeURIComponent(String(t.id)) + "?provider=" + (t.provider || "tidal") + "&duration=" + t.duration, function(ok, d) {
      if (src.loadedFor !== key) return                              // the track moved on while we waited
      if (!ok || !d) { src.state = "failed"; return }
      // Another edition under the same id decodes to another length: not ours.
      var good = d.state === "ready" && Math.abs((d.duration || 0) - t.duration) <= 3
      src.state = good ? "ready" : (d.state === "ready" ? "none" : (d.state || "none"))
      src.map = good ? d : null
    })
  }

  onTrackChanged: load(false)
  onApiChanged: load(false)
  onEnabledChanged: load(false)
  Component.onCompleted: load(false)

  property Connections conn: Connections {
    target: src.api
    ignoreUnknownSignals: true
    function onStatusChanged() {
      var a = src.api && src.api.status ? src.api.status.analysis : null
      if (!a || a.version === src.seenVersion) return
      src.seenVersion = a.version
      if (src.state !== "ready" && a.key === src.loadedFor && a.state === "ready") src.load(true)
    }
  }
}
