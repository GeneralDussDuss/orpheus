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
  // A user style ("@name", orpheusd/shaders.py) lives wherever the daemon built
  // it; a rebuild changes the URL (content hash) with styleName unchanged, so
  // Qt loads the new package in place, no transition: the live-edit feel. The
  // fallback keeps engines without styleUrl (dev tools' fakes) working.
  fragmentShader: engine && engine.styleUrl ? engine.styleUrl(shownStyle || styleName)
                                            : Qt.resolvedUrl("shaders/" + (shownStyle || styleName) + ".frag.qsb")
  blending: true

  // What the daemon knows about a user style (uses, scale, transition); null for builtins.
  readonly property var userMeta: engine && engine.userStyle ? engine.userStyle(shownStyle || styleName) : null
  readonly property var oldMeta: engine && engine.userStyle && transitioning ? engine.userStyle(oldStyle) : null
  function uses(m, w) { return !!m && !!m.uses && m.uses.indexOf(w) >= 0 }
  // qsb can't see a D3D11/GL-side failure; the item would keep its previous
  // material and show the old picture with no word. Say so instead.
  onStatusChanged: if (status === ShaderEffect.Error && engine && engine.isUserStyle && engine.reportShaderRuntime
                       && engine.isUserStyle(shownStyle || styleName)) engine.reportShaderRuntime(shownStyle || styleName, log)

  // Fraction of full resolution to shade at (the stage's auto quality sets it).
  // Below 1 the effect renders into a smaller layer that is scaled back up, so
  // the fragment cost drops with the square of it. The shaders work in
  // qt_TexCoord0 and `res`, so nothing in them changes.
  property real renderScale: 1
  readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
  // A user style shades at its own scale on top of that (0.8 unless its
  // `//! scale:` says otherwise): Shadertoy shaders commonly cost 5-20x an
  // Orpheus style. Bloom and trails still key off renderScale alone.
  readonly property real userScale: userMeta && userMeta.scale > 0 ? userMeta.scale : 1
  readonly property real effScale: renderScale * userScale
  // Drop effects ride in VizPost too, so with them on the chain stays built even
  // with bloom and trails off (no layer toggle, and so no hitch, on the drop).
  readonly property bool dropFxOn: !!engine && engine.dropFx === true && styleName !== "mini" && Math.min(width, height) >= 48
  readonly property bool postOn: bloomOn || feedbackOn || transitioning || dropFxOn
  layer.enabled: effScale < 0.999 || postOn
  layer.smooth: true
  layer.textureSize: Qt.size(Math.max(1, Math.round(width * dpr * effScale)),
                             Math.max(1, Math.round(height * dpr * effScale)))
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
      dropFx: !!fx.engine && fx.engine.dropFx === true && fx.styleName !== "mini"
      drop: fx.drop
      build: fx.build
      downbeat: fx.downbeat
      beatPhase: fx.beatPhase
      snap: fx.snap
      anticipate: fx.anticipate
      mapped: fx.mapped
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
  property real anticipate: engine ? (engine.anticipate || 0) : 0   // drop map wind-up (fbshow, via VizPost)
  property real mapped: engine ? (engine.dropMapped || 0) : 0
  // Shadertoy imports (orpheusd/shaders.py): iMouse, iFrame, iTimeDelta. Builtins ignore them.
  // The mouse is in item pixels, bottom-up, like `res` and fragCoord; the click
  // (zw) stays 0, since a click on the stage already switches style.
  property vector4d mouse: hov.hovered && uses(userMeta, "iMouse")
                           ? Qt.vector4d(hov.point.position.x, height - hov.point.position.y, 0, 0) : zero
  property real frame: 0
  onTimeChanged: if (userMeta || oldMeta) frame = (frame + 1) % 16777216   // builtins never read it
  property real dt: 1 / Math.max(10, fps)
  // passive, and only on for a style that reads iMouse: the stage's MouseAreas still get every click
  HoverHandler { id: hov; enabled: fx.uses(fx.userMeta, "iMouse") }

  // ---- Shadertoy channels -------------------------------------------------------
  //
  // Samplers bind by name: iChannel0/2/3 are a 512x2 audio texture in
  // Shadertoy's layout (row 0 the spectrum, row 1 a wave the bands drive),
  // iChannel1 the spectrum history below. No builtin declares them, so for
  // those the properties are ignored and the audio pass never runs.
  readonly property var audioTex: audioPass.item ? audioPass.item.tex : null
  property var iChannel0: audioTex
  property var iChannel1: histSource
  property var iChannel2: audioTex
  property var iChannel3: audioTex
  function usesAudio(m) { return uses(m, "iChannel0") || uses(m, "iChannel2") || uses(m, "iChannel3") }
  readonly property bool wantsAudio: usesAudio(userMeta) || usesAudio(oldMeta)

  // Built only for a style that samples it: otherwise its eleven bindings would
  // dirty a hidden 512x2 pass every frame on every Viz (stage, rail, widget, mini).
  Loader {
    id: audioPass
    active: fx.wantsAudio
    sourceComponent: Item {
      property alias tex: audioSource
      ShaderEffect {
        id: audioFx
        width: 512
        height: 2
        fragmentShader: Qt.resolvedUrl("shaders/audiotex.frag.qsb")
        property vector4d b0: fx.b0
        property vector4d b1: fx.b1
        property vector4d b2: fx.b2
        property vector4d b3: fx.b3
        property vector4d b4: fx.b4
        property vector4d b5: fx.b5
        property vector4d b6: fx.b6
        property vector4d b7: fx.b7
        property real time: fx.time
        property real energy: fx.energy
        property real kick: fx.kick
      }

      ShaderEffectSource {
        id: audioSource
        sourceItem: audioFx
        hideSource: true
        live: fx.wantsAudio && fx.visible && !!fx.engine && fx.engine.energy > 0.001
        smooth: true
        format: ShaderEffectSource.RGBA8
        textureSize: Qt.size(512, 2)   // fixed, and not recursive: nothing here ever resizes in place
      }
    }
  }

  // Spectrum history for Prism, Horizon, Scope and Skyline, kept on the GPU: histFx renders a 32x40 target
  // from its own previous frame (rows shift back one step, row 0 = now).
  function usesHistory(s) { return s === "prism" || s === "horizon" || s === "scope" || s === "skyline" || s === "ridge" }
  readonly property bool wantsHistory: usesHistory(shownStyle || styleName) || (transitioning && usesHistory(oldStyle))
                                       || uses(userMeta, "iChannel1") || uses(oldMeta, "iChannel1")
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

  // Ridge draws each history row as its own line, so it wants seconds of song,
  // not frames: its history steps at a fixed rate (40 rows at 30 Hz = 1.3 s,
  // the same at any fps). The others shift every frame, as they were tuned.
  readonly property int histHz: (shownStyle || styleName) === "ridge" ? 30 : 0
  Timer {
    interval: fx.histHz > 0 ? Math.round(1000 / fx.histHz) : 1000
    repeat: true
    running: fx.histHz > 0 && fx.wantsHistory && fx.visible && !!fx.engine && fx.engine.energy > 0.001
    onTriggered: histSource.scheduleUpdate()
  }

  ShaderEffectSource {
    id: histSource
    sourceItem: histFx
    hideSource: true
    recursive: true
    // Only advance while there's sound to remember; otherwise hold still.
    live: fx.wantsHistory && fx.histHz === 0 && !!fx.engine && fx.engine.energy > 0.001
    smooth: true   // linear filtering: ridges and rows interpolate instead of stair-stepping
    format: ShaderEffectSource.RGBA8
    textureSize: Qt.size(32, 40)
  }

  // ---- ink: the water ---------------------------------------------------------
  //
  // Ink's dye lives in a persistent half-float buffer at ~0.4 of the view
  // (capped at 1280 wide), advected every frame by inkstate.frag along an
  // analytic curl-noise flow and fed by the music; ink.frag then shades it.
  // Like the history it renders from its own previous frame, and only while
  // ink is on screen (or leaving it in a transition). Each time it goes live
  // the water is cleared for a few frames, then the emitters let out a cloud.
  readonly property bool wantsInk: (shownStyle || styleName) === "ink" || (transitioning && oldStyle === "ink")
  property var inkState: inkLoader.item ? inkLoader.item.src : null
  readonly property real inkScale: Math.min(0.4, 1280 / Math.max(1, width * dpr))
  property real inkFresh: 1
  property real inkIntro: 0
  // Checked a beat later: starting a transition flips wantsInk off and on
  // again within one update, and that must not wipe the water.
  property bool inkWasLive: false
  onWantsInkChanged: Qt.callLater(inkWake)
  function inkWake() {
    if (wantsInk && !inkWasLive) { inkFresh = 1; inkIntroAnim.stop(); inkWarm.restart() }
    inkWasLive = wantsInk
  }
  Timer { id: inkWarm; interval: 60; onTriggered: { fx.inkFresh = 0; inkIntroAnim.restart() } }
  NumberAnimation { id: inkIntroAnim; target: fx; property: "inkIntro"; from: 1; to: 0; duration: 1400; easing.type: Easing.OutQuad }

  // A recursive source must never change size in place (Qt swaps its texture
  // out from under the bound shader and the NVIDIA driver crashes on it; see
  // VizPost.qml's feedback buffer). The water follows the view's size, so a
  // resize tears it down and builds it fresh once the size holds still.
  readonly property size inkWant: Qt.size(Math.max(16, Math.round(width * dpr * inkScale)),
                                          Math.max(16, Math.round(height * dpr * inkScale)))
  property size inkSize
  property bool inkReady: false
  onInkWantChanged: {
    if (!inkReady && !inkRebuild.running) return   // not built yet: Component.onCompleted does it
    if (inkWant.width === inkSize.width && inkWant.height === inkSize.height) return
    inkReady = false
    inkRebuild.restart()
  }
  Timer { id: inkRebuild; interval: 150; onTriggered: { fx.inkSize = fx.inkWant; fx.inkReady = true } }

  Loader {
    id: inkLoader
    active: fx.inkReady
    // fresh texture, so fresh water
    onLoaded: { fx.inkWasLive = false; fx.inkWake() }
    sourceComponent: Item {
      readonly property alias src: inkSource
      ShaderEffect {
        id: inkFx
        width: fx.inkSize.width
        height: fx.inkSize.height
        fragmentShader: Qt.resolvedUrl("shaders/inkstate.frag.qsb")
        property var prev: inkSource
        property real time: fx.time
        property real asp: fx.width / Math.max(1, fx.height)
        property real dt: 1 / Math.max(10, fx.fps)
        property vector2d texel: Qt.vector2d(1 / fx.inkSize.width, 1 / fx.inkSize.height)
        property color c1: fx.c1
        property color c2: fx.c2
        property color c3: fx.c3
        property real bass: fx.bass
        property real energy: fx.energy
        property real swell: fx.swell
        property real snap: fx.snap
        property real build: fx.build
        property real drop: fx.drop
        property real kicks: fx.kicks
        property vector4d kickAge: fx.kickAge
        property real fresh: fx.inkFresh
        property real intro: fx.inkIntro
      }

      ShaderEffectSource {
        id: inkSource
        sourceItem: inkFx
        hideSource: true
        recursive: true
        live: fx.wantsInk
        smooth: true
        format: ShaderEffectSource.RGBA16F
        // set once: a resize rebuilds the whole Loader (see inkWant)
        Component.onCompleted: textureSize = fx.inkSize
      }
    }
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
  readonly property var kinds: ({ prism: 0, skyline: 0, horizon: 3, orb: 2, tunnel: 1, halo: 2, scope: 3, nova: 1, ridge: 0, ink: 4, abyss: 1, aurora: 4 })

  Component.onCompleted: { shownStyle = styleName; inkSize = inkWant; inkReady = true; inkWake() }
  onStyleNameChanged: requestStyle()
  function requestStyle() {
    if (shownStyle === "") return
    if (styleName === "mini" || shownStyle === "mini" || !visible || Math.min(width, height) < 48) {
      endTransition(); downbeatWait.stop(); pendingStyle = ""; shownStyle = styleName; return
    }
    if (styleName === shownStyle) { downbeatWait.stop(); pendingStyle = ""; return }
    pendingStyle = styleName
    // A mapped drop is on its way (Stage pre-arms 1.5 s ahead): stretch the
    // transition so it completes on the drop frame itself.
    if (engine && engine.mapLocked && engine.dropIn > 0.3 && engine.dropIn < 3) { beginTransition(Math.round(1000 * engine.dropIn)); return }
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

  function beginTransition(durationMs) {
    downbeatWait.stop()
    if (pendingStyle === "" || pendingStyle === shownStyle) { pendingStyle = ""; return }
    endTransition()
    oldStyle = shownStyle
    shownStyle = pendingStyle
    pendingStyle = ""
    // A user style may name its own way in (`//! transition:`); otherwise a random one.
    var um = engine && engine.userStyle ? engine.userStyle(shownStyle) : null
    tkind = kinds[shownStyle] !== undefined ? kinds[shownStyle]
          : (um && um.transition >= 0 ? um.transition : Math.floor(Math.random() * 4))
    tseed = Math.floor(Math.random() * 1000)
    tprog = 0
    transAnim.duration = durationMs > 0 ? durationMs : Math.round(1000 * Math.max(0.8, Math.min(1.5, 1 / Math.max(0.3, tempo))))
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
    fragmentShader: fx.oldStyle === "" ? ""
                    : fx.engine && fx.engine.styleUrl ? fx.engine.styleUrl(fx.oldStyle)
                    : Qt.resolvedUrl("shaders/" + fx.oldStyle + ".frag.qsb")
    property var hist: fx.hist
    property var inkState: fx.inkState
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
    property real anticipate: fx.anticipate
    property real mapped: fx.mapped
    property vector4d mouse: fx.mouse
    property real frame: fx.frame
    property real dt: fx.dt
    property var iChannel0: fx.iChannel0
    property var iChannel1: fx.iChannel1
    property var iChannel2: fx.iChannel2
    property var iChannel3: fx.iChannel3
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
