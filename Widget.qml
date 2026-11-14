import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Tui.js" as Tui

// Desktop widget: lives above the wallpaper, below windows, in a corner.
//   compact  ┌─ now playing ─────── ⏯ ┐   art · title · artist · seek · controls
//   full     ┌─ orpheus · prism ─────┐   the same, with a live Prism spectrum on top
//   cassette a standing walkman tape -- the spectrum is the window, two reels
//            spin and wind with the seek, the track written on the label below;
//            narrow and tall, for a vertical bar (WidgetCassette.qml)
// Hides when nothing is playing and while a window is fullscreen.
PanelWindow {
  id: win

  property var engine: null
  readonly property var player: engine ? engine.player : null
  readonly property var cfg: engine ? engine.widget : ({})
  readonly property string styleName: ["compact", "full", "cassette"].indexOf(cfg.style) >= 0 ? cfg.style : "full"
  readonly property bool cassette: styleName === "cassette"
  readonly property bool full: styleName !== "compact"
  readonly property string corner: cfg.corner || "bottom-right"
  // top: above windows (fades back until hovered) · reserve: above windows, and
  // tiled windows make room (full-width edge strip) · desktop: below windows
  readonly property string layer: ["top", "reserve", "desktop"].indexOf(cfg.layer) >= 0 ? cfg.layer : "top"
  readonly property bool reserve: layer === "reserve"
  readonly property bool atTop: corner.indexOf("top") === 0
  readonly property bool atLeft: corner.indexOf("left") > 0
  readonly property var hyprMonitor: Hyprland.monitorFor(screen)
  readonly property bool fullscreen: !!(hyprMonitor && hyprMonitor.activeWorkspace && hyprMonitor.activeWorkspace.hasFullscreen)

  FontMetrics { id: fm; font.family: Style.font.family; font.pixelSize: Style.font.body }
  readonly property real cw: fm.advanceWidth("M")
  readonly property real ch: fm.height
  readonly property real gap: Style.gapsOut * 4

  screen: {
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++) if (cfg.monitor && list[i].name === cfg.monitor) return list[i]
    // Default: the biggest screen.
    var best = null
    for (var j = 0; j < list.length; j++)
      if (!best || list[j].width * list[j].height > best.width * best.height) best = list[j]
    return best
  }

  // The cassette form stands tall and narrow so it tucks into a vertical bar.
  readonly property int boxWidth: Math.round(cw * (cassette ? 26 : 48))
  implicitWidth: boxWidth
  implicitHeight: Math.round(bodyLoader.item ? bodyLoader.item.implicitHeight : 0)
  color: "transparent"
  visible: !!player && !fullscreen

  // A corner anchor can't reserve space, so "reserve" spans the whole edge,
  // reserves the widget's height, and only the box itself takes input.
  anchors.top: atTop
  anchors.bottom: !atTop
  anchors.left: reserve || atLeft
  anchors.right: reserve || !atLeft
  margins.top: atTop ? gap + (reserve ? 0 : Style.bar.sizeHorizontal) : 0
  margins.bottom: atTop ? 0 : gap
  margins.left: reserve ? 0 : gap
  margins.right: reserve ? 0 : gap
  exclusionMode: reserve ? ExclusionMode.Normal : ExclusionMode.Ignore
  exclusiveZone: reserve ? implicitHeight + gap : 0
  mask: Region { item: bodyLoader.item }

  WlrLayershell.layer: layer === "desktop" ? WlrLayer.Bottom : WlrLayer.Top
  WlrLayershell.namespace: "orpheus-widget"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  HoverHandler { id: hover }

  // One body at a time: the horizontal WidgetBody, or the vertical cassette.
  // A Loader keeps only the chosen one alive (its timers, spectrum and
  // live-count), so switching style swaps cleanly.
  Loader {
    id: bodyLoader
    sourceComponent: win.cassette ? cassetteBody : horizBody
    x: !win.reserve ? 0 : (win.atLeft ? win.gap : parent.width - width - win.gap)
    // Floating over windows: sit back until the pointer comes near.
    property real rest: win.layer === "top" && !hover.hovered ? 0.72 : 1
    Behavior on rest { NumberAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
  }

  Component {
    id: horizBody
    WidgetBody {
      engine: win.engine
      full: win.full
      width: win.boxWidth
      height: implicitHeight
      opacity: bodyLoader.rest * appear
    }
  }
  Component {
    id: cassetteBody
    WidgetCassette {
      engine: win.engine
      full: win.full
      width: win.boxWidth
      height: implicitHeight
      opacity: bodyLoader.rest * appear
    }
  }
}
