import Foundation

/// Image en niveaux de gris (ou saturation) en portrait, 8 bits.
public struct Plan8: Sendable {
    public var largeur: Int
    public var hauteur: Int
    public var pixels: [UInt8]
    public init(largeur: Int, hauteur: Int, pixels: [UInt8]) {
        self.largeur = largeur; self.hauteur = hauteur; self.pixels = pixels
    }
    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 { pixels[y * largeur + x] }
}

public enum ResultatCalibrage: Sendable {
    case ok(LigneAxe, qualite: String)
    /// La ligne n'est pas trouvée avec certitude : on s'arrête plutôt que de deviner.
    case echec(String)
}

/// Repérage précis des deux bords de la ligne dans l'axe, port de find_axis_line() de juge_ligne.py.
/// Au lieu de chercher la ligne dans toute l'image, on part de deux points touchés à l'écran
/// (bout proche et bout lointain), puis on mesure les bords ligne par ligne.
public enum Calibrage {
    /// Masque des pixels blancs : chapeau haut-de-forme 41×41 > 30 et saturation < 110,
    /// limité au rectangle utile (le reste vaut 0).
    static func masqueBlanc(gris: Plan8, sat: Plan8, xMin: Int, xMax: Int, yMin: Int, yMax: Int) -> [UInt8] {
        let W = gris.largeur, H = gris.hauteur
        let r = 20
        // rectangle de calcul élargi de r pour l'ouverture morphologique
        let ax = max(0, xMin - 2 * r), bx = min(W - 1, xMax + 2 * r)
        let ay = max(0, yMin - 2 * r), by = min(H - 1, yMax + 2 * r)
        let w = bx - ax + 1, h = by - ay + 1
        var src = [Int](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { src[y * w + x] = Int(gris[ax + x, ay + y]) } }
        func filtre(_ a: [Int], _ mini: Bool) -> [Int] {
            // filtre min (ou max) 41×41 séparable ; au bord de l'image, la fenêtre est tronquée
            // (équivalent au bord constant « neutre » d'OpenCV pour l'érosion et la dilatation)
            var t = [Int](repeating: 0, count: w * h), o = t
            for y in 0..<h {
                for x in 0..<w {
                    var v = mini ? Int.max : Int.min
                    for k in max(0, x - r)...min(w - 1, x + r) { v = mini ? min(v, a[y * w + k]) : max(v, a[y * w + k]) }
                    t[y * w + x] = v
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    var v = mini ? Int.max : Int.min
                    for k in max(0, y - r)...min(h - 1, y + r) { v = mini ? min(v, t[k * w + x]) : max(v, t[k * w + x]) }
                    o[y * w + x] = v
                }
            }
            return o
        }
        let ouverture = filtre(filtre(src, true), false)
        var m = [UInt8](repeating: 0, count: W * H)
        for y in max(yMin, H / 2)...yMax {
            for x in xMin...xMax {
                let th = src[(y - ay) * w + (x - ax)] - ouverture[(y - ay) * w + (x - ax)]
                if th > 30 && sat[x, y] < 110 { m[y * W + x] = 1 }
            }
        }
        return m
    }

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        // interpolation linéaire, comme np.percentile par défaut
        let s = v.sorted()
        let pos = q / 100 * Double(s.count - 1)
        let i = Int(pos.rounded(.down)), f = pos - Double(i)
        return i + 1 < s.count ? s[i] + f * (s[i + 1] - s[i]) : s[i]
    }

    static func ajustementRobuste(_ ys: [Double], _ xs: [Double]) -> ([Double], [Bool]) {
        let lo = percentile(ys, 25), hi = percentile(ys, 75)
        let q = ys.indices.filter { ys[$0] >= lo && ys[$0] <= hi }
        var p = Maths.polyfit(q.map { ys[$0] }, q.map { xs[$0] }, 1)
        var ok = [Bool](repeating: true, count: ys.count)
        for _ in 0..<3 {
            ok = ys.indices.map { abs(Maths.polyval(p, ys[$0]) - xs[$0]) <= 2 }
            let i = ys.indices.filter { ok[$0] }
            if i.count < 2 { break }
            p = Maths.polyfit(i.map { ys[$0] }, i.map { xs[$0] }, 1)
        }
        return (p, ok)
    }

    /// - Parameters:
    ///   - proche, lointain : points touchés sur la ligne (portrait), bout proche (bas) et bout lointain (haut).
    public static func reperer(gris: Plan8, sat: Plan8, proche: (Double, Double), lointain: (Double, Double),
                               coteFaute: CoteFaute) -> ResultatCalibrage {
        var (x1, y1) = proche, (x2, y2) = lointain
        if y1 < y2 { swap(&x1, &x2); swap(&y1, &y2) }
        let W = gris.largeur, H = gris.hauteur
        guard y1 - y2 > 60 else { return .echec("les deux points touchés sont trop proches") }
        let yA = max(0, Int(y2) - 30), yB = min(H - 1, Int(y1) + 30)
        let xMin = max(0, Int(min(x1, x2)) - 60), xMax = min(W - 1, Int(max(x1, x2)) + 60)
        let m = masqueBlanc(gris: gris, sat: sat, xMin: xMin, xMax: xMax, yMin: yA, yMax: yB)
        func interp(_ y: Double) -> Double {
            // np.interp(y, [y2, y1], [x2, x1]) : valeur bornée aux extrémités
            if y <= y2 { return x2 }
            if y >= y1 { return x1 }
            return x2 + (x1 - x2) * (y - y2) / (y1 - y2)
        }
        var rows: [Double] = [], lefts: [Double] = [], rights: [Double] = []
        for y in yA..<yB {
            let xc = Int(interp(Double(y)).rounded())
            let a0 = max(0, xc - 40), b0 = min(W, xc + 40)
            guard a0 < b0 else { continue }
            var best = -1, bd = Int.max
            for x in a0..<b0 where m[y * W + x] != 0 && abs(x - xc) < bd { bd = abs(x - xc); best = x }
            guard best >= 0 else { continue }
            var a = best, b = best
            while a - 1 >= a0 && m[y * W + a - 1] != 0 { a -= 1 }
            while b + 1 < b0 && m[y * W + b + 1] != 0 { b += 1 }
            rows.append(Double(y)); lefts.append(Double(a)); rights.append(Double(b))
        }
        guard rows.count >= 50 else { return .echec("ligne trop courte ou peu visible") }
        let w = zip(rights, lefts).map { $0 - $1 + 1 }
        let wmed = w.indices.map { i in Maths.median(Array(w[max(0, i - 15)..<min(w.count, i + 16)])) }
        let good = w.indices.filter { w[$0] <= 1.6 * wmed[$0] }   // écarte les croisements avec d'autres lignes
        guard good.count >= 10 else { return .echec("bords de ligne introuvables") }
        let (pl, _) = ajustementRobuste(good.map { rows[$0] }, good.map { lefts[$0] })
        let (pr, _) = ajustementRobuste(good.map { rows[$0] }, good.map { rights[$0] })
        var ys: [Double] = [], resid: [Double] = []
        for i in rows.indices {
            let fl = Maths.polyval(pl, rows[i]), fr = Maths.polyval(pr, rows[i])
            let wfit = fr - fl + 1
            if abs(lefts[i] - fl) <= 2 && abs(rights[i] - fr) <= 2 && abs(w[i] - wfit) <= max(2, 0.3 * wfit) {
                ys.append(rows[i]); resid.append(fl - lefts[i])
            }
        }
        guard !ys.isEmpty else { return .echec("bords de ligne irréguliers") }
        let res = (resid.map { $0 * $0 }.reduce(0, +) / Double(resid.count)).squareRoot()
        // plus long tronçon continu (trous ≤ 20 lignes tolérés)
        var parts: [[Double]] = [[ys[0]]]
        for y in ys.dropFirst() { if y - parts[parts.count - 1].last! > 20 { parts.append([y]) } else { parts[parts.count - 1].append(y) } }
        let part = parts.max { $0.count < $1.count }!
        let s0 = part.min()!, s1 = part.max()!
        let cover = Double(part.count) / max(1, s1 - s0 + 1)
        let qualite = "couverture \(Int((cover * 100).rounded())) %, écart \(String(format: "%.1f", res)) px"
        if cover < 0.6 || res > 1.5 { return .echec("détection peu nette (\(qualite))") }
        return .ok(LigneAxe(gauche: pl, droite: pr, y0: Int(s0), y1: Int(s1), coteFaute: coteFaute), qualite: qualite)
    }

    /// Le téléphone a-t-il bougé ? Décalage (px) du bord gauche au milieu de la ligne, nil si la ligne
    /// n'est plus retrouvée. Le script s'arrête au-delà de 4 px.
    public static func decalage(_ ligne: LigneAxe, gris: Plan8, sat: Plan8) -> Double? {
        let yA = Double(ligne.y0), yB = Double(ligne.y1)
        let centre = { (y: Double) -> Double in (Maths.polyval(ligne.gauche, y) + Maths.polyval(ligne.droite, y)) / 2 }
        guard case .ok(let l2, _) = reperer(gris: gris, sat: sat, proche: (centre(yB), yB), lointain: (centre(yA), yA),
                                            coteFaute: ligne.coteFaute) else { return nil }
        let ym = (yA + yB) / 2
        return abs(Maths.polyval(l2.gauche, ym) - Maths.polyval(ligne.gauche, ym))
    }
}
