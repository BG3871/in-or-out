import Foundation

public extension Plan8 {
    /// Gris et saturation (formules d'OpenCV) de toute l'image, remise en portrait.
    static func grisEtSaturation(_ img: ImageBGRA, orientation: Orientation) -> (gris: Plan8, sat: Plan8) {
        let (W, H): (Int, Int) = orientation == .identite ? (img.largeur, img.hauteur) : (img.hauteur, img.largeur)
        var g = [UInt8](repeating: 0, count: W * H), s = g
        for yb in 0..<img.hauteur {
            let row = img.base + yb * img.octetsParLigne
            for xb in 0..<img.largeur {
                let p = row + xb * 4
                let B = Int(p[0]), G = Int(p[1]), R = Int(p[2])
                let (xp, yp) = orientation == .identite ? (xb, yb) : (img.hauteur - 1 - yb, xb)
                let i = yp * W + xp
                g[i] = UInt8((R * 4899 + G * 9617 + B * 1868 + 8192) >> 14)
                let v = max(R, G, B), d = v - min(R, G, B)
                s[i] = v == 0 ? 0 : UInt8((d * 255 + v / 2) / v)
            }
        }
        return (Plan8(largeur: W, hauteur: H, pixels: g), Plan8(largeur: W, hauteur: H, pixels: s))
    }

    /// Médiane pixel par pixel de plusieurs images (fond sans joueurs ni balles), comme le script.
    static func mediane(_ plans: [Plan8]) -> Plan8 {
        precondition(!plans.isEmpty)
        let n = plans[0].pixels.count, k = plans.count
        var out = [UInt8](repeating: 0, count: n)
        var v = [UInt8](repeating: 0, count: k)
        for i in 0..<n {
            for j in 0..<k { v[j] = plans[j].pixels[i] }
            v.sort()
            out[i] = k % 2 == 1 ? v[k / 2] : UInt8((Int(v[k / 2 - 1]) + Int(v[k / 2])) / 2)
        }
        return Plan8(largeur: plans[0].largeur, hauteur: plans[0].hauteur, pixels: out)
    }
}
