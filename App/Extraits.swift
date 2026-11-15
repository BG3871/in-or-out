import AVFoundation

/// Enregistrement en continu par tranches de 4 s, effacées au fur et à mesure.
/// Quand une balle est douteuse (ou faute), on garde les 2 s avant et 1 s après le rebond
/// dans le dossier Extraits, pour que Bruno l'annote plus tard.
final class Extraits {
    private let file = DispatchQueue(label: "extraits")
    private let dossierTranches: URL
    let dossierExtraits: URL
    private struct Tranche { let url: URL; let debut: Double; var fin: Double }
    private var tranches: [Tranche] = []        // terminées, les plus récentes à la fin
    private var ecrivain: AVAssetWriter?
    private var entree: AVAssetWriterInput?
    private var courante: Tranche?
    private var demandes: [(t: Double, nom: String, fini: (URL?) -> Void)] = []
    private let dureeTranche = 4.0
    var actif = true

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dossierExtraits = docs.appendingPathComponent("Extraits", isDirectory: true)
        dossierTranches = FileManager.default.temporaryDirectory.appendingPathComponent("tranches", isDirectory: true)
        try? FileManager.default.removeItem(at: dossierTranches)
        try? FileManager.default.createDirectory(at: dossierTranches, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dossierExtraits, withIntermediateDirectories: true)
    }

    /// À appeler pour chaque image (sur la file d'analyse).
    func ajouter(_ sb: CMSampleBuffer) {
        guard actif else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if ecrivain == nil || t - (courante?.debut ?? t) >= dureeTranche { nouvelleTranche(sb, t) }
        if let e = entree, e.isReadyForMoreMediaData { e.append(sb); courante?.fin = t }
    }

    private func nouvelleTranche(_ sb: CMSampleBuffer, _ t: Double) {
        if let w = ecrivain, let e = entree, let c = courante {
            e.markAsFinished()
            w.finishWriting { [weak self] in
                self?.file.async { self?.trancheTerminee(c) }
            }
        }
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        let d = CMVideoFormatDescriptionGetDimensions(fmt)
        let url = dossierTranches.appendingPathComponent("t\(Int(t * 1000)).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { ecrivain = nil; return }
        let reglages: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(d.width), AVVideoHeightKey: Int(d.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 25_000_000, AVVideoExpectedSourceFrameRateKey: 240],
        ]
        let e = AVAssetWriterInput(mediaType: .video, outputSettings: reglages)
        e.expectsMediaDataInRealTime = true
        // les images arrivent en paysage : on tourne la vidéo pour qu'elle se lise en portrait
        e.transform = CGAffineTransform(rotationAngle: .pi / 2)
        guard w.canAdd(e) else { return }
        w.add(e)
        w.startWriting()
        w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
        ecrivain = w; entree = e
        courante = Tranche(url: url, debut: t, fin: t)
    }

    private func trancheTerminee(_ c: Tranche) {
        tranches.append(c)
        traiterDemandes()
        // on garde 12 s de tranches au maximum
        while tranches.count > 3 {
            let vieille = tranches.removeFirst()
            if !demandes.contains(where: { $0.t - 2 < vieille.fin }) { try? FileManager.default.removeItem(at: vieille.url) }
        }
    }

    /// Garde l'extrait autour de l'instant `t` (horloge de la caméra), sous le nom `nom`.mov.
    func garder(autour t: Double, nom: String, fini: @escaping (URL?) -> Void) {
        file.async {
            self.demandes.append((t, nom, fini))
            self.traiterDemandes()
        }
    }

    private func traiterDemandes() {
        let finDispo = tranches.last?.fin ?? -1
        var restantes: [(t: Double, nom: String, fini: (URL?) -> Void)] = []
        for d in demandes {
            guard finDispo >= d.t + 1 else { restantes.append(d); continue }
            let utiles = tranches.filter { $0.fin >= d.t - 2 && $0.debut <= d.t + 1 }
            exporter(utiles, de: d.t - 2, a: d.t + 1, nom: d.nom, fini: d.fini)
        }
        demandes = restantes
    }

    private func exporter(_ ts: [Tranche], de a: Double, a b: Double, nom: String, fini: @escaping (URL?) -> Void) {
        guard !ts.isEmpty else { return fini(nil) }
        let compo = AVMutableComposition()
        guard let piste = compo.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return fini(nil) }
        Task {
            var curseur = CMTime.zero
            for tr in ts {
                let asset = AVURLAsset(url: tr.url)
                guard let src = try? await asset.loadTracks(withMediaType: .video).first,
                      let duree = try? await asset.load(.duration) else { continue }
                // portion de la tranche dans [a, b]
                let debut = max(0, a - tr.debut), fin = min(duree.seconds, b - tr.debut)
                guard fin > debut else { continue }
                let plage = CMTimeRange(start: CMTime(seconds: debut, preferredTimescale: 2400),
                                        end: CMTime(seconds: fin, preferredTimescale: 2400))
                try? piste.insertTimeRange(plage, of: src, at: curseur)
                if let tf = try? await src.load(.preferredTransform) { piste.preferredTransform = tf }
                curseur = curseur + plage.duration
            }
            let url = self.dossierExtraits.appendingPathComponent(nom + ".mov")
            try? FileManager.default.removeItem(at: url)
            guard let export = AVAssetExportSession(asset: compo, presetName: AVAssetExportPresetPassthrough) else { return fini(nil) }
            export.outputURL = url
            export.outputFileType = .mov
            export.exportAsynchronously {
                fini(export.status == .completed ? url : nil)
            }
        }
    }
}
