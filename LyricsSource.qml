import QtQuick

// The lyrics for the playing track, from orpheusd's /lyrics, and the timing
// arithmetic on them. LyricsPane draws the whole page from this; the stage
// borrows it for the current line over the visualizer.
QtObject {
  id: src

  property var api: null
  property var track: null

  property var lines: []
  property string plain: ""
  property string source: ""
  property bool synced: false
  property bool loading: false
  property bool instrumental: false
  property string loadedFor: ""
  property real offset: 0          // seconds; starts at the daemon's, the pane can nudge it

  function load() {
    if (!api || !track || !track.id) { lines = []; plain = ""; source = ""; loadedFor = ""; return }
    if (loadedFor === String(track.id)) return
    var id = String(track.id)
    loadedFor = id
    loading = true
    lines = []; plain = ""; source = ""; instrumental = false; offset = 0
    api.get("/lyrics/" + id, function(ok, d) {
      if (src.loadedFor !== id) return       // the track moved on while we waited
      src.loading = false
      if (!ok || !d) { src.source = "none"; return }
      src.lines = d.lines || []
      src.plain = d.plain || ""
      src.synced = d.synced === true
      src.source = d.source || "none"
      src.instrumental = d.instrumental === true
      src.offset = -(d.offset || 0)
    })
  }

  onTrackChanged: load()
  onApiChanged: load()
  Component.onCompleted: load()

  // The last line starting at or before `t` (seconds), or -1.
  function lineAt(t) {
    if (!lines || !lines.length) return -1
    var lo = 0, hi = lines.length - 1, found = -1
    while (lo <= hi) {
      var mid = (lo + hi) >> 1
      if (lines[mid].t <= t) { found = mid; lo = mid + 1 } else { hi = mid - 1 }
    }
    return found
  }

  function tokenize(s) {
    var out = [], i = 0
    while (i < s.length) {
      while (i < s.length && s.charAt(i) === " ") i++
      var a = i
      while (i < s.length && s.charAt(i) !== " ") i++
      if (i > a) out.push({ text: s.substring(a, i), a: a, b: i })
    }
    return out
  }

  // One span per visible word: when it starts, and when the next takes over.
  function wordSpans(idx) {
    var line = lines[idx]
    if (!line || !line.text) return []
    var toks = tokenize(line.text)
    if (!toks.length) return []

    var t0 = line.t
    var t1 = idx + 1 < lines.length ? lines[idx + 1].t : t0 + 4
    if (t1 - t0 < 0.4) t1 = t0 + 0.4
    if (t1 - t0 > 10) t1 = t0 + 10     // a long gap after a line is silence, not a drawl

    // Guess first, weighting each word by its length: long words take longer to
    // sing than short ones, so an even split visibly runs ahead on "I" and
    // behind on anything with four syllables.
    var total = 0, i
    for (i = 0; i < toks.length; i++) total += toks[i].text.length + 1
    var out = [], acc = 0
    for (i = 0; i < toks.length; i++) {
      out.push({ text: toks[i].text, t: t0 + (t1 - t0) * (acc / total) })
      acc += toks[i].text.length + 1
    }

    // A real tag beats the guess. Tags are matched by character overlap, so a
    // tag landing mid-word still claims the word it is inside.
    var tags = line.words || []
    for (var k = 0; k < tags.length; k++) {
      for (i = 0; i < toks.length; i++) {
        if (toks[i].a < tags[k].b && tags[k].a < toks[i].b) { out[i].t = tags[k].t; break }
      }
    }
    for (i = 1; i < out.length; i++) if (out[i].t < out[i - 1].t) out[i].t = out[i - 1].t
    for (i = 0; i < out.length; i++) out[i].end = i + 1 < out.length ? out[i + 1].t : t1
    return out
  }
}
