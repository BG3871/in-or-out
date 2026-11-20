import AVFoundation
import CoreTransferable
import JugeCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Vidéo choisie dans Photos, copiée dans un fichier temporaire.
struct Film: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { recu in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(recu.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: recu.file, to: dest)
            return Film(url: dest)
        }
    }
}

/// Rejeu d'une vidéo au ralenti déjà filmée : même détecteur et même juge que le direct,
/// pour comparer avec les annotations avant de faire confiance au flash.
@MainActor
final class Rejeu: ObservableObject {
    enum Etape: Equatable {
        case choix, chargement, pointProche, pointLointain, cote, echec(String), pret(String), analyse, fini(String), erreur(String)
    }
    @Published var etape: Etape = .choix
    @Published var fond: UIImage?
    @Published var proche: CGPoint?
    @Published var lointain: CGPoint?
    @Published var ligne: LigneAxe?
    @Published var progression: Double = 0
    @Published var nomVideo = ""
    private var url: URL?
    private var orientation: Orientation = .identite
    private var plans: (Plan8, Plan8)?
    private var annule = false
    let journal: Journal

    init(journal: Journal) { self.journal = journal }

    func charger(_ item: PhotosPickerItem) async {
        etape = .chargement
        do {
            guard let film = try await item.loadTransferable(type: Film.self) else { throw CocoaError(.fileReadUnknown) }
            url = film.url
            nomVideo = film.url.deletingPathExtension().lastPathComponent
            let asset = AVURLAsset(url: film.url)
            guard let piste = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let (taille, tf, duree) = try await (piste.load(.naturalSize), piste.load(.preferredTransform), asset.load(.duration))
            // portrait normal de l'iPhone : rotation de +90° (b = 1, c = −1)
            let tourne = tf.b == 1 && tf.c == -1
            if taille.width > taille.height && tourne { orientation = .paysageVersPortrait }
            else if taille.width < taille.height && !tourne { orientation = .identite }
            else { throw NSError(domain: "rejeu", code: 1, userInfo: [NSLocalizedDescriptionKey: "La vidéo doit être filmée en portrait."]) }
            // 7 images réparties sur la vidéo, dont on prend la médiane (comme juge_ligne.py)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            var gs: [Plan8] = [], ss: [Plan8] = []
            var apercu: CGImage?
            let d = duree.seconds
            for k in 0..<7 {
                let t = 5 + (d - 10) * Double(k) / 6
                let (img, _) = try await gen.image(at: CMTime(seconds: max(0, t), preferredTimescale: 600))
                if apercu == nil { apercu = img }
                guard let pl = Rejeu.plans(img) else { continue }
                gs.append(pl.0); ss.append(pl.1)
            }
            guard !gs.isEmpty, gs[0].largeur == 1080, gs[0].hauteur == 1920 else {
                throw NSError(domain: "rejeu", code: 2, userInfo: [NSLocalizedDescriptionKey: "Il faut une vidéo 1080 × 1920 (ralenti 240 i/s)."])
            }
            plans = (Plan8.mediane(gs), Plan8.mediane(ss))
            fond = apercu.map { UIImage(cgImage: $0) }
            proche = nil; lointain = nil; ligne = nil
            // d'abord le côté faute, puis recherche automatique de la ligne (sans toucher l'image)
            etape = .cote
        } catch {
            etape = .erreur(error.localizedDescription)
        }
    }

    /// CGImage (déjà en portrait) → gris et saturation.
    nonisolated static func plans(_ img: CGImage) -> (Plan8, Plan8)? {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok: Bool = px.withUnsafeMutableBytes { b in
            guard let ctx = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return px.withUnsafeBufferPointer { b in
            Plan8.grisEtSaturation(ImageBGRA(base: b.baseAddress!, largeur: w, hauteur: h, octetsParLigne: w * 4), orientation: .identite)
        }
    }

    func toucher(_ p: CGPoint) {
        switch etape {
        case .pointProche, .echec, .pret: proche = p; lointain = nil; ligne = nil; etape = .pointLointain
        case .pointLointain: lointain = p; etape = .cote
        default: break
        }
    }

    func choisirCote(_ c: CoteFaute) {
        guard let pl = plans else { return }
        let r: ResultatCalibrage
        if let p = proche, let l = lointain {
            r = Calibrage.reperer(gris: pl.0, sat: pl.1, proche: (Double(p.x), Double(p.y)),
                                  lointain: (Double(l.x), Double(l.y)), coteFaute: c)
        } else {
            r = Calibrage.detecter(gris: pl.0, sat: pl.1, coteFaute: c)
        }
        switch r {
        case .ok(let lg, let q): ligne = lg; etape = .pret(q)
        case .echec(let m): etape = .echec(m)
        }
    }

    func annuler() { annule = true }

    func analyser() {
        guard let url, let ligne else { return }
        etape = .analyse
        progression = 0
        annule = false
        let orientation = self.orientation, nom = nomVideo
        Task.detached(priority: .userInitiated) {
            let r = await Rejeu.lire(url: url, ligne: ligne, orientation: orientation,
                                     progres: { p in Task { @MainActor in self.progression = p } },
                                     annule: { await MainActor.run { self.annule } })
            await MainActor.run {
                switch r {
                case .failure(let e): self.etape = .erreur(e.localizedDescription)
                case .success(let appels):
                    for a in appels {
                        self.journal.ajouter(Entree(date: Date(), source: nom, tVideo: a.t, appel: a, extrait: nil, annotation: nil))
                    }
                    let f = appels.filter { $0.verdict == .faute }.count, b = appels.filter { $0.verdict == .bonne }.count
                    self.etape = .fini("\(appels.count) rebonds de jeu jugés : \(b) bonnes, \(f) fautes, \(appels.count - b - f) douteuses. Détail dans le journal.")
                }
            }
        }
    }

    nonisolated static func lire(url: URL, ligne: LigneAxe, orientation: Orientation, progres: @escaping (Double) -> Void,
                                 annule: @escaping () async -> Bool) async -> Result<[Appel], Error> {
        do {
            let asset = AVURLAsset(url: url)
            guard let piste = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let duree = try await asset.load(.duration).seconds
            let lecteur = try AVAssetReader(asset: asset)
            let sortie = AVAssetReaderTrackOutput(track: piste, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            sortie.alwaysCopiesSampleData = false
            lecteur.add(sortie)
            guard lecteur.startReading() else { throw lecteur.error ?? CocoaError(.fileReadUnknown) }
            var det: DetecteurBalle?
            let juge = JugeDirect(ligne: ligne)
            var appels: [Appel] = []
            var n = 0
            while let sb = sortie.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
                if det == nil {
                    det = DetecteurBalle(zonePortrait: ligne.zoneAnalyse(largeur: 1080, hauteur: 1920), orientation: orientation,
                                         largeurBrute: w, hauteurBrute: h)
                }
                if let base = CVPixelBufferGetBaseAddress(pb) {
                    let img = ImageBGRA(base: UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), largeur: w, hauteur: h,
                                        octetsParLigne: CVPixelBufferGetBytesPerRow(pb))
                    // numéro d'image = rang dans la vidéo, comme dans juge_ligne.py
                    appels += juge.image(n, temps: t, detections: det!.analyser(img, numero: n, temps: t))
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
                n += 1
                if n % 480 == 0 {
                    progres(t / max(duree, 0.001))
                    if await annule() { lecteur.cancelReading(); break }
                }
            }
            appels += juge.terminer()
            return .success(appels)
        } catch {
            return .failure(error)
        }
    }
}

struct VueRejeu: View {
    @ObservedObject var rejeu: Rejeu
    @State private var choix: PhotosPickerItem?

    var body: some View {
        VStack(spacing: 12) {
            Text(texte).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            if let img = rejeu.fond, rejeu.etape != .choix {
                GeometryReader { geo in
                    let c = Cadre(taille: geo.size)
                    ZStack {
                        Image(uiImage: img).resizable().scaledToFit().frame(width: geo.size.width, height: geo.size.height)
                        Canvas { ctx, _ in
                            if let l = rejeu.ligne {
                                for p in [l.gauche, l.droite] {
                                    var path = Path()
                                    path.move(to: c.ecran(Maths.polyval(p, Double(l.y0)), Double(l.y0)))
                                    path.addLine(to: c.ecran(Maths.polyval(p, Double(l.y1)), Double(l.y1)))
                                    ctx.stroke(path, with: .color(.pink), lineWidth: 1.5)
                                }
                            }
                            for p in [rejeu.proche, rejeu.lointain].compactMap({ $0 }) {
                                let e = c.ecran(Double(p.x), Double(p.y))
                                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - 10, y: e.y - 10, width: 20, height: 20)), with: .color(.yellow), lineWidth: 2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in rejeu.toucher(c.image(p)) }
                    }
                }
            } else {
                Spacer()
            }
            switch rejeu.etape {
            case .cote:
                HStack {
                    Button("Faute à gauche") { rejeu.choisirCote(.gauche) }.buttonStyle(.borderedProminent)
                    Button("Faute à droite") { rejeu.choisirCote(.droite) }.buttonStyle(.borderedProminent)
                }
            case .pret:
                Button("Analyser la vidéo") { rejeu.analyser() }.buttonStyle(.borderedProminent)
            case .analyse:
                ProgressView(value: rejeu.progression)
                Button("Annuler") { rejeu.annuler() }
            default:
                EmptyView()
            }
            if rejeu.etape != .analyse && rejeu.etape != .chargement {
                PhotosPicker(selection: $choix, matching: .videos) { Label("Choisir une vidéo au ralenti", systemImage: "film") }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .onChange(of: choix) { _, item in
            if let item { Task { await rejeu.charger(item) } }
        }
    }

    var texte: String {
        switch rejeu.etape {
        case .choix: return "Rejoue une vidéo au ralenti déjà filmée (comme IMG_1299 ou IMG_1323) pour comparer les verdicts de l'appli à tes annotations."
        case .chargement: return "Chargement de la vidéo…"
        case .pointProche: return "Touche le bout PROCHE de la ligne dans l'axe."
        case .pointLointain: return "Touche le bout LOINTAIN de la même ligne."
        case .cote: return "De quel côté la balle est-elle faute ?"
        case .echec(let m): return "Ligne non trouvée avec certitude : \(m). Touche le bout proche de la ligne pour la tracer à la main."
        case .pret(let q): return "\(rejeu.nomVideo) : ligne trouvée (\(q))."
        case .analyse: return "Analyse de \(rejeu.nomVideo)… compte environ la durée de la vidéo."
        case .fini(let m): return m
        case .erreur(let m): return m
        }
    }
}
