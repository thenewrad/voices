import AVFoundation

enum BeepTone: String, CaseIterable, Identifiable {
    case standard = "standard"
    case double   = "double"
    case chime    = "chime"
    case subtle   = "subtle"

    var id: String { rawValue }
    var isDefault: Bool { self == .standard }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .double:   return "Double"
        case .chime:    return "Chime"
        case .subtle:   return "Subtle"
        }
    }

    // Filename in the app bundle (without extension)
    var filename: String {
        switch self {
        case .standard: return "tone_standard"
        case .double:   return "tone_double"
        case .chime:    return "tone_chime"
        case .subtle:   return "tone_subtle"
        }
    }

    static var stored: BeepTone {
        BeepTone(rawValue: UserDefaults.standard.string(forKey: "beepTone") ?? "") ?? .standard
    }
}

final class BeepToneService: NSObject, AVAudioPlayerDelegate {
    static let shared = BeepToneService()

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?

    private override init() { super.init() }

    func play(_ tone: BeepTone) async {
        guard let url = Bundle.main.url(forResource: tone.filename, withExtension: "wav") else {
            print("[BeepTone] ❌ File not found in bundle: \(tone.filename).wav")
            return
        }
        guard let newPlayer = (try? AVAudioPlayer(contentsOf: url)) else {
            print("[BeepTone] ❌ Failed to create player for: \(url)")
            return
        }
        print("[BeepTone] ✓ Playing \(tone.filename).wav")
        player = newPlayer
        player?.delegate = self
        player?.prepareToPlay()
        player?.play()
        await withCheckedContinuation { cont in
            continuation = cont
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        continuation?.resume()
        continuation = nil
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        continuation?.resume()
        continuation = nil
    }
}
