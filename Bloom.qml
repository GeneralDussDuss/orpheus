import QtQuick

// Post-process bloom for a layered item: use it as `layer.effect`, or set
// `source` to any texture provider and size it like the source.
//
//   source ─ bright pass (soft knee, 1/div res, 4x4 box) ─ d0
//   d0 ─ Kawase down ─ d1 ─ Kawase down ─ d2            (half res each)
//   d2 ─ tent up + d1 ─ u1 ─ tent up + d0 ─ u0
//   source + u0 · strength, screen blended ─ out
//
// Everything but the last pass runs at 1/div of the item's pixels or less, so
// the cost is one extra full-res pass of five taps. Strength breathes with the
// music: `swell` (loudness) raises it, `kick` flares it, quiet stays crisp.
Item {
  id: bloom

  property var source: null
  // The source texture's size in pixels (for texel offsets); defaults to the item's.
  property size sourceSize: Qt.size(width * dpr, height * dpr)
  readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1

  property real intensity: 0.6     // subtle ~0.6, full 1.0
  property real kick: 0
  property real swell: 0
  // 2: blur from 1/4 res over three levels, smoothed upsample.
  // 1: from 1/8 res over two levels, single-tap upsample (auto quality's first step down).
  property int quality: 2

  readonly property int div: quality >= 2 ? 4 : 8
  readonly property real strength: intensity * (1.0 + 1.5 * swell + 1.1 * kick)
  readonly property real threshold: 0.48 - 0.12 * swell - 0.05 * kick
  readonly property real knee: 0.22

  function px(d) {
    return Qt.size(Math.max(1, Math.round(width * dpr / d)), Math.max(1, Math.round(height * dpr / d)))
  }
  readonly property size s0: px(div)
  readonly property size s1: px(div * 2)
  readonly property size s2: px(div * 4)

  // ---- passes ---------------------------------------------------------------
  // Each pass is a ShaderEffect drawn only into its own small texture
  // (hideSource), the same pattern as the visualizer's history target.

  ShaderEffect {
    id: brightFx
    width: bloom.width; height: bloom.height
    blending: false
    property var source: bloom.source
    property vector2d texel: Qt.vector2d(1 / Math.max(1, bloom.sourceSize.width), 1 / Math.max(1, bloom.sourceSize.height))
    property real threshold: bloom.threshold
    property real knee: bloom.knee
    fragmentShader: Qt.resolvedUrl("shaders/bloom_bright.frag.qsb")
  }
  ShaderEffectSource { id: d0; sourceItem: brightFx; hideSource: true; smooth: true; textureSize: bloom.s0; format: ShaderEffectSource.RGBA16F }

  ShaderEffect {
    id: down1
    width: bloom.width; height: bloom.height
    blending: false
    property var source: d0
    property vector2d texel: Qt.vector2d(1 / bloom.s0.width, 1 / bloom.s0.height)
    fragmentShader: Qt.resolvedUrl("shaders/bloom_down.frag.qsb")
  }
  ShaderEffectSource { id: d1; sourceItem: down1; hideSource: true; smooth: true; textureSize: bloom.s1; format: ShaderEffectSource.RGBA16F }

  ShaderEffect {
    id: down2
    width: bloom.width; height: bloom.height
    blending: false
    visible: bloom.quality >= 2
    property var source: d1
    property vector2d texel: Qt.vector2d(1 / bloom.s1.width, 1 / bloom.s1.height)
    fragmentShader: Qt.resolvedUrl("shaders/bloom_down.frag.qsb")
  }
  ShaderEffectSource { id: d2; sourceItem: down2; hideSource: true; smooth: true; textureSize: bloom.s2; format: ShaderEffectSource.RGBA16F
                       live: bloom.quality >= 2 }

  ShaderEffect {
    id: up1
    width: bloom.width; height: bloom.height
    blending: false
    visible: bloom.quality >= 2
    property var low: d2
    property var here: d1
    property vector2d texel: Qt.vector2d(1 / bloom.s2.width, 1 / bloom.s2.height)
    property real keep: 0.45
    fragmentShader: Qt.resolvedUrl("shaders/bloom_up.frag.qsb")
  }
  ShaderEffectSource { id: u1; sourceItem: up1; hideSource: true; smooth: true; textureSize: bloom.s1; format: ShaderEffectSource.RGBA16F
                       live: bloom.quality >= 2 }

  ShaderEffect {
    id: up0
    width: bloom.width; height: bloom.height
    blending: false
    property var low: bloom.quality >= 2 ? u1 : d1
    property var here: d0
    property vector2d texel: Qt.vector2d(1 / bloom.s1.width, 1 / bloom.s1.height)   // u1 and d1 are both s1
    property real keep: 0.40
    fragmentShader: Qt.resolvedUrl("shaders/bloom_up.frag.qsb")
  }
  ShaderEffectSource { id: u0; sourceItem: up0; hideSource: true; smooth: true; textureSize: bloom.s0; format: ShaderEffectSource.RGBA16F }

  // ---- composite ---------------------------------------------------------------
  ShaderEffect {
    anchors.fill: parent
    property var source: bloom.source
    property var glowTex: u0
    property vector2d texel: Qt.vector2d(1 / bloom.s0.width, 1 / bloom.s0.height)
    property real strength: bloom.strength
    property real taps: bloom.quality >= 2 ? 4 : 1
    fragmentShader: Qt.resolvedUrl("shaders/bloom_mix.frag.qsb")
  }
}
