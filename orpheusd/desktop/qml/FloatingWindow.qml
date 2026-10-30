import QtQuick
import QtQuick.Window

// A normal top-level window that opens at its implicit size. On Hyprland these
// have no decorations, so here they are frameless too: the TUI boxes are the
// frame. Drag the top strip to move it (double-click to maximize), drag an edge
// or corner to resize; the window manager does the work, so snapping still applies.
Window {
  id: w
  // Declared inside Service's Item, a Window would wait for that Item's window
  // to show first, and Service has none. These are top-level windows.
  transientParent: null
  flags: Qt.Window | Qt.FramelessWindowHint

  property real implicitWidth: 960
  property real implicitHeight: 640
  property size minimumSize: Qt.size(0, 0)
  property size maximumSize: Qt.size(16777215, 16777215)

  width: implicitWidth
  height: implicitHeight
  minimumWidth: minimumSize.width
  minimumHeight: minimumSize.height
  maximumWidth: maximumSize.width
  maximumHeight: maximumSize.height

  // Beneath the window's own content: a press on anything that takes clicks
  // (the status line's hints) goes to it, and a press on plain text or empty
  // space falls through to here and moves the window. Above the content, as
  // this was, it swallowed every click in the strip, even with no drag.
  Item {
    z: -1
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: 28
    DragHandler {
      target: null
      grabPermissions: PointerHandler.CanTakeOverFromAnything
      onActiveChanged: if (active) w.startSystemMove()
    }
    TapHandler {
      acceptedButtons: Qt.LeftButton
      gesturePolicy: TapHandler.DragThreshold
      onDoubleTapped: w.visibility = w.visibility === Window.Maximized ? Window.Windowed : Window.Maximized
    }
  }

  Repeater {
    model: [
      { e: Qt.LeftEdge,                  x: 0, y: 1, wd: 0, ht: 2, c: Qt.SizeHorCursor },
      { e: Qt.RightEdge,                 x: 2, y: 1, wd: 0, ht: 2, c: Qt.SizeHorCursor },
      { e: Qt.TopEdge,                   x: 1, y: 0, wd: 2, ht: 0, c: Qt.SizeVerCursor },
      { e: Qt.BottomEdge,                x: 1, y: 2, wd: 2, ht: 0, c: Qt.SizeVerCursor },
      { e: Qt.TopEdge | Qt.LeftEdge,     x: 0, y: 0, wd: 1, ht: 1, c: Qt.SizeFDiagCursor },
      { e: Qt.BottomEdge | Qt.RightEdge, x: 2, y: 2, wd: 1, ht: 1, c: Qt.SizeFDiagCursor },
      { e: Qt.TopEdge | Qt.RightEdge,    x: 2, y: 0, wd: 1, ht: 1, c: Qt.SizeBDiagCursor },
      { e: Qt.BottomEdge | Qt.LeftEdge,  x: 0, y: 2, wd: 1, ht: 1, c: Qt.SizeBDiagCursor }
    ]
    // x/y: 0 = near edge, 1 = along the side, 2 = far edge. wd/ht: 0 = grip, 1 = corner, 2 = span.
    MouseArea {
      required property var modelData
      readonly property int grip: 6
      readonly property int corner: 14
      z: 10001
      visible: w.visibility !== Window.Maximized && w.visibility !== Window.FullScreen
      x: modelData.x === 0 ? 0 : modelData.x === 2 ? w.width - width : corner
      y: modelData.y === 0 ? 0 : modelData.y === 2 ? w.height - height : corner
      width: modelData.wd === 0 ? grip : modelData.wd === 1 ? corner : w.width - 2 * corner
      height: modelData.ht === 0 ? grip : modelData.ht === 1 ? corner : w.height - 2 * corner
      cursorShape: modelData.c
      onPressed: w.startSystemResize(modelData.e)
    }
  }
}
