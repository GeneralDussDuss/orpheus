import QtQuick
import QtQuick.Window

// A normal top-level window that opens at its implicit size.
Window {
  // Declared inside Service's Item, a Window would wait for that Item's window
  // to show first, and Service has none. These are top-level windows.
  transientParent: null

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
}
