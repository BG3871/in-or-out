import AVFoundation
import JugeCore
import SwiftUI

/// Aperçu de la caméra, en portrait, sans recadrage (l'image 1080 × 1920 tient entière à l'écran).
struct Apercu: UIViewRepresentable {
    let session: AVCaptureSession
    final class Vue: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var couche: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Vue {
        let v = Vue()
        v.couche.session = session
        v.couche.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }
    func updateUIView(_ v: Vue, context: Context) {
        if let c = v.couche.connection, c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
    }
}

/// Conversion entre les pixels de l'image en portrait (1080 × 1920) et les points de l'écran.
struct Cadre {
    let taille: CGSize
    var echelle: CGFloat { min(taille.width / 1080, taille.height / 1920) }
    var origine: CGPoint { CGPoint(x: (taille.width - 1080 * echelle) / 2, y: (taille.height - 1920 * echelle) / 2) }
    func ecran(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origine.x + CGFloat(x) * echelle, y: origine.y + CGFloat(y) * echelle) }
    func image(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origine.x) / echelle, y: (p.y - origine.y) / echelle) }
}

struct VueDirect: View {
    @ObservedObject var moteur: Moteur

    var body: some View {
        GeometryReader { geo in
            let cadre = Cadre(taille: geo.size)
            ZStack {
                Apercu(session: moteur.camera.session)
                dessin(cadre)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in moteur.toucher(cadre.image(p)) }
                VStack(spacing: 10) {
                    bandeau
                    Spacer()
                    if moteur.etape == .jeu { tableau }
                    commandes
                }
                .padding()
            }
        }
        .background(Color.black)
        .task { if moteur.etape == .demarrage { await moteur.demarrer() } }
    }

    // MARK: dessin de la ligne et des points touchés

    @ViewBuilder func dessin(_ c: Cadre) -> some View {
        Canvas { ctx, _ in
            if let l = moteur.ligne {
                for p in [l.gauche, l.droite] {
                    var path = Path()
                    path.move(to: c.ecran(Maths.polyval(p, Double(l.y0)), Double(l.y0)))
                    path.addLine(to: c.ecran(Maths.polyval(p, Double(l.y1)), Double(l.y1)))
                    ctx.stroke(path, with: .color(.pink), lineWidth: 1.5)
                }
                // côté faute en rouge translucide
                let ym = Double(l.y0 + l.y1) / 2
                let x = l.coteFaute == .droite ? Maths.polyval(l.droite, ym) + 60 : Maths.polyval(l.gauche, ym) - 60
                ctx.draw(Text("FAUTE").font(.caption.bold()).foregroundColor(.red), at: c.ecran(x, ym))
            }
            for p in [moteur.proche, moteur.lointain].compactMap({ $0 }) {
                let e = c.ecran(Double(p.x), Double(p.y))
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - 10, y: e.y - 10, width: 20, height: 20)), with: .color(.yellow), lineWidth: 2)
            }
            if let a = moteur.dernierAppel {
                let e = c.ecran(a.x, a.y)
                ctx.stroke(Path(ellipseIn: CGRect(x: e.x - 8, y: e.y - 8, width: 16, height: 16)),
                           with: .color(a.verdict == .faute ? .red : (a.verdict == .bonne ? .green : .orange)), lineWidth: 3)
            }
        }
    }

    // MARK: textes

    var consigne: String {
        switch moteur.etape {
        case .demarrage: return "Démarrage de la caméra…"
        case .erreur(let m): return m
        case .reglage: return "Pose le téléphone au bout de la ligne, bien calé, puis appuie sur « Calibrer et commencer ». Tu auras 3 s pour lâcher le téléphone."
        case .decompte(let n): return "Ne touche plus le téléphone… \(n)"
        case .recherche: return "Recherche de la ligne dans l'axe…"
        case .echec(let m): return "Ligne non trouvée avec certitude : \(m). Réessaie, ou trace la ligne à la main."
        case .pointProche: return "Touche le bout PROCHE de la ligne. (Le téléphone peut bouger un peu : la ligne sera remesurée après un décompte.)"
        case .pointLointain: return "Touche maintenant le bout LOINTAIN de la même ligne."
        case .jeu:
            let base = moteur.mode == .arbitre ? "Arbitrage en cours : flash sur les fautes nettes." :
                "Mode silencieux : l'appli note ses verdicts sans signal."
            return "Ligne trouvée (\(moteur.qualite)). Vérifie les traits roses sur les bords. " + base
        case .bouge(let m): return "Arrêt : le téléphone a bougé (\(m)). Recalibre."
        }
    }

    var bandeau: some View {
        Text(consigne)
            .font(.callout)
            .foregroundStyle(.white)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    var tableau: some View {
        VStack(spacing: 4) {
            if let a = moteur.dernierAppel {
                Text(a.verdict == .faute ? "FAUTE" : (a.verdict == .bonne ? "BONNE" : "DOUTEUSE"))
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(a.verdict == .faute ? .red : (a.verdict == .bonne ? .green : .orange))
                Text(String(format: "%@ %.1f cm (± %.1f)", a.dehorsCm > 0 ? "dehors de" : "dedans de", abs(a.dehorsCm), a.margeCm))
                    .foregroundStyle(.white)
            }
            Text("Bonnes \(moteur.compte.bonnes) · Fautes \(moteur.compte.fautes) · Douteuses \(moteur.compte.douteuses)")
                .font(.footnote).foregroundStyle(.white)
            Text(String(format: "%.0f images/s analysées", moteur.imagesParSeconde))
                .font(.caption2)
                .foregroundStyle(moteur.imagesParSeconde < 200 ? .orange : .gray)
        }
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    var choixMode: some View {
        Picker("Mode", selection: Binding(get: { moteur.mode }, set: { moteur.changerMode($0) })) {
            ForEach(Moteur.Mode.allCases) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented)
    }

    @ViewBuilder var commandes: some View {
        switch moteur.etape {
        case .reglage, .echec, .bouge:
            VStack(spacing: 10) {
                Picker("Côté faute", selection: $moteur.coteFaute) {
                    Text("Faute à gauche").tag(CoteFaute.gauche)
                    Text("Faute à droite").tag(CoteFaute.droite)
                }.pickerStyle(.segmented)
                choixMode
                HStack {
                    Text(String(format: "Flash : %.1f s", moteur.dureeFlash)).foregroundStyle(.white).font(.footnote)
                    Slider(value: $moteur.dureeFlash, in: 0.5...3, step: 0.5)
                    Button("Essai") { moteur.essaiFlash() }.buttonStyle(.bordered).tint(.white)
                }
                Button("Calibrer et commencer") { moteur.calibrerEtCommencer() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                if case .reglage = moteur.etape {} else {
                    Button("Tracer la ligne à la main") { moteur.traceManuel() }.buttonStyle(.bordered).tint(.white)
                }
            }
            .padding(10)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        case .decompte(let n):
            VStack {
                Text("\(n)").font(.system(size: 96, weight: .heavy)).foregroundStyle(.white)
                Button("Annuler") { moteur.annulerDecompte() }.buttonStyle(.bordered).tint(.white)
            }
        case .jeu:
            VStack {
                choixMode
                Button("Arrêter") { moteur.arreterJeu() }.buttonStyle(.bordered).tint(.white)
            }
        case .pointProche, .pointLointain:
            Button("Annuler") { moteur.annulerDecompte() }.buttonStyle(.bordered).tint(.white)
        default:
            EmptyView()
        }
    }
}
