import AVFoundation
import FerrostarCore
import FerrostarCoreFFI
import Foundation

/// Says the turn out loud, twice, in Arabic.
///
/// Ferrostar ships a spoken-instruction observer, and it is not used here for
/// one reason: it speaks the routing server's own text, and that text is the
/// broken bilingual prose `ArabicGuidance` exists to replace. The observer never
/// sees the structured manoeuvre, so it cannot be fixed from inside. This drives
/// the announcements from navigation state instead, which carries the manoeuvre
/// type, the modifier and the road.
///
/// The voice is the system's. iOS ships exactly one Arabic voice — Majed,
/// `ar-001`, Modern Standard, super-compact quality (measured: it is the only
/// `ar-*` voice installed). It is not a Saudi voice and it is not a good one,
/// but it is free, offline, and never fails at the moment a turn arrives. The
/// phrasing above is what makes it usable; a cloned Saudi voice can replace this
/// layer later without touching a word of the sentence-building.
@MainActor
final class ArabicVoiceGuide {
    /// Off until someone asks for it: a map that starts talking on its own, in
    /// a car with passengers, is a map people mute permanently.
    var isEnabled = true

    private let synthesizer = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice?
    /// What has already been said for the step being driven, so a manoeuvre is
    /// announced once per phase and not on every location update.
    private var spoken: Set<String> = []
    private var sessionReady = false

    init() {
        voice = Self.arabicVoice()
    }

    /// The best Arabic voice the phone has, or none.
    ///
    /// Preference order is Saudi, then any Arabic. Nothing is invented: if the
    /// phone has no Arabic voice at all this stays nil and the guide stays
    /// silent rather than reading Arabic text with an English voice, which is
    /// unintelligible in a way that sounds like a bug in the route.
    private static func arabicVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let saudi = voices.first(where: { $0.language.lowercased() == "ar-sa" }) {
            return saudi
        }
        /* Enhanced or premium first when a user has downloaded one. */
        let arabic = voices.filter { $0.language.lowercased().hasPrefix("ar") }
        return arabic.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    var hasVoice: Bool { voice != nil }

    /// Start of a new trip: forget what was said on the last one.
    func reset() {
        spoken.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// Called on every navigation state update.
    func consider(state: NavigationState?) {
        guard isEnabled, let state else { return }
        guard let progress = state.currentProgress else { return }
        let remaining = progress.distanceToNextManeuver
        guard remaining.isFinite, remaining >= 0 else { return }

        let phase: ArabicGuidance.Phase
        if remaining <= ArabicGuidance.nowMeters {
            phase = .now
        } else if remaining <= ArabicGuidance.prepareMeters {
            phase = .prepare
        } else {
            return
        }

        let instruction = state.currentVisualInstruction?.primaryContent
        /* The road to name is the one you end up on, not the one you are
         * leaving. Measured on a live route: a step's visual instruction
         * describes the manoeuvre at its *end*, and the road that manoeuvre
         * leads onto is the next step's. Naming the current step's road told
         * drivers to turn into the street they were already in. */
        let next = state.remainingSteps?.dropFirst().first
        /* The step this manoeuvre belongs to, identified by something stable
         * across updates: how many steps are left. Distance changes constantly
         * and would re-announce every metre. */
        let stepKey = "\(state.remainingSteps?.count ?? 0)"
        let key = "\(stepKey)#\(phase == .now ? "now" : "prepare")"
        guard !spoken.contains(key) else { return }

        guard let sentence = ArabicGuidance.sentence(
            type: instruction?.maneuverType,
            modifier: instruction?.maneuverModifier,
            roadName: next?.roadName ?? instruction?.text,
            exitNumber: next?.exits.first,
            roundaboutExit: instruction?.roundaboutExitDegrees,
            distanceMeters: remaining,
            phase: phase
        ) else {
            /* Nothing worth saying is a real outcome — mark it said so we do not
             * recompute it on every fix. */
            spoken.insert(key)
            return
        }

        /* Saying "prepare" is pointless once "now" has been said. */
        if phase == .now { spoken.insert("\(stepKey)#prepare") }
        spoken.insert(key)
        #if DEBUG
        /* What the driver will actually hear, on a real route, in order — the
         * only way to check phrasing without sitting in the car. */
        NSLog("[farq-voice] %@", sentence)
        #endif
        speak(sentence)
    }

    func speak(_ text: String) {
        guard let voice else { return }
        prepareSession()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        /* A touch under the default: navigation Arabic is read at speed by a
         * compact voice, and the endings run together at 0.5. */
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.postUtteranceDelay = 0.1
        /* A new instruction replaces an old one. Queuing them means hearing
         * about the turn you already took. */
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        synthesizer.speak(utterance)
    }

    /// Duck the music rather than stop it, and hand the stage back afterwards.
    private func prepareSession() {
        guard !sessionReady else { return }
        sessionReady = true
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .voicePrompt,
                options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            /* No audio session is a reason to stay quiet, not to crash a car's
             * navigation. */
            sessionReady = false
        }
    }
}
