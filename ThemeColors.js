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

// fallback: { foreground, accent, urgent, muted } from Commons.Color
function resolve(raw, fallback) {
  var kv = parseKv(raw)
  return {
    up: kv.green || kv.color2 || fallback.accent,
    warn: kv.yellow || kv.color3 || fallback.urgent,
    down: kv.red || kv.color1 || fallback.urgent,
    unknown: kv.muted || fallback.muted
  }
}
