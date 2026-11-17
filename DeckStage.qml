import QtQuick
import QtQuick.Effects
import "Tui.js" as Tui

// The depth rig every hardware deck stands in: makes the device read as a
// near-3D object on the desk without leaving the house style.
//
//   tilt       the device leans a few degrees toward the pointer (a real
//              projected rotation), springing back to rest when it leaves
//   lightVec   the key light (unit vector, x right, y down, z out of the
//              screen) swings with the pointer -- feed it to the material
//              shaders so highlights slide across metal and glass
//   par(d)     a parallax offset for a layer `d` px in front of (+) or behind
//              (-) the faceplate: glass shifts against what is under it
//   shadow     a soft contact shadow under the device that moves with the tilt
//   spill      the device's own light (LEDs, displays) glowing on the desk
//              behind it in the accent, breathing with the music
//
// Usage: DeckStage { id: stage; core: core; anchors.fill: parent
//                    Item { ...the device, filling the stage... } }
// Children see the device rect (`stage.inner`). Cost: the tilt re-composites
// one cached layer; nothing else redraws unless a deck binds lightVec into a
// shader (then that shader redraws while the pointer moves, never at rest).
Item {
  id: stage

  property var core: null
  default property alias content: device.data
  // degrees of lean at the edge of the device; 0 turns the rig off
  property real maxTilt: 7
  // room left round the device so the lean and the shadow never clip
  property real margin: Math.round(Math.min(width, height) * 0.035)
  // how far the light spill reaches, 0 = none (decks set this to their glow)
  property real spillAmount: 1
  // the device's silhouette corner radius, for the shadow and the spill
  property real radius: 12
  readonly property alias inner: device

  // --- pointer -> tilt ----------------------------------------------------
  HoverHandler { id: hover }
  readonly property var dbg: core && core.engine && core.engine.debugTilt !== undefined ? core.engine.debugTilt : null
  readonly property real targetX: dbg ? dbg.x : hover.hovered && width > 0 ? Math.max(-1, Math.min(1, (hover.point.position.x / width) * 2 - 1)) : 0
  readonly property real targetY: dbg ? dbg.y : hover.hovered && height > 0 ? Math.max(-1, Math.min(1, (hover.point.position.y / height) * 2 - 1)) : 0
  readonly property bool still: !!core && core.gameMode
  property real tx: 0
  property real ty: 0
  Binding on tx { value: stage.still ? 0 : stage.targetX }
  Binding on ty { value: stage.still ? 0 : stage.targetY }
  Behavior on tx { enabled: !stage.dbg; SpringAnimation { spring: 2.6; damping: 0.32; epsilon: 0.002 } }
  Behavior on ty { enabled: !stage.dbg; SpringAnimation { spring: 2.6; damping: 0.32; epsilon: 0.002 } }

  // The key light: up and to the left, swung by the pointer. Normalised.
  readonly property vector3d lightVec: {
    var x = -0.42 + 0.38 * tx, y = -0.62 + 0.32 * ty, z = 0.66
    var l = Math.sqrt(x * x + y * y + z * z)
    return Qt.vector3d(x / l, y / l, z / l)
  }
  function par(d) { return Qt.point(-tx * d, -ty * d) }

  // --- the desk: shadow and light spill ---------------------------------------
  readonly property color accent: core ? core.accent : "#ffffff"
  readonly property real bloom: core ? core.bloom : 0.5
  readonly property bool light: core ? core.light : false
  // Light on the desk: the accent, from under the device, scaled by bloom
  // (light themes keep a faint version), lifting with the music.
  readonly property real glow: spillAmount * (light ? 0.35 : Math.max(0.25, bloom))
                               * (core && core.playing ? 0.55 + 0.25 * core.swell + 0.2 * core.beat : 0.3)
  Item {
    id: spillBox
    anchors.fill: device
    visible: stage.glow > 0.01 && stage.spillAmount > 0
    Rectangle { id: spillSrc; anchors.fill: parent; anchors.margins: parent.width * 0.06; radius: stage.radius; color: stage.accent; visible: false }
    MultiEffect {
      source: spillSrc
      anchors.fill: spillSrc
      autoPaddingEnabled: true
      blurEnabled: true; blur: 1; blurMax: 64
      scale: 1.12
      opacity: 0.32 * stage.glow
    }
  }
  Item {
    id: shadowBox
    anchors.fill: device
    // the shadow falls away from the light, further when the device leans
    transform: Translate { x: -stage.lightVec.x * stage.margin * 0.55 + stage.tx * stage.margin * 0.25
                           y: -stage.lightVec.y * stage.margin * 0.55 + stage.ty * stage.margin * 0.25 }
    Rectangle { id: shadowSrc; anchors.fill: parent; anchors.margins: 2; radius: stage.radius; color: "black"; visible: false }
    MultiEffect {
      source: shadowSrc
      anchors.fill: shadowSrc
      autoPaddingEnabled: true
      blurEnabled: true; blur: 1; blurMax: 40
      opacity: stage.light ? 0.28 : 0.55
    }
  }

  // --- the side wall: the device's body, extruded --------------------------------
  // A few darkened copies of the cached device stacked behind it, stepping
  // away from the viewer: the edge's thickness shows on the side the device
  // leans away from, and a sliver at the bottom even at rest.
  property real thickness: Math.round(Math.min(device.width, device.height) * 0.022)
  property int slabs: thickness > 0 ? 6 : 0
  readonly property real wallX: -tx * thickness
  readonly property real wallY: thickness * 0.45 - ty * thickness
  ShaderEffectSource { id: devTex; sourceItem: device; hideSource: false; visible: false; smooth: true }
  Repeater {
    model: stage.slabs
    ShaderEffect {
      required property int index
      readonly property real k: (index + 1) / stage.slabs
      x: device.x + stage.wallX * k
      y: device.y + stage.wallY * k
      width: device.width; height: device.height
      property var src: devTex
      // darker the further back; light themes keep a lighter wall
      property real shade: (stage.light ? 0.62 : 0.42) - 0.12 * k
      fragmentShader: Qt.resolvedUrl("shaders/deck_slab.frag.qsb")
      transform: [
        Rotation { origin.x: width / 2; origin.y: height / 2; axis { x: 0; y: 1; z: 0 } angle: stage.tx * stage.maxTilt },
        Rotation { origin.x: width / 2; origin.y: height / 2; axis { x: 1; y: 0; z: 0 } angle: -stage.ty * stage.maxTilt }
      ]
    }
  }

  // --- the device -------------------------------------------------------------
  Item {
    id: device
    x: stage.margin; y: stage.margin
    width: stage.width - 2 * stage.margin
    height: stage.height - 2 * stage.margin
    // Cached while it leans so the tilt is one textured quad; live content
    // inside still updates the layer when it changes.
    layer.enabled: Math.abs(stage.tx) + Math.abs(stage.ty) > 0.002
    layer.smooth: true
    layer.samples: 4
    transform: [
      Rotation { origin.x: device.width / 2; origin.y: device.height / 2
                 axis { x: 0; y: 1; z: 0 } angle: stage.tx * stage.maxTilt },
      Rotation { origin.x: device.width / 2; origin.y: device.height / 2
                 axis { x: 1; y: 0; z: 0 } angle: -stage.ty * stage.maxTilt }
    ]
  }
}
