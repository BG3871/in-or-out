import AVFoundation
import JugeCore
import SwiftUI

/// Chef d'orchestre du mode direct : caméra → détecteur → juge → flash, voix, extraits, journal.
@MainActor
final class Moteur: ObservableObject {
    enum Etape: Equatable {
        case demarrage
        case erreur(String)
        case pointProche                       // toucher le bout proche de la ligne
        case pointLointain                     // toucher le bout lointain
        case cote                              // choisir le côté faute
        case recherche                         // calibrage en cours
        case echec(String)                     // ligne pas trouvée avec certitude
        case pret(qualite: String)             // ligne trouvée, prêt à juger
        case jeu
        case bouge(String)                     // le téléphone a bougé : on arrête de juger
    }

    enum Mode: String, CaseIterable, Identifiable {
        case silencieux = "Silencieux"
        case arbitre = "Arbitre"
        var id: String { rawValue }
    }

    @Published var etape: Etape = .demarrage
    @Published var mode: Mode = .silencieux
    @Published var ligne: LigneAxe?
    @Published var proche: CGPoint?        // en pixels du portrait 1080 × 1920
    @Published var lointain: CGPoint?
    @Published private(set) var dernierAppel: Appel?
    @Published private(set) var imagesParSeconde: Double = 0
    @Published private(set) var compte = (bonnes: 0, fautes: 0, douteuses: 0)

    nonisolated(unsafe) let camera = Camera()
    let journal: Journal
    private let annonce = Annonce()
    nonisolated(unsafe) private let extraits = Extraits()

    // état de la file d'analyse (accédé seulement depuis camera.fileAnalyse)
    nonisolated(unsafe) private var detecteur: DetecteurBalle?
    nonisolated(unsafe) private var juge: JugeDirect?
    nonisolated(unsafe) private var t0: Double?
    nonisolated(unsafe) private var dernierNumero = -1
    nonisolated(unsafe) private var demandesFond: Int = 0
    nonisolated(unsafe) private var fondsAttendus: Int = 0
    nonisolated(unsafe) private var fondsCollectes: [(Plan8, Plan8)] = []
    nonisolated(unsafe) private var surFonds: (([(Plan8, Plan8)]) -> Void)?
    nonisolated(unsafe) private var dernierFond: Double = 0
    nonisolated(unsafe) private var verifEnCours = false
    nonisolated(unsafe) private var echecsVerif = 0
    nonisolated(unsafe) private var modeArbitre = false
    private var debutSeance = Date()

    init(journal: Journal) {
        self.journal = journal
        camera.surImage = { [unowned self] sb in self.image(sb) }
    }

    func demarrer() async {
        do {
            try await camera.demarrer()
            etape = .pointProche
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.imagesParSeconde = self?.camera.imagesParSeconde ?? 0 }
            }
        } catch {
            etape = .erreur(error.localizedDescription)
        }
    }

    // MARK: - calibrage

    func toucher(_ p: CGPoint) {
        switch etape {
        case .pointProche, .echec, .pret, .bouge:
            proche = p; lointain = nil; ligne = nil; etape = .pointLointain
        case .pointLointain:
            lointain = p; etape = .cote
        default: break
        }
    }

    func recommencer() {
        arreterJeu()
        proche = nil; lointain = nil; ligne = nil
        etape = .pointProche
    }

    func choisirCote(_ cote: CoteFaute) {
        guard let p = proche, let l = lointain else { return }
        etape = .recherche
        // 5 images espacées de 0,2 s, dont on prend la médiane (les joueurs et balles disparaissent)
        collecterFonds(5, intervalle: 0.2) { [weak self] fonds in
            let g = Plan8.mediane(fonds.map { $0.0 }), s = Plan8.mediane(fonds.map { $0.1 })
            let r = Calibrage.reperer(gris: g, sat: s, proche: (Double(p.x), Double(p.y)),
                                      lointain: (Double(l.x), Double(l.y)), coteFaute: cote)
            Task { @MainActor in
                guard let self else { return }
                switch r {
                case .ok(let lg, let q): self.ligne = lg; self.etape = .pret(qualite: q)
                case .echec(let m): self.etape = .echec(m)
                }
            }
        }
    }

    // MARK: - jeu

    func commencer() {
        guard let lg = ligne else { return }
        camera.bloquerMiseAuPoint(true)
        let modeA = mode == .arbitre
        debutSeance = Date()
        compte = (0, 0, 0)
        dernierAppel = nil
        camera.fileAnalyse.async {
            self.detecteur = DetecteurBalle(zonePortrait: lg.zoneAnalyse(largeur: 1080, hauteur: 1920),
                                            orientation: .paysageVersPortrait, largeurBrute: 1920, hauteurBrute: 1080)
            self.juge = JugeDirect(ligne: lg)
            self.t0 = nil; self.dernierNumero = -1; self.echecsVerif = 0
            self.modeArbitre = modeA
        }
        etape = .jeu
    }

    func changerMode(_ m: Mode) {
        mode = m
        let a = m == .arbitre
        camera.fileAnalyse.async { self.modeArbitre = a }
    }

    func arreterJeu() {
        camera.bloquerMiseAuPoint(false)
        camera.fileAnalyse.async { self.detecteur = nil; self.juge = nil }
        if etape == .jeu { etape = .pret(qualite: "séance arrêtée") }
    }

    // MARK: - file d'analyse

    nonisolated private func image(_ sb: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let img = ImageBGRA(base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)),
                            largeur: CVPixelBufferGetWidth(pb), hauteur: CVPixelBufferGetHeight(pb),
                            octetsParLigne: CVPixelBufferGetBytesPerRow(pb))
        guard img.largeur == 1920, img.hauteur == 1080 else { return }

        // images de fond demandées (calibrage ou vérification que le téléphone n'a pas bougé) :
        // on copie l'image (≈ 1 ms) et on la convertit ailleurs pour ne pas retarder l'analyse
        if demandesFond > 0, t - dernierFond >= 0.2 {
            dernierFond = t
            demandesFond -= 1
            let copie = Data(bytes: base, count: img.octetsParLigne * img.hauteur)
            let (w, h, bpr) = (img.largeur, img.hauteur, img.octetsParLigne)
            DispatchQueue.global(qos: .userInitiated).async {
                let plans = copie.withUnsafeBytes { b in
                    Plan8.grisEtSaturation(ImageBGRA(base: b.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                     largeur: w, hauteur: h, octetsParLigne: bpr), orientation: .paysageVersPortrait)
                }
                self.camera.fileAnalyse.async {
                    self.fondsCollectes.append(plans)
                    if self.demandesFond == 0, self.fondsCollectes.count >= self.fondsAttendus, let f = self.surFonds {
                        let fonds = self.fondsCollectes; self.fondsCollectes = []; self.surFonds = nil; f(fonds)
                    }
                }
            }
        }

        guard let det = detecteur, let juge = juge else { return }
        extraits.ajouter(sb)
        if t0 == nil { t0 = t }
        // numéro d'image tiré de l'horloge : une image perdue laisse un trou, comme une balle non vue
        var n = Int(((t - t0!) * 240).rounded())
        if n <= dernierNumero { n = dernierNumero + 1 }
        dernierNumero = n
        let dets = det.analyser(img, numero: n, temps: t)
        for a in juge.image(n, temps: t, detections: dets) { appel(a) }

        // toutes les 3 s : le téléphone a-t-il bougé ?
        if !verifEnCours, n % 720 == 0, n > 0 { verifierLigne() }
    }

    nonisolated private func collecterFonds(_ n: Int, intervalle: Double, _ fini: @escaping ([(Plan8, Plan8)]) -> Void) {
        camera.fileAnalyse.async {
            self.fondsCollectes = []
            self.dernierFond = 0
            self.surFonds = { f in DispatchQueue.global(qos: .userInitiated).async { fini(f) } }
            self.fondsAttendus = n
            self.demandesFond = n
        }
    }

    nonisolated private func verifierLigne() {
        guard let lg = juge?.ligne else { return }
        verifEnCours = true
        surFonds = { [weak self] f in
            DispatchQueue.global(qos: .utility).async {
                let d = Calibrage.decalage(lg, gris: f[0].0, sat: f[0].1)
                self?.camera.fileAnalyse.async {
                    guard let self else { return }
                    self.verifEnCours = false
                    // un joueur peut cacher la ligne : on n'arrête qu'après 3 échecs de suite
                    if let d, d <= 4 { self.echecsVerif = 0; return }
                    self.echecsVerif += 1
                    if self.echecsVerif >= 3 || (d ?? 0) > 4 {
                        let msg = d.map { "la ligne s'est décalée de \(Int($0.rounded())) px" } ?? "la ligne n'est plus visible"
                        self.detecteur = nil; self.juge = nil
                        Task { @MainActor in self.etape = .bouge(msg); self.camera.bloquerMiseAuPoint(false) }
                    }
                }
            }
        }
        fondsCollectes = []
        dernierFond = 0
        fondsAttendus = 1
        demandesFond = 1
    }

    nonisolated private func appel(_ a: Appel) {
        if a.verdict == .faute && modeArbitre {
            camera.flash()
            Task { @MainActor in self.annonce.faute() }
        }
        let nom = "\(Int(Date().timeIntervalSince1970))_\(a.verdict.rawValue)"
        let garder = a.verdict != .bonne
        let tSeance = a.t - (t0 ?? a.t)
        Task { @MainActor in
            self.dernierAppel = a
            switch a.verdict {
            case .bonne: self.compte.bonnes += 1
            case .faute: self.compte.fautes += 1
            case .douteuse: self.compte.douteuses += 1
            }
            let e = Entree(date: Date(), source: "Direct", tVideo: tSeance, appel: a, extrait: garder ? nom + ".mov" : nil, annotation: nil)
            let id = e.id
            self.journal.ajouter(e)
            if garder {
                self.extraits.garder(autour: a.t, nom: nom) { url in
                    if url == nil {
                        Task { @MainActor in
                            if var e2 = self.journal.entrees.first(where: { $0.id == id }) { e2.extrait = nil; self.journal.mettreAJour(e2) }
                        }
                    }
                }
            }
        }
    }
}
