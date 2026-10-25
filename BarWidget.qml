import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Tiny always-on spectrum in the bar. Left click opens the big stage, right
// click or scroll cycles its style, middle click toggles the mini player.
BarWidget {
  id: root
  moduleName: "orpheus"

  readonly property var engine: bar && bar.shell ? bar.shell.serviceFor("orpheus") : null
  readonly property int vizWidth: Style.space(vertical ? 18 : 56)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Tell the service a bar widget is showing so it keeps the audio running.
  property var registeredWith: null
  function register() {
    if (registeredWith === engine) return
    if (registeredWith) registeredWith.barWidgets = Math.max(0, registeredWith.barWidgets - 1)
    registeredWith = engine
    if (engine) engine.barWidgets += 1
  }
  onEngineChanged: register()
  Component.onCompleted: register()
  Component.onDestruction: if (registeredWith) registeredWith.barWidgets = Math.max(0, registeredWith.barWidgets - 1)

  function run(method) { Quickshell.execDetached(["omarchy-shell", "-q", "orpheus", method]) }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: root.vizWidth + Style.space(10)
    tooltipText: !root.engine ? "Orpheus is starting"
      : !root.engine.hasCava ? "Orpheus needs cava: sudo pacman -S cava"
      : (root.engine.player ? (root.engine.player.trackTitle || "") + (root.engine.player.trackArtist ? " · " + root.engine.player.trackArtist : "") + "\n" : "")
        + root.engine.styleLabels[root.engine.style] + " · Click: visualizer · Right/scroll: style · Middle: mini player"
    onPressed: function(code) {
      if (!root.engine) return
      if (code === Qt.LeftButton) root.engine.open = !root.engine.open
      else if (code === Qt.RightButton) root.engine.nextStyle(1)
      else if (code === Qt.MiddleButton) root.engine.setMiniPlayer(!root.engine.miniPlayer)
    }
    onWheelMoved: function(delta) { if (root.engine) root.engine.nextStyle(delta > 0 ? -1 : 1) }
  }

  Viz {
    anchors.centerIn: parent
    width: root.vizWidth
    height: Math.round(root.barSize * 0.72)
    engine: root.engine
    styleName: "mini"
  }
}
