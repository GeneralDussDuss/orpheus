YOUR SHADERS  ·  orpheus
========================

Every .frag file in this folder is a visualizer style. Save one here and it
compiles within a second or two and joins the style list as @<file name>
(stage tabs, digit keys, Ctrl+K, settings, the player's plane, the widget).
Edit it while it is on screen: each save rebuilds it in place. A broken save
keeps the last good picture drawing and tells you the line.

Other ways in: paste a shadertoy.com link, or an Image shader's code, into
Ctrl+K (or settings > visuals > your shaders > import from clipboard), or drop
a .frag onto the visualizer card. Delete a file to remove its style.
Files starting with "_" or "." are ignored.

WRITE IT THE SHADERTOY WAY
  void mainImage(out vec4 fragColor, in vec2 fragCoord) { ... }
  Put a Common tab above the Image tab, in one file.
  iTime  iTimeDelta  iFrame  iFrameRate  iResolution  iMouse (xy, while hovered)
  iChannel0   audio, 512x2: row y<0.5 the spectrum, y>0.5 a wave (centred on 0.5)
              Orpheus gets 32 bands and no samples: the spectrum is real, the
              wave is synthesised from the bands.
  iChannel1   32x40 spectrum history (row 0 = now)
  iChannel2/3 the audio texture again
  iChannelResolution[i]  iChannelTime[i]  iSampleRate   (iDate is always 0)
  Not supported: Buffer A-D, cubemaps, keyboard/video/texture inputs.

EVERYTHING ORPHEUS KNOWS ABOUT THE MUSIC IS IN SCOPE
  time res b0..b7 p0..p7 c1 c2 c3 bg fg bass energy light beat flow tempo
  kick snap swell kicks kickAge bloomAmt beatPhase barPhase downbeat
  beatConfidence build drop section mouse frame dt
  band(x) bandAt(i) peakAt(i) pal(x) hash(p) lit(x) faux(x, k) glow(d, r)
  (shaders/_common.glsl in the app explains each one.)
  These names are taken at global scope. A helper you define yourself with
  the same name as one of the functions (hash, pal, glow...) wins over ours.

PRAGMAS (in the first 40 lines)
  //! name: Neon Rain        the label in the style list
  //! scale: 0.6             render scale 0.25..1 (default 0.8: Shadertoy
                             shaders are often far heavier than Orpheus's own)
  //! time: flow             iTime follows the music's travel instead of the clock
  //! transition: 2          the blend into this style: 0 slices, 1 zoom,
                             2 dissolve, 3 chroma, 4 melt

ORPHEUS-NATIVE
  A file with a line "//#common" is compiled like the app's own styles: that
  line becomes shaders/_common.glsl, and you write main() yourself.

WHEN SOMETHING IS WRONG
  A toast, a tick on the stage, settings > visuals > your shaders, and
  .build/<name>.log (the compiler's own words; .build/<name>.frag is what it
  compiled). A shader that compiles but fails on the GPU says so too.

COMPILER
  Styles need qsb, the Qt Shader Baker. Windows: put qsb.exe and
  Qt6ShaderTools.dll in %LOCALAPPDATA%\Orpheus\tools\qsb (or set ORPHEUS_QSB).
  Linux: install qt6-shadertools. Then "recompile your shaders" in Ctrl+K.

No album art reaches shaders; nothing here ever does.
Shadertoy imports keep their author and link at the top of the file. Shaders on
shadertoy.com are CC BY-NC-SA 3.0 unless their page says otherwise: they are
yours to enjoy here, not to sell.
