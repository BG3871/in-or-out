import Foundation
import XCTest
@testable import JugeCore

/// Rejeu des détections de IMG_1299 et IMG_1323 (exportées depuis juge_ligne.py) :
/// le cœur Swift doit retrouver les mêmes rebonds que le script, et les verdicts
/// doivent concorder avec les annotations de Bruno (dossiers « Balles bonnes » et « Balles fautes »).
final class RejeuTests: XCTestCase {
    struct Video {
        let dets: [Detection]
        let ligne: LigneAxe
        let attendus: [[String: Any]]
    }

    static var cache: [String: Video] = [:]

    func video(_ stem: String) throws -> Video {
        if let v = Self.cache[stem] { return v }
        let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let pts = try String(contentsOf: dir.appendingPathComponent("\(stem)_pts.csv"), encoding: .utf8)
            .split(separator: "\n").map { Double($0)! }
        let dets = try String(contentsOf: dir.appendingPathComponent("\(stem)_det.csv"), encoding: .utf8)
            .split(separator: "\n").map { l -> Detection in
                let c = l.split(separator: ",").map { Double($0)! }
                let f = Int(c[0])
                return Detection(image: f, temps: pts[f], x: c[1], y: c[2], aire: c[3])
            }
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("\(stem)_expected.json"))) as! [String: Any]
        let l = json["line"] as! [String: Any]
        // Sur les deux vidéos, les balles fautes sont à droite de la ligne (côté vert).
        let ligne = LigneAxe(gauche: l["left"] as! [Double], droite: l["right"] as! [Double],
                             y0: l["y0"] as! Int, y1: l["y1"] as! Int, coteFaute: .droite)
        let v = Video(dets: dets, ligne: ligne, attendus: json["bounces"] as! [[String: Any]])
        Self.cache[stem] = v
        return v
    }

    func classes(_ v: Video, sans masque: (Double, Double)? = nil) -> [RebondClasse] {
        var d = v.dets
        if let (t, w) = masque { d = d.filter { abs($0.temps - t) > w } }
        return Classement.classer(AnalyseHorsLigne.rebonds(d), ligne: v.ligne)
    }

    /// Même liste de rebonds que juge_ligne.py, aux mêmes instants et distances.
    func testPariteAvecLeScript() throws {
        for stem in ["IMG_1299", "IMG_1323"] {
            let v = try video(stem)
            let B = classes(v)
            XCTAssertEqual(B.count, v.attendus.count, "\(stem) : nombre de rebonds")
            for (b, e) in zip(B, v.attendus) {
                XCTAssertEqual(b.rebond.t, e["t"] as! Double, accuracy: 1e-4, "\(stem) instant")
                XCTAssertEqual(b.rebond.x, e["x"] as! Double, accuracy: 0.05, "\(stem) x à \(b.rebond.t)")
                XCTAssertEqual(b.jeu, e["jeu"] as! Bool, "\(stem) jeu à \(b.rebond.t)")
                XCTAssertEqual(b.dribble, e["dribble"] as! Bool, "\(stem) dribble à \(b.rebond.t)")
                if let dcm = e["d_cm"] as? Double {
                    let a = try XCTUnwrap(b.appel, "\(stem) appel manquant à \(b.rebond.t)")
                    XCTAssertEqual(a.distanceCm, dcm, accuracy: 0.05, "\(stem) distance à \(b.rebond.t)")
                    XCTAssertEqual(a.margeCm, e["unc_cm"] as! Double, accuracy: 0.05, "\(stem) marge à \(b.rebond.t)")
                    XCTAssertEqual(a.niveau.rawValue, e["cls"] as! String, "\(stem) niveau à \(b.rebond.t)")
                    XCTAssertEqual(a.confiance.rawValue, e["conf"] as! String)
                } else {
                    XCTAssertNil(b.appel)
                }
            }
        }
    }

    /// Les 10 balles annotées par Bruno sur IMG_1323, et les 2 balles bonnes de IMG_1299 :
    /// jamais de flash sur une balle bonne, et chaque faute est annoncée.
    func testAnnotationsDeBruno() throws {
        let cas: [(String, Double, [Verdict])] = [
            ("IMG_1323", 349.375, [.bonne]), ("IMG_1323", 385.491, [.bonne, .douteuse]),
            ("IMG_1323", 446.923, [.bonne, .douteuse]), ("IMG_1323", 464.727, [.bonne]),
            ("IMG_1323", 610.166, [.bonne, .douteuse]), ("IMG_1323", 692.780, [.bonne]),
            ("IMG_1323", 466.594, [.faute]), ("IMG_1323", 731.779, [.faute]),
            ("IMG_1323", 833.479, [.faute]), ("IMG_1323", 858.282, [.faute]),
            ("IMG_1299", 1209.494, [.bonne]), ("IMG_1299", 1275.603, [.bonne]),
        ]
        for (stem, t, ok) in cas {
            let a = try appels(stem).filter { abs($0.t - t) < 0.05 }
            XCTAssertEqual(a.count, 1, "\(stem) \(t) : appel absent ou en double")
            if let a = a.first { XCTAssertTrue(ok.contains(a.verdict), "\(stem) \(t) : \(a.verdict), attendu \(ok)") }
        }
    }

    /// En direct, on doit annoncer exactement les mêmes rebonds de jeu que l'analyse complète.
    func testJugeDirectIdentiqueAuRejeu() throws {
        for stem in ["IMG_1299", "IMG_1323"] {
            let direct = try appels(stem)
            let horsLigne = classes(try video(stem)).filter { $0.jeu }.compactMap(\.appel)
            XCTAssertEqual(direct.count, horsLigne.count, "\(stem)")
            // seule la durée d'image médiane (donc la marge) peut différer très légèrement :
            // en direct, les positions plus de 30 images après le rebond ne sont pas encore connues
            for (a, b) in zip(direct, horsLigne) {
                XCTAssertEqual(a.t, b.t); XCTAssertEqual(a.distanceCm, b.distanceCm)
                XCTAssertEqual(a.margeCm, b.margeCm, accuracy: 0.05)
                XCTAssertEqual(a.niveau, b.niveau); XCTAssertEqual(a.confiance, b.confiance)
                if a.verdict != b.verdict { XCTAssertLessThan(abs(abs(a.dehorsCm) - b.margeCm), 0.05) }
            }
        }
    }

    /// Délai entre le rebond et l'annonce en direct : moins de 0,25 s.
    func testDelaiDAnnonce() throws {
        let v = try video("IMG_1323")
        let juge = JugeDirect(ligne: v.ligne)
        let parImage = Dictionary(grouping: v.dets, by: \.image)
        let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let pts = try String(contentsOf: dir.appendingPathComponent("IMG_1323_pts.csv"), encoding: .utf8)
            .split(separator: "\n").map { Double($0)! }
        var pires = 0.0
        for (i, t) in pts.enumerated() {
            for a in juge.image(i, temps: t, detections: parImage[i] ?? []) { pires = max(pires, t - a.t) }
        }
        XCTAssertLessThan(pires, 0.25)
    }

    /// Balle masquée ±15 ms au contact : le rebond est retrouvé par extrapolation.
    func testBalleMasquee() throws {
        for (stem, t) in [("IMG_1323", 610.166), ("IMG_1299", 508.409)] {
            let v = try video(stem)
            let ref = classes(v).first { $0.jeu && abs($0.rebond.t - t) < 0.05 }?.appel
            let m = classes(v, sans: (t, 0.015)).first { $0.jeu && abs($0.rebond.t - t) < 0.05 }?.appel
            let r = try XCTUnwrap(ref), a = try XCTUnwrap(m, "\(stem) \(t) perdu quand la balle est masquée")
            XCTAssertGreaterThanOrEqual(a.extrapoleMs, 5)
            XCTAssertLessThanOrEqual(abs(a.distanceCm - r.distanceCm), max(3, a.margeCm))
        }
    }

    func appels(_ stem: String) throws -> [Appel] {
        let v = try video(stem)
        let juge = JugeDirect(ligne: v.ligne)
        var out: [Appel] = []
        let parImage = Dictionary(grouping: v.dets, by: \.image)
        for fr in parImage.keys.sorted() {
            out += juge.image(fr, temps: parImage[fr]![0].temps, detections: parImage[fr]!)
        }
        return out + juge.terminer()
    }
}
