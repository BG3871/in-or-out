import Foundation
import XCTest
@testable import JugeCore

final class CalibrageTests: XCTestCase {
    func plan(_ stem: String, _ nom: String) throws -> Plan8 {
        let dir = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let crop = try Data(contentsOf: dir.appendingPathComponent("\(stem)_\(nom)_900_1920.u8"))
        var px = [UInt8](repeating: 0, count: 1080 * 1920)
        px.replaceSubrange((900 * 1080)..<(1920 * 1080), with: crop)
        return Plan8(largeur: 1080, hauteur: 1920, pixels: px)
    }

    /// À partir de deux points touchés approximativement (à 8 px près), on retrouve les bords
    /// de ligne trouvés par juge_ligne.py à moins d'un demi-pixel.
    func testRetrouveLaLigneDuScript() throws {
        let attendu: [String: ([Double], [Double], Int, Int)] = [
            "IMG_1299": ([-0.2786640825263625, 905.1752265486193], [-0.1815367010629184, 798.8997228932328], 1154, 1357),
            "IMG_1323": ([-0.22295355224187474, 751.3618021332446], [-0.1259978579936452, 653.8503103386265], 1025, 1241),
        ]
        for (stem, (g, d, y0, y1)) in attendu {
            let centre = { (y: Double) in (Maths.polyval(g, y) + Maths.polyval(d, y)) / 2 }
            let r = Calibrage.reperer(gris: try plan(stem, "gris"), sat: try plan(stem, "sat"),
                                      proche: (centre(Double(y1)) + 8, Double(y1) + 10),
                                      lointain: (centre(Double(y0)) - 6, Double(y0) - 5), coteFaute: .droite)
            guard case .ok(let l, let q) = r else { return XCTFail("\(stem) : \(r)") }
            print(stem, q, l)
            for y in [Double(y0), Double(y1)] {
                XCTAssertEqual(Maths.polyval(l.gauche, y), Maths.polyval(g, y), accuracy: 0.5, "\(stem) bord gauche à y=\(y)")
                XCTAssertEqual(Maths.polyval(l.droite, y), Maths.polyval(d, y), accuracy: 0.5, "\(stem) bord droit à y=\(y)")
            }
            XCTAssertEqual(Double(l.y0), Double(y0), accuracy: 15)
            XCTAssertEqual(Double(l.y1), Double(y1), accuracy: 15)
            XCTAssertEqual(try XCTUnwrap(Calibrage.decalage(l, gris: try plan(stem, "gris"), sat: try plan(stem, "sat"))), 0, accuracy: 0.5)
        }
    }

    /// Sans aucun toucher : la ligne dans l'axe est trouvée seule, aux mêmes bords que le script.
    func testDetectionAutomatique() throws {
        let attendu: [String: ([Double], [Double])] = [
            "IMG_1299": ([-0.2786640825263625, 905.1752265486193], [-0.1815367010629184, 798.8997228932328]),
            "IMG_1323": ([-0.22295355224187474, 751.3618021332446], [-0.1259978579936452, 653.8503103386265]),
        ]
        for (stem, (g, d)) in attendu {
            let debut = Date()
            let r = Calibrage.detecter(gris: try plan(stem, "gris"), sat: try plan(stem, "sat"), coteFaute: .droite)
            print(stem, "détection auto en", Date().timeIntervalSince(debut), "s")
            guard case .ok(let l, let q) = r else { return XCTFail("\(stem) : \(r)") }
            print(stem, q, l)
            for y in [Double(l.y0), Double(l.y1)] {
                XCTAssertEqual(Maths.polyval(l.gauche, y), Maths.polyval(g, y), accuracy: 0.5, "\(stem) bord gauche à y=\(y)")
                XCTAssertEqual(Maths.polyval(l.droite, y), Maths.polyval(d, y), accuracy: 0.5, "\(stem) bord droit à y=\(y)")
            }
        }
    }

    /// Points touchés à côté de toute ligne : refus, pas de ligne inventée.
    func testRefuseSiPasDeLigne() throws {
        let r = Calibrage.reperer(gris: try plan("IMG_1323", "gris"), sat: try plan("IMG_1323", "sat"),
                                  proche: (100, 1450), lointain: (150, 1000), coteFaute: .droite)
        if case .ok = r { XCTFail("ligne inventée") }
    }
}

final class DetecteurTests: XCTestCase {
    /// Image brute en paysage 1920 × 1080 (comme le capteur), fond de court bleu-gris,
    /// avec une balle jaune de rayon 6 px.
    static func image(balle: (Double, Double)?) -> [UInt8] {
        let W = 1920, H = 1080
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for i in 0..<(W * H) { px[4 * i] = 140; px[4 * i + 1] = 110; px[4 * i + 2] = 90; px[4 * i + 3] = 255 }
        if let (bx, by) = balle {
            for y in Int(by) - 8...Int(by) + 8 {
                for x in Int(bx) - 8...Int(bx) + 8 where hypot(Double(x) - bx, Double(y) - by) <= 6 {
                    let i = 4 * (y * W + x)
                    px[i] = 40; px[i + 1] = 215; px[i + 2] = 225
                }
            }
        }
        return px
    }

    func testBalleQuiBougeEnPortrait() {
        let zone = ZoneImage(x: 200, y: 900, largeur: 650, hauteur: 340)  // en portrait
        let det = DetecteurBalle(zonePortrait: zone, orientation: .paysageVersPortrait, largeurBrute: 1920, hauteurBrute: 1080)
        // balle en portrait (500, 1100) puis (510, 1104) ; brut : xb = yp, yb = 1079 − xp
        var res: [Detection] = []
        for (k, (xp, yp)) in [(500.0, 1100.0), (510.0, 1104.0)].enumerated() {
            var img = Self.image(balle: (yp, 1079 - xp))
            res = img.withUnsafeMutableBufferPointer { b in
                det.analyser(ImageBGRA(base: UnsafePointer(b.baseAddress!), largeur: 1920, hauteur: 1080, octetsParLigne: 1920 * 4),
                             numero: k, temps: Double(k) / 240)
            }
        }
        XCTAssertEqual(res.count, 1)
        guard let d = res.first else { return }
        XCTAssertEqual(d.x, 510, accuracy: 0.6)
        XCTAssertEqual(d.y, 1104, accuracy: 0.6)
        XCTAssertGreaterThan(d.aire, 90)
        XCTAssertGreaterThanOrEqual(d.pixJaunes ?? 0, 12)
    }

    func testBalleImmobileIgnoree() {
        let zone = ZoneImage(x: 200, y: 900, largeur: 650, hauteur: 340)
        let det = DetecteurBalle(zonePortrait: zone, orientation: .paysageVersPortrait, largeurBrute: 1920, hauteurBrute: 1080)
        var img = Self.image(balle: (1100, 1079 - 500))
        for k in 0..<3 {
            let r = img.withUnsafeMutableBufferPointer { b in
                det.analyser(ImageBGRA(base: UnsafePointer(b.baseAddress!), largeur: 1920, hauteur: 1080, octetsParLigne: 1920 * 4),
                             numero: k, temps: 0)
            }
            XCTAssertTrue(r.isEmpty)
        }
    }

    func testHSVCommeOpenCV() {
        // valeurs de cv2.cvtColor(np.uint8([[[40, 215, 225]]]), cv2.COLOR_BGR2HSV) = [[[28, 210, 225]]]
        let (h, s, v) = CouleurHSV.hsv(b: 40, g: 215, r: 225)
        XCTAssertEqual(h, 28); XCTAssertEqual(s, 210); XCTAssertEqual(v, 225)
    }
}

final class PerformanceTests: XCTestCase {
    /// Temps d'analyse d'une image dans la zone de la ligne (affiché, pour suivre le budget de 4 ms à 240 i/s).
    func testTempsParImage() {
        let zone = ZoneImage(x: 174, y: 945, largeur: 650, hauteur: 336)  // zone de IMG_1323
        let det = DetecteurBalle(zonePortrait: zone, orientation: .paysageVersPortrait, largeurBrute: 1920, hauteurBrute: 1080)
        var imgs = (0..<2).map { k in DetecteurTests.image(balle: (1100 + Double(k) * 10, 500)) }
        // du « bruit » de mouvement : un joueur qui bouge (bande sombre décalée d'une image à l'autre)
        for k in 0..<2 { for y in 300..<700 { for x in (1000 + k * 6)..<(1060 + k * 6) { imgs[k][4 * (y * 1920 + x) + 1] = 60 } } }
        let debut = Date()
        let n = 240
        for i in 0..<n {
            _ = imgs[i % 2].withUnsafeMutableBufferPointer { b in
                det.analyser(ImageBGRA(base: UnsafePointer(b.baseAddress!), largeur: 1920, hauteur: 1080, octetsParLigne: 1920 * 4),
                             numero: i, temps: Double(i) / 240)
            }
        }
        print(String(format: "Détecteur : %.2f ms par image", Date().timeIntervalSince(debut) * 1000 / Double(n)))
    }
}
