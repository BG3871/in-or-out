import Foundation

/// Orientation entre l'image brute de la caméra et l'image en portrait où l'on juge.
public enum Orientation: Sendable {
    /// L'image brute est déjà en portrait.
    case identite
    /// L'image brute est en paysage (capteur de l'iPhone, ou vidéo .MOV tournée de 90°) :
    /// portrait (xp, yp) = (hauteurBrute − 1 − yb, xb).
    case paysageVersPortrait
}

/// Image BGRA brute (format des tampons de la caméra), lue sans copie.
public struct ImageBGRA {
    public let base: UnsafePointer<UInt8>
    public let largeur: Int
    public let hauteur: Int
    public let octetsParLigne: Int
    public init(base: UnsafePointer<UInt8>, largeur: Int, hauteur: Int, octetsParLigne: Int) {
        self.base = base; self.largeur = largeur; self.hauteur = hauteur; self.octetsParLigne = octetsParLigne
    }
}

/// Détecteur de balle, port de detect_chunk() de juge_ligne.py : une balle est une tache jaune
/// qui bouge (différence d'image > 18 sur le gris lissé), de 10 à 1500 px, au plus 60 × 60 px et pas
/// trop allongée. Il ne travaille que dans la zone autour de la ligne, ce qui le rend assez rapide
/// pour 240 images par seconde.
public final class DetecteurBalle {
    public let zonePortrait: ZoneImage
    public let orientation: Orientation
    /// Rectangle analysé dans l'image brute.
    public let x0: Int, y0: Int, w: Int, h: Int
    let largeurBrute: Int, hauteurBrute: Int

    private var gris: [Int16]
    private var precedent: [Int16]
    private var aUnPrecedent = false
    private var brut: [Int32]
    private var horiz: [Int32]
    private var mouvement: [UInt8]
    /// 1 = jaune, 2 = ajouté par la dilatation ; 4 = dans la fermeture ; 8 = déjà étiqueté
    private var drapeaux: [UInt8]
    private var touches: [Int32] = []
    private var jaunes: [Int32] = []
    private var pile: [Int32] = []

    public init(zonePortrait z: ZoneImage, orientation: Orientation, largeurBrute: Int, hauteurBrute: Int) {
        zonePortrait = z
        self.orientation = orientation
        self.largeurBrute = largeurBrute
        self.hauteurBrute = hauteurBrute
        switch orientation {
        case .identite:
            x0 = z.x; y0 = z.y; w = z.largeur; h = z.hauteur
        case .paysageVersPortrait:
            // xb = yp ; yb = H − 1 − xp
            x0 = z.y; w = z.hauteur
            y0 = hauteurBrute - z.x - z.largeur; h = z.largeur
        }
        let n = w * h
        gris = [Int16](repeating: 0, count: n)
        precedent = gris
        brut = [Int32](repeating: 0, count: n)
        horiz = brut
        mouvement = [UInt8](repeating: 0, count: n)
        drapeaux = mouvement
    }

    /// Passage des coordonnées brutes (dans le rectangle) vers le portrait.
    @inline(__always)
    func versPortrait(_ bx: Double, _ by: Double) -> (Double, Double) {
        switch orientation {
        case .identite: return (bx + Double(x0), by + Double(y0))
        case .paysageVersPortrait: return (Double(hauteurBrute - 1) - (by + Double(y0)), bx + Double(x0))
        }
    }

    public func reinitialiser() { aUnPrecedent = false }

    /// Analyse une image. `numero` et `temps` sont recopiés dans les détections.
    public func analyser(_ img: ImageBGRA, numero: Int, temps: Double) -> [Detection] {
        precondition(img.largeur == largeurBrute && img.hauteur == hauteurBrute)
        let w = self.w, h = self.h, n = w * h
        let x0 = self.x0, y0 = self.y0, bpr = img.octetsParLigne, base = img.base
        var nMouv = 0
        let premier = !aUnPrecedent
        jaunes.removeAll(keepingCapacity: true)
        brut.withUnsafeMutableBufferPointer { t in
        horiz.withUnsafeMutableBufferPointer { hz in
        gris.withUnsafeMutableBufferPointer { g in
        precedent.withUnsafeBufferPointer { pr in
        mouvement.withUnsafeMutableBufferPointer { mv in
            // 1. gris (formule d'OpenCV) et repérage des pixels jaunes (mêmes rapports que le script)
            for y in 0..<h {
                let row = base + (y0 + y) * bpr + x0 * 4
                let o = y * w
                for x in 0..<w {
                    let p = row + x &* 4
                    let B = Int32(p[0]), G = Int32(p[1]), R = Int32(p[2])
                    t[o + x] = (R &* 4899 &+ G &* 9617 &+ B &* 1868 &+ 8192) >> 14
                    if G > 100 && B &* 100 < 62 &* G && R &* 100 > 85 &* G && R &* 100 < 130 &* G {
                        jaunes.append(Int32(o + x))
                    }
                }
            }
            // 2. flou gaussien 3×3 ([1 2 1] ⊗ [1 2 1] / 16), bords réfléchis comme cv2.GaussianBlur
            for y in 0..<h {
                let o = y * w
                hz[o] = 2 * t[o] + 2 * t[o + 1]
                for x in 1..<(w - 1) { hz[o + x] = t[o + x - 1] &+ 2 &* t[o + x] &+ t[o + x + 1] }
                hz[o + w - 1] = 2 * t[o + w - 1] + 2 * t[o + w - 2]
            }
            for y in 0..<h {
                let a = (y == 0 ? 1 : y - 1) * w, b = y * w, c = (y == h - 1 ? h - 2 : y + 1) * w
                for x in 0..<w {
                    let v = Int16((hz[a + x] &+ 2 &* hz[b + x] &+ hz[c + x] &+ 8) >> 4)
                    g[b + x] = v
                    if !premier {
                        let m: UInt8 = abs(Int32(v) - Int32(pr[b + x])) > 18 ? 1 : 0
                        mv[b + x] = m
                        nMouv &+= Int(m)
                    }
                }
            }
        }}}}}
        swap(&gris, &precedent)
        aUnPrecedent = true
        guard !premier, nMouv > 20, !jaunes.isEmpty else { return [] }

        // 3. fermeture 3×3 du masque jaune (dilatation puis érosion), calculée seulement autour des
        //    pixels jaunes : identique à cv2.morphologyEx(MORPH_CLOSE) mais bien plus rapide.
        var out: [Detection] = []
        drapeaux.withUnsafeMutableBufferPointer { f in
            touches.removeAll(keepingCapacity: true)
            for q in jaunes { f[Int(q)] = 1; touches.append(q) }
            for q in jaunes {
                let i = Int(q), x = i % w, y = i / w
                for dy in -1...1 where y + dy >= 0 && y + dy < h {
                    for dx in -1...1 where x + dx >= 0 && x + dx < w {
                        let j = (y + dy) * w + x + dx
                        if f[j] == 0 { f[j] = 2; touches.append(Int32(j)) }
                    }
                }
            }
            // érosion : un pixel dilaté reste si tous ses voisins (dans l'image) sont dilatés
            for q in touches {
                let i = Int(q), x = i % w, y = i / w
                var garde = true
                for dy in -1...1 where garde && y + dy >= 0 && y + dy < h {
                    for dx in -1...1 where x + dx >= 0 && x + dx < w {
                        if f[(y + dy) * w + x + dx] & 3 == 0 { garde = false; break }
                    }
                }
                if garde { f[i] |= 4 }
            }
            // 4. composantes connexes (8-voisinage) de la fermeture, gardées si elles touchent le mouvement
            for q in touches where f[Int(q)] & 4 != 0 && f[Int(q)] & 8 == 0 {
                f[Int(q)] |= 8
                pile.removeAll(keepingCapacity: true)
                pile.append(q)
                var aire = 0, sx = 0, sy = 0, minx = Int.max, maxx = -1, miny = Int.max, maxy = -1
                var bouge = false
                while let p = pile.popLast() {
                    let i = Int(p), x = i % w, y = i / w
                    aire += 1; sx += x; sy += y
                    minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
                    if mouvement[i] != 0 { bouge = true }
                    for dy in -1...1 where y + dy >= 0 && y + dy < h {
                        for dx in -1...1 where x + dx >= 0 && x + dx < w && (dx != 0 || dy != 0) {
                            let j = (y + dy) * w + x + dx
                            if f[j] & 4 != 0 && f[j] & 8 == 0 { f[j] |= 8; pile.append(Int32(j)) }
                        }
                    }
                }
                let bw = maxx - minx + 1, bh = maxy - miny + 1
                guard bouge, aire >= 10, aire <= 1500, bw <= 60, bh <= 60, max(bw, bh) * 2 <= 7 * min(bw, bh) else { continue }
                let cx = Double(sx) / Double(aire), cy = Double(sy) / Double(aire)
                let (px, py) = versPortrait(cx, cy)
                let r = (Double(aire) / Double.pi).squareRoot()
                out.append(Detection(image: numero, temps: temps, x: px, y: py, aire: Double(aire),
                                     pixJaunes: pixelsJauneVif(img, Int((cx + Double(x0)).rounded()),
                                                               Int((cy + Double(y0)).rounded()), Int(r.rounded()) + 2)))
            }
            for q in touches { f[Int(q)] = 0 }
        }
        _ = n
        return out
    }

    /// Contrôle couleur de juge_ligne.py : pixels jaune vif (HSV d'OpenCV : 20 ≤ H ≤ 45, S ≥ 110, V ≥ 160)
    /// dans le carré autour de la balle. Écarte les chaussures beiges et objets jaunâtres ternes.
    func pixelsJauneVif(_ img: ImageBGRA, _ x: Int, _ y: Int, _ r: Int) -> Int {
        var n = 0
        for yy in max(0, y - r)...min(img.hauteur - 1, y + r) {
            let row = img.base + yy * img.octetsParLigne
            for xx in max(0, x - r)...min(img.largeur - 1, x + r) {
                let p = row + xx * 4
                if CouleurHSV.jauneVif(b: p[0], g: p[1], r: p[2]) { n += 1 }
            }
        }
        return n
    }
}

public enum CouleurHSV {
    /// HSV 8 bits d'OpenCV : H dans 0…180, S et V dans 0…255.
    public static func hsv(b: UInt8, g: UInt8, r: UInt8) -> (h: Int, s: Int, v: Int) {
        let B = Int(b), G = Int(g), R = Int(r)
        let v = max(R, G, B), mn = min(R, G, B), d = v - mn
        let s = v == 0 ? 0 : (d * 255 + v / 2) / v
        if d == 0 { return (0, s, v) }
        var hDeg: Double
        if v == R { hDeg = 60 * Double(G - B) / Double(d) }
        else if v == G { hDeg = 120 + 60 * Double(B - R) / Double(d) }
        else { hDeg = 240 + 60 * Double(R - G) / Double(d) }
        if hDeg < 0 { hDeg += 360 }
        return (Int((hDeg / 2).rounded()), s, v)
    }

    @inline(__always)
    public static func jauneVif(b: UInt8, g: UInt8, r: UInt8) -> Bool {
        let (h, s, v) = hsv(b: b, g: g, r: r)
        return h >= 20 && h <= 45 && s >= 110 && v >= 160
    }
}
