import AVFoundation
import JugeCore

/// Caméra arrière en 240 images/s (1920 × 1080, BGRA), lampe et transmission des images.
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private(set) var device: AVCaptureDevice?
    private let sortie = AVCaptureVideoDataOutput()
    let fileAnalyse = DispatchQueue(label: "analyse", qos: .userInteractive)
    private let fileConfig = DispatchQueue(label: "camera.config")
    private(set) var imagesParSeconde: Double = 0

    /// Appelée sur la file d'analyse pour chaque image reçue.
    var surImage: ((CMSampleBuffer) -> Void)?

    enum Erreur: LocalizedError {
        case pasDeCamera, pasDe240, refus
        var errorDescription: String? {
            switch self {
            case .pasDeCamera: return "Caméra arrière introuvable."
            case .pasDe240: return "Cette caméra ne filme pas à 240 images par seconde en 1080p."
            case .refus: return "L'accès à la caméra est refusé. Autorise-le dans Réglages > Juge de ligne."
            }
        }
    }

    func demarrer() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            if !(await AVCaptureDevice.requestAccess(for: .video)) { throw Erreur.refus }
        default: throw Erreur.refus
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            fileConfig.async {
                do { try self.configurer(); self.session.startRunning(); c.resume() } catch { c.resume(throwing: error) }
            }
        }
    }

    func arreter() { fileConfig.async { self.session.stopRunning() } }

    private func configurer() throws {
        guard session.inputs.isEmpty else { return }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw Erreur.pasDeCamera }
        device = dev
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .inputPriority
        let entree = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(entree) else { throw Erreur.pasDeCamera }
        session.addInput(entree)

        // format 1920 × 1080 capable de 240 i/s (le même que la vidéo au ralenti de l'appareil photo)
        let formats = dev.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080 && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 240 }
        }
        guard let format = formats.first(where: { !$0.isVideoBinned }) ?? formats.first else { throw Erreur.pasDe240 }
        try dev.lockForConfiguration()
        dev.activeFormat = format
        let d = CMTime(value: 1, timescale: 240)
        dev.activeVideoMinFrameDuration = d
        dev.activeVideoMaxFrameDuration = d
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        dev.unlockForConfiguration()

        sortie.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        sortie.alwaysDiscardsLateVideoFrames = true
        sortie.setSampleBufferDelegate(self, queue: fileAnalyse)
        guard session.canAddOutput(sortie) else { throw Erreur.pasDeCamera }
        session.addOutput(sortie)
        // pas de rotation des images : on reste en paysage (moins de calcul), le cœur s'occupe de l'orientation
        if let c = sortie.connection(with: .video), c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
    }

    /// Bloque la mise au point une fois la ligne calibrée (évite que l'image « pompe » pendant le jeu).
    func bloquerMiseAuPoint(_ bloquer: Bool) {
        fileConfig.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let mode: AVCaptureDevice.FocusMode = bloquer ? .locked : .continuousAutoFocus
            if dev.isFocusModeSupported(mode) { dev.focusMode = mode }
            dev.unlockForConfiguration()
        }
    }

    /// Lampe arrière allumée pendant `duree` secondes.
    func flash(duree: Double = 1.5) {
        fileConfig.async {
            guard let dev = self.device, dev.hasTorch, (try? dev.lockForConfiguration()) != nil else { return }
            try? dev.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
            dev.unlockForConfiguration()
            self.fileConfig.asyncAfter(deadline: .now() + duree) {
                guard (try? dev.lockForConfiguration()) != nil else { return }
                dev.torchMode = .off
                dev.unlockForConfiguration()
            }
        }
    }

    // MARK: - images
    private var derniers: [Double] = []
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        derniers.append(t)
        if derniers.count > 240 { derniers.removeFirst(derniers.count - 240) }
        if derniers.count > 10, let a = derniers.first, let b = derniers.last, b > a {
            imagesParSeconde = Double(derniers.count - 1) / (b - a)
        }
        surImage?(sampleBuffer)
    }

    private(set) var imagesPerdues = 0
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        imagesPerdues += 1
    }
}
