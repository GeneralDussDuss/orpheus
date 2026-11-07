#version 440
// Orpheus "Teletype": the stage as a living terminal. The spectrum history
// prints itself as a wall of braille, rastered in the shader: the screen is a
// character grid, every cell is a 2x4 braille dot block, and a cell's dots
// fill from the bottom the way ⣀⣤⣶⣿ fill, so the waterfall IS text. Columns
// are frequencies, rows are time: the newest line prints at the bottom from
// the live bands and history scrolls up and dims into the past. Peak caps
// print as single bright dots that fall slowly (btop's meters). Grey until it
// matters: the body is muted fg, the accent is spent on the live row, the
// peaks and the loudest cells. A kick slams the bottom rows to full blocks,
// the downbeat ticks the frame, and a drop prints one full-width line of ⣿ in
// c3 that rides up with the history. The beat sweeps a faint cursor column.
// A build raises the phosphor glow; breakdowns let the wall decay to sparse
// dots. Light themes are ink on paper: same text, multiplied, no glow.
// Cost: trivial — one history tap and a handful of hashes per pixel.

//#common

layout(binding = 1) uniform sampler2D hist;   // 32 x 40 spectrum history, row 0 = now

const float COLS = 64.0;          // character columns; 2 freq-dot columns each
const float HROWS = 38.0;         // history rows on screen (of the 40 kept)

void main() {
    vec2 px = vec2(qt_TexCoord0.x, 1.0 - qt_TexCoord0.y) * res;
    float dark = 1.0 - light;

    // ---- the character grid: square-ish cells from the width ----
    float cw = res.x / COLS;                   // cell width in px
    float chh = cw * 1.9;                      // a text cell is ~2x taller than wide
    float rows = floor(res.y / chh);
    vec2 cell = floor(px / vec2(cw, chh));     // integer cell coords, y = 0 at bottom
    vec2 inCell = fract(px / vec2(cw, chh));   // 0..1 inside the cell

    // ---- braille dot addressing: 2 columns x 4 rows, with gutters ----
    vec2 dotsGrid = inCell * vec2(2.0, 4.0);
    vec2 dotIdx = floor(dotsGrid);             // dot column 0..1, dot row 0..3 (bottom up)
    vec2 inDot = fract(dotsGrid) - 0.5;
    float dotR = 0.30;                         // dot radius in sub-cell units
    float fwx = fwidth(dotsGrid.x) + 1e-4;
    float dotCov = 1.0 - smoothstep(dotR - fwx, dotR + fwx, length(inDot * vec2(1.0, 1.1)));

    // ---- the field this wall prints: live row + history above it ----
    float u = (cell.x * 2.0 + dotIdx.x + 0.5) / (COLS * 2.0);  // frequency 0..1, per dot column
    float rowUp = cell.y;                                       // rows above the bottom
    float v;
    float liveRow = step(rowUp, 0.5);                           // bottom character row is live
    if (liveRow > 0.5) {
        v = band(u);
    } else {
        float age = clamp((rowUp - 0.0) / HROWS, 0.0, 1.0);
        v = texture(hist, vec2(u, age)).r;
    }
    // Breakdown thins the wall; swell is the master gain so silence sleeps.
    // The bands run quiet (bass peaks ~0.15 on this rig), so lift them
    // perceptually or soft music never earns a dot.
    float sec = floor(section + 0.5);
    float thin = (sec == 3.0) ? 0.72 : 1.0;
    v = pow(clamp(v, 0.0, 1.0), 0.55);
    v = clamp(v * (0.8 + 0.6 * swell) * thin, 0.0, 1.0);

    // ---- braille fill order: dots light from the bottom, left before right ----
    float n = v * 8.0;                                          // dots earned, 0..8
    float ord = (3.0 - dotIdx.y) * 2.0 + dotIdx.x;              // 0 = bottom-left ... 7 = top-right
    float on = clamp(n - ord, 0.0, 1.0);                        // soft edge on the last dot

    // ---- kick: the bottom rows slam to full block ⣿ ----
    float slam = kick * kick * smoothstep(3.0, 0.0, rowUp);
    on = max(on, slam * step(0.05, v));                         // silence never slams

    // ---- drop: one full-width printed line of ⣿ rides up with the history ----
    float dropRow = (1.0 - drop) * HROWS;                       // row the drop line sits on now
    float dl = (drop > 0.001) ? (1.0 - smoothstep(0.0, 1.2, abs(rowUp - dropRow))) * smoothstep(0.0, 0.08, drop) : 0.0;
    on = max(on, dl);

    // ---- peak caps: one bright dot where this column's peak sits ----
    float pk = peakAt(int(clamp(u, 0.0, 0.999) * 32.0));
    float pkN = clamp(pow(clamp(pk, 0.0, 1.0), 0.55) * (0.8 + 0.6 * swell) * thin, 0.0, 1.0) * 8.0;
    float capHere = liveRow * step(abs(ord - floor(pkN)), 0.01) * step(1.0, pkN);

    // ---- colour: grey body, accent where it matters ----
    float ageDim = liveRow > 0.5 ? 1.0 : mix(0.8, 0.22, clamp(rowUp / HROWS, 0.0, 1.0));
    float hot = smoothstep(0.55, 0.95, v);                      // the loudest cells earn colour
    vec3 body = mix(fg.rgb * mix(0.42, 0.62, dark), pal(0.25 + 0.5 * u), hot * 0.8);
    vec3 dotC = mix(body, c2.rgb, liveRow * 0.55) * ageDim;
    dotC = mix(dotC, c3.rgb, max(dl, slam * 0.6));
    vec3 capC = c3.rgb;

    // ---- the cursor: a faint column sweeping with the beat grid ----
    float cur = 0.0;
    if (beatConfidence > 0.15) {
        float curCol = fract(barPhase) * COLS;
        cur = (1.0 - smoothstep(0.0, 1.5, abs(cell.x + 0.5 - curCol))) * 0.5 * beatConfidence;
    }

    // ---- the frame: a 1px border on the outer cell ring, downbeat ticks it ----
    float edgeCell = step(cell.x, 0.0) + step(COLS - 1.0, cell.x) + step(cell.y, 0.0) + step(rows - 1.0, cell.y);
    vec2 eb = min(px, res - px);
    float frameLine = (1.0 - smoothstep(0.5, 1.8, min(eb.x, eb.y))) * step(0.5, edgeCell);
    float frameGlow = frameLine * (0.35 + 0.65 * downbeat * beatConfidence);

    // ---- compose ----
    float glowGain = lit(0.25 + 0.45 * build + 0.3 * anticipate);
    if (light < 0.5) {
        vec3 col = bg.rgb;
        // phosphor bed: the faintest trace of every cell's value, so the wall has a body
        col += pal(0.3 + 0.4 * u) * v * v * 0.09 * glowGain;
        col += dotC * dotCov * on;
        col += capC * dotCov * capHere * 0.9;
        col += c1.rgb * cur * (1.0 - dotCov * on) * 0.12;
        col += mix(fg.rgb * 0.5, c2.rgb, downbeat) * frameGlow * 0.6;
        // soft glow under lit dots, dialled back when the real bloom runs
        col += dotC * on * faux(0.18, 0.8) * smoothstep(0.3, 0.0, length(inDot)) * glowGain;
        fragColor = vec4(max(col, 0.0) + dither(px), 1.0) * qt_Opacity;
    } else {
        // ink on paper: dots multiply the page down, the live row in the accent ink
        vec3 inkC = mix(fg.rgb, c2.rgb, liveRow * 0.5 + max(dl, slam * 0.5));
        vec3 col = bg.rgb;
        float a = dotCov * on * ageDim;
        col = mix(col, inkC * 0.35, a);
        col = mix(col, c3.rgb * 0.3, dotCov * capHere * 0.8);
        col = mix(col, fg.rgb * 0.4, frameLine * 0.7);
        fragColor = vec4(col + dither(px), 1.0) * qt_Opacity;
    }
}
