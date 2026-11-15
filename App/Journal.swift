import Foundation
import JugeCore

/// Un rebond jugé, gardé dans le journal (et l'annotation de Bruno, s'il en fait une).
struct Entree: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var source: String           // « Direct » ou nom de la vidéo rejouée
    var tVideo: Double           // instant dans la vidéo (rejeu) ou dans la séance (direct), s
    var appel: Appel
    var extrait: String?         // nom du fichier dans Documents/Extraits
    var annotation: Verdict?     // .bonne ou .faute, choisi par Bruno
}

/// Journal enregistré dans Documents/journal.json et exportable en CSV.
@MainActor
final class Journal: ObservableObject {
    @Published private(set) var entrees: [Entree] = []
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("journal.json")

    init() {
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([Entree].self, from: d) { entrees = e }
    }

    func ajouter(_ e: Entree) { entrees.insert(e, at: 0); sauver() }

    func mettreAJour(_ e: Entree) {
        guard let i = entrees.firstIndex(where: { $0.id == e.id }) else { return }
        entrees[i] = e; sauver()
    }

    func annoter(_ e: Entree, _ v: Verdict?) {
        var e = e; e.annotation = v; mettreAJour(e)
    }

    func effacer() { entrees = []; sauver() }

    private func sauver() {
        if let d = try? JSONEncoder().encode(entrees) { try? d.write(to: url, options: .atomic) }
    }

    /// Concordance entre l'appli et les annotations (les balles douteuses sont comptées à part).
    var concordance: (accords: Int, desaccords: Int, douteuses: Int) {
        var a = 0, d = 0, dt = 0
        for e in entrees {
            guard let an = e.annotation else { continue }
            if e.appel.verdict == .douteuse { dt += 1 } else if e.appel.verdict == an { a += 1 } else { d += 1 }
        }
        return (a, d, dt)
    }

    func csv() -> URL {
        var s = "date;source;instant_s;verdict;niveau;confiance;distance_cm;dehors_cm;marge_cm;extrapole_ms;annotation;extrait\n"
        let f = ISO8601DateFormatter()
        for e in entrees.reversed() {
            let a = e.appel
            s += [f.string(from: e.date), e.source, String(format: "%.3f", e.tVideo), a.verdict.rawValue, a.niveau.rawValue,
                  a.confiance.rawValue, String(format: "%.1f", a.distanceCm), String(format: "%.1f", a.dehorsCm),
                  String(format: "%.1f", a.margeCm), String(format: "%.0f", a.extrapoleMs), e.annotation?.rawValue ?? "",
                  e.extrait ?? ""].joined(separator: ";") + "\n"
        }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("journal-juge-de-ligne.csv")
        try? s.data(using: .utf8)?.write(to: u)
        return u
    }
}

extension Double {
    /// 754.123 s → « 12:34.123 », comme les rapports du script.
    var mmss: String {
        let ms = Int((self * 1000).rounded())
        return String(format: "%02d:%06.3f", ms / 60000, Double(ms % 60000) / 1000)
    }
}
