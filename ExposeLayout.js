// The Exposé layout (pure functions, testable outside the shell).

// Windows in the screen's reading order: top to bottom, then left to right,
// tolerating a small vertical offset between neighbours.
function readingOrder(rects) {
  var order = (rects || []).map(function(r, i) { return i })
  order.sort(function(a, b) {
    var ra = rects[a], rb = rects[b]
    var rowA = Math.round(ra.y / 120), rowB = Math.round(rb.y / 120)
    return rowA - rowB || ra.x - rb.x || a - b
  })
  return order
}

// Places n windows (rects { x, y, w, h }, in the wanted order) in the area
// { x, y, w, h }: a grid whose column count gives the largest thumbnails, each
// scaled from its window (never enlarged) and centred in its cell. An
// incomplete last row is centred. Returns { columns, tiles: [{ x, y, w, h }] }.
function layout(rects, area, gap, labelRoom) {
  var n = (rects || []).length
  if (n === 0) return { columns: 1, tiles: [] }
  var g = Math.max(0, gap || 0)
  var label = Math.max(0, labelRoom || 0)

  function fit(r, cw, ch) {
    var w = Math.max(1, r.w), h = Math.max(1, r.h)
    var s = Math.min(cw / w, (ch - label) / h, 1)
    return { w: w * s, h: h * s }
  }

  var best = null
  for (var cols = 1; cols <= n; cols++) {
    var rows = Math.ceil(n / cols)
    var cw = (area.w - g * (cols - 1)) / cols
    var ch = (area.h - g * (rows - 1)) / rows
    if (cw <= 0 || ch - label <= 0) continue
    var covered = 0
    for (var i = 0; i < n; i++) {
      var f = fit(rects[i], cw, ch)
      covered += f.w * f.h
    }
    if (!best || covered > best.covered + 0.5) best = { cols: cols, rows: rows, cw: cw, ch: ch, covered: covered }
  }
  if (!best) best = { cols: n, rows: 1, cw: area.w / n, ch: area.h, covered: 0 }

  var tiles = []
  var gridH = best.rows * best.ch + (best.rows - 1) * g
  var top = area.y + (area.h - gridH) / 2
  for (var k = 0; k < n; k++) {
    var row = Math.floor(k / best.cols)
    var col = k % best.cols
    var inRow = Math.min(best.cols, n - row * best.cols)
    var rowW = inRow * best.cw + (inRow - 1) * g
    var left = area.x + (area.w - rowW) / 2
    var t = fit(rects[k], best.cw, best.ch)
    tiles.push({
      x: left + col * (best.cw + g) + (best.cw - t.w) / 2,
      y: top + row * (best.ch + g) + (best.ch - label - t.h) / 2,
      w: t.w,
      h: t.h
    })
  }
  return { columns: best.cols, tiles: tiles }
}

// The neighbour in a direction ("left", "right", "up", "down"): the tile whose
// centre is closest that way, or the current index when there is none.
function neighbor(tiles, index, direction) {
  var list = tiles || []
  if (list.length === 0) return -1
  if (index < 0 || index >= list.length) return 0
  var c = list[index]
  var cx = c.x + c.w / 2, cy = c.y + c.h / 2
  var best = index, bestScore = Infinity
  for (var i = 0; i < list.length; i++) {
    if (i === index) continue
    var t = list[i]
    var dx = t.x + t.w / 2 - cx, dy = t.y + t.h / 2 - cy
    var along, across
    if (direction === "left") { along = -dx; across = Math.abs(dy) }
    else if (direction === "right") { along = dx; across = Math.abs(dy) }
    else if (direction === "up") { along = -dy; across = Math.abs(dx) }
    else { along = dy; across = Math.abs(dx) }
    if (along <= 1) continue
    var score = along + across * 2
    if (score < bestScore) { bestScore = score; best = i }
  }
  return best
}

if (typeof module !== "undefined") module.exports = { readingOrder: readingOrder, layout: layout, neighbor: neighbor }
