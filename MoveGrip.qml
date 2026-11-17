import QtQuick

// A handle for moving a real window (xdg toplevel): press and drag anywhere on
// it and the compositor takes over the move (startSystemMove), so Hyprland's
// own rules apply: floating windows follow the pointer, tiled ones can be
// dragged to swap places.
//
// It only ever takes a passive grab on the press, so a click on anything
// under or over it still reaches that item. The drag takes over from a
// MouseArea only once the pointer has travelled past the drag threshold, and
// by then the press was no longer a click. startSystemMove() answers false
// outside an active press, which is why it is called from the drag's
// activation and nowhere else.
//
// Place it behind the buttons it shares a strip with (declare it first, or
// give it a lower z): a button under the pointer then keeps its own pointing
// cursor and takes the press itself, so dragging starts only on bare strip.
// Over something that fills the strip (a picture with a click handler), put
// it on top and pass cursor: false so it does not hide that item's cursor.
Item {
  id: grip

  // The cursor over a bare strip says it can be moved.
  property bool cursor: true

  DragHandler {
    id: drag
    target: null                      // the compositor moves the window; nothing here does
    enabled: grip.enabled
    // take the drag over from a MouseArea, or any item, once it passes the threshold
    grabPermissions: PointerHandler.CanTakeOverFromItems | PointerHandler.CanTakeOverFromHandlersOfDifferentType
                     | PointerHandler.ApprovesTakeOverByAnything
    onActiveChanged: {
      if (!active) return
      var w = grip.Window.window
      if (w && typeof w.startSystemMove === "function") w.startSystemMove()
    }
  }
  HoverHandler {
    enabled: grip.enabled && grip.cursor
    cursorShape: Qt.SizeAllCursor
  }
}
