import QtQuick

// One visualizer surface. Every Orpheus shader shares the same uniforms, so
// switching style only swaps the fragment shader.
ShaderEffect {
  id: fx

  property var engine: null
  property string styleName: "skyline"

  readonly property vector4d zero: Qt.vector4d(0, 0, 0, 0)

  fragmentShader: Qt.resolvedUrl("shaders/" + styleName + ".frag.qsb")
  blending: true

  // Fraction of full resolution to shade at (the stage's auto quality sets it).
  // Below 1 the effect renders into a smaller layer that is scaled back up, so
  // the fragment cost drops with the square of it. The shaders work in
  // qt_TexCoord0 and `res`, so nothing in them changes.
  property real renderScale: 1
  readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
  layer.enabled: renderScale < 0.999 || bloomOn
  layer.smooth: true
  layer.textureSize: Qt.size(Math.max(1, Math.round(width * dpr * renderScale)),
                             Math.max(1, Math.round(height * dpr * renderScale)))
  // Bloom reads the layer in half float, so light the shaders push past 1.0
  // still counts as hot instead of being clipped first.
  layer.format: bloomOn ? ShaderEffectSource.RGBA16F : ShaderEffectSource.RGBA8
  layer.effect: bloomOn ? bloomComponent : null

  // ---- bloom ------------------------------------------------------------------
  //
  // Real post-process glow (Bloom.qml) over every style: off on light themes
  // (glow reads as smudge there, same as lit()), and off for the tiny bar viz.
  // Auto quality makes it cheaper before the shader itself loses resolution:
  // at the first step down the blur starts from 1/8 res over two levels, and
  // at the last step it is skipped.
  property string bloomLevel: engine && engine.bloom ? engine.bloom : "subtle"   // off | subtle | full
  readonly property bool bloomOn: bloomLevel !== "off" && light < 0.5 && styleName !== "mini"
                                  && renderScale > 0.6 && Math.min(width, height) >= 48
  readonly property real bloomIntensity: bloomLevel === "full" ? 1.0 : 0.6
  Component {
    id: bloomComponent
    Bloom {
      sourceSize: fx.layer.textureSize
      intensity: fx.bloomIntensity
      kick: fx.kick
      swell: fx.swell
      quality: fx.renderScale > 0.9 ? 2 : 1
    }
  }

  property real time: engine ? engine.time : 0
  property vector2d res: Qt.vector2d(width, height)

  property vector4d b0: engine ? engine.b0 : zero
  property vector4d b1: engine ? engine.b1 : zero
  property vector4d b2: engine ? engine.b2 : zero
  property vector4d b3: engine ? engine.b3 : zero
  property vector4d b4: engine ? engine.b4 : zero
  property vector4d b5: engine ? engine.b5 : zero
  property vector4d b6: engine ? engine.b6 : zero
  property vector4d b7: engine ? engine.b7 : zero
  property vector4d p0: engine ? engine.p0 : zero
  property vector4d p1: engine ? engine.p1 : zero
  property vector4d p2: engine ? engine.p2 : zero
  property vector4d p3: engine ? engine.p3 : zero
  property vector4d p4: engine ? engine.p4 : zero
  property vector4d p5: engine ? engine.p5 : zero
  property vector4d p6: engine ? engine.p6 : zero
  property vector4d p7: engine ? engine.p7 : zero

  property color c1: engine ? engine.c1 : "white"
  property color c2: engine ? engine.c2 : "white"
  property color c3: engine ? engine.c3 : "white"
  property color bg: engine ? engine.bg : "black"
  property color fg: engine ? engine.fg : "white"
  property real bass: engine ? engine.bass : 0
  property real energy: engine ? engine.energy : 0
  property real light: engine && engine.lightTheme ? 1 : 0
  property real beat: engine ? engine.beat : 0
  property real flow: engine ? engine.travel : 0
  // Added later; shaders that don't declare these simply ignore them.
  property real tempo: engine ? engine.paceBpm / 120 : 1
  property real kick: engine ? engine.kick : 0
  property real snap: engine ? engine.snap : 0
  property real swell: engine ? engine.swell : 0
  property real kicks: engine ? engine.kicks : 0
  property vector4d kickAge: engine ? engine.kickAge : Qt.vector4d(8, 8, 8, 0)
  // How much real bloom sits over this view: the shaders dial their own halos down by it.
  property real bloomAmt: bloomOn ? bloomIntensity : 0
  // The director's beat grid and song structure (see _common.glsl). Defaults
  // read as "no grid, no structure": phase 0, nothing confident, steady.
  property real beatPhase: engine ? engine.beatPhase : 0
  property real barPhase: engine ? engine.barPhase : 0
  property real downbeat: engine ? engine.downbeat : 0
  property real beatConfidence: engine ? engine.beatConfidence : 0
  property real build: engine ? engine.build : 0
  property real drop: engine ? engine.drop : 0
  property real section: engine ? engine.sectionCode : 4

  // Spectrum history for Prism, Horizon, Scope and Skyline, kept on the GPU: histFx renders a 32x40 target
  // from its own previous frame (rows shift back one step, row 0 = now).
  readonly property bool wantsHistory: styleName === "prism" || styleName === "horizon" || styleName === "scope"
                                      || styleName === "skyline"
  property var hist: histSource

  ShaderEffect {
    id: histFx
    width: 32
    height: 40
    fragmentShader: Qt.resolvedUrl("shaders/history.frag.qsb")
    property var prev: histSource
    property vector4d b0: fx.b0
    property vector4d b1: fx.b1
    property vector4d b2: fx.b2
    property vector4d b3: fx.b3
    property vector4d b4: fx.b4
    property vector4d b5: fx.b5
    property vector4d b6: fx.b6
    property vector4d b7: fx.b7
    property real rows: 40
  }

  ShaderEffectSource {
    id: histSource
    sourceItem: histFx
    hideSource: true
    recursive: true
    // Only advance while there's sound to remember; otherwise hold still.
    live: fx.wantsHistory && !!fx.engine && fx.engine.energy > 0.001
    smooth: true   // linear filtering: ridges and rows interpolate instead of stair-stepping
    format: ShaderEffectSource.RGBA8
    textureSize: Qt.size(32, 40)
  }
}
