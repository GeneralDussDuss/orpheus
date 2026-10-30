import QtQuick
import "VizProfiles.js" as Profiles

// One visualizer surface. Every Orpheus shader shares the same uniforms, so
// switching style only swaps the fragment shader. After the shader, the frame
// goes through VizPost.qml as this item's layer effect: the style-change
// transition, the feedback trails and bloom, in that order.
ShaderEffect {
  id: fx

  property var engine: null
  property string styleName: "skyline"

  readonly property vector4d zero: Qt.vector4d(0, 0, 0, 0)

  // The style on screen: it trails styleName while a change waits for the
  // downbeat (see "style transitions" below).
  property string shownStyle: ""
  fragmentShader: Qt.resolvedUrl("shaders/" + (shownStyle || styleName) + ".frag.qsb")
  blending: true

  // Fraction of full resolution to shade at (the stage's auto quality sets it).
  // Below 1 the effect renders into a smaller layer that is scaled back up, so
  // the fragment cost drops with the square of it. The shaders work in
  // qt_TexCoord0 and `res`, so nothing in them changes.
  property real renderScale: 1
  readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
  readonly property bool postOn: bloomOn || feedbackOn || transitioning
  layer.enabled: renderScale < 0.999 || postOn
  layer.smooth: true
  layer.textureSize: Qt.size(Math.max(1, Math.round(width * dpr * renderScale)),
                             Math.max(1, Math.round(height * dpr * renderScale)))
  // Bloom and feedback read the layer in half float, so light the shaders push
  // past 1.0 still counts as hot instead of being clipped first.
  layer.format: postOn ? ShaderEffectSource.RGBA16F : ShaderEffectSource.RGBA8
  layer.effect: postOn ? postComponent : null

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

  // ---- feedback ---------------------------------------------------------------
  //
  // MilkDrop-style trails: every frame the last composite is warped by the
  // style's own profile (VizProfiles.js), decayed toward transparent, pulled a
  // touch toward the palette, and the new frame laid over it. Before bloom, in
  // a buffer at 3/4 of the shading resolution; auto quality's first step down
  // halves the buffer, its last step turns feedback off.
  property string feedbackLevel: engine && engine.feedback ? engine.feedback : "subtle"   // off | subtle | full
  readonly property bool feedbackOn: feedbackLevel !== "off" && styleName !== "mini"
                                     && renderScale > 0.6 && Math.min(width, height) >= 48
  readonly property real fps: engine && engine.fps ? engine.fps : 60
  // Over a transition the outgoing style's profile blends into the incoming one.
  readonly property var fbProfile: Profiles.warp(
      Profiles.blend(Profiles.of(oldStyle || shownStyle || styleName), Profiles.of(shownStyle || styleName), transitioning ? tprog : 1),
      { kick: kick, swell: swell, snap: snap, flow: flow, time: time, full: feedbackLevel === "full", light: light > 0.5, dt: 60 / fps })

  Component {
    id: postComponent
    VizPost {
      sourceSize: fx.layer.textureSize
      bloomOn: fx.bloomOn
      intensity: fx.bloomIntensity
      kick: fx.kick
      swell: fx.swell
      quality: fx.renderScale > 0.9 ? 2 : 1
      feedbackOn: fx.feedbackOn
      fbScale: fx.renderScale > 0.9 ? 0.75 : 0.5
      gain: fx.fbProfile.gain
      warpA: Qt.vector4d(fx.fbProfile.a[0], fx.fbProfile.a[1], fx.fbProfile.a[2], fx.fbProfile.a[3])
      warpB: Qt.vector4d(fx.fbProfile.b[0], fx.fbProfile.b[1], fx.fbProfile.b[2], fx.fbProfile.b[3])
      warpC: Qt.vector4d(fx.fbProfile.c[0], fx.fbProfile.c[1], fx.fbProfile.c[2], fx.fbProfile.c[3])
      time: fx.time
      transitioning: fx.transitioning
      oldSource: oldSrc
      tprog: fx.tprog
      tkind: fx.tkind
      tseed: fx.tseed
      c1: fx.c1
      c2: fx.c2
      c3: fx.c3
      light: fx.light
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
  function usesHistory(s) { return s === "prism" || s === "horizon" || s === "scope" || s === "skyline" }
  readonly property bool wantsHistory: usesHistory(shownStyle || styleName) || (transitioning && usesHistory(oldStyle))
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

  // ---- album art --------------------------------------------------------------
  //
  // The current cover as the sampler `art` (512 px, mipmapped so a style can
  // read it blurred, or as one average colour). A new cover crossfades in over
  // the old one; alpha is 0 where there is no cover (nothing playing, not
  // loaded yet, or `albumArt` off), and every style falls back to its own look
  // there.
  readonly property bool artOn: !!engine && engine.albumArt !== false && styleName !== "mini"
  readonly property string artUrl: {
    if (!artOn) return ""
    var p = engine.player, t = engine.api ? engine.api.track : null
    return (p && p.trackArtUrl) ? String(p.trackArtUrl) : (t && t.art ? String(t.art) : "")
  }
  property int artFront: 0
  property real artMix: 1
  property var art: artSrc
  readonly property var artImgs: [artImg0, artImg1]
  onArtUrlChanged: loadArt()
  function loadArt() {
    var front = artImgs[artFront], back = artImgs[1 - artFront]
    if (artUrl === "") {
      if (String(front.source) !== "") { back.source = ""; showArt() }
      return
    }
    if (String(front.source) === artUrl) return
    back.source = artUrl
    if (back.status === Image.Ready) showArt()
  }
  function artReady(img) { if (img === artImgs[1 - artFront] && String(img.source) === artUrl) showArt() }
  function showArt() {
    artFront = 1 - artFront
    artFade.restart()
  }
  NumberAnimation { id: artFade; target: fx; property: "artMix"; from: 0; to: 1; duration: 900; easing.type: Easing.InOutSine }
  Image { id: artImg0; visible: false; asynchronous: true; cache: true; smooth: true; sourceSize: Qt.size(512, 512)
          onStatusChanged: if (status === Image.Ready) fx.artReady(artImg0) }
  Image { id: artImg1; visible: false; asynchronous: true; cache: true; smooth: true; sourceSize: Qt.size(512, 512)
          onStatusChanged: if (status === Image.Ready) fx.artReady(artImg1) }
  ShaderEffect {
    id: artFx
    width: 512; height: 512
    blending: false
    visible: fx.artOn
    readonly property var cur: fx.artImgs[fx.artFront]
    readonly property var old: fx.artImgs[1 - fx.artFront]
    property var artCur: cur
    property var artPrev: old
    property real artMix: fx.artMix
    property real curOk: fx.artOn && cur.status === Image.Ready && String(cur.source) !== "" ? 1 : 0
    property real prevOk: fx.artOn && old.status === Image.Ready && String(old.source) !== "" ? 1 : 0
    fragmentShader: Qt.resolvedUrl("shaders/artmix.frag.qsb")
  }
  ShaderEffectSource {
    id: artSrc
    sourceItem: artFx
    hideSource: true
    live: fx.artOn
    smooth: true
    mipmap: true
    format: ShaderEffectSource.RGBA8
    textureSize: Qt.size(512, 512)
  }

  // ---- style transitions ------------------------------------------------------
  //
  // A new style (picked, palette, autoStyle) waits for the next downbeat when
  // the director has a confident beat grid (at most ~2.5 s), then both styles
  // render for two beats (0.8-1.5 s) and trans.frag blends them: glitch
  // slices, a zoom through, a radial dissolve or a chroma split, chosen by the
  // style being entered. oldFx renders only for that time.
  property string oldStyle: ""
  property string pendingStyle: ""
  property bool transitioning: false
  property real tprog: 0
  property int tkind: 0
  property real tseed: 0
  property real lastBar: 0
  readonly property var kinds: ({ prism: 0, skyline: 0, horizon: 3, orb: 2, tunnel: 1, halo: 2, scope: 3, nova: 1 })

  Component.onCompleted: { shownStyle = styleName; loadArt() }
  onStyleNameChanged: requestStyle()
  function requestStyle() {
    if (shownStyle === "") return
    if (styleName === "mini" || shownStyle === "mini" || !visible || Math.min(width, height) < 48) {
      endTransition(); downbeatWait.stop(); pendingStyle = ""; shownStyle = styleName; return
    }
    if (styleName === shownStyle) { downbeatWait.stop(); pendingStyle = ""; return }
    pendingStyle = styleName
    // Just past a downbeat already (a drop switches style the instant it is
    // heard, ~0.1 bar after the downbeat it re-anchored): go now, not a bar later.
    if (beatConfidence > 0.35 && barPhase > 0.12) downbeatWait.restart()
    else beginTransition()
  }
  // The director's barPhase wraps back to 0 on the downbeat.
  onBarPhaseChanged: {
    if (pendingStyle !== "" && downbeatWait.running && barPhase < lastBar - 0.5) beginTransition()
    lastBar = barPhase
  }
  Timer { id: downbeatWait; interval: 2500; onTriggered: fx.beginTransition() }

  function beginTransition() {
    downbeatWait.stop()
    if (pendingStyle === "" || pendingStyle === shownStyle) { pendingStyle = ""; return }
    endTransition()
    oldStyle = shownStyle
    shownStyle = pendingStyle
    pendingStyle = ""
    tkind = kinds[shownStyle] !== undefined ? kinds[shownStyle] : Math.floor(Math.random() * 4)
    tseed = Math.floor(Math.random() * 1000)
    tprog = 0
    transAnim.duration = Math.round(1000 * Math.max(0.8, Math.min(1.5, 1 / Math.max(0.3, tempo))))
    transitioning = true
    transAnim.restart()
  }
  function endTransition() {
    transAnim.stop()
    transitioning = false
    oldStyle = ""
    tprog = 0
  }
  NumberAnimation { id: transAnim; target: fx; property: "tprog"; from: 0; to: 1; easing.type: Easing.InOutSine
                    onFinished: fx.endTransition() }

  // The outgoing style, live, for the length of the transition. Same uniforms
  // as fx, bound one by one (a ShaderEffect only sees its own properties):
  // a uniform added to fx should be added here too.
  ShaderEffect {
    id: oldFx
    width: fx.width; height: fx.height
    visible: fx.transitioning && fx.oldStyle !== ""
    blending: true
    fragmentShader: fx.oldStyle !== "" ? Qt.resolvedUrl("shaders/" + fx.oldStyle + ".frag.qsb") : ""
    property var hist: fx.hist
    property var art: fx.art
    property real time: fx.time
    property vector2d res: fx.res
    property vector4d b0: fx.b0
    property vector4d b1: fx.b1
    property vector4d b2: fx.b2
    property vector4d b3: fx.b3
    property vector4d b4: fx.b4
    property vector4d b5: fx.b5
    property vector4d b6: fx.b6
    property vector4d b7: fx.b7
    property vector4d p0: fx.p0
    property vector4d p1: fx.p1
    property vector4d p2: fx.p2
    property vector4d p3: fx.p3
    property vector4d p4: fx.p4
    property vector4d p5: fx.p5
    property vector4d p6: fx.p6
    property vector4d p7: fx.p7
    property color c1: fx.c1
    property color c2: fx.c2
    property color c3: fx.c3
    property color bg: fx.bg
    property color fg: fx.fg
    property real bass: fx.bass
    property real energy: fx.energy
    property real light: fx.light
    property real beat: fx.beat
    property real flow: fx.flow
    property real tempo: fx.tempo
    property real kick: fx.kick
    property real snap: fx.snap
    property real swell: fx.swell
    property real kicks: fx.kicks
    property vector4d kickAge: fx.kickAge
    property real bloomAmt: fx.bloomAmt
    property real beatPhase: fx.beatPhase
    property real barPhase: fx.barPhase
    property real downbeat: fx.downbeat
    property real beatConfidence: fx.beatConfidence
    property real build: fx.build
    property real drop: fx.drop
    property real section: fx.section
  }
  ShaderEffectSource {
    id: oldSrc
    sourceItem: oldFx
    hideSource: true
    live: fx.transitioning
    smooth: true
    format: ShaderEffectSource.RGBA16F
    textureSize: fx.layer.textureSize
  }
}
