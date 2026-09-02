// Reads the same raw theme colors.toml text the shell's Color singleton
// parses (see Commons/Color.qml). We need semantic red/green/yellow tokens
// for status dots, which Color.qml deliberately does not expose beyond
// foreground/background/accent/urgent/muted -- so we do our own light-touch
// parse of the same file for the extra tokens, and fall back to Color's
// exposed roles when a theme omits them.

function parseKv(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{3})/)
    if (m) out[m[1]] = m[2]
  }
  return out
}

function hexToRgb(hex) {
  var h = String(hex || "").replace("#", "")
  if (h.length === 3) h = h[0] + h[0] + h[1] + h[1] + h[2] + h[2]
  // QML `color` values stringify as 8-digit "#AARRGGBB" -- the fallback
  // colors passed in from Color.qml go through here too, so drop the alpha
  // pair rather than reject the whole string.
  if (h.length === 8) h = h.slice(2)
  if (h.length !== 6) return null
  var n = parseInt(h, 16)
  if (!isFinite(n)) return null
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }
}

// Straight-line RGB distance, 0-441. Not perceptually uniform, but plenty
// good enough to catch "these two are basically the same color".
function colorDistance(hexA, hexB) {
  var a = hexToRgb(hexA), b = hexToRgb(hexB)
  if (!a || !b) return Infinity
  var dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
  return Math.sqrt(dr * dr + dg * dg + db * db)
}

// Two fixed candidates per state, tried in order: the first one that's far
// enough from every color in `avoid` wins, else the last candidate is used
// regardless (never leave a state unassigned).
var SAFE_WARN = ["#e0af68", "#ff9e64"]
var SAFE_DOWN = ["#f7768e", "#db4b4b"]
var COLLISION_THRESHOLD = 60

function pickDistinct(preferred, avoid, safeChain) {
  var candidates = [preferred].concat(safeChain)
  for (var i = 0; i < candidates.length; i++) {
    var ok = true
    for (var j = 0; j < avoid.length; j++) {
      if (colorDistance(candidates[i], avoid[j]) < COLLISION_THRESHOLD) { ok = false; break }
    }
    if (ok) return candidates[i]
  }
  return candidates[candidates.length - 1]
}

// fallback: { foreground, accent, urgent, muted } from Commons.Color
function resolve(raw, fallback) {
  var kv = parseKv(raw)

  var up = kv.green || kv.color2 || fallback.accent
  // bright_yellow first: some themes (monochrome/single-accent ones, e.g.
  // Osaka Jade) reuse a green-tinted shade for the base "yellow" slot to
  // stay visually cohesive, which silently makes warn indistinguishable
  // from up. The "bright" ANSI slot is meant to stand out and is far more
  // reliably an actual yellow.
  var warnRaw = kv.bright_yellow || kv.yellow || kv.color3 || fallback.urgent
  var downRaw = kv.red || kv.color1 || fallback.urgent

  // Belt-and-suspenders for whichever theme still collides: the dots exist
  // to be told apart at a glance, so two states rendering as the same color
  // is worse than the theme not matching exactly. Fall back to a fixed,
  // always-distinct color rather than let that happen silently -- and if
  // even the first fixed fallback happens to collide too (a theme's `up`
  // landing close to it), try a second one rather than give up.
  var warn = pickDistinct(warnRaw, [up], SAFE_WARN)
  var down = pickDistinct(downRaw, [up, warn], SAFE_DOWN)

  return {
    up: up,
    warn: warn,
    down: down,
    unknown: kv.muted || fallback.muted
  }
}
