import Foundation

/// The on-device model, seen from the parser: a prompt in, the grammar-constrained JSON out.
/// `LlamaIntentEngine` in the app; a recorded-replay fake in the tests.
protocol AssistantLanguageModel: AnyObject {
    /// nil when the model cannot answer now (not loaded, too hot, Low Power Mode…).
    func classify(_ prompt: AssistantPrompt) async -> String?
}

/// The few-shot prompt and the grammar for one trip (`Resources/Assistant`). The prefix — the
/// instructions and the examples — is the same for every question of a trip, so the engine
/// keeps it evaluated (its KV cache) and only reads the new question.
struct AssistantPrompt: Equatable {
    var prefix: String
    var question: String
    var grammar: String

    var full: String { prefix + Self.turn(question) }

    static func turn(_ q: String) -> String {
        "<|im_start|>user\n\(q)<|im_end|>\n<|im_start|>assistant\n"
    }

    struct Resources: Equatable {
        var system: String
        var examples: [(String, String)]
        var grammar: String

        static func == (a: Resources, b: Resources) -> Bool {
            a.system == b.system && a.grammar == b.grammar && a.examples.map(\.0) == b.examples.map(\.0) && a.examples.map(\.1) == b.examples.map(\.1)
        }

        static func load(_ bundle: Bundle = .main) -> Resources? {
            func read(_ name: String, _ ext: String) -> String? {
                (bundle.url(forResource: name, withExtension: ext) ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Assistant"))
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            }
            guard let s = read("assistant-prompt", "txt"), let e = read("assistant-examples", "txt"), let g = read("assistant-intent", "gbnf") else { return nil }
            let ex = e.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.components(separatedBy: " => ")
                return parts.count == 2 ? (parts[0], parts[1]) : nil
            }
            return Resources(system: s.trimmingCharacters(in: .whitespacesAndNewlines), examples: ex, grammar: g)
        }
    }

    /// Strip what a member's name could do to the prompt or the grammar.
    static func safeName(_ s: String) -> String {
        String(s.filter { !"\"\\<>|{}\n\r".contains($0) }.prefix(30)).trimmingCharacters(in: .whitespaces)
    }

    static func make(_ r: Resources, question: String, members: [String], destination: String?) -> AssistantPrompt {
        let names = members.map(safeName).filter { !$0.isEmpty }
        let m1 = names.first ?? "سعود", m2 = names.dropFirst().first ?? m1
        let system = r.system.replacingOccurrences(of: "{members}", with: names.isEmpty ? "(لا أحد غيري)" : names.joined(separator: "، "))
            .replacingOccurrences(of: "{destination}", with: destination.map(safeName).flatMap { $0.isEmpty ? nil : $0 } ?? "(غير محددة)")
        var p = "<|im_start|>system\n\(system)<|im_end|>\n"
        for (u, a) in r.examples {
            /* Examples that name a member only make sense when the trip has them (the grammar allows only its names). */
            if names.isEmpty, u.contains("{m1}") || u.contains("{m2}") { continue }
            let fill: (String) -> String = { $0.replacingOccurrences(of: "{m1}", with: m1).replacingOccurrences(of: "{m2}", with: m2) }
            p += "<|im_start|>user\n\(fill(u))<|im_end|>\n<|im_start|>assistant\n\(fill(a))<|im_end|>\n"
        }
        let alts = names.map { " | \"\\\"\($0)\\\"\"" }.joined()
        let g = r.grammar.replacingOccurrences(of: "{member}", with: alts)
        let q = String(question.replacingOccurrences(of: "<|", with: "").prefix(160))
        return AssistantPrompt(prefix: p, question: q, grammar: g)
    }
}

/// Free speech or text → one intent. The keyword rules first (instant, and safety words always
/// win); the model only for what they cannot place; and if neither is sure, nothing is guessed.
struct AssistantParser {
    enum Source: String, Equatable { case keywords, model, none }

    struct Result: Equatable {
        var intent: AssistantIntent
        var source: Source
    }

    var resources: AssistantPrompt.Resources?

    func parse(_ text: String, members: [String], destination: String?, model: AssistantLanguageModel?) async -> Result {
        let ctx = AssistantKeywords.Context(members: members, destinationName: destination)
        if let k = AssistantKeywords.match(text, ctx) { return Result(intent: k, source: .keywords) }
        guard let model, let r = resources, !AssistantText.normalize(text).isEmpty else { return Result(intent: .unknown, source: .none) }
        let prompt = AssistantPrompt.make(r, question: text, members: members, destination: destination)
        guard let raw = await model.classify(prompt), let i = AssistantIntent.decode(json: raw, members: members.map(AssistantPrompt.safeName)) else {
            return Result(intent: .unknown, source: .none)
        }
        /* The model may only ever *explain* SOS like the rules do; it never changes what the assistant can do. */
        return Result(intent: i, source: i == .unknown ? .none : .model)
    }
}
