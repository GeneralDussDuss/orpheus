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

  // Spectrum history for Prism, Horizon and Scope, kept on the GPU: histFx renders a 32x40 target
  // from its own previous frame (rows shift back one step, row 0 = now).
  readonly property bool wantsHistory: styleName === "prism" || styleName === "horizon" || styleName === "scope"
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
