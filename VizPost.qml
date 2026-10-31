import QtQuick

// Everything a visualizer goes through after its own shader, as its layer
// effect (Viz.qml sets `layer.effect`; `source` is the style's fresh frame):
//
//   source ─┬─────────────────────────────── fresh ─┬─ fbFx ⟲ (feedback buffer)
//   old ────┴ transFx (only while switching style) ─┘     │
//                                                   fresh + trails ─ showFx + drop fx ─ Bloom
//
// Each pass is a ShaderEffect drawn only into its own texture (hideSource),
// like Bloom.qml and the history target. Passes that are not needed right now
// are hidden and not live, so they cost nothing: with feedback off and no
// transition running this is exactly the old bloom-only path.
//
// The drop effects (colour split, lens push and shockwave, kick vignette,
// grain) are folded into showFx: no pass of their own. With trails on (the
// default) they only switch a branch in it; otherwise showFx comes on just for
// a build or a drop's tail and goes again after, its texture kept allocated
// while the setting is on so that costs no reallocation.
Item {
  id: post

  property var source: null
  property size sourceSize: Qt.size(width, height)

  // ---- transition --------------------------------------------------------
  property bool transitioning: false
  property var oldSource: null
  property real tprog: 0
  property int tkind: 0
  property real tseed: 0

  // ---- feedback ------------------------------------------------------------
  property bool feedbackOn: false
  property real fbScale: 0.75          // feedback buffer size, as a fraction of the source's
  property real gain: 0.6              // how strongly the trails show
  property vector4d warpA: Qt.vector4d(1, 0, 0, 0)
  property vector4d warpB: Qt.vector4d(0, 0, 0.85, 0)
  property vector4d warpC: Qt.vector4d(0.5, 0.5, 0, 0)
  property real time: 0

  // ---- bloom ---------------------------------------------------------------
  property bool bloomOn: false
  property real intensity: 0.6
  property real kick: 0
  property real swell: 0
  property int quality: 2

  property color c1: "white"
  property color c2: "white"
  property color c3: "white"
  property real light: 0

  // ---- drop effects (the director's structure, see _common.glsl) ----------------
  property bool dropFx: false
  property real drop: 0
  property real build: 0
  property real downbeat: 0
  property real beatPhase: 0
  property real snap: 0

  // Live from a build's first tension to the end of a drop's tail (~8 s). The
  // envelopes are floored at those thresholds so nothing pops on or off.
  readonly property bool dropLive: dropFx && (drop > 0.006 || build > 0.02)
  readonly property real dropK: dropLive ? Math.max(0, drop - 0.006) / 0.994 : 0
  readonly property real buildK: dropLive ? Math.max(0, build - 0.02) / 0.98 : 0

  readonly property bool needShow: feedbackOn || transitioning || dropLive

  // ---- 1. transition: old and new style blended ------------------------------
  ShaderEffect {
    id: transFx
    width: post.width; height: post.height
    blending: false
    visible: post.transitioning
    property var a: post.oldSource
    property var b: post.source
    property vector2d res: Qt.vector2d(post.width, post.height)
    property real prog: post.tprog
    property real kind: post.tkind
    property real seed: post.tseed
    property real light: post.light
    property color c1: post.c1
    property color c2: post.c2
    property color c3: post.c3
    fragmentShader: Qt.resolvedUrl("shaders/trans.frag.qsb")
  }
  ShaderEffectSource { id: transSrc; sourceItem: transFx; hideSource: true; smooth: true; live: post.transitioning
                       textureSize: post.sourceSize; format: ShaderEffectSource.RGBA16F }

  readonly property var fresh: transitioning ? transSrc : source

  // ---- 2. feedback: last composite, warped and decayed, under this frame -------
  // `amount` holds at 0 for the first frames after switching on, so the buffer
  // starts from this frame instead of whatever the texture held.
  property real amount: 0
  onFeedbackOnChanged: { amount = 0; if (feedbackOn) warmup.restart() }
  Timer { id: warmup; interval: 50; onTriggered: post.amount = 1 }
  Component.onCompleted: if (feedbackOn) warmup.restart()

  ShaderEffect {
    id: fbFx
    width: post.width; height: post.height
    blending: false
    visible: post.feedbackOn
    property var prev: fbSrc
    property var fresh: post.fresh
    property vector2d res: Qt.vector2d(post.width, post.height)
    property vector4d warpA: post.warpA
    property vector4d warpB: post.warpB
    property vector4d warpC: post.warpC
    property color c1: post.c1
    property color c2: post.c2
    property color c3: post.c3
    property real time: post.time
    property real amount: post.amount
    property real light: post.light
    fragmentShader: Qt.resolvedUrl("shaders/feedback.frag.qsb")
  }
  ShaderEffectSource {
    id: fbSrc
    sourceItem: fbFx
    hideSource: true
    recursive: true
    smooth: true
    live: post.feedbackOn
    // Half float: decays well below 1/255 per frame still reach zero.
    format: ShaderEffectSource.RGBA16F
    textureSize: Qt.size(Math.max(1, Math.round(post.sourceSize.width * post.fbScale)),
                         Math.max(1, Math.round(post.sourceSize.height * post.fbScale)))
  }

  // ---- 3. this frame, crisp, with the trails showing through, and the drop fx --
  ShaderEffect {
    id: showFx
    width: post.width; height: post.height
    visible: post.needShow
    property var fresh: post.fresh
    property var trail: post.feedbackOn ? fbSrc : post.fresh
    property real gain: post.feedbackOn ? post.gain : 0
    property real light: post.light
    property real fxOn: post.dropLive ? 1 : 0
    property vector2d res: Qt.vector2d(post.width, post.height)
    property real time: post.time
    property real drop: post.dropK
    property real build: post.buildK
    property real downbeat: post.downbeat
    property real kick: post.kick
    property real swell: post.swell
    property color c1: post.c1
    property color c2: post.c2
    fragmentShader: Qt.resolvedUrl("shaders/fbshow.frag.qsb")
  }
  // Only needed as a texture when bloom reads it; otherwise showFx draws itself.
  // Kept (not live) while drop fx are on, so a drop does not allocate it.
  ShaderEffectSource { id: showSrc; sourceItem: post.bloomOn && (post.needShow || post.dropFx) ? showFx : null; hideSource: true; smooth: true
                       live: post.bloomOn && post.needShow
                       textureSize: post.sourceSize; format: ShaderEffectSource.RGBA16F }

  // ---- 4. bloom, last, so trails glow but never feed the glow back -------------
  Loader {
    anchors.fill: parent
    active: post.bloomOn
    sourceComponent: Bloom {
      source: post.needShow ? showSrc : post.source
      sourceSize: post.sourceSize
      intensity: post.intensity
      kick: post.kick
      swell: post.swell
      quality: post.quality
    }
  }
  // Without bloom and without the show pass, just draw the frame.
  ShaderEffect {
    anchors.fill: parent
    visible: !post.bloomOn && !post.needShow
    property var source: post.source
  }
}
