import QtQuick
import Quickshell
import qs.Commons
import "Tui.js" as Tui

// Listening stats, as a page of the player: what the daemon's history says
// about the last week, month, year or all of it, and a "wrapped" for this
// calendar month. Text all the way down, like the rest of the window: block
// bars, a braille-free bar chart in eighth blocks, and a weekday x hour
// heatmap in shade glyphs, all in the theme's accent.
//
// ⇥ / h l change the range, w jumps to wrapped, j/k scroll, r reloads.
// Anything else goes to the window's own keys.
Rectangle {
  id: pane

  property var host: null
  readonly property var api: host ? host.api : null

  // Opaque, for the same reason as the equalizer: Color.background carries alpha.
  readonly property color base: Color.background
  color: Qt.rgba(base.r, base.g, base.b, 1)
  focus: true

  MouseArea { anchors.fill: parent; onPressed: function(m) { pane.forceActiveFocus(); m.accepted = false } }

  readonly property var ranges: [
    { id: "week", label: "week" }, { id: "month", label: "30 days" }, { id: "year", label: "year" },
    { id: "all", label: "all time" }, { id: "wrapped", label: "wrapped" }
  ]
  property string range: host && host.page && host.page.range ? host.page.range : "week"
  readonly property int rangeIndex: {
    for (var i = 0; i < ranges.length; i++) if (ranges[i].id === range) return i
    return 0
  }
  readonly property bool wrapped: range === "wrapped"
  property var d: null
  property bool loading: false
  property string err: ""

  function load() {
    if (!api) return
    var r = range
    loading = true
    api.stats(r, function(ok, data) {
      if (r !== pane.range) return
      pane.loading = false
      if (ok && data && typeof data === "object") { pane.d = data; pane.err = "" }
      else pane.err = host.errText(data, "the service has no stats yet")
    })
  }
  onRangeChanged: { flick.contentY = 0; load() }
  Component.onCompleted: load()
  // A play lands in the history when it ends; keep the page current while open.
  Timer { interval: 20000; repeat: true; running: pane.visible; onTriggered: pane.load() }

  function step(dir) { range = ranges[(rangeIndex + dir + ranges.length) % ranges.length].id }

  Keys.onPressed: function(e) {
    var t = e.text, k = e.key
    if (k === Qt.Key_Tab || t === "]" || k === Qt.Key_Right || t === "l") { step(1); e.accepted = true }
    else if (k === Qt.Key_Backtab || t === "[" || k === Qt.Key_Left || t === "h") { step(-1); e.accepted = true }
    else if (k === Qt.Key_Down || t === "j") { flick.scrollBy(ch * 3); e.accepted = true }
    else if (k === Qt.Key_Up || t === "k") { flick.scrollBy(-ch * 3); e.accepted = true }
    else if (k === Qt.Key_PageDown) { flick.scrollBy(flick.height * 0.8); e.accepted = true }
    else if (k === Qt.Key_PageUp) { flick.scrollBy(-flick.height * 0.8); e.accepted = true }
    else if (t === "g") { flick.contentY = 0; e.accepted = true }
    else if (t === "w") { range = "wrapped"; e.accepted = true }
    else if (t === "r") { load(); e.accepted = true }
    else e.accepted = host.handleKey(e)
  }

  // ---- drawing helpers -------------------------------------------------------
  readonly property real cw: host ? host.cw : 8
  readonly property real ch: host ? host.ch : 16
  readonly property color accent: host ? host.accent : "#7aa2f7"
  readonly property color fg: host ? host.fg : "#e6e6e6"
  readonly property color dim: host ? host.dim : "#808080"
  readonly property color faint: Tui.mix(dim, host ? host.bg : "#000000", 0.45)
  readonly property int cols: Math.max(40, Math.floor(width / cw))

  function rule(title) {
    return '<font color="' + Tui.hex(accent) + '">╱╱</font> ' + Tui.esc(title) + ' '
         + '<font color="' + Tui.hex(faint) + '">' + "─".repeat(220) + '</font>'
  }
  // A horizontal bar in eighth blocks: █████▍░░░
  function bar(v, n) {
    v = Math.max(0, Math.min(1, v || 0))
    var eighths = Math.round(v * n * 8), full = Math.floor(eighths / 8), part = eighths % 8
    var s = "█".repeat(full) + (part ? "▏▎▍▌▋▊▉".charAt(part - 1) : "")
    var rest = Math.max(0, n - full - (part ? 1 : 0))
    return '<font color="' + Tui.hex(accent) + '">' + s + '</font><font color="' + Tui.hex(faint) + '">' + "░".repeat(rest) + '</font>'
  }
  function hours(m) {
    m = Math.round(m || 0)
    return m < 60 ? m + " min" : Math.floor(m / 60) + " h " + (m % 60 ? (m % 60) + " min" : "")
  }
  function pct(x) { return Math.round((x || 0) * 100) + "%" }
  function pad(s, n) { s = String(s); while (s.length < n) s += " "; return s.length > n ? s.slice(0, n - 1) + "…" : s }
  function lpad(s, n) { s = String(s); while (s.length < n) s = " " + s; return s }
  function who(a) { return (a || []).slice(0, 2).join(", ") }
  readonly property var days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

  // A bar chart of the series, `rows` lines tall, in eighth blocks.
  function chart(series, rows) {
    if (!series || !series.length) return ""
    var max = 0
    for (var i = 0; i < series.length; i++) max = Math.max(max, series[i].minutes)
    var w = Math.max(1, Math.min(4, Math.floor((cols - 2) / series.length) - 1))
    var lines = []
    for (var r = 0; r < rows; r++) {
      var floor = (rows - 1 - r) * 8, s = ""
      for (var b = 0; b < series.length; b++) {
        var h = max > 0 ? Math.round(series[b].minutes / max * rows * 8) : 0
        if (series[b].minutes > 0 && h === 0) h = 1
        var f = Math.max(0, Math.min(8, h - floor))
        s += (f ? " ▁▂▃▄▅▆▇█".charAt(f) : (r === rows - 1 ? "▁" : " ")).repeat(w) + " "
      }
      lines.push(s)
    }
    // labels under the bars, as many as fit
    var lab = "", every = Math.max(1, Math.ceil(series.length * 4 / ((w + 1) * series.length)))
    for (var k = 0; k < series.length; k++) {
      var t = k % every === 0 ? String(series[k].label) : ""
      lab += pad(t, (w + 1))
    }
    return '<font color="' + Tui.hex(accent) + '">' + lines.join("<br>").replace(/ /g, "&nbsp;") + '</font><br>'
         + '<font color="' + Tui.hex(dim) + '">' + Tui.esc(lab).replace(/ /g, "&nbsp;") + '</font>'
  }

  // Weekday x hour, in shades of the accent: ·░▒▓█
  function heatmap(m) {
    if (!m || !m.length) return ""
    var max = 0
    for (var y = 0; y < m.length; y++) for (var x = 0; x < 24; x++) max = Math.max(max, m[y][x])
    var w = cols >= 4 + 24 * 3 ? 3 : 2
    var out = '<font color="' + Tui.hex(dim) + '">' + "&nbsp;".repeat(4)
    for (var hh = 0; hh < 24; hh++) out += (hh % 6 === 0 ? pad(String(hh), w * (hh % 6 === 0 ? 1 : 1)) : " ".repeat(w)).replace(/ /g, "&nbsp;")
    out += '</font>'
    var glyphs = "·░▒▓█"
    for (var d = 0; d < 7; d++) {
      out += '<br><font color="' + Tui.hex(dim) + '">' + days[d] + '&nbsp;</font>'
      for (var h = 0; h < 24; h++) {
        var v = max > 0 ? m[d][h] / max : 0
        var g = v <= 0 ? 0 : Math.min(4, 1 + Math.floor(v * 3.999))
        var col = v <= 0 ? faint : Tui.mix(dim, accent, Math.min(1, 0.35 + v * 0.65))
        out += '<font color="' + Tui.hex(col) + '">' + glyphs.charAt(g).repeat(w - 1) + '</font>&nbsp;'
      }
    }
    return out
  }

  // A ranked list with bars: tracks, artists or albums.
  function ranked(items, kind, n) {
    if (!items || !items.length) return '<font color="' + Tui.hex(dim) + '">nothing yet</font>'
    var max = 1
    for (var i = 0; i < items.length; i++) max = Math.max(max, items[i].plays || 0)
    var nameW = Math.max(14, Math.min(40, Math.floor(halfCols * 0.55)))
    var barW = Math.max(6, halfCols - nameW - 12)
    var out = []
    for (var j = 0; j < Math.min(n, items.length); j++) {
      var it = items[j]
      var name = kind === "artist" ? it.name : it.title + (kind === "track" || kind === "album" ? " · " + who(it.artists) : "")
      out.push('<font color="' + Tui.hex(j === 0 ? accent : dim) + '">' + lpad(j + 1, 2) + '</font>&nbsp;'
               + '<font color="' + Tui.hex(j < 3 ? fg : Tui.mix(fg, dim, 0.4)) + '">' + Tui.esc(pad(name, nameW)).replace(/ /g, "&nbsp;") + '</font>&nbsp;'
               + bar((it.plays || 0) / max, barW) + '&nbsp;<font color="' + Tui.hex(dim) + '">' + lpad(it.plays || 0, 3) + '×</font>')
    }
    return out.join("<br>")
  }
  readonly property int halfCols: Math.floor((cols - 4) / (twoUp ? 2 : 1))
  readonly property bool twoUp: cols >= 110

  // ---- layout ------------------------------------------------------------------

  Column {
    id: top
    width: parent.width
    spacing: pane.ch * 0.3
    Text {
      width: parent.width
      clip: true
      textFormat: Text.StyledText
      text: '<font color="' + Tui.hex(pane.accent) + '">╱╱</font> ' + (pane.wrapped ? "WRAPPED" : "STATS") + ' '
            + '<font color="' + Tui.hex(pane.faint) + '">' + "─".repeat(200) + '</font>'
      font.family: host.family; font.pixelSize: Style.font.caption; font.letterSpacing: 1
      color: pane.dim
    }
    Row {
      spacing: pane.cw * 2
      Repeater {
        model: pane.ranges
        Text {
          required property var modelData
          required property int index
          readonly property bool on: index === pane.rangeIndex
          text: (on ? "▰ " : "▱ ") + modelData.label
          font.family: host.family; font.pixelSize: Style.font.body; font.bold: on
          color: on ? host.accentText : (rangeArea.containsMouse ? pane.fg : pane.dim)
          MouseArea { id: rangeArea; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                      onClicked: { pane.range = parent.modelData.id; pane.forceActiveFocus() } }
        }
      }
    }
  }

  Flickable {
    id: flick
    anchors.top: top.bottom; anchors.topMargin: pane.ch * 0.8
    anchors.bottom: footer.top; anchors.bottomMargin: pane.ch * 0.4
    width: parent.width
    clip: true
    contentHeight: body.height
    boundsBehavior: Flickable.StopAtBounds
    function scrollBy(dy) { contentY = Math.max(0, Math.min(Math.max(0, contentHeight - height), contentY + dy)) }

    Column {
      id: body
      width: flick.width
      spacing: pane.ch * 0.9

      Text {
        visible: !pane.d
        text: pane.err || (pane.loading ? "reading the history…" : "")
        font.family: host.family; font.pixelSize: Style.font.body; color: pane.dim
      }

      // ── the regular view ─────────────────────────────────────────────────
      Column {
        visible: !!pane.d && !pane.wrapped
        width: parent.width
        spacing: pane.ch * 0.9

        // headline numbers
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.StyledText
          text: {
            var d = pane.d || {}, s = d.streaks || {}
            function big(v, l) { return '<font color="' + Tui.hex(host.accentText) + '"><b>' + v + '</b></font> <font color="' + Tui.hex(pane.dim) + '">' + l + '</font>' }
            return [big(pane.hours(d.minutes), "listened"), big(d.plays || 0, "plays"),
                    big(pane.pct(d.skipRate), "skipped"),
                    big((d.distinct || {}).artists || 0, "artists"),
                    big((s.current || 0) + " d", "streak · best " + (s.longest || 0))].join("&nbsp;&nbsp;&nbsp;")
          }
          font.family: host.family; font.pixelSize: Style.font.body + 2
        }

        Text {
          width: parent.width
          textFormat: Text.StyledText
          text: pane.rule(pane.range === "year" || pane.range === "all" ? "minutes by month" : "minutes by day")
          font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim
          clip: true
        }
        Text {
          textFormat: Text.StyledText
          text: pane.d ? pane.chart(pane.d.series, 4) : ""
          font.family: host.family; font.pixelSize: Style.font.body
          lineHeight: 0.95
        }

        Grid {
          columns: pane.twoUp ? 2 : 1
          columnSpacing: pane.cw * 4
          rowSpacing: pane.ch * 0.9
          Repeater {
            model: [{ t: "top tracks", k: "track", f: "tracks" }, { t: "top artists", k: "artist", f: "artists" }]
            Column {
              required property var modelData
              width: pane.halfCols * pane.cw
              spacing: pane.ch * 0.4
              Text { width: parent.width; clip: true; textFormat: Text.StyledText; text: pane.rule(modelData.t)
                     font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim }
              Text { textFormat: Text.StyledText; text: pane.d ? pane.ranked(pane.d[modelData.f], modelData.k, 10) : ""
                     font.family: host.family; font.pixelSize: Style.font.body }
            }
          }
        }

        Grid {
          columns: pane.twoUp ? 2 : 1
          columnSpacing: pane.cw * 4
          rowSpacing: pane.ch * 0.9
          Column {
            width: pane.halfCols * pane.cw
            spacing: pane.ch * 0.4
            Text { width: parent.width; clip: true; textFormat: Text.StyledText; text: pane.rule("top albums")
                   font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim }
            Text { textFormat: Text.StyledText; text: pane.d ? pane.ranked(pane.d.albums, "album", 6) : ""
                   font.family: host.family; font.pixelSize: Style.font.body }
          }
          Column {
            width: pane.halfCols * pane.cw
            spacing: pane.ch * 0.4
            Text { width: parent.width; clip: true; textFormat: Text.StyledText; text: pane.rule("when · minutes by weekday and hour")
                   font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim }
            Text { textFormat: Text.StyledText; text: pane.d ? pane.heatmap(pane.d.heatmap) : ""
                   font.family: host.family; font.pixelSize: Style.font.body }
          }
        }
      }

      // ── wrapped: this calendar month as a story ───────────────────────────────
      Column {
        visible: !!pane.d && pane.wrapped
        width: parent.width
        spacing: pane.ch * 0.8
        readonly property var w: (pane.d && pane.d.wrapped) || ({})

        Text {
          text: (parent.w.month || "this month").toUpperCase()
          font.family: host.family; font.pixelSize: Style.font.body * 2; font.bold: true; font.letterSpacing: 3
          color: host.accentText
        }
        Text {
          textFormat: Text.StyledText
          text: '<font color="' + Tui.hex(pane.dim) + '">you listened for </font><font color="' + Tui.hex(pane.fg) + '"><b>'
                + pane.hours(pane.d ? pane.d.minutes : 0) + '</b></font><font color="' + Tui.hex(pane.dim) + '"> · '
                + (pane.d ? pane.d.plays : 0) + ' plays · ' + ((pane.d && pane.d.distinct) ? pane.d.distinct.tracks : 0) + ' different songs</font>'
          font.family: host.family; font.pixelSize: Style.font.body + 4
        }
        // the cards: label on the left, the answer on the right
        Text {
          width: parent.width
          textFormat: Text.StyledText
          wrapMode: Text.WordWrap
          text: {
            var d = pane.d || {}, w = parent.w || {}
            var rows = []
            function row(k, v) { rows.push('<font color="' + Tui.hex(pane.accent) + '">' + pane.pad(k, 14).replace(/ /g, "&nbsp;") + '</font>' + v) }
            var ta = (d.artists || [])[0], tt = (d.tracks || [])[0], tal = (d.albums || [])[0]
            if (ta) row("#1 artist", '<b>' + Tui.esc(ta.name) + '</b> <font color="' + Tui.hex(pane.dim) + '">· ' + ta.plays + ' plays · ' + pane.hours(ta.minutes) + '</font>')
            if (tt) row("#1 song", '<b>' + Tui.esc(tt.title) + '</b> <font color="' + Tui.hex(pane.dim) + '">· ' + Tui.esc(pane.who(tt.artists)) + ' · ' + tt.plays + '×</font>')
            if (tal) row("#1 album", Tui.esc(tal.title) + ' <font color="' + Tui.hex(pane.dim) + '">· ' + Tui.esc(pane.who(tal.artists)) + '</font>')
            if (w.onRepeat) row("on repeat", Tui.esc(w.onRepeat.title) + ' <font color="' + Tui.hex(pane.dim) + '">· ' + w.onRepeat.plays + '× in one day (' + w.onRepeat.date + ')</font>')
            if (w.topDay) row("your day", w.topDay.date + ' <font color="' + Tui.hex(pane.dim) + '">· ' + pane.hours(w.topDay.minutes) + '</font>')
            if (w.topHour) row("your hour", (w.topHour.hour < 10 ? "0" : "") + w.topHour.hour + ':00 <font color="' + Tui.hex(pane.dim) + '">· ' + pane.hours(w.topHour.minutes) + ' across the month</font>')
            if (w.newArtistCount !== undefined)
              row("new to you", w.newArtistCount + ' artist' + (w.newArtistCount === 1 ? '' : 's') + (w.newArtists && w.newArtists.length
                  ? ' <font color="' + Tui.hex(pane.dim) + '">· ' + w.newArtists.slice(0, 3).map(function(a) { return Tui.esc(a.name) }).join(", ") + '</font>' : ''))
            if (d.streaks) row("streak", d.streaks.longest + ' day' + (d.streaks.longest === 1 ? '' : 's') + ' in a row <font color="' + Tui.hex(pane.dim) + '">· ' + d.streaks.days + ' days with music</font>')
            row("skipped", pane.pct(d.skipRate) + ' <font color="' + Tui.hex(pane.dim) + '">of what started</font>')
            if (w.first) row("it began with", Tui.esc(w.first.title) + ' <font color="' + Tui.hex(pane.dim) + '">· ' + Tui.esc(pane.who(w.first.artists)) + '</font>')
            return rows.join("<br>")
          }
          font.family: host.family; font.pixelSize: Style.font.body
          color: pane.fg
          lineHeight: 1.25
        }
        Text {
          width: parent.width; clip: true; textFormat: Text.StyledText; text: pane.rule("the month, day by day")
          font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim
        }
        Text {
          textFormat: Text.StyledText
          text: pane.d ? pane.chart(pane.d.series, 3) : ""
          font.family: host.family; font.pixelSize: Style.font.body
          lineHeight: 0.95
        }
        Grid {
          columns: pane.twoUp ? 2 : 1
          columnSpacing: pane.cw * 4
          rowSpacing: pane.ch * 0.9
          Repeater {
            model: [{ t: "top 5 artists", k: "artist", f: "artists" }, { t: "top 5 songs", k: "track", f: "tracks" }]
            Column {
              required property var modelData
              width: pane.halfCols * pane.cw
              spacing: pane.ch * 0.4
              Text { width: parent.width; clip: true; textFormat: Text.StyledText; text: pane.rule(modelData.t)
                     font.family: host.family; font.pixelSize: Style.font.caption; color: pane.dim }
              Text { textFormat: Text.StyledText; text: pane.d ? pane.ranked(pane.d[modelData.f], modelData.k, 5) : ""
                     font.family: host.family; font.pixelSize: Style.font.body }
            }
          }
        }
      }
    }
  }

  Text {
    id: footer
    anchors.bottom: parent.bottom
    width: parent.width
    elide: Text.ElideRight
    textFormat: Text.StyledText
    text: Tui.hints([["⇥", "range"], ["w", "wrapped"], ["j/k", "scroll"], ["r", "reload"], ["esc", "back"]], host.accentText, pane.dim)
          + (pane.loading ? '<font color="' + Tui.hex(pane.dim) + '">&nbsp;&nbsp;&nbsp;·&nbsp;reading…</font>' : "")
    font.family: host.family; font.pixelSize: Style.font.caption
  }
}
