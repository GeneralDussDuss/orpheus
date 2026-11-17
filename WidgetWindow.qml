import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import "Tui.js" as Tui

// The widget as a real window, so it snaps into the user's Hyprland layout
// (tile) or floats where they drag it (float). The title tells the window rule
// which: "Orpheus Widget" tiles, "Orpheus Widget [float]" floats at the card
// size, and the cassette floats as "[float][tall]" so the rule leaves its
// portrait default alone. Either body fills the window (fill: true). The
// cassette deck also takes the keyboard here (it prints its keys): a layer
// surface can't, so the corner widget's copy has none.
FloatingWindow {
  id: win

  property var engine: null
  property bool floating: false
  readonly property var cfg: engine ? engine.widget : ({})
  // Any tall style: the Studio deck ("cassette") or a hardware deck.
  readonly property bool cassette: (engine && engine.tallStyles ? engine.tallStyles : ["cassette"]).indexOf(cfg.style) >= 0
  // A hardware deck is an object on the desk, not a card: the window is
  // see-through and undecorated ("[deck]" in the title tells the rule) so the
  // device stands on the wallpaper with only its own shadow and light spill.
  readonly property bool deck: cassette && cfg.style !== "cassette"

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height

  title: (floating ? (cassette ? "Orpheus Widget [float][tall]" : "Orpheus Widget [float]")
                   : "Orpheus Widget") + (deck ? "[deck]" : "")
  color: deck ? "transparent" : Commons.Color.background
  implicitWidth: Math.round(cw * (cassette ? 30 : 48))
  implicitHeight: Math.round(ch * (cassette ? 44 : 18))
  minimumSize: cassette ? Qt.size(Math.round(cw * 22), Math.round(ch * 24))
                        : Qt.size(Math.round(cw * 30), Math.round(ch * 7))
  // Closing it turns the widget off; game mode hiding it does not.
  onVisibleChanged: if (!visible && engine && !engine.gameMode) engine.setWidget("enabled", "off")

  Loader {
    anchors.fill: parent
    // decks bring their own room (the stage margin) for the lean and shadow
    anchors.margins: win.deck ? 0 : Math.round(win.cw * 0.5)
    sourceComponent: win.cassette ? ({ cassette: cassetteBody, monolith: monolithBody, reference: referenceBody, field: fieldBody })[win.cfg.style] : horizBody
    focus: true
    onLoaded: if (item) item.forceActiveFocus()
  }

  // Floating only: drag the top strip to move it (a tiled window is placed by
  // the layout). Above the body, whose picture takes clicks across its whole
  // face; the grip passes plain clicks through (MoveGrip.qml), so the close
  // button in the corner still closes. cursor: false keeps that button's
  // pointing hand rather than painting a move cursor over it.
  MoveGrip {
    visible: win.floating
    enabled: win.floating
    cursor: false
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.round(win.cw * 0.5 + win.ch * 1.5)
    z: 10
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
      keys: true
    }
  }
  Component {
    id: monolithBody
    WidgetMonolith {
      engine: win.engine
      fill: true
      keys: true
    }
  }
  Component {
    id: referenceBody
    WidgetReference {
      engine: win.engine
      fill: true
      keys: true
    }
  }
  Component {
    id: fieldBody
    WidgetField {
      engine: win.engine
      fill: true
      keys: true
    }
  }
}
