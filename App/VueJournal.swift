import AVKit
import JugeCore
import SwiftUI

struct VueJournal: View {
    @ObservedObject var journal: Journal
    @State private var confirmer = false
    private let dossier = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Extraits")

    var body: some View {
        NavigationStack {
            List {
                let c = journal.concordance
                if c.accords + c.desaccords + c.douteuses > 0 {
                    Section("Concordance avec tes annotations") {
                        Text("\(c.accords) d'accord, \(c.desaccords) en désaccord, \(c.douteuses) douteuses annotées")
                    }
                }
                ForEach(journal.entrees) { e in
                    NavigationLink { VueEntree(journal: journal, entree: e, dossier: dossier) } label: { ligne(e) }
                }
            }
            .navigationTitle("Journal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: journal.csv()) { Image(systemName: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Effacer", role: .destructive) { confirmer = true }.disabled(journal.entrees.isEmpty)
                }
            }
            .confirmationDialog("Effacer tout le journal ? Les extraits vidéo restent dans l'app Fichiers.", isPresented: $confirmer) {
                Button("Effacer le journal", role: .destructive) { journal.effacer() }
            }
        }
    }

    func ligne(_ e: Entree) -> some View {
        HStack {
            Circle().fill(couleur(e.appel.verdict)).frame(width: 12, height: 12)
            VStack(alignment: .leading) {
                Text("\(e.appel.verdict.rawValue.capitalized) · \(e.source) \(e.tVideo.mmss)").font(.subheadline)
                Text(String(format: "%@ %.1f cm (± %.1f) · confiance %@", e.appel.dehorsCm > 0 ? "dehors" : "dedans",
                            abs(e.appel.dehorsCm), e.appel.margeCm, e.appel.confiance.rawValue))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let a = e.annotation { Text(a == .faute ? "Faute ✓" : "Bonne ✓").font(.caption).foregroundStyle(.blue) }
            if e.extrait != nil { Image(systemName: "film").foregroundStyle(.secondary) }
        }
    }
}

func couleur(_ v: Verdict) -> Color { v == .faute ? .red : (v == .bonne ? .green : .orange) }

struct VueEntree: View {
    @ObservedObject var journal: Journal
    let entree: Entree
    let dossier: URL

    var courante: Entree { journal.entrees.first { $0.id == entree.id } ?? entree }

    var body: some View {
        VStack(spacing: 16) {
            if let nom = courante.extrait, FileManager.default.fileExists(atPath: dossier.appendingPathComponent(nom).path) {
                let player = AVPlayer(url: dossier.appendingPathComponent(nom))
                VideoPlayer(player: player)
                    .frame(maxHeight: 420)
                    .onAppear { player.rate = 0.25 }
            } else if courante.extrait != nil {
                Text("Extrait en cours d'enregistrement…").foregroundStyle(.secondary)
            }
            Text("Verdict de l'appli : \(courante.appel.verdict.rawValue)").font(.headline).foregroundStyle(couleur(courante.appel.verdict))
            Text(String(format: "Distance au bord : %.1f cm (± %.1f cm), niveau %@", courante.appel.distanceCm, courante.appel.margeCm,
                        courante.appel.niveau.rawValue))
            if courante.appel.extrapoleMs >= 1 {
                Text(String(format: "Contact extrapolé sur %.0f ms (balle non vue au contact)", courante.appel.extrapoleMs)).font(.caption)
            }
            Text("Ton jugement :").font(.headline)
            HStack {
                Button("Bonne") { journal.annoter(courante, .bonne) }
                    .buttonStyle(.borderedProminent).tint(courante.annotation == .bonne ? .green : .gray)
                Button("Faute") { journal.annoter(courante, .faute) }
                    .buttonStyle(.borderedProminent).tint(courante.annotation == .faute ? .red : .gray)
                if courante.annotation != nil { Button("Effacer") { journal.annoter(courante, nil) } }
            }
            Spacer()
        }
        .padding()
        .navigationTitle("\(courante.source) \(courante.tVideo.mmss)")
    }
}
