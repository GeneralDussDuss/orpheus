import QtQuick
import QtQuick.Window
import Quickshell.Wayland
import OrpheusDesktop

// A layer-shell panel, approximated with a frameless window: placed on its screen
// from its anchors and margins, kept above or below other windows by its layer.
Window {
  id: w

  // Declared inside Service's Item, a Window would wait for that Item's window
  // to show first, and Service has none. These are top-level windows.
  transientParent: null

  property PanelEdges anchors: PanelEdges {}
  property PanelEdges margins: PanelEdges {}
  property int exclusionMode
  property int exclusiveZone
  property var mask
  property real implicitWidth: 400
  property real implicitHeight: 300

  readonly property rect area: screen ? Qt.rect(screen.virtualX, screen.virtualY, screen.width, screen.height)
                                      : Qt.rect(0, 0, 1280, 720)
  readonly property bool spanX: anchors.left && anchors.right
  readonly property bool spanY: anchors.top && anchors.bottom

  color: "transparent"
  flags: Qt.FramelessWindowHint | Qt.Tool
         | (WlrLayershell.layer >= WlrLayer.Top ? Qt.WindowStaysOnTopHint : Qt.WindowStaysOnBottomHint)
         | (WlrLayershell.keyboardFocus === WlrKeyboardFocus.None ? Qt.WindowDoesNotAcceptFocus : 0)

  width: spanX ? area.width - margins.left - margins.right : implicitWidth
  height: spanY ? area.height - margins.top - margins.bottom : implicitHeight
  x: area.x + (anchors.left ? margins.left
               : anchors.right ? area.width - width - margins.right
               : (area.width - width) / 2)
  y: area.y + (anchors.top ? margins.top
               : anchors.bottom ? area.height - height - margins.bottom
               : (area.height - height) / 2)

  onVisibleChanged: if (visible && WlrLayershell.keyboardFocus !== WlrKeyboardFocus.None) requestActivate()
}
