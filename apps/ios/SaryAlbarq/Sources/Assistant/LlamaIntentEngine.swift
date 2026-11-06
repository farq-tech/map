import Foundation
import UIKit
#if canImport(llama)
import llama
#endif

/// When the model may run at all: not when the phone is hot, not in Low Power Mode. Then the
/// keyword rules answer alone (the assistant still works, just less flexibly).
enum AssistantPower {
    static var modelAllowed: Bool {
        let p = ProcessInfo.processInfo
        return p.thermalState != .serious && p.thermalState != .critical && !p.isLowPowerModeEnabled
    }

    static var reason: String? {
        let p = ProcessInfo.processInfo
        if p.isLowPowerModeEnabled { return "وضع توفير الطاقة شغّال: المساعد يفهم الأسئلة الأساسية بس." }
        if p.thermalState == .serious || p.thermalState == .critical { return "الجوال حار: المساعد يفهم الأسئلة الأساسية بس لين يبرد." }
        return nil
    }
}

/// llama.cpp (MIT, ggml-org/llama.cpp, Metal) running the downloaded GGUF on this phone.
/// One serial queue; loaded on the first question, unloaded after 60 s idle, on a memory
/// warning, when the phone heats up or Low Power Mode turns on. The instructions + examples
/// are evaluated once per load (kept in the KV cache); a question reads only its own tokens.
final class LlamaIntentEngine: AssistantLanguageModel {
    static let idleUnloadS: TimeInterval = 60
    static let maxOutputTokens = 48

    private let queue = DispatchQueue(label: "sary.assistant.llama", qos: .userInitiated)
    private let lock = NSLock()
    private var _modelURL: URL?
    /// The downloaded, verified model file (nil: not downloaded or switched off). Set from the main thread.
    var modelURL: URL? {
        get { lock.lock(); defer { lock.unlock() }; return _modelURL }
        set { lock.lock(); _modelURL = newValue; lock.unlock(); if newValue == nil { queue.async { self.unload() } } }
    }
    static let shared = LlamaIntentEngine()
    private var lastUse = Date.distantPast
    private var idleTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    /// ms of the last classify (debug readout + tests on device).
    private(set) var lastTimings: (loadMs: Double, prefixMs: Double, questionMs: Double, tokens: Int)?

    #if canImport(llama)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var vocab: OpaquePointer?
    private var loadedPath: String?
    private var prefixText: String?
    private var prefixCount: Int32 = 0
    private static let backend: Void = { llama_backend_init() }()
    #endif

    init() {
        let nc = NotificationCenter.default
        for name in [UIApplication.didReceiveMemoryWarningNotification, ProcessInfo.thermalStateDidChangeNotification,
                     Notification.Name.NSProcessInfoPowerStateDidChange, UIApplication.didEnterBackgroundNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: nil) { [weak self] n in
                guard let self else { return }
                if n.name == UIApplication.didReceiveMemoryWarningNotification || n.name == UIApplication.didEnterBackgroundNotification || !AssistantPower.modelAllowed {
                    self.queue.async { self.unload() }
                }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        idleTimer?.cancel()
    }

    static var available: Bool {
        #if canImport(llama)
        return true
        #else
        return false
        #endif
    }

    func classify(_ prompt: AssistantPrompt) async -> String? {
        guard AssistantPower.modelAllowed, let url = modelURL else { return nil }
        return await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.run(prompt, url: url)) }
        }
    }

    /// Load ahead (the mic opened): the first answer then waits only for the question.
    func prewarm(_ prompt: AssistantPrompt) {
        guard AssistantPower.modelAllowed, let url = modelURL else { return }
        queue.async {
            #if canImport(llama)
            guard self.load(url) else { return }
            _ = self.ensurePrefix(prompt.prefix)
            self.touch()
            #endif
        }
    }

    private func touch() {
        lastUse = Date()
        guard idleTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastUse) > Self.idleUnloadS { self.unload() }
        }
        t.resume()
        idleTimer = t
    }

    func unloadNow() { queue.async { self.unload() } }

    private func unload() {
        idleTimer?.cancel()
        idleTimer = nil
        #if canImport(llama)
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil
        model = nil
        vocab = nil
        loadedPath = nil
        prefixText = nil
        prefixCount = 0
        #endif
    }

    private func run(_ prompt: AssistantPrompt, url: URL) -> String? {
        #if canImport(llama)
        let t0 = Date()
        guard load(url) else { return nil }
        let t1 = Date()
        guard ensurePrefix(prompt.prefix) else { return nil }
        let t2 = Date()
        defer { touch() }
        let out = generate(question: AssistantPrompt.turn(prompt.question), grammar: prompt.grammar)
        lastTimings = (t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, Date().timeIntervalSince(t2) * 1000, out?.1 ?? 0)
        #if DEBUG
        NSLog("[assistant] llama load %.0f ms, prefix %.0f ms, question %.0f ms → %@", lastTimings!.loadMs, lastTimings!.prefixMs, lastTimings!.questionMs, out?.0 ?? "nil")
        #endif
        return out?.0
        #else
        return nil
        #endif
    }

    #if canImport(llama)
    private func load(_ url: URL) -> Bool {
        if loadedPath == url.path, ctx != nil { return true }
        unload()
        _ = Self.backend
        var mp = llama_model_default_params()
        #if targetEnvironment(simulator)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 99
        #endif
        guard let m = llama_model_load_from_file(url.path, mp) else { return false }
        var cp = llama_context_default_params()
        cp.n_ctx = 2048
        cp.n_batch = 2048
        cp.n_threads = 4
        cp.n_threads_batch = 4
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); return false }
        model = m
        ctx = c
        vocab = llama_model_get_vocab(m)
        loadedPath = url.path
        return true
    }

    private func tokenize(_ s: String, special: Bool) -> [llama_token] {
        let n = Int32(s.utf8.count)
        var buf = [llama_token](repeating: 0, count: Int(n) + 8)
        var k = llama_tokenize(vocab, s, n, &buf, Int32(buf.count), false, special)
        if k < 0 {
            buf = [llama_token](repeating: 0, count: Int(-k))
            k = llama_tokenize(vocab, s, n, &buf, Int32(buf.count), false, special)
        }
        return k > 0 ? Array(buf.prefix(Int(k))) : []
    }

    private func decode(_ tokens: [llama_token], from pos: Int32, lastLogits: Bool) -> Bool {
        guard !tokens.isEmpty, let ctx else { return false }
        var batch = llama_batch_init(Int32(tokens.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, t) in tokens.enumerated() {
            batch.token[i] = t
            batch.pos[i] = pos + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (lastLogits && i == tokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(tokens.count)
        return llama_decode(ctx, batch) == 0
    }

    /// The instructions + examples, once per load and trip.
    private func ensurePrefix(_ prefix: String) -> Bool {
        guard let ctx else { return false }
        if prefixText == prefix { return true }
        llama_memory_clear(llama_get_memory(ctx), true)
        let toks = tokenize(prefix, special: true)
        guard toks.count < 1900, decode(toks, from: 0, lastLogits: false) else { prefixText = nil; return false }
        prefixText = prefix
        prefixCount = Int32(toks.count)
        return true
    }

    private func generate(question: String, grammar: String) -> (String, Int)? {
        guard let ctx, let vocab else { return nil }
        /* Forget the previous question; keep the shared prefix. */
        _ = llama_memory_seq_rm(llama_get_memory(ctx), 0, prefixCount, -1)
        let q = tokenize(question, special: true)
        guard decode(q, from: prefixCount, lastLogits: true) else { return nil }
        guard let chain = llama_sampler_chain_init(llama_sampler_chain_default_params()) else { return nil }
        defer { llama_sampler_free(chain) }
        guard let g = llama_sampler_init_grammar(vocab, grammar, "root") else { return nil }
        llama_sampler_chain_add(chain, g)
        llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        var bytes: [UInt8] = []
        var pos = prefixCount + Int32(q.count)
        var n = 0
        var piece = [CChar](repeating: 0, count: 64)
        while n < Self.maxOutputTokens {
            let tok = llama_sampler_sample(chain, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            let k = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if k > 0 { bytes += piece.prefix(Int(k)).map { UInt8(bitPattern: $0) } }
            n += 1
            /* The grammar's root is complete once the object closes: nothing else may follow. */
            if let s = String(bytes: bytes, encoding: .utf8), s.hasSuffix("}"), (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil {
                return (s, n)
            }
            guard decode([tok], from: pos, lastLogits: true) else { return nil }
            pos += 1
        }
        return String(bytes: bytes, encoding: .utf8).map { ($0, n) }
    }
    #endif
}
