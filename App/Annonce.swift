import AVFoundation

/// L'annonce « Faute ! ». Par ordre de préférence :
/// 1. le son personnel (Documents/annonce.caf), enregistré dans l'appli ou importé d'un fichier ;
/// 2. un son fourni avec l'appli (faute.m4a dans les ressources), s'il existe ;
/// 3. la voix française de l'iPhone.
/// Le son est préparé à l'avance pour partir sans délai.
@MainActor
final class Annonce: ObservableObject {
    private let voix = AVSpeechSynthesizer()
    private var lecteur: AVAudioPlayer?
    private var enregistreur: AVAudioRecorder?
    @Published private(set) var enregistrement = false
    @Published private(set) var source = "voix de l'iPhone"

    static var urlPerso: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("annonce.caf")
    }
    private static var urlBrut: URL { FileManager.default.temporaryDirectory.appendingPathComponent("annonce-brut.caf") }

    init() {
        lecture()
        charger()
        // échauffement silencieux du moteur de voix
        let u = AVSpeechUtterance(string: "Faute")
        u.volume = 0
        voix.speak(u)
    }

    /// .playback : on entend l'annonce même en mode silencieux, et sur une enceinte Bluetooth connectée.
    private func lecture() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? s.setActive(true)
    }

    private func charger() {
        lecteur = nil
        if FileManager.default.fileExists(atPath: Self.urlPerso.path), let p = try? AVAudioPlayer(contentsOf: Self.urlPerso) {
            lecteur = p; source = "ton son enregistré"
        } else if let u = Bundle.main.url(forResource: "faute", withExtension: "m4a"), let p = try? AVAudioPlayer(contentsOf: u) {
            lecteur = p; source = "son fourni avec l'appli"
        } else {
            source = "voix de l'iPhone"
        }
        lecteur?.volume = 1
        lecteur?.prepareToPlay()
    }

    func faute() {
        if let p = lecteur {
            p.currentTime = 0
            p.play()
            return
        }
        if voix.isSpeaking { voix.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: "Faute !")
        u.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        u.volume = 1
        u.rate = 0.52
        u.pitchMultiplier = 1.15
        u.preUtteranceDelay = 0
        voix.speak(u)
    }

    // MARK: - son personnel

    /// Enregistre 2 s au micro, puis coupe les silences et monte le volume au maximum.
    func enregistrer() async -> String? {
        guard !enregistrement else { return nil }
        guard await AVAudioApplication.requestRecordPermission() else {
            return "Micro refusé : autorise-le dans Réglages > Juge de ligne."
        }
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try s.setActive(true)
            let reglages: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100.0,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false]
            let r = try AVAudioRecorder(url: Self.urlBrut, settings: reglages)
            enregistreur = r
            enregistrement = true
            r.record(forDuration: 2)
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            r.stop()
            enregistrement = false
            lecture()
            try Self.nettoyer(Self.urlBrut, vers: Self.urlPerso)
            charger()
            faute()
            return nil
        } catch {
            enregistrement = false
            lecture()
            return "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    /// Utilise un fichier audio choisi dans Fichiers (m4a, mp3, wav…).
    func importer(_ url: URL) -> String? {
        let acces = url.startAccessingSecurityScopedResource()
        defer { if acces { url.stopAccessingSecurityScopedResource() } }
        do {
            try Self.nettoyer(url, vers: Self.urlPerso)
            charger()
            faute()
            return nil
        } catch {
            return "Fichier illisible : \(error.localizedDescription)"
        }
    }

    func revenirALaVoix() {
        try? FileManager.default.removeItem(at: Self.urlPerso)
        charger()
    }

    /// Coupe le silence avant et après (seuil à 5 % du maximum), garde au plus 1,5 s
    /// et normalise le maximum à 98 % de la pleine échelle.
    nonisolated static func nettoyer(_ src: URL, vers dest: URL) throws {
        let f = try AVAudioFile(forReading: src)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.processingFormat.sampleRate, channels: 1, interleaved: false)!
        let n = AVAudioFrameCount(f.length)
        guard n > 0, let lu = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: n) else { throw CocoaError(.fileReadCorruptFile) }
        try f.read(into: lu)
        // mono : moyenne des canaux
        let canaux = Int(f.processingFormat.channelCount), total = Int(lu.frameLength)
        var x = [Float](repeating: 0, count: total)
        if let d = lu.floatChannelData {
            for c in 0..<canaux { for i in 0..<total { x[i] += d[c][i] / Float(canaux) } }
        } else if let d = lu.int16ChannelData {
            for c in 0..<canaux { for i in 0..<total { x[i] += Float(d[c][i]) / 32768 / Float(canaux) } }
        }
        let crete = x.map(abs).max() ?? 0
        guard crete > 0.01 else { throw NSError(domain: "annonce", code: 1, userInfo: [NSLocalizedDescriptionKey: "son trop faible ou vide"]) }
        let seuil = 0.05 * crete
        let debut = max(0, (x.firstIndex { abs($0) > seuil } ?? 0) - Int(0.01 * fmt.sampleRate))
        var fin = min(total, (x.lastIndex { abs($0) > seuil } ?? total - 1) + Int(0.08 * fmt.sampleRate))
        fin = min(fin, debut + Int(1.5 * fmt.sampleRate))
        let k = 0.98 / crete
        let m = AVAudioFrameCount(fin - debut)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: m) else { throw CocoaError(.fileWriteUnknown) }
        out.frameLength = m
        for i in 0..<Int(m) {
            // fondu de 5 ms aux extrémités pour éviter les clics
            let fondu = min(1, Float(i) / Float(0.005 * fmt.sampleRate), Float(Int(m) - i) / Float(0.005 * fmt.sampleRate))
            out.floatChannelData![0][i] = x[debut + i] * k * fondu
        }
        try? FileManager.default.removeItem(at: dest)
        let w = try AVAudioFile(forWriting: dest, settings: fmt.settings)
        try w.write(from: out)
    }
}
