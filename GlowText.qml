import QtQuick
import QtQuick.Effects
import qs.Commons

// A Text with a soft halo in the accent, for light that means something: the
// beat, what is playing, what is focused. Never body text, menus or settings.
//
// `glow` is the strength 0..1, already scaled by the bloom budget (Tui.bloom).
// The halo is a zero-offset shadow, so the text draws once plus one small blur.
// The layer only exists while `glowLive`; callers whose glow pulses down to 0
// (the play key on the beat) hold it on instead, so the texture is not torn
// down and rebuilt on every beat.
Text {
  id: t

  property real glow: 0
  property color glowColor: Color.accent
  property int glowRadius: 10            // px; fixed per instance (changing it recompiles the blur)
  property bool glowLive: glow > 0.002

  layer.enabled: visible && glowLive
  layer.effect: MultiEffect {
    autoPaddingEnabled: true
    shadowEnabled: true
    shadowColor: t.glowColor
    shadowOpacity: Math.max(0, Math.min(1, t.glow))
    shadowBlur: 1
    blurMax: t.glowRadius
    shadowHorizontalOffset: 0
    shadowVerticalOffset: 0
  }
}
