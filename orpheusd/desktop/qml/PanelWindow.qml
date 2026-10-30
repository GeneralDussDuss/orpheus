import QtQuick
import QtQuick.Window
import Quickshell.Wayland
import OrpheusDesktop

// A layer-shell panel, approximated with a frameless window: placed on its screen
// from its anchors and margins, kept above or below other windows by its layer.
// The Background layer goes one further on Windows: the window is parented in
// behind the desktop icons (wallpaper.py), takes no input and never activates.
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

  readonly property bool wallpaper: WlrLayershell.layer === WlrLayer.Background && Qt.platform.os === "windows"
  property string wallpaperLayout: ""     // "raised" | "classic" | "progman" once attached
  // Explorer restarted and took the native window with it: the owner should
  // make a new one.
  signal wallpaperLost()

  color: "transparent"
  flags: Qt.FramelessWindowHint | Qt.Tool
         | (WlrLayershell.layer >= WlrLayer.Top ? Qt.WindowStaysOnTopHint : Qt.WindowStaysOnBottomHint)
         | (WlrLayershell.keyboardFocus === WlrKeyboardFocus.None ? Qt.WindowDoesNotAcceptFocus : 0)
         | (wallpaper ? Qt.WindowTransparentForInput | Qt.WindowDoesNotAcceptFocus : 0)

  width: spanX ? area.width - margins.left - margins.right : implicitWidth
  height: spanY ? area.height - margins.top - margins.bottom : implicitHeight
  x: area.x + (anchors.left ? margins.left
               : anchors.right ? area.width - width - margins.right
               : (area.width - width) / 2)
  y: area.y + (anchors.top ? margins.top
               : anchors.bottom ? area.height - height - margins.bottom
               : (area.height - height) / 2)

  onVisibleChanged: {
    if (visible && WlrLayershell.keyboardFocus !== WlrKeyboardFocus.None) requestActivate()
    if (wallpaper && visible) Qt.callLater(attachWallpaper)
    else if (!visible) detachWallpaper()
  }
  Component.onCompleted: if (wallpaper && visible) Qt.callLater(attachWallpaper)
  Component.onDestruction: detachWallpaper()

  function attachWallpaper() {
    if (wallpaper && visible && wallpaperLayout === "") wallpaperLayout = Wallpaper.attach(w)
  }
  function detachWallpaper() {
    if (wallpaperLayout === "") return
    wallpaperLayout = ""
    Wallpaper.detach(w)
  }
  Connections {
    target: w.wallpaper ? Wallpaper : null
    function onLost() { if (w.wallpaperLayout !== "") { w.wallpaperLayout = ""; w.wallpaperLost() } }
  }
}
