import QtQuick
import qs.Commons

// Placeholder for the Monolith hardware deck (built on DeckCore).
Item {
  id: deck
  property var engine: null
  property bool full: true
  property bool fill: false
  property bool keys: false
  implicitHeight: Math.round(width * 1.7)
  DeckCore { id: core; engine: deck.engine; keys: deck.keys }
  focus: keys
  Keys.onPressed: function(e) { core.key(e) }
  Rectangle { anchors.fill: parent; color: core.bg; border.color: core.accent }
  Text { anchors.centerIn: parent; text: "Monolith · " + core.title + " · " + core.clock(core.shownPos); color: core.fg; font.family: core.fontFamily }
}
