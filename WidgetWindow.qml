import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Tui.js" as Tui

// The widget as a real window, so it snaps into the user's Hyprland layout
// (tile) or floats where they drag it (float). The title tells the window rule
// which: "Orpheus Widget" tiles, "Orpheus Widget [float]" floats at the card
// size, and the cassette floats as "[float][tall]" so the rule leaves its
// portrait default alone. Either body fills the window (fill: true).
FloatingWindow {
  id: win

  property var engine: null
  property bool floating: false
  readonly property var cfg: engine ? engine.widget : ({})
  readonly property bool cassette: cfg.style === "cassette"

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height

  title: floating ? (cassette ? "Orpheus Widget [float][tall]" : "Orpheus Widget [float]")
                  : "Orpheus Widget"
  color: Commons.Color.background
  implicitWidth: Math.round(cw * (cassette ? 30 : 48))
  implicitHeight: Math.round(ch * (cassette ? 44 : 18))
  minimumSize: cassette ? Qt.size(Math.round(cw * 22), Math.round(ch * 24))
                        : Qt.size(Math.round(cw * 30), Math.round(ch * 7))
  // Closing it turns the widget off; game mode hiding it does not.
  onVisibleChanged: if (!visible && engine && !engine.gameMode) engine.setWidget("enabled", "off")

  Loader {
    anchors.fill: parent
    anchors.margins: Math.round(win.cw * 0.5)
    sourceComponent: win.cassette ? cassetteBody : horizBody
  }

  Component {
    id: horizBody
    WidgetBody {
      engine: win.engine
      full: win.cfg.style !== "compact"
      fill: true
    }
  }
  Component {
    id: cassetteBody
    WidgetCassette {
      engine: win.engine
      fill: true
    }
  }
}
