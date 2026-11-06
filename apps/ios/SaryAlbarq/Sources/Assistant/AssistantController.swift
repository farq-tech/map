import Combine
import Foundation

/// «اسأل سرى»: one question at a time — heard (on-device speech) or typed, understood
/// (`AssistantParser`), answered from the app's state (`AssistantAnswers`), optionally spoken.
@MainActor
final class AssistantController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(String)
        case thinking(String)
        case answered(question: String, AssistantAnswer)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var typed = ""
    /// Where the last intent came from (debug readout / UI tests).
    @Published private(set) var lastSource: AssistantParser.Source = .none
    @Published private(set) var lastLatencyMs: Int?

    let speech = AssistantSpeech()
    let voice = AssistantVoice()
    let store: AssistantModelStore
    private let parser: AssistantParser
    private let model: AssistantLanguageModel?
    private let engine: LlamaIntentEngine?
    /// The app's state at the moment of the question.
    var facts: () -> AssistantFacts
    /// Runs an answer's action (navigate, radio, channel, chat…). Never SOS: there is no such action.
    var perform: (AssistantAction) -> Void = { _ in }
    /// Driving: voice only, big targets, the answer is spoken.
    var driving: () -> Bool = { false }

    static let speakKey = "sary.assistant.speak.v1"
    var speaksAnswers: Bool {
        get { UserDefaults.standard.object(forKey: Self.speakKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.speakKey); objectWillChange.send() }
    }

    init(facts: @escaping () -> AssistantFacts, store: AssistantModelStore = .shared,
         model: AssistantLanguageModel? = nil, resources: AssistantPrompt.Resources? = .load()) {
        self.facts = facts
        self.store = store
        if let model {
            self.model = model
            engine = nil
        } else if LlamaIntentEngine.available {
            engine = LlamaIntentEngine.shared
            self.model = engine
        } else {
            engine = nil
            self.model = nil
        }
        parser = AssistantParser(resources: resources)
        speech.onFinal = { [weak self] t in self?.ask(t) }
        speech.$state.receive(on: DispatchQueue.main).sink { [weak self] s in
            guard let self else { return }
            switch s {
            case let .listening(t): self.phase = .listening(t)
            case let .unavailable(msg):
                self.phase = .answered(question: "", AssistantAnswer(kind: .clarify, text: msg, spoken: .system(msg)))
            case .idle:
                if case .listening = self.phase { self.phase = .idle }
            }
        }.store(in: &bag)
    }

    private var bag = Set<AnyCancellable>()

    /// The model when it is downloaded, switched on, and the phone is cool and not in Low Power Mode.
    var modelActive: Bool {
        guard store.modelURL != nil, AssistantPower.modelAllowed else { return false }
        return engine == nil ? model != nil : LlamaIntentEngine.available
    }

    func micTapped() {
        voice.stop()
        if speech.isListening { return speech.finish() }
        prewarm()
        speech.start()
    }

    func prewarm() {
        guard let engine, let r = parser.resources else { return }
        engine.modelURL = store.modelURL
        let f = facts()
        engine.prewarm(AssistantPrompt.make(r, question: "", members: f.memberNames, destination: f.destinationName))
    }

    func submitTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        ask(t)
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        phase = .thinking(q)
        let started = Date()
        let f0 = facts()
        engine?.modelURL = store.modelURL
        Task { [weak self] in
            guard let self else { return }
            let useModel = self.modelActive ? self.model : nil
            let r = await self.parser.parse(q, members: f0.memberNames, destination: f0.destinationName, model: useModel)
            self.lastSource = r.source
            self.lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
            if r.intent == .nearestFuel || r.intent == .navigate(.station) { await self.waitForStations() }
            let answer = AssistantAnswers.answer(r.intent, self.facts())
            self.phase = .answered(question: q, answer)
            if self.speaksAnswers || self.driving() { self.voice.speak(answer.spoken) }
            if let a = answer.action { self.perform(a) }
        }
    }

    /// The stations are fetched on demand: ask for them and wait a little (they need the network
    /// once; offline the answer says so instead of naming a station it does not know).
    private func waitForStations() async {
        func settled() -> Bool {
            switch facts().stations {
            case .loaded?, .empty?, .error?: return true
            default: return false
            }
        }
        if settled() { return }
        perform(.openStations)
        for _ in 0..<20 where !settled() { try? await Task.sleep(nanoseconds: 300_000_000) }
    }

    func reset() {
        speech.cancel()
        voice.stop()
        phase = .idle
    }
}

