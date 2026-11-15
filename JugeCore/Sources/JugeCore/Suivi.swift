import Foundation

/// Une tache jaune qui bouge, vue sur une image (coordonnées de l'image en portrait).
public struct Detection: Sendable, Equatable {
    public var image: Int        // numéro de l'image dans la séquence
    public var temps: Double     // horodatage de l'image, en secondes
    public var x: Double
    public var y: Double
    public var aire: Double      // pixels
    /// Pixels jaune vif autour de la balle (contrôle couleur de juge_ligne.py). nil = non mesuré.
    public var pixJaunes: Int?

    public init(image: Int, temps: Double, x: Double, y: Double, aire: Double, pixJaunes: Int? = nil) {
        self.image = image; self.temps = temps; self.x = x; self.y = y; self.aire = aire; self.pixJaunes = pixJaunes
    }
}

/// Trajectoire : suite de détections reliées d'image en image.
public final class Trajectoire {
    public internal(set) var points: [Detection] = []
    let id: Int
    /// Indices déjà examinés comme rebond possible.
    var prochainExamen = 2
    var dernierRebondImage: Int?
    init(id: Int, premier: Detection) { self.id = id; points = [premier] }
    var dernier: Detection { points[points.count - 1] }
}

/// Suivi en ligne, image par image, identique à track() de juge_ligne.py :
/// chaque trajectoire (la plus longue d'abord) prend la détection libre la plus proche
/// dans un rayon de 25 + 15·écart px ; une trajectoire meurt après maxTrou images sans détection.
public final class Suivi {
    public let maxTrou: Int
    private(set) var actives: [Trajectoire] = []
    private var compteur = 0

    public init(maxTrou: Int = 14) { self.maxTrou = maxTrou }

    /// Ajoute les détections d'une image. Renvoie les trajectoires qui viennent de mourir.
    @discardableResult
    public func ajouter(image fr: Int, detections cand: [Detection]) -> [Trajectoire] {
        guard !cand.isEmpty else { return [] }
        var mortes: [Trajectoire] = []
        actives.removeAll { t in
            let mort = fr - t.dernier.image > maxTrou
            if mort { mortes.append(t) }
            return mort
        }
        var utilise = [Bool](repeating: false, count: cand.count)
        // tri stable par longueur décroissante, comme sorted(act, key=lambda t: -len(t))
        let ordre = actives.enumerated().sorted { a, b in
            a.element.points.count != b.element.points.count ? a.element.points.count > b.element.points.count : a.offset < b.offset
        }.map { $0.element }
        for t in ordre {
            let last = t.dernier
            let gap = Double(fr - last.image)
            var best = -1
            var bd = 1e9
            for (k, c) in cand.enumerated() where !utilise[k] {
                let dd = hypot(c.x - last.x, c.y - last.y)
                if dd <= 25 + 15 * gap && dd < bd { bd = dd; best = k }
            }
            if best >= 0 { t.points.append(cand[best]); utilise[best] = true }
        }
        for (k, c) in cand.enumerated() where !utilise[k] {
            compteur += 1
            actives.append(Trajectoire(id: compteur, premier: c))
        }
        return mortes
    }

    public var trajectoiresActives: [Trajectoire] { actives }

    /// Fin de séquence : toutes les trajectoires restantes.
    public func terminer() -> [Trajectoire] {
        let r = actives
        actives = []
        return r
    }
}
