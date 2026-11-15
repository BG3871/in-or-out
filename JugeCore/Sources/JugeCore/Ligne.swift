import Foundation

/// Côté de la ligne où la balle est faute, dans l'image en portrait (x vers la droite).
public enum CoteFaute: String, Codable, Sendable {
    case gauche, droite
}

/// Ligne dans l'axe du téléphone, dans l'image en portrait (1080 × 1920 en 240 i/s).
/// Chaque bord est une droite x = a·y + b, valable de y0 (bout lointain) à y1 (bout proche).
public struct LigneAxe: Codable, Equatable, Sendable {
    public var gauche: [Double]   // [a, b] du bord gauche
    public var droite: [Double]   // [a, b] du bord droit
    public var y0: Int
    public var y1: Int
    public var coteFaute: CoteFaute

    public init(gauche: [Double], droite: [Double], y0: Int, y1: Int, coteFaute: CoteFaute) {
        self.gauche = gauche; self.droite = droite; self.y0 = y0; self.y1 = y1; self.coteFaute = coteFaute
    }

    public func bords(_ y: Double) -> (Double, Double) {
        (Maths.polyval(gauche, y), Maths.polyval(droite, y))
    }

    /// Zone de l'image analysée pour la balle (mêmes marges que juge_ligne.py), bornée à l'image.
    public func zoneAnalyse(largeur: Int, hauteur: Int) -> ZoneImage {
        let xs = [gauche, droite].flatMap { p in [Double(y0), Double(y1)].map { Maths.polyval(p, $0) } }
        let x0 = max(0, Int(xs.min()!) - 300)
        let x1 = min(largeur, Int(xs.max()!) + 300)
        let yA = max(0, y0 - 80)
        let yB = min(hauteur, y1 + 40)
        return ZoneImage(x: x0, y: yA, largeur: (x1 - x0) / 2 * 2, hauteur: (yB - yA) / 2 * 2)
    }
}

public struct ZoneImage: Codable, Equatable, Sendable {
    public var x: Int, y: Int, largeur: Int, hauteur: Int
    public init(x: Int, y: Int, largeur: Int, hauteur: Int) {
        self.x = x; self.y = y; self.largeur = largeur; self.hauteur = hauteur
    }
}

/// Réglages du jugement, repris de juge_ligne.py (validés par Bruno le 2026-11-14).
public struct Reglages: Codable, Sendable {
    public var largeurLigneCm = 5.0
    public var litigeCm = 5.0
    public var procheCm = 30.0
    public var vitesseJeuPxS = 384.0
    public var maxTrou = 14
    public var minPixJaunes = 12
    public init() {}
}
