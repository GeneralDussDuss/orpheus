import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "Tui.js" as Tui

// Desktop widget: lives above the wallpaper, below windows, in a corner.
//   compact  ┌─ now playing ─────── ⏯ ┐   art · title · artist · seek · controls
//   full     ┌─ orpheus · prism ─────┐   the same, with a live Prism spectrum on top
// Hides when nothing is playing and while a window is fullscreen.
PanelWindow {
  id: win

  property var engine: null
  readonly property var player: engine ? engine.player : null
  readonly property var cfg: engine ? engine.widget : ({})
  readonly property bool full: cfg.style !== "compact"
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

  readonly property int boxWidth: Math.round(cw * 48)
  implicitWidth: boxWidth
  implicitHeight: Math.round(box.implicitHeight)
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
  mask: Region { item: box }

  WlrLayershell.layer: layer === "desktop" ? WlrLayer.Bottom : WlrLayer.Top
  WlrLayershell.namespace: "orpheus-widget"
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  HoverHandler { id: hover }

  WidgetBody {
    id: box
    engine: win.engine
    full: win.full
    width: win.boxWidth
    height: implicitHeight
    x: !win.reserve ? 0 : (win.atLeft ? win.gap : parent.width - width - win.gap)
    // Floating over windows: sit back until the pointer comes near.
    property real rest: win.layer === "top" && !hover.hovered ? 0.72 : 1
    Behavior on rest { NumberAnimation { duration: Tui.STATE; easing.type: Easing.InOutCubic } }
    opacity: rest * appear
  }
}
