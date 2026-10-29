// HulkBin — a pixel-art Hulk that stands on your Dock's Trash tile and smashes whatever you drop in it.
//
// How it works
//  • Finds the Trash tile in the Dock through the Accessibility API (needs Accessibility permission).
//  • Parks a transparent, click-through window over that tile and draws an animated Hulk into it.
//    Drops still land on the real Trash underneath; the Hulk just stands in front of it.
//  • Watches global mouse events + the drag pasteboard to know when files are dragged towards the Trash,
//    and confirms a drop by checking the dragged files have left their original location.
//
// Build:  ./build.sh        Preview contact sheet:  HulkBin.app/Contents/MacOS/HulkBin --preview out.png

import AppKit
import ApplicationServices
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Small helpers

func rgb(_ hex: UInt32) -> UInt32 {
    let r = (hex >> 16) & 255, g = (hex >> 8) & 255, b = hex & 255
    return 0xFF00_0000 | (b << 16) | (g << 8) | r
}
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, x)) }
func easeOutCubic(_ t: Double) -> Double { let u = 1 - clamp(t); return 1 - u * u * u }
func easeOutBack(_ t: Double) -> Double { let u = clamp(t) - 1; return 1 + 2.4 * u * u * u + 1.4 * u * u }
func easeInOut(_ t: Double) -> Double { let t = clamp(t); return t * t * (3 - 2 * t) }

struct V { var x: Double; var y: Double }
func lerp(_ a: V, _ b: V, _ t: Double) -> V { V(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t)) }

let ART_W = 132, ART_H = 140          // scene size in art pixels
let CX = 66.0                          // Hulk's centre line

// MARK: - Pixel canvas

/// Six-tone shading: outline, warm bounce light along the bottom, deep core shadow,
/// mid shadow, base fill, and a rim light up on the top-left.
struct Style {
    var fill: UInt32
    var shadow: UInt32? = nil
    var light: UInt32? = nil
    var edge: UInt32? = nil
    var core: UInt32? = nil
    var bounce: UInt32? = nil
}

final class Canvas {
    let w: Int, h: Int
    var px: [UInt32]
    var ox = 0, oy = 0                 // translation applied to every draw call
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [UInt32](repeating: 0, count: w * h) }

    func clear() { px = [UInt32](repeating: 0, count: w * h) }

    @inline(__always) func put(_ x: Int, _ y: Int, _ col: UInt32) {
        let X = x + ox, Y = y + oy
        if X < 0 || Y < 0 || X >= w || Y >= h { return }
        px[(h - 1 - Y) * w + X] = col
    }
    func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ col: UInt32) {
        if rw <= 0 || rh <= 0 { return }
        for j in 0..<rh { for i in 0..<rw { put(x + i, y + j, col) } }
    }

    /// Fills every pixel whose centre satisfies `inside`, with outline, bounce, two shadow tones and a rim light.
    func shape(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ st: Style, sd: Double = 2,
               inside: (Double, Double) -> Bool) {
        let ix0 = Int(floor(x0)) - 1, ix1 = Int(ceil(x1)) + 1
        let iy0 = Int(floor(y0)) - 1, iy1 = Int(ceil(y1)) + 1
        if ix1 < ix0 || iy1 < iy0 { return }
        for y in iy0...iy1 {
            for x in ix0...ix1 {
                let fx = Double(x) + 0.5, fy = Double(y) + 0.5
                if !inside(fx, fy) { continue }
                var col = st.fill
                if let e = st.edge, !(inside(fx - 1, fy) && inside(fx + 1, fy) && inside(fx, fy - 1) && inside(fx, fy + 1)) {
                    col = e
                } else if let b = st.bounce, !inside(fx, fy - 1.4) {
                    col = b
                } else if let cr = st.core, !inside(fx + sd * 0.5, fy - sd * 0.5) {
                    col = cr
                } else if let s = st.shadow, !inside(fx + sd, fy - sd) {
                    col = s
                } else if let l = st.light, !inside(fx - 1.3, fy + 1.3) {
                    col = l
                }
                put(x, y, col)
            }
        }
    }
    func disc(_ cx: Double, _ cy: Double, _ r: Double, _ st: Style, sd: Double? = nil) {
        shape(cx - r, cy - r, cx + r, cy + r, st, sd: sd ?? max(1.2, r * 0.38)) { x, y in
            (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r
        }
    }
    func cap(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ r: Double, _ st: Style, sd: Double? = nil) {
        let dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy
        shape(min(ax, bx) - r, min(ay, by) - r, max(ax, bx) + r, max(ay, by) + r, st, sd: sd ?? max(1.2, r * 0.4)) { x, y in
            var t = l2 > 0 ? ((x - ax) * dx + (y - ay) * dy) / l2 : 0
            t = min(1, max(0, t))
            let qx = ax + t * dx - x, qy = ay + t * dy - y
            return qx * qx + qy * qy <= r * r
        }
    }
    func rrect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ rad: Double, _ st: Style, sd: Double = 2) {
        shape(x0, y0, x1, y1, st, sd: sd) { x, y in
            if x < x0 || x > x1 || y < y0 || y > y1 { return false }
            let cx = min(max(x, x0 + rad), x1 - rad), cy = min(max(y, y0 + rad), y1 - rad)
            return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= rad * rad
        }
    }
    func ell(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ st: Style, sd: Double = 1.6) {
        shape(cx - rx, cy - ry, cx + rx, cy + ry, st, sd: sd) { x, y in
            let nx = (x - cx) / rx, ny = (y - cy) / ry
            return nx * nx + ny * ny <= 1
        }
    }
    /// Convex polygon; winding is normalised so mirrored point lists work too.
    func poly(_ pts: [V], _ st: Style, sd: Double = 3) {
        var area = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        let p = area < 0 ? pts.reversed().map { $0 } : pts
        let xs = p.map { $0.x }, ys = p.map { $0.y }
        shape(xs.min()!, ys.min()!, xs.max()!, ys.max()!, st, sd: sd) { x, y in
            for i in 0..<p.count {
                let a = p[i], b = p[(i + 1) % p.count]
                if (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x) < 0 { return false }
            }
            return true
        }
    }
    func flatDisc(_ cx: Double, _ cy: Double, _ r: Double, _ col: UInt32, dither: Bool = false) {
        let n = Int(ceil(r))
        let ix = Int(cx.rounded()), iy = Int(cy.rounded())
        for dy in -n...n { for dx in -n...n where Double(dx * dx + dy * dy) <= r * r {
            if dither && (ix + dx + iy + dy) & 1 == 1 { continue }
            put(ix + dx, iy + dy, col)
        } }
    }
    /// Nearest-neighbour blit of an n×n sprite (row 0 = top) into a w×h box whose bottom-left is (x, y).
    func sprite(_ s: [UInt32], n: Int, x: Double, y: Double, w bw: Int, h bh: Int) {
        if bw <= 0 || bh <= 0 { return }
        let bx = Int(x.rounded()), by = Int(y.rounded())
        for j in 0..<bh {
            let sy = min(n - 1, (bh - 1 - j) * n / bh)
            for i in 0..<bw {
                let sx = min(n - 1, i * n / bw)
                let col = s[sy * n + sx]
                if col != 0 { put(bx + i, by + j, col) }
            }
        }
    }

    func cgImage(scale s: Int = 1) -> CGImage {
        let ow = w * s, oh = h * s
        var out = px
        if s > 1 {
            out = [UInt32](repeating: 0, count: ow * oh)
            for y in 0..<oh { for x in 0..<ow { out[y * ow + x] = px[(y / s) * w + x / s] } }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        return CGImage(width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: data as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}

// MARK: - Palette (dark outline, four greens, bright rim; torn denim shorts)

let OUTL   = rgb(0x163318)
let skin   = Style(fill: rgb(0x5CB04D), shadow: rgb(0x3F8C3E), light: rgb(0x8FD765), edge: OUTL,
                   core: rgb(0x2E6B35))
let skinD  = Style(fill: rgb(0x4E9D44), shadow: rgb(0x377E38), light: rgb(0x80C85B), edge: OUTL,
                   core: rgb(0x295F30))
let skinN  = Style(fill: rgb(0x5CB04D), shadow: rgb(0x3F8C3E), light: rgb(0x8FD765), core: rgb(0x2E6B35))
let skinNd = Style(fill: rgb(0x4E9D44), shadow: rgb(0x377E38), light: rgb(0x80C85B), core: rgb(0x295F30))
let RIM    = rgb(0xB4E870)
let denim  = Style(fill: rgb(0x44519B), shadow: rgb(0x2E3570), light: rgb(0x7384C9), edge: rgb(0x141936),
                   core: rgb(0x242A5C))
let patchS = Style(fill: rgb(0x7FA3C4), shadow: rgb(0x5B7D9E), light: rgb(0xA3C2DA), core: rgb(0x47637F))
let hairS  = Style(fill: rgb(0x25332B), shadow: rgb(0x16201A), light: rgb(0x40553F), edge: rgb(0x0B120D))
let TOOTH  = rgb(0xF2EDDC), GUM = rgb(0x300E12), GAP = rgb(0x8E8878)

// MARK: - Pose & rig

struct Pose {
    var lF = V(x: -22, y: 25), rF = V(x: 22, y: 25)      // fist targets, relative to CX
    var mouth = 0.0, anger = 0.15, glow = 0.0, bob = 0.0, lean = 0.0, speed = 0.0
    func mixed(_ o: Pose, _ t: Double) -> Pose {
        Pose(lF: lerp(lF, o.lF, t), rF: lerp(rF, o.rF, t), mouth: lerp(mouth, o.mouth, t),
             anger: lerp(anger, o.anger, t), glow: lerp(glow, o.glow, t), bob: lerp(bob, o.bob, t),
             lean: lerp(lean, o.lean, t), speed: lerp(speed, o.speed, t))
    }
}

let SHOULDER_X = 18.0, SHOULDER_Y = 46.5
let UPPER = 13.0, FORE = 12.5

func ik(_ s: V, _ target: V, side: Double) -> (elbow: V, hand: V) {
    var dx = target.x - s.x, dy = target.y - s.y
    var d = max(hypot(dx, dy), 4)
    let maxd = UPPER + FORE - 0.3
    if d > maxd { dx *= maxd / d; dy *= maxd / d; d = maxd }
    let a = acos(clamp((UPPER * UPPER + d * d - FORE * FORE) / (2 * UPPER * d), -1, 1))
    let base = atan2(dy, dx)
    let e1 = V(x: s.x + UPPER * cos(base + a), y: s.y + UPPER * sin(base + a))
    let e2 = V(x: s.x + UPPER * cos(base - a), y: s.y + UPPER * sin(base - a))
    let elbow = (e1.x - s.x) * side > (e2.x - s.x) * side ? e1 : e2
    return (elbow, V(x: s.x + dx, y: s.y + dy))
}

/// A limb segment with a bright rim light along its outer edge: a bright capsule,
/// then the shaded body inset towards the inside of the figure.
func limb(_ c: Canvas, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
          _ r: Double, side: Double, _ st: Style) {
    c.cap(ax, ay, bx, by, r, Style(fill: RIM, edge: OUTL), sd: 1)
    var inner = st; inner.edge = nil
    c.cap(ax - side * 1.5, ay, bx - side * 1.5, by, r - 1.35, inner, sd: r * 0.55)
}

// MARK: - Figure
//
// Vertical layout, in art pixels from the Dock tile's floor:
//   feet 0–6 · shins 5–18 · shorts 14–33 · torso 31–49 · shoulders 38–55
//   jaw 44 · crown 60 · hair to 67

/// Feet, shins and the torn denim shorts. The legs stay close enough to hide the bin behind them.
func drawLegs(_ c: Canvas, _ p: Pose) {
    let b = p.bob * 0.3
    for s in [-1.0, 1.0] {
        let footX = CX + s * 8.0, kneeX = CX + s * 5.5, ankX = CX + s * 7.5
        let st = s < 0 ? skin : skinD
        // shin, rim-lit on the outside
        limb(c, kneeX, 19.0 + b, ankX, 7.2 + b, 5.6, side: s, st)
        c.ell(kneeX + s * 3.2, 12.8 + b, 2.5, 4.0, s < 0 ? skinN : skinNd, sd: 1.8)   // calf
        c.rect(Int((kneeX - 2.5).rounded()), Int((17 + b).rounded()), 5, 1, st.shadow!)
        // foot: broad, with toes along the front edge
        c.rrect(footX - 7.0, 0 + b, footX + 6.6, 6.4 + b, 2.0, st, sd: 2.4)
        for t in 0..<4 { c.disc(footX - 4.6 + Double(t) * 3.0, 1.9 + b, 1.5, s < 0 ? skinN : skinNd, sd: 1.1) }
        c.rect(Int((footX - 6).rounded()), Int((4.6 + b).rounded()), 12, 1, RIM)
    }
    // torn denim shorts: wide at the thighs, ragged hem, shallow notch between the legs
    let hem = 14.0 + b, top = 33.0 + b
    for pass in 0..<2 {
        let inset = pass == 0 ? 0.0 : 1.4
        var st = pass == 0 ? Style(fill: rgb(0x8EA0E4), edge: denim.edge) : denim
        if pass == 1 { st.edge = nil }
        c.shape(CX - 19, hem - 3, CX + 19, top, st, sd: 3.2) { x, y in
            if y > top - inset * 0.6 { return false }
            let dx = abs(x - CX)
            let t = clamp((y - hem) / (top - hem))
            if dx > lerp(17.5, 11.2, t) - inset { return false }
            if y < hem + 2.4 * abs(sin(dx * 1.05 + 0.7)) + inset * 0.5 { return false }
            if dx < 3.4 - inset && y < 18.5 + b - dx * dx * 0.7 { return false }
            return true
        }
    }
    let ix = Int(CX)
    c.rect(ix - 10, Int((30.4 + b).rounded()), 20, 2, denim.light!)        // waistband
    c.rect(ix, Int((24 + b).rounded()), 1, 7, denim.core!)                 // fly seam
    c.ell(CX - 10.5, 21.0 + b, 3.8, 3.2, patchS, sd: 1.8)                  // worn patches
    c.ell(CX + 10.0, 19.6 + b, 3.2, 2.7, patchS, sd: 1.6)
}

/// Torso, pecs, abs, traps and the shoulder slabs.
func drawTorso(_ c: Canvas, _ p: Pose) {
    let b = p.bob, ln = p.lean, ix = Int((CX + ln).rounded())
    let waist = 31.0 + b, top = 49.0 + b
    func halfWidth(_ y: Double) -> Double {
        let t = clamp((y - waist) / (top - waist))
        return t < 0.70 ? lerp(11.0, 16.0, t / 0.70) : lerp(16.0, 14.2, (t - 0.70) / 0.30)
    }
    // big V torso, rim-lit down both outer edges
    for pass in 0..<2 {
        let inset = pass == 0 ? 0.0 : 1.4
        var st = pass == 0 ? Style(fill: RIM, edge: OUTL) : skin
        if pass == 1 { st.edge = nil }
        c.shape(CX - 19, waist - 1, CX + 19, top + 1, st, sd: 3.4) { x, y in
            if y < waist + inset * 0.4 || y > top - inset * 0.5 { return false }
            return abs(x - CX - ln) <= halfWidth(y) - inset
        }
    }
    // abs: a narrow column of blocks with a centre line
    for row in 0..<3 {
        let ay = Int((32.5 + Double(row) * 3.2 + b).rounded())
        c.rect(ix - 5, ay, 4, 2, skin.shadow!)
        c.rect(ix + 2, ay, 4, 2, skin.shadow!)
        c.rect(ix - 5, ay + 2, 4, 1, skin.light!)
        c.rect(ix + 2, ay + 2, 4, 1, skin.light!)
    }
    c.rect(ix, Int((32 + b).rounded()), 1, 11, skin.core!)
    // pecs
    for s in [-1.0, 1.0] {
        c.ell(CX + ln + s * 7.6, 44.0 + b, 8.0, 5.0, s < 0 ? skinN : skinNd, sd: 2.8)
    }
    c.rect(ix, Int((39.5 + b).rounded()), 1, 9, skin.core!)                // sternum
    c.rect(ix - 14, Int((39.2 + b).rounded()), 13, 1, skin.core!)          // pec shelf
    c.rect(ix + 2, Int((39.2 + b).rounded()), 13, 1, skin.core!)
    // traps filling the gap between neck and shoulders
    for s in [-1.0, 1.0] {
        c.poly([V(x: CX + ln + s * 3.5, y: 45.0 + b), V(x: CX + ln + s * 16.0, y: 45.0 + b),
                V(x: CX + ln + s * 14.0, y: 51.5 + b), V(x: CX + ln + s * 4.0, y: 54.0 + b)],
               s < 0 ? skinD : skinNd, sd: 2.4)
    }
    // shoulder slabs
    for s in [-1.0, 1.0] {
        c.disc(CX + ln + s * SHOULDER_X, SHOULDER_Y + b, 8.3, Style(fill: RIM, edge: OUTL), sd: 1)
        var inner = s < 0 ? skin : skinD; inner.edge = nil
        c.disc(CX + ln + s * (SHOULDER_X - 1.4), SHOULDER_Y + b, 7.0, inner, sd: 3.4)
        c.ell(CX + ln + s * SHOULDER_X, 49.5 + b, 4.6, 2.6, s < 0 ? skinN : skinNd, sd: 1.5)
    }
}

func drawHead(_ c: Canvas, _ p: Pose, look: V, blink: Bool) {
    let hx = CX + p.lean * 1.2, hy = p.bob
    let ix = Int(hx.rounded())
    // ears
    c.disc(hx - 10.0, 50.5 + hy, 2.1, skinD)
    c.disc(hx + 10.0, 50.5 + hy, 2.1, skinD)
    // skull with a heavy square jaw
    c.poly([V(x: hx - 5.8, y: 43.0 + hy), V(x: hx + 5.8, y: 43.0 + hy),
            V(x: hx + 9.2, y: 46.0 + hy), V(x: hx + 10.0, y: 52.0 + hy),
            V(x: hx + 8.6, y: 60.5 + hy), V(x: hx - 8.6, y: 60.5 + hy),
            V(x: hx - 10.0, y: 52.0 + hy), V(x: hx - 9.2, y: 46.0 + hy)], skin, sd: 3.0)
    // heavy brow ridge, eyes set deep in its shadow
    c.cap(hx - 8.0, 54.6 + hy, hx + 8.0, 54.6 + hy, 2.4,
          Style(fill: skin.shadow!, shadow: skin.core!, light: skin.fill), sd: 2.0)
    let ey = Int((51.0 + hy).rounded())
    c.rect(ix - 8, ey, 7, 3, skin.core!)
    c.rect(ix + 1, ey, 7, 3, skin.core!)
    // eyes
    if p.glow > 0.5 {
        c.rect(ix - 9, ey - 1, 9, 5, rgb(0x6FD04A)); c.rect(ix, ey - 1, 9, 5, rgb(0x6FD04A))
    }
    let eyeCol = p.glow > 0.3 ? rgb(0xEAFF6B) : rgb(0xF7F3DC)
    for x0 in [ix - 7, ix + 2] {
        if blink { c.rect(x0, ey + 1, 5, 1, rgb(0x14260F)); continue }
        c.rect(x0, ey, 5, 3, eyeCol)
        if p.glow < 0.7 {
            let pxl = x0 + 2 + max(-1, min(1, Int(look.x.rounded())))
            c.rect(pxl, ey, 2, 3, rgb(0x12180F))
        }
    }
    // angry brows riding the ridge
    let a = p.anger
    c.cap(hx - 8.2, 55.8 + a * 1.0 + hy, hx - 1.6, 53.4 - a * 1.2 + hy, 1.35, Style(fill: hairS.fill, edge: hairS.edge))
    c.cap(hx + 8.2, 55.8 + a * 1.0 + hy, hx + 1.6, 53.4 - a * 1.2 + hy, 1.35, Style(fill: hairS.fill, edge: hairS.edge))
    // broad nose
    c.rect(ix - 2, Int((48.6 + hy).rounded()), 4, 2, skin.shadow!)
    c.rect(ix - 3, Int((48.4 + hy).rounded()), 1, 1, skin.core!)
    c.rect(ix + 2, Int((48.4 + hy).rounded()), 1, 1, skin.core!)
    // mouth: a clenched grimace that opens to a roar — teeth stay visible throughout
    let my = Int((44.6 + hy).rounded())
    if p.mouth < 0.12 {
        c.rect(ix - 7, my, 14, 3, GUM)
        c.rect(ix - 6, my + 1, 12, 2, TOOTH)
        for k in 0..<6 { c.rect(ix - 5 + k * 2, my + 1, 1, 2, GAP) }
    } else {
        let hgt = 3 + Int((p.mouth * 5).rounded())
        let bot = my + 3 - hgt
        c.rect(ix - 7, bot, 14, hgt, GUM)
        c.rect(ix - 6, my + 2, 12, 1, TOOTH)                               // upper row
        c.rect(ix - 6, bot + 1, 12, 1, TOOTH)                              // lower row
        for k in 0..<6 {
            c.rect(ix - 5 + k * 2, my + 2, 1, 1, GAP)
            c.rect(ix - 5 + k * 2, bot + 1, 1, 1, GAP)
        }
        if hgt >= 5 { c.rect(ix - 3, bot + 2, 6, max(1, hgt - 4), rgb(0xB8454F)) }   // tongue
    }
    // shaggy hair: a heavy mass over the crown with a jagged fringe and a widow's peak
    c.shape(hx - 12, 52 + hy, hx + 12, 70 + hy, hairS, sd: 2.6) { x, y in
        let dx = x - hx
        if abs(dx) > 10.4 { return false }
        let crown = 67.0 + hy - 0.082 * dx * dx + 0.95 * sin(dx * 0.82)     // chunky notched crown
        if y > crown { return false }
        let fringe = 55.4 + hy + max(0, 2.1 - abs(dx) * 0.44) - 1.1 * abs(sin(dx * 1.15))
        return y >= fringe
    }
    c.rect(ix - 10, Int((50 + hy).rounded()), 2, 7, hairS.fill)            // sideburns
    c.rect(ix + 8, Int((50 + hy).rounded()), 2, 7, hairS.fill)
}

/// Both arms. Returns the lowest fist edge, used to squash the file under them.
@discardableResult
func drawArms(_ c: Canvas, _ p: Pose) -> Double {
    var lowest = 99.0
    for side in [-1.0, 1.0] {
        let f = side < 0 ? p.lF : p.rF
        let s = V(x: CX + side * SHOULDER_X + p.lean, y: SHOULDER_Y + p.bob)
        let (e, h) = ik(s, V(x: CX + f.x, y: f.y), side: side)
        let st = side < 0 ? skin : skinD, stN = side < 0 ? skinN : skinNd
        if p.speed > 0.05 {                                               // motion streaks
            let n = 5
            for k in 0..<n {
                let sx = Int((h.x + Double(k - n / 2) * 2.8).rounded())
                let lo = Int((h.y + 8 + Double(k % 3) * 2).rounded())
                let hi = lo + Int(13 * p.speed) + (k % 2) * 5
                for yy in lo...hi where (yy + sx) & 1 == 0 { c.put(sx, yy, rgb(0xCFF0A8)) }
            }
        }
        limb(c, s.x, s.y, e.x, e.y, 6.5, side: side, st)                   // upper arm
        c.ell(lerp(s.x, e.x, 0.42), lerp(s.y, e.y, 0.42), 3.8, 3.4, stN, sd: 1.9)   // bicep
        limb(c, e.x, e.y, h.x, h.y, 6.0, side: side, st)                   // forearm
        c.ell(lerp(e.x, h.x, 0.3), lerp(e.y, h.y, 0.3), 3.3, 2.9, stN, sd: 1.7)
        c.disc(h.x, h.y, 6.6, Style(fill: RIM, edge: OUTL), sd: 1)         // fist
        var inner = st; inner.edge = nil
        c.disc(h.x - side * 1.4, h.y, 5.4, inner, sd: 2.8)
        let hx = Int(h.x.rounded()), hy = Int(h.y.rounded())
        for k in 0..<3 { c.rect(hx - 3 + k * 2, hy - 2, 1, 4, st.core!) }  // knuckles
        c.rect(hx - 3, hy + 2, 6, 1, st.light!)
        lowest = min(lowest, h.y - 6.6)
    }
    return lowest
}

// MARK: - Pixel font (5×7)

let glyphs: [Character: [String]] = [
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".####", "#....", "#....", "#....", "#....", "#....", ".####"],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
    "J": ["....#", "....#", "....#", "....#", "#...#", "#...#", ".###."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "##..#", "##..#", "#.#.#", "#..##", "#..##", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
]

func drawWord(_ c: Canvas, _ word: String, cx: Double, y: Int, scale s: Int, fade: Bool = false,
              jitter: Double = 0, time: Double = 0) {
    let chars = Array(word)
    let totalW = chars.count * 6 * s - s
    let x0 = Int(cx.rounded()) - totalW / 2
    func pass(_ dx: Int, _ dy: Int, _ col: UInt32) {
        var x = x0
        for (i, ch) in chars.enumerated() {
            guard let g = glyphs[ch] else { x += 6 * s; continue }
            let jy = Int((sin(time * 40 + Double(i) * 1.7) * jitter).rounded())
            for (gy, row) in g.enumerated() {
                for (gx, cell) in row.enumerated() where cell == "#" {
                    for sy in 0..<s { for sx in 0..<s {
                        let X = x + gx * s + sx + dx, Y = y + (6 - gy) * s + sy + dy + jy
                        if fade && (X + Y) & 1 == 1 { continue }
                        c.put(X, Y, col)
                    } }
                }
            }
            x += 6 * s
        }
    }
    for dy in -3...2 { for dx in -2...2 where abs(dx) + abs(dy) > 2 { pass(dx, dy, rgb(0xFFF4D0)) } }
    for dy in -2...1 { for dx in -1...1 { pass(dx, dy, rgb(0x1B1024)) } }
    pass(0, -1, rgb(0xE5432B))
    pass(0, 0, rgb(0xFFD93B))
}

func textWidth(_ s: String, _ scale: Int) -> Int { max(0, s.count * 6 * scale - scale) }

func drawPlainText(_ c: Canvas, _ s: String, x: Int, y: Int, scale: Int, col: UInt32) {
    var cx = x
    for ch in s {
        guard let g = glyphs[ch] else { cx += 6 * scale; continue }
        for (gy, row) in g.enumerated() {
            for (gx, cell) in row.enumerated() where cell == "#" {
                for sy in 0..<scale { for sx in 0..<scale {
                    c.put(cx + gx * scale + sx, y + (6 - gy) * scale + sy, col)
                } }
            }
        }
        cx += 6 * scale
    }
}

/// Comic speech bubble with a tail pointing down at the Hulk's head.
func drawBubble(_ c: Canvas, _ lines: [String], cx: Double, bottomY: Int, scale: Int) {
    let ink = rgb(0x1B1024), paper = rgb(0xFFFBEA)
    let lineH = 9 * scale
    let w = lines.map { textWidth($0, scale) }.max() ?? 0
    let bw = w + 12, bh = lineH * lines.count + 6
    let x0 = Double(Int(cx.rounded()) - bw / 2), y0 = Double(bottomY)
    c.rrect(x0, y0, x0 + Double(bw), y0 + Double(bh), 3.5,
            Style(fill: paper, shadow: rgb(0xE6E0CA), light: rgb(0xFFFFFF), edge: ink), sd: 2)
    // tail: a dark triangle with a lighter one inside, both overlapping the body by a pixel
    c.poly([V(x: cx - 5.5, y: y0 + 1.5), V(x: cx + 5.5, y: y0 + 1.5), V(x: cx - 1.0, y: y0 - 6.0)], Style(fill: ink))
    c.poly([V(x: cx - 3.8, y: y0 + 1.5), V(x: cx + 3.6, y: y0 + 1.5), V(x: cx - 1.4, y: y0 - 3.6)], Style(fill: paper))
    for (i, ln) in lines.enumerated() {
        let tw = textWidth(ln, scale)
        drawPlainText(c, ln, x: Int(cx.rounded()) - tw / 2,
                      y: Int(y0) + bh - 4 - lineH * (i + 1), scale: scale, col: ink)
    }
}

/// Jagged comic starburst, dithered so the figure shows through it.
func drawBurst(_ c: Canvas, cx: Double, cy: Double, r: Double, spikes: Int, phase: Double, col: UInt32, dither: Bool) {
    let R = r + 2
    let y0 = Int((cy - R * 0.62).rounded()), y1 = Int((cy + R * 0.62).rounded())
    let x0 = Int((cx - R).rounded()), x1 = Int((cx + R).rounded())
    for y in y0...y1 {
        for x in x0...x1 {
            if dither && (x + y) & 1 == 1 { continue }
            let dx = Double(x) - cx, dy = (Double(y) - cy) / 0.62
            let d = hypot(dx, dy)
            if d < 0.5 { c.put(x, y, col); continue }
            let th = atan2(dy, dx)
            let rr = r * (0.56 + 0.44 * pow(abs(cos(Double(spikes) * 0.5 * th + phase)), 0.55))
            if d <= rr { c.put(x, y, col) }
        }
    }
}

// MARK: - Scene

final class Smash {
    let start: Double, sprite: [UInt32], from: V
    var isLast: Bool
    var p0 = Pose(), activated = false, impacted = false, lastHalf = -1
    var duration: Double { isLast ? 2.1 : 0.85 }
    init(start: Double, sprite: [UInt32], from: V, isLast: Bool) {
        self.start = start; self.sprite = sprite; self.from = from; self.isLast = isLast
    }
}

struct Bit {
    var x: Double, y: Double, vx: Double, vy: Double
    var life: Double, color: UInt32, kind: Int      // 0 chip, 1 dust, 2 spark, 3 confetti
    var age = 0.0
}

final class HulkScene {
    var time = 0.0
    var smashes: [Smash] = []
    var bits: [Bit] = []
    var rings: [Double] = []
    var texts: [(t0: Double, word: String)] = []
    var shakeAmp = 0.0, shake = V(x: 0, y: 0)
    var hover = 0.0, breath = 0.0
    var cur = Pose()
    var look = V(x: 0, y: 0)
    var flexAt = 7.0
    var fistBottom = 14.0
    var wordIdx = 0
    var rng: UInt64 = 0x9E3779B97F4A7C15
    var onImpact: (() -> Void)?

    var busy: Bool { !smashes.isEmpty || !bits.isEmpty || !texts.isEmpty || shakeAmp > 0.05 }

    func rnd() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng % 1_000_000) / 1_000_000
    }

    // MARK: triggering
    func smash(sprites: [[UInt32]], from: V) {
        var t0 = time + 0.02
        if let prev = smashes.last, prev.start + prev.duration > time {
            prev.isLast = false
            t0 = max(t0, prev.start + 0.85)
        }
        let n = min(sprites.count, 5)
        for i in 0..<n {
            smashes.append(Smash(start: t0 + Double(i) * 0.85, sprite: sprites[i], from: from, isLast: i == n - 1))
        }
        flexAt = time + 10
    }

    // MARK: update
    func update(_ dt: Double, mouse: V, hoverTarget: Double) {
        time += dt
        hover += (hoverTarget - hover) * min(1, dt * 8)
        breath += dt * (2.4 + 6 * hover)
        look = V(x: clamp((mouse.x - CX) / 35, -1, 1), y: clamp((mouse.y - 53) / 35, -1, 1))

        for s in smashes where !s.activated && time >= s.start { s.activated = true; s.p0 = cur }
        for s in smashes where s.activated && !s.impacted && time >= s.start + 0.6 { impact(s) }

        if let s = smashes.last(where: { time >= $0.start && time < $0.start + $0.duration }) {
            let t = time - s.start
            cur = smashPose(s, t)
            if s.isLast && t >= 1.1 && t < 1.9 {
                let half = Int((t - 1.1) / 0.1)
                if half % 2 == 1 && half != s.lastHalf { s.lastHalf = half; shakeAmp = max(shakeAmp, 0.9) }
            }
        } else {
            cur = idlePose()
        }
        smashes.removeAll { time > $0.start + $0.duration + 0.1 }

        // particles
        for i in bits.indices {
            bits[i].age += dt
            switch bits[i].kind {
            case 0, 3:
                bits[i].vy -= (bits[i].kind == 0 ? 150 : 60) * dt
                bits[i].x += bits[i].vx * dt; bits[i].y += bits[i].vy * dt
                if bits[i].kind == 3 { bits[i].vx *= 0.985 }
                if bits[i].y < 0.5 {
                    bits[i].y = 0.5
                    bits[i].vy = abs(bits[i].vy) > 14 ? abs(bits[i].vy) * 0.3 : 0
                    bits[i].vx *= 0.6
                }
            case 1:
                bits[i].x += bits[i].vx * dt; bits[i].y += bits[i].vy * dt; bits[i].vx *= 0.96
            default:
                bits[i].x += bits[i].vx * dt; bits[i].y += bits[i].vy * dt
            }
        }
        bits.removeAll { $0.age > $0.life }
        rings.removeAll { time - $0 > 0.4 }
        texts.removeAll { time - $0.t0 > 0.9 }

        shakeAmp *= exp(-dt * 9)
        if shakeAmp < 0.05 { shakeAmp = 0 }
        shake = V(x: (sin(time * 70) * shakeAmp).rounded(), y: (cos(time * 83) * shakeAmp * 0.6).rounded())
    }

    func idlePose() -> Pose {
        var p = Pose()
        let br = sin(breath), h = hover
        p.bob = br * 0.5
        let sh = sin(time * 38) * 0.9 * h, sv = cos(time * 31) * 0.7 * h
        p.lF = V(x: lerp(-22, -18.0, h) + sh, y: lerp(25, 34, h) + br * 0.4 + sv)
        p.rF = V(x: lerp(22, 18.0, h) - sh, y: lerp(25, 34, h) + br * 0.4 - sv)
        p.mouth = h * 0.7
        p.anger = lerp(0.15, 1, h)
        p.glow = clamp((h - 0.55) / 0.4)
        if h < 0.1 && time >= flexAt {
            let t = time - flexAt
            if t < 1.0 {
                let w = sin(t * .pi)
                p.lF = lerp(p.lF, V(x: -13, y: 53), w); p.rF = lerp(p.rF, V(x: 13, y: 53), w)
                p.mouth = 0.3 * w; p.anger = lerp(p.anger, 0.6, w); p.bob += w * 1.2
            } else {
                flexAt = time + 9 + rnd() * 6
            }
        }
        return p
    }

    func smashPose(_ s: Smash, _ t: Double) -> Pose {
        let upL = V(x: -16, y: 70), upR = V(x: 16, y: 70)
        let dnL = V(x: -9.5, y: 13), dnR = V(x: 9.5, y: 13)
        let outL = V(x: -21, y: 33), outR = V(x: 21, y: 33)
        let rest = Pose()
        var p = Pose(); let p0 = s.p0
        if t < 0.38 {                                     // wind-up
            let u = t / 0.38, e = easeOutBack(u), k = easeOutCubic(u)
            p.lF = lerp(p0.lF, upL, e); p.rF = lerp(p0.rF, upR, e)
            p.mouth = lerp(p0.mouth, 1, k); p.anger = lerp(p0.anger, 1, k); p.glow = lerp(p0.glow, 1, k)
            p.bob = lerp(p0.bob, 1.5, k); p.lean = lerp(p0.lean, -1, k)
        } else if t < 0.5 {                               // quiver at the top
            let q = t - 0.38
            p.lF = V(x: upL.x + sin(q * 110) * 0.6, y: upL.y + cos(q * 95) * 0.6)
            p.rF = V(x: upR.x - sin(q * 110) * 0.6, y: upR.y + cos(q * 90) * 0.6)
            p.mouth = 1; p.anger = 1; p.glow = 1; p.bob = 1.5; p.lean = -1
        } else if t < 0.6 {                               // SLAM — body drops into the blow
            let u = (t - 0.5) / 0.1, e = u * u
            p.lF = lerp(upL, dnL, e); p.rF = lerp(upR, dnR, e)
            p.mouth = 1; p.anger = 1; p.glow = 1; p.bob = lerp(1.5, -10, e); p.lean = lerp(-1, 0.5, e)
            p.speed = 1
        } else if !s.isLast || t < 0.8 {                  // pressed down, recoil wobble
            let q = t - 0.6
            p.lF = dnL; p.rF = dnR
            p.mouth = 1; p.anger = 1; p.glow = 1
            p.bob = -10 + sin(q * 70) * 1.4 * exp(-q * 14); p.lean = 0.5
        } else if t < 1.1 {                               // rise back up
            let u = easeInOut((t - 0.8) / 0.3)
            p.lF = lerp(dnL, outL, u); p.rF = lerp(dnR, outR, u)
            p.mouth = 1; p.anger = 1; p.glow = 1; p.bob = lerp(-10, 0, u); p.lean = lerp(0.5, 0, u)
        } else if t < 1.9 {                               // chest pounding
            let q = t - 1.1, k = Int(q / 0.2)
            let u = (q - Double(k) * 0.2) / 0.2, e = sin(u * .pi)
            let inL = V(x: -5, y: 41), inR = V(x: 5, y: 41)
            p.lF = k % 2 == 0 ? lerp(outL, inL, e) : outL
            p.rF = k % 2 == 1 ? lerp(outR, inR, e) : outR
            p.bob = -0.9 * e; p.mouth = 0.75 + 0.25 * sin(t * 26); p.anger = 1; p.glow = 1
        } else {                                          // settle
            let u = easeInOut((t - 1.9) / 0.2)
            p.lF = lerp(outL, rest.lF, u); p.rF = lerp(outR, rest.rF, u)
            p.mouth = lerp(1, 0, u); p.anger = lerp(1, rest.anger, u); p.glow = lerp(1, 0, u)
        }
        return p
    }

    // MARK: impact FX
    func impact(_ s: Smash) {
        s.impacted = true
        for sy in 0..<14 { for sx in 0..<14 {
            let col = s.sprite[sy * 14 + sx]; if col == 0 { continue }
            let dx = Double(sx) - 6.5
            bits.append(Bit(x: CX - 7 + Double(sx), y: 2 + Double(13 - sy) * 0.3,
                            vx: dx * 4.2 + (rnd() - 0.5) * 9, vy: 34 + rnd() * 46 - abs(dx) * 0.8,
                            life: 1.0 + rnd() * 0.6, color: col, kind: 0))
        } }
        for i in 0..<14 {
            let dir: Double = i % 2 == 0 ? -1 : 1
            bits.append(Bit(x: CX + dir * (3 + rnd() * 7), y: 2, vx: dir * (16 + rnd() * 30), vy: 3 + rnd() * 10,
                            life: 0.5 + rnd() * 0.3, color: rgb(0xE3DED3), kind: 1))
        }
        for i in 0..<16 {
            let a = Double.pi * (0.04 + 0.92 * Double(i) / 15), sp = 80 + rnd() * 50
            bits.append(Bit(x: CX, y: 6, vx: cos(a) * sp, vy: sin(a) * sp * 0.8, life: 0.18 + rnd() * 0.08,
                            color: i % 2 == 0 ? rgb(0xFFE14A) : rgb(0xFFFFFF), kind: 2))
        }
        for _ in 0..<18 {
            bits.append(Bit(x: CX + (rnd() - 0.5) * 11, y: 4, vx: (rnd() - 0.5) * 80, vy: 38 + rnd() * 50,
                            life: 1.1 + rnd() * 0.5, color: rnd() < 0.5 ? rgb(0xFFFFFF) : rgb(0xE9E2CF), kind: 3))
        }
        let words = ["SMASH!", "CRUSH!", "BOOM!", "HULK!"]
        texts.append((time, words[wordIdx % words.count])); wordIdx += 1
        rings.append(time)
        shakeAmp = 3.0
        onImpact?()
    }

    // MARK: render
    func render(into c: Canvas, clear: Bool) {
        if clear { c.clear() }
        let p = cur
        let blink = time.truncatingRemainder(dividingBy: 4.3) < 0.13 && p.glow < 0.3
        drawLegs(c, p)
        drawTorso(c, p)
        drawHead(c, p, look: look, blink: blink)
        drawFiles(c)
        fistBottom = drawArms(c, p)
        drawFX(c)
    }

    func drawFiles(_ c: Canvas) {
        for s in smashes {
            let t = time - s.start
            if t < 0 || t >= 0.66 { continue }
            if t < 0.30 {
                let u = t / 0.30, e = easeOutCubic(u)
                c.sprite(s.sprite, n: 14, x: lerp(s.from.x - 7, CX - 7, e),
                         y: lerp(s.from.y - 7, 2, e) + 16 * sin(u * .pi), w: 14, h: 14)
            } else {
                var hgt = clamp(fistBottom - 2, 2, 14)
                if t >= 0.6 { hgt = 2 }
                let width = Int((14 * (1 + (14 - hgt) / 14 * 0.55)).rounded())
                c.sprite(s.sprite, n: 14, x: CX - Double(width) / 2, y: 2, w: width, h: Int(hgt.rounded()))
            }
        }
    }

    func drawFX(_ c: Canvas) {
        for t0 in rings {
            let a = time - t0; if a < 0 || a > 0.35 { continue }
            let rad = 4 + a / 0.35 * 40
            for k in 0..<160 {
                let th = Double(k) / 160 * 2 * .pi
                let x = Int((CX + cos(th) * rad).rounded()), y = Int((2 + sin(th) * rad * 0.22).rounded())
                if a > 0.2 && (x + y) & 1 == 1 { continue }
                c.put(x, y, rgb(0xFFF0B8))
            }
        }
        for b in bits {
            let fade = b.life - b.age < 0.3 || (b.kind == 1 && b.age > b.life * 0.45)
            let x = Int(b.x.rounded()), y = Int(b.y.rounded())
            switch b.kind {
            case 0: if !(fade && (x + y) & 1 == 1) { c.put(x, y, b.color) }
            case 3: if !(fade && (x + y) & 1 == 1) { c.put(x, y, b.color); c.put(x + 1, y, b.color) }
            case 1: c.flatDisc(b.x, b.y, min(3.6, 1.2 + b.age * 5), b.color, dither: fade)
            default:
                c.put(x, y, b.color)
                c.put(Int((b.x - b.vx * 0.025).rounded()), Int((b.y - b.vy * 0.025).rounded()), b.color)
            }
        }
        for t in texts {
            let a = time - t.t0
            let ty = 79 + Int(min(a * 20, 6))
            if a < 0.45 {
                let r = 14 + easeOutCubic(a / 0.45) * 22
                drawBurst(c, cx: CX, cy: Double(ty) + 7, r: r, spikes: 11, phase: time * 5,
                          col: a < 0.2 ? rgb(0xFFF6C8) : rgb(0xFFD93B), dither: true)
            }
            drawWord(c, t.word, cx: CX, y: ty, scale: a < 0.07 ? 3 : 2, fade: a > 0.6,
                     jitter: a < 0.25 ? 1.2 : 0, time: time)
        }
        if hover > 0.75 && smashes.isEmpty && bits.isEmpty {
            let lift = Int((sin(time * 5) * 1.0).rounded())
            drawBubble(c, ["GIVE ME", "SOMETHING", "TO SMASH!"], cx: CX, bottomY: 76 + lift, scale: 2)
        }
    }
}

// MARK: - Sprites from file icons

func makeSprite(_ img: NSImage, n: Int = 14) -> [UInt32] {
    var buf = [UInt8](repeating: 0, count: n * n * 4)
    buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: n, height: n), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }
    var out = [UInt32](repeating: 0, count: n * n)
    for i in 0..<(n * n) {
        let a = Int(buf[i * 4 + 3]); if a < 110 { continue }
        let r = min(255, Int(buf[i * 4]) * 255 / a), g = min(255, Int(buf[i * 4 + 1]) * 255 / a), b = min(255, Int(buf[i * 4 + 2]) * 255 / a)
        out[i] = 0xFF00_0000 | UInt32(b << 16) | UInt32(g << 8) | UInt32(r)
    }
    return out
}

func fakeDocSprite() -> [UInt32] {
    var s = [UInt32](repeating: 0, count: 14 * 14)
    for y in 0..<14 { for x in 0..<14 {
        var col = rgb(0xFAFAFA)
        if x == 0 || x == 13 || y == 0 || y == 13 { col = rgb(0x8A8F98) }
        else if [4, 6, 8, 10].contains(y) && (3...10).contains(x) { col = rgb(0x4C8DF6) }
        if x >= 10 && y <= 3 && x - 10 >= y { s[y * 14 + x] = 0; continue }
        s[y * 14 + x] = col
    } }
    return s
}

// MARK: - Sound (synthesised thump)

func makeThump() -> Data {
    let sr = 44100, n = Int(0.55 * Double(sr))
    var pcm = [Int16](); pcm.reserveCapacity(n)
    var ph = 0.0, lp = 0.0, seed: UInt32 = 12345
    for i in 0..<n {
        let t = Double(i) / Double(sr)
        ph += 2 * .pi * (42 + 70 * exp(-t * 18)) / Double(sr)
        seed = seed &* 1664525 &+ 1013904223
        let nz = Double(seed >> 8) / Double(1 << 24) * 2 - 1
        lp += (nz - lp) * 0.18
        let s = sin(ph) * exp(-t * 6.5) * 0.9 + lp * exp(-t * 38) * 0.7
        pcm.append(Int16(max(-1, min(1, s)) * 30000))
    }
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count * 2))
    d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(44100); u32(88200); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count * 2))
    pcm.withUnsafeBytes { d.append(contentsOf: $0) }
    return d
}

// MARK: - Dock tracking (Accessibility API)

final class DockWatcher {
    var el: AXUIElement?
    func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
    func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
        if let s = attr(e, "AXSubrole") as? String, s == "AXTrashDockItem" { return e }
        guard depth < 4, let kids = attr(e, "AXChildren") as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, depth + 1) { return f } }
        return nil
    }
    /// Trash tile in Cocoa screen coordinates (origin bottom-left).
    func trashFrame() -> CGRect? {
        if el == nil {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
            el = find(AXUIElementCreateApplication(app.processIdentifier), 0)
        }
        guard let e = el, let pv = attr(e, "AXPosition"), let sv = attr(e, "AXSize") else { el = nil; return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        let ph = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: ph - p.y - s.height, width: s.width, height: s.height)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let scene = HulkScene()
    let canvas = Canvas(ART_W, ART_H)
    let dock = DockWatcher()
    var window: NSWindow!
    var imageLayer = CALayer()
    var trash: CGRect?
    var scale: Double = 1.5
    var sizePct = UserDefaults.standard.object(forKey: "sizePct") as? Double ?? 1.0
    var nudge = UserDefaults.standard.integer(forKey: "nudge")
    var lastTick = CACurrentMediaTime()
    var tickCount = 0
    var statusItem: NSStatusItem!
    var soundOn = true
    var players: [AVAudioPlayer] = []
    let thump = makeThump()

    var lastChecked = NSPasteboard(name: .drag).changeCount
    var seenDrag = NSPasteboard(name: .drag).changeCount
    var dragActive = false
    var dragURLs: [URL] = []
    var dragSprites: [[UInt32]] = []
    var pendingDropUntil = 0.0
    var lastSmashWall = 0.0
    var knownTrash: Set<String>?
    var trashReadable = false

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        // Without Accessibility there is no Dock tile to find, so the window stays hidden and the
        // app looks like it never launched. Say so out loud instead of failing silently.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.warnIfUntrusted() }

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ART_W * 3, height: ART_H * 3),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let host = NSView(frame: window.contentRect(forFrameRect: window.frame))
        host.wantsLayer = true
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .nearest
        host.layer?.addSublayer(imageLayer)
        window.contentView = host

        scene.onImpact = { [weak self] in self?.playThump() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let head = Canvas(22, 22); head.ox = 11 - Int(CX); head.oy = -46
        drawHead(head, Pose(anger: 0.9), look: V(x: 0, y: 0), blink: false)
        let icon = NSImage(cgImage: head.cgImage(scale: 2), size: NSSize(width: 18, height: 18))
        statusItem.button?.image = icon
        let menu = NSMenu(); menu.delegate = self
        statusItem.menu = menu

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.mouseEvent(e)
        }
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.pollTrash() }
        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        refreshDock()
    }

    // MARK: frame loop
    @objc func tick() {
        tickCount += 1
        let idle = !scene.busy && !dragActive && scene.hover < 0.01
        if idle && tickCount % 2 == 1 { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.1); lastTick = now
        if tickCount % 3 == 0 { refreshDock() }

        let m = NSEvent.mouseLocation
        let origin = window.frame.origin
        let mouse = V(x: Double(m.x - origin.x) / scale, y: Double(m.y - origin.y) / scale)
        var h = 0.0
        if let r = trash {
            if dragActive {
                let dist = hypot(m.x - r.midX, m.y - (r.minY + CGFloat(25 * scale)))
                h = clamp((300 - Double(dist)) / 220)
            } else {
                // the whole figure is a hover target, not just the tile he stands on
                let fw = CGFloat(62 * scale), fh = CGFloat(72 * scale)
                let body = CGRect(x: r.midX - fw / 2, y: r.minY - 6, width: fw, height: fh)
                if body.contains(m) { h = 1 }
            }
        }
        scene.update(dt, mouse: mouse, hoverTarget: h)
        scene.render(into: canvas, clear: true)

        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.contents = canvas.cgImage()
        imageLayer.frame = CGRect(x: scene.shake.x * scale, y: scene.shake.y * scale,
                                  width: Double(ART_W) * scale, height: Double(ART_H) * scale)
        CATransaction.commit()

        let want = trash != nil
        if want && !window.isVisible { window.orderFrontRegardless() }
        if !want && window.isVisible && !scene.busy { window.orderOut(nil) }
    }

    func refreshDock() {
        guard AXIsProcessTrusted() else { trash = nil; return }
        if let r = dock.trashFrame(), r.width > 16, r.width < 260,
           NSScreen.screens.contains(where: { $0.frame.contains(r) }) {
            trash = r
            // Scale from the Dock's configured tile size, never the live AX width — with Dock
            // magnification on, the tile balloons under the cursor and the Hulk would grow with it.
            let configured = UserDefaults(suiteName: "com.apple.dock")?.double(forKey: "tilesize") ?? 0
            let baseW = configured > 8 ? configured : Double(r.width)
            scale = max(0.6, baseW / 40.0 * sizePct)
            let wpx = CGFloat(Double(ART_W) * scale), hpx = CGFloat(Double(ART_H) * scale)
            let frame = NSRect(x: r.midX - wpx / 2, y: r.minY + CGFloat(Double(nudge) * scale), width: wpx, height: hpx)
            if window.frame != frame { window.setFrame(frame, display: false) }
        } else {
            trash = nil
        }
    }

    // MARK: drag & drop detection
    func mouseEvent(_ e: NSEvent) {
        let pb = NSPasteboard(name: .drag)
        if e.type == .leftMouseDragged {
            guard !dragActive, pb.changeCount != lastChecked, pb.changeCount != seenDrag else { return }
            lastChecked = pb.changeCount
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                dragURLs = urls
                dragSprites = urls.prefix(5).map { makeSprite(NSWorkspace.shared.icon(forFile: $0.path)) }
                dragActive = true
            }
        } else {
            seenDrag = pb.changeCount
            let loc = NSEvent.mouseLocation
            if dragActive, let r = trash, r.insetBy(dx: -14, dy: -14).contains(loc) {
                let urls = dragURLs, sprites = dragSprites
                pendingDropUntil = CACurrentMediaTime() + 1.6
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.finishDrop(urls, sprites, loc)
                }
            }
            dragActive = false; dragURLs = []; dragSprites = []
        }
    }

    func finishDrop(_ urls: [URL], _ sprites: [[UInt32]], _ loc: CGPoint) {
        // a drop on the Trash tile only counts if the files actually left their folder
        let gone = urls.indices.filter { !FileManager.default.fileExists(atPath: urls[$0].path) }
        guard !gone.isEmpty else { return }
        let o = window.frame.origin
        startSmash(gone.prefix(5).map { sprites[$0] },
                   from: V(x: Double(loc.x - o.x) / scale, y: Double(loc.y - o.y) / scale))
    }

    /// ⌘⌫ in Finder: needs Full Disk Access to peek into ~/.Trash; silently disabled otherwise.
    func pollTrash() {
        let dir = NSHomeDirectory() + "/.Trash"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { trashReadable = false; return }
        trashReadable = true
        let set = Set(names)
        defer { knownTrash = set }
        guard let old = knownTrash else { return }
        let new = set.subtracting(old).filter { !$0.hasPrefix(".") }.sorted()
        let now = CACurrentMediaTime()
        if new.isEmpty || now < pendingDropUntil || now - lastSmashWall < 1.5 { return }
        let sprites = new.prefix(5).map { makeSprite(NSWorkspace.shared.icon(forFile: dir + "/" + $0)) }
        startSmash(sprites, from: V(x: 26, y: 70))
    }

    func startSmash(_ sprites: [[UInt32]], from: V) {
        guard trash != nil else { return }
        lastSmashWall = CACurrentMediaTime()
        scene.smash(sprites: sprites, from: from)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func playThump() {
        guard soundOn, let p = try? AVAudioPlayer(data: thump) else { return }
        players.removeAll { !$0.isPlaying }
        p.volume = 0.9; p.play(); players.append(p)
    }

    // MARK: menu
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector?, on: Bool = false, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: enabled ? sel : nil, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off; menu.addItem(i)
        }
        add("Smash test", #selector(testSmash))
        add("Combo ×3", #selector(testCombo))
        menu.addItem(.separator())
        if AXIsProcessTrusted() {
            add(trash != nil ? "Dock: Trash tile found ✓" : "Dock: Trash tile not visible", nil, enabled: false)
        } else {
            add("⚠︎ Grant Accessibility access…", #selector(openAX))
        }
        add(trashReadable ? "⌘⌫ detection on ✓" : "⌘⌫ detection off (needs Full Disk Access)", #selector(openFDA), enabled: !trashReadable)
        menu.addItem(.separator())
        add("Hulk sound", #selector(toggleSound), on: soundOn)
        add("Bigger", #selector(bigger))
        add("Smaller", #selector(smaller))
        add("Reset size", #selector(resetSize))
        add("Nudge Hulk up", #selector(nudgeUp))
        add("Nudge Hulk down", #selector(nudgeDown))
        menu.addItem(.separator())
        add("Quit", #selector(quit))
    }
    @objc func testSmash() { startSmash([makeSprite(NSWorkspace.shared.icon(for: .plainText))], from: V(x: 28, y: 56)) }
    @objc func testCombo() {
        let ic = [UTType.plainText, .pdf, .png].map { makeSprite(NSWorkspace.shared.icon(for: $0)) }
        startSmash(ic, from: V(x: 28, y: 56))
    }
    /// Shown when the Accessibility grant is missing — most often because a rebuild changed the
    /// app's ad-hoc signature, which invalidates the old grant while leaving the entry in place.
    /// macOS then refuses to re-prompt, so the stale entry has to be removed by hand.
    func warnIfUntrusted() {
        guard !AXIsProcessTrusted() else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "HulkBin needs Accessibility access"
        a.informativeText = """
        It uses it only to locate the Trash tile in your Dock. Without it there is nothing to stand on,         so the Hulk stays hidden.

        If HulkBin is ALREADY listed under Accessibility, select it and remove it with the – button         first, then relaunch. Rebuilding the app changes its signature, and macOS will not honour the         old entry or ask you again.
        """
        a.addButton(withTitle: "Open Accessibility Settings")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { openAX() }
    }

    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openFDA() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
    @objc func toggleSound() { soundOn.toggle() }
    func setSize(_ v: Double) {
        sizePct = min(2.0, max(0.5, v))
        UserDefaults.standard.set(sizePct, forKey: "sizePct")
        refreshDock()
    }
    @objc func bigger() { setSize(sizePct + 0.1) }
    @objc func smaller() { setSize(sizePct - 0.1) }
    @objc func resetSize() { setSize(1.0) }
    @objc func nudgeUp() { nudge += 1; UserDefaults.standard.set(nudge, forKey: "nudge") }
    @objc func nudgeDown() { nudge -= 1; UserDefaults.standard.set(nudge, forKey: "nudge") }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Preview (contact sheet of key frames, no window needed)

func runPreview(_ path: String) {
    let sc = HulkScene()
    let cv = Canvas(ART_W, ART_H)
    var tiles: [CGImage] = []
    var hoverTarget = 0.0
    let mouse = V(x: 110, y: 50)

    func step(to t: Double) { while sc.time < t { sc.update(1.0 / 60, mouse: mouse, hoverTarget: hoverTarget) } }
    func snap() {
        cv.clear(); cv.ox = 0; cv.oy = 0
        for y in 0..<ART_H { for x in 0..<ART_W {
            let g = UInt32(0x30 + y / 4)
            cv.px[(ART_H - 1 - y) * ART_W + x] = rgb((g - 8) << 16 | g << 8 | (g + 40))
        } }
        // mock Dock shelf with a neighbouring icon and the Trash tile the Hulk stands over
        cv.rect(0, 0, ART_W, 2, rgb(0x8A92A3)); cv.rect(0, 1, ART_W, 1, rgb(0xB6BDCB))
        cv.rrect(CX - 48, 2, CX - 24, 26, 3, Style(fill: rgb(0x3D7BD6), shadow: rgb(0x2A57A0), edge: rgb(0x16315E)))
        let binS = Style(fill: rgb(0xC9CCD2), shadow: rgb(0x9A9EA8), light: rgb(0xE6E8EC), edge: rgb(0x6B707B))
        cv.shape(CX - 12, 2, CX + 12, 25, binS, sd: 2) { x, y in
            if y > 23 { return false }
            return abs(x - CX) <= lerp(8.5, 10.5, clamp((y - 2) / 21))
        }
        cv.rrect(CX - 11.5, 23, CX + 11.5, 25.5, 1.2, binS)
        sc.render(into: cv, clear: false)
        tiles.append(cv.cgImage())
    }

    step(to: 0.5); snap()                         // idle
    hoverTarget = 1; step(to: 1.4); snap()        // file dragged near
    hoverTarget = 0; step(to: 3.0)
    let t0 = sc.time + 0.02
    sc.smash(sprites: [fakeDocSprite()], from: V(x: 16, y: 56))
    for tau in [0.15, 0.30, 0.45, 0.55, 0.62, 0.70, 0.90, 1.20, 1.50, 2.40] { step(to: t0 + tau); snap() }

    let cols = 4, rows = (tiles.count + cols - 1) / cols, sc3 = 3
    let tw = ART_W * sc3, th = ART_H * sc3
    let ctx = CGContext(data: nil, width: cols * tw, height: rows * th, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    for (i, img) in tiles.enumerated() {
        ctx.draw(img, in: CGRect(x: (i % cols) * tw, y: (rows - 1 - i / cols) * th, width: tw, height: th))
    }
    let url = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(path)")
}

// MARK: - main

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--preview") {
    runPreview(i + 1 < args.count ? args[i + 1] : "preview.png")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
