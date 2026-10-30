import QtQuick
import Quickshell
import qs.Commons

// The widget as a real window, so it snaps into the user's Hyprland layout
// (tile) or floats where they drag it (float). The title tells the window rule
// which: "Orpheus Widget" tiles, "Orpheus Widget [float]" floats.
FloatingWindow {
  id: win

  property var engine: null
  property bool floating: false
  readonly property var cfg: engine ? engine.widget : ({})

  title: floating ? "Orpheus Widget [float]" : "Orpheus Widget"
  color: Color.background
  implicitWidth: Math.round(body.cw * 48)
  implicitHeight: Math.round(body.ch * 18)
  minimumSize: Qt.size(Math.round(body.cw * 30), Math.round(body.ch * 7))
  // Closing it turns the widget off; game mode hiding it does not.
  onVisibleChanged: if (!visible && engine && !engine.gameMode) engine.setWidget("enabled", "off")

  WidgetBody {
    id: body
    anchors.fill: parent
    anchors.margins: Math.round(cw * 0.5)
    engine: win.engine
    full: win.cfg.style !== "compact"
    fill: true
  }
}
