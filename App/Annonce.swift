import AVFoundation

/// Le « Faute ! » parlé, fort, comme un juge de ligne. La voix est préparée au lancement
/// pour que la première annonce parte sans délai.
final class Annonce {
    private let voix = AVSpeechSynthesizer()

    init() {
        let s = AVAudioSession.sharedInstance()
        // .playback : on entend l'annonce même si l'iPhone est en mode silencieux
        try? s.setCategory(.playback, mode: .default, options: [.duckOthers])
        try? s.setActive(true)
        // échauffement silencieux du moteur de voix
        let u = AVSpeechUtterance(string: "Faute")
        u.volume = 0
        voix.speak(u)
    }

    func faute() {
        if voix.isSpeaking { voix.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: "Faute !")
        u.voice = AVSpeechSynthesisVoice(language: "fr-FR")
        u.volume = 1
        u.rate = 0.52
        u.pitchMultiplier = 1.15
        u.preUtteranceDelay = 0
        voix.speak(u)
    }
}
