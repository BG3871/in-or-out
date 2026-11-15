import Foundation

/// Rebond estimé, avec les mêmes champs que juge_ligne.py.
public struct Rebond: Sendable {
    public var t: Double          // instant du contact (s)
    public var x: Double, y: Double, r: Double
    public var nb: Int, na: Int   // positions suivies avant / après (fenêtre de 25 images)
    public var vxb: Double, vxa: Double  // vitesse latérale avant / après (px/s)
    public var dt: Double         // durée d'une image autour du rebond
    public var ext: Double        // écart entre le contact et la position vue la plus proche (s)
    public var imageRebond: Int   // image réelle la plus proche
    public var xi: Double, yi: Double
    public var dxb: Double, dxa: Double
    public var pixJaunes: Int?
}

enum Rebonds {
    /// Teste si l'indice k de la trajectoire est un rebond (port direct de bounces()).
    static func examiner(_ t: [Detection], _ k: Int) -> Rebond? {
        let n = t.count
        guard k >= 2, k < n - 2 else { return nil }
        let fk = t[k].image
        let yk = t[k].y
        // point le plus bas (y max) dans ±25 images
        var ymax = -Double.infinity
        var bef: [Detection] = [], aft: [Detection] = []
        for p in t {
            let df = p.image - fk
            if abs(df) <= 25 { ymax = max(ymax, p.y) }
            if df < 0 && df >= -25 { bef.append(p) }
            if df > 0 && df <= 25 { aft.append(p) }
        }
        if yk < ymax { return nil }
        if bef.count < 3 || aft.count < 3 { return nil }
        if yk - bef.map(\.y).min()! < 4 || yk - aft.map(\.y).min()! < 4 { return nil }
        if Maths.polyfit(bef.map { Double($0.image) }, bef.map(\.y), 1)[0] <= 0 { return nil }
        if Maths.polyfit(aft.map { Double($0.image) }, aft.map(\.y), 1)[0] >= 0 { return nil }
        let rs = t[max(0, k - 5)..<min(n, k + 6)].map { ($0.aire / Double.pi).squareRoot() }
        let r = Maths.median(rs)

        let t0 = t[k].temps
        let tt = t.map { $0.temps - t0 }
        var ib = (0..<n).filter { t[$0].image <= fk && t[$0].image >= fk - 30 }.suffix(10).map { $0 }
        var ia = Array((0..<n).filter { t[$0].image >= fk && t[$0].image <= fk + 30 }.prefix(10))
        let gb = tt[k] - tt[k - 1]
        let ga = tt[k + 1] - tt[k]
        if max(gb, ga) > 2.5 * min(gb, ga) {
            if ga > gb { ia.removeAll { $0 == k } } else { ib.removeAll { $0 == k } }
        }
        var tc = 0.0, xc = t[k].x, yc = t[k].y, vxb = 0.0, vxa = 0.0
        if ib.count >= 3 && ia.count >= 3 {
            let pyb = Maths.polyfit(ib.map { tt[$0] }, ib.map { t[$0].y }, ib.count >= 5 ? 2 : 1)
            let pya = Maths.polyfit(ia.map { tt[$0] }, ia.map { t[$0].y }, ia.count >= 5 ? 2 : 1)
            let pxb = Maths.polyfit(ib.map { tt[$0] }, ib.map { t[$0].x }, 1)
            let pxa = Maths.polyfit(ia.map { tt[$0] }, ia.map { t[$0].x }, 1)
            vxb = pxb[0]; vxa = pxa[0]
            let lo = tt[k - 1], hi = tt[k + 1]
            let db = Maths.polyder(pyb), da = Maths.polyder(pya)
            let roots = Maths.realRoots(Maths.polysub(pyb, pya)).filter {
                lo - 0.004 <= $0 && $0 <= hi + 0.004 && Maths.polyval(db, $0) > 0 && 0 > Maths.polyval(da, $0)
            }
            if let best = roots.min(by: { abs($0) < abs($1) }) {
                tc = best
                xc = (Maths.polyval(pxb, tc) + Maths.polyval(pxa, tc)) / 2
                yc = Maths.polyval(pyb, tc)
            }
        }
        let win = tt[max(0, k - 12)..<min(n, k + 13)]
        let diffs = zip(win.dropFirst(), win).map { $0 - $1 }
        let dt = diffs.isEmpty ? 1.0 / 240 : Maths.median(Array(diffs))
        let ext = tt.map { abs($0 - tc) }.min()!
        return Rebond(t: t0 + tc, x: xc, y: yc, r: r, nb: bef.count, na: aft.count, vxb: vxb, vxa: vxa, dt: dt, ext: ext,
                      imageRebond: fk, xi: t[k].x, yi: t[k].y,
                      dxb: t[k].x - bef[0].x, dxa: aft[aft.count - 1].x - t[k].x, pixJaunes: t[k].pixJaunes)
    }

    /// Tous les rebonds d'une trajectoire complète (hors ligne), dans l'ordre.
    static func tous(_ t: [Detection]) -> [Rebond] {
        var out: [Rebond] = []
        guard t.count >= 5 else { return out }
        for k in 2..<(t.count - 2) {
            guard let b = examiner(t, k) else { continue }
            if let last = out.last, b.imageRebond - last.imageRebond <= 6 { continue }
            out.append(b)
        }
        return out
    }
}
