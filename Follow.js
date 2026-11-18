.pragma library

// "react to music": one choice that stands for the eight follow-the-music
// switches (SettingsPane.qml). Pure, so it tests headless.
//
// "subtle" is exactly what a fresh config does today (Service.qml's defaults),
// so a new install reads as a preset and never as "custom". Pilgrimage stays
// opt-in in every preset.

var KEYS = ["director", "beatLock", "autoStyle", "pilgrimage", "trackTitle", "lyricsOverViz", "dropMap", "dropFx"]
var NAMES = ["off", "subtle", "full"]
var PRESETS = {
  off:    { director: false, beatLock: false, autoStyle: false, pilgrimage: false, trackTitle: false, lyricsOverViz: false, dropMap: false, dropFx: false },
  subtle: { director: true,  beatLock: true,  autoStyle: false, pilgrimage: false, trackTitle: true,  lyricsOverViz: false, dropMap: true,  dropFx: true },
  full:   { director: true,  beatLock: true,  autoStyle: true,  pilgrimage: false, trackTitle: true,  lyricsOverViz: true,  dropMap: true,  dropFx: true }
}

// The preset the eight values add up to; get(key) reads one, as a boolean.
function detect(get) {
  for (var n = 0; n < NAMES.length; n++) {
    var p = PRESETS[NAMES[n]], same = true
    for (var i = 0; i < KEYS.length; i++) if (!!get(KEYS[i]) !== p[KEYS[i]]) { same = false; break }
    if (same) return NAMES[n]
  }
  return "custom"
}

// What a preset writes, as a fresh object; null for anything but a preset.
function values(name) {
  var p = PRESETS[name]
  if (!p) return null
  var out = {}
  for (var i = 0; i < KEYS.length; i++) out[KEYS[i]] = p[KEYS[i]]
  return out
}
