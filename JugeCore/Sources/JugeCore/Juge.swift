import Foundation

public enum Niveau: String, Codable, Sendable { case litigieux, proche, loin }
public enum Confiance: String, Codable, Sendable { case elevee = "élevée", moyenne, faible }

/// Verdict annoncé par l'appli.
public enum Verdict: String, Codable, Sendable {
    /// Balle sur la ligne ou côté court, au-delà de la marge d'incertitude.
    case bonne
    /// Balle nettement dehors : flash et « Faute ! ».
    case faute
    /// Trop près pour trancher, ou suivi trop court : pas de signal, l'extrait est gardé pour annotation.
    case douteuse
}

/// Rebond de jeu jugé par rapport à la ligne dans l'axe.
public struct Appel: Codable, Sendable, Equatable {
    public var t: Double
    public var verdict: Verdict
    public var niveau: Niveau
    public var confiance: Confiance
    /// Distance au bord de ligne le plus proche (0 si la balle est sur la ligne), comme juge_ligne.py.
    public var distanceCm: Double
    /// Distance signée au bord extérieur : positive = dehors, négative = sur la ligne ou côté court.
    public var dehorsCm: Double
    public var margeCm: Double
    public var extrapoleMs: Double
    public var x: Double, y: Double
}

/// Rebond classé (sortie hors ligne, pour comparer avec juge_ligne.py).
public struct RebondClasse: Sendable {
    public var rebond: Rebond
    public var jeu: Bool
    public var dribble: Bool
    public var appel: Appel?   // nil si le contact est hors de l'étendue de la ligne
}

public enum Classement {
    /// Frappe de raquette (inversion latérale nette) : pas un rebond.
    static func estFrappe(_ b: Rebond) -> Bool {
        b.dxb * b.dxa < 0 && min(abs(b.dxb), abs(b.dxa)) > 30
    }

    static func estJeu(_ b: Rebond, _ r: Reglages) -> Bool {
        b.vxb * b.vxa > 0 && min(abs(b.vxb), abs(b.vxa)) >= r.vitesseJeuPxS
    }

    /// Mesure par rapport à la ligne et verdict. nil si le contact est en dehors de l'étendue de la ligne.
    public static func juger(_ b: Rebond, ligne: LigneAxe, reglages r: Reglages = Reglages()) -> Appel? {
        let cx = b.x, cy = b.y + b.r
        guard Double(ligne.y0) - 15 <= cy && cy <= Double(ligne.y1) + 5 else { return nil }
        let (a, c) = ligne.bords(cy)
        let largeur = c - a + 1
        let d = (a <= cx && cx <= c) ? 0.0 : min(abs(cx - a), abs(cx - c))
        let vx = max(abs(b.vxb), abs(b.vxa))
        let extMs = 1000 * max(0.0, b.ext - b.dt)
        let unc = max(1.5, 0.3 * b.r, 0.5 * vx * b.dt + 0.5 * vx * extMs / 1000)
        let k = r.largeurLigneCm / largeur
        let dCm = d * k, uncCm = unc * k
        let niveau: Niveau = (d <= unc || dCm <= r.litigeCm) ? .litigieux : (dCm <= r.procheCm ? .proche : .loin)
        let m = min(b.nb, b.na)
        let conf: Confiance = m >= 8 ? .elevee : (m >= 5 ? .moyenne : .faible)
        let dehors = (ligne.coteFaute == .droite ? cx - c : a - cx) * k
        let verdict: Verdict
        if dehors > max(uncCm, r.litigeCm) && conf != .faible {
            verdict = .faute
        } else if dehors <= -uncCm {
            verdict = .bonne
        } else {
            verdict = .douteuse
        }
        return Appel(t: b.t, verdict: verdict, niveau: niveau, confiance: conf, distanceCm: dCm, dehorsCm: dehors,
                     margeCm: uncCm, extrapoleMs: extMs, x: cx, y: cy)
    }

    /// Port de classify() + filtres de postprocess() (hors contrôle couleur si non mesuré).
    public static func classer(_ tous: [Rebond], ligne: LigneAxe, reglages r: Reglages = Reglages()) -> [RebondClasse] {
        let B0 = tous.filter { !estFrappe($0) }
        var B: [Rebond] = []
        for b in B0.enumerated().sorted(by: { $0.element.t != $1.element.t ? $0.element.t < $1.element.t : $0.offset < $1.offset }).map(\.element) {
            if let last = B.last, b.t - last.t < 0.05 {
                if min(b.nb, b.na) > min(last.nb, last.na) { B[B.count - 1] = b }
                continue
            }
            B.append(b)
        }
        return B.enumerated().map { i, b in
            let dribble = B.enumerated().contains { j, c in
                j != i && 0.3 < abs(c.t - b.t) && abs(c.t - b.t) < 3.0 && abs(c.x - b.x) < 30 && abs(c.y - b.y) < 15
            }
            return RebondClasse(rebond: b, jeu: estJeu(b, r), dribble: dribble, appel: juger(b, ligne: ligne, reglages: r))
        }
    }
}

/// Analyse hors ligne d'une séquence complète de détections (rejeu d'une vidéo).
public enum AnalyseHorsLigne {
    public static func rebonds(_ dets: [Detection], reglages r: Reglages = Reglages()) -> [Rebond] {
        let suivi = Suivi(maxTrou: r.maxTrou)
        var parImage: [Int: [Detection]] = [:]
        var images: [Int] = []
        for d in dets {
            if parImage[d.image] == nil { images.append(d.image) }
            parImage[d.image, default: []].append(d)
        }
        images.sort()
        var toutes: [Trajectoire] = []
        var vues = Set<Int>()
        for fr in images {
            suivi.ajouter(image: fr, detections: parImage[fr]!)
            for t in suivi.trajectoiresActives where !vues.contains(t.id) { vues.insert(t.id); toutes.append(t) }
        }
        return toutes.filter { $0.points.count >= 8 }.flatMap { Rebonds.tous($0.points) }
    }
}

/// Juge en direct : reçoit les détections image par image et annonce chaque rebond de jeu
/// près de la ligne dès que le résultat ne peut plus changer (environ 45 images après le rebond,
/// soit 0,2 s à 240 i/s). Donne le même résultat que l'analyse hors ligne pour les rebonds de jeu.
public final class JugeDirect {
    public var ligne: LigneAxe
    public let reglages: Reglages
    private let suivi: Suivi
    private var enAttente: [(ordre: Int, b: Rebond)] = []   // rebonds trouvés, pas encore dédoublonnés
    private var candidat: Rebond?                          // dernier rebond gardé (peut encore être remplacé)
    private var ordre = 0

    public init(ligne: LigneAxe, reglages: Reglages = Reglages()) {
        self.ligne = ligne
        self.reglages = reglages
        self.suivi = Suivi(maxTrou: reglages.maxTrou)
    }

    /// Ajoute les détections de l'image `image` (prise à `temps`). Renvoie les appels devenus définitifs.
    public func image(_ image: Int, temps: Double, detections: [Detection]) -> [Appel] {
        historique.append((image, temps))
        if historique.count > 64 { historique.removeFirst(historique.count - 64) }
        let mortes = suivi.ajouter(image: image, detections: detections)
        for t in mortes { examiner(t, image: image, morte: true) }
        for t in suivi.trajectoiresActives { examiner(t, image: image, morte: false) }
        return finaliser(horizonImage: image - 32, temps: temps)
    }

    /// Fin de séquence (rejeu) : annonce tout ce qui reste.
    public func terminer() -> [Appel] {
        for t in suivi.terminer() { examiner(t, image: Int.max / 2, morte: true) }
        var out = finaliser(horizonImage: Int.max / 2, temps: .infinity)
        if let c = candidat { out += annoncer(c); candidat = nil }
        return out
    }

    private func examiner(_ t: Trajectoire, image: Int, morte: Bool) {
        let p = t.points
        // une trajectoire n'est retenue qu'à partir de 8 positions (comme track())
        guard p.count >= 8 else { return }
        while t.prochainExamen < p.count - 2 {
            let k = t.prochainExamen
            // il faut toutes les positions jusqu'à 30 images après k
            if !morte && p[p.count - 1].image <= p[k].image + 30 && image <= p[k].image + 30 { break }
            t.prochainExamen += 1
            guard let b = Rebonds.examiner(p, k) else { continue }
            if let last = t.dernierRebondImage, b.imageRebond - last <= 6 { continue }
            t.dernierRebondImage = b.imageRebond
            ordre += 1
            enAttente.append((ordre, b))
        }
    }

    private func finaliser(horizonImage: Int, temps: Double) -> [Appel] {
        var out: [Appel] = []
        // rebonds dont tous les voisins possibles sont connus, traités par ordre chronologique
        let prets = enAttente.filter { $0.b.imageRebond <= horizonImage }
            .sorted { $0.b.t != $1.b.t ? $0.b.t < $1.b.t : $0.ordre < $1.ordre }
        enAttente.removeAll { $0.b.imageRebond <= horizonImage }
        for (_, b) in prets where !Classement.estFrappe(b) {
            if let c = candidat {
                if b.t - c.t < 0.05 {
                    if min(b.nb, b.na) > min(c.nb, c.na) { candidat = b }
                    continue
                }
                out += annoncer(c)
            }
            candidat = b
        }
        // le candidat est définitif quand plus aucun rebond ne peut tomber à moins de 0,05 s
        // (un rebond pas encore prêt est postérieur à l'image horizon, à une image près)
        if let c = candidat, horizonTemps(horizonImage, temps) - c.t >= 0.06,
           !enAttente.contains(where: { $0.b.t - c.t < 0.05 }) {
            out += annoncer(c)
            candidat = nil
        }
        return out
    }

    /// Horodatages des dernières images reçues (y compris celles sans détection).
    private var historique: [(image: Int, temps: Double)] = []
    private func horizonTemps(_ horizon: Int, _ temps: Double) -> Double {
        if temps.isInfinite { return .infinity }
        // temps de la dernière image reçue à l'horizon ou avant ; à défaut, le plus ancien connu
        return historique.last(where: { $0.image <= horizon })?.temps ?? (historique.first?.temps ?? temps) - 1
    }

    private func annoncer(_ b: Rebond) -> [Appel] {
        guard Classement.estJeu(b, reglages) else { return [] }
        if let pj = b.pixJaunes, pj < reglages.minPixJaunes { return [] }
        guard let a = Classement.juger(b, ligne: ligne, reglages: reglages) else { return [] }
        return [a]
    }
}
