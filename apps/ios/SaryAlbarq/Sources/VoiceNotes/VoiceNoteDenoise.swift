import Accelerate
import AVFoundation
import CoreML
import Foundation

/// «تنقية الصوت» for voice notes, on the sender's phone after recording and before upload:
/// DeepFilterNet3 (github.com/Rikorose/DeepFilterNet, MIT OR Apache-2.0) removes wind, engine
/// and tyre noise. Nothing leaves the device; the receiver's radio chain is untouched.
///
/// The bundled Core ML model (`DeepFilterNet3Stream`, fp16, ≈4 MB) is the network only
/// (encoder + ERB and deep-filter decoders) in fixed 200-frame chunks with its GRU states
/// carried between chunks, so a whole note equals one pass of the original model. Everything
/// around it is libDF ported to Accelerate: 48 kHz, 960-point Vorbis-window STFT with hop 480,
/// 32 ERB bands, 96 deep-filter bins of order 5, exponential feature norms (α = 0.99), the
/// two-frame look-ahead, the ERB gains and the deep filter. The voice is kept natural by a
/// 24 dB attenuation limit (a trace of the scene stays instead of an empty, "underwater" voice).
///
/// Notes are 16 kHz mono: up-sampled ×3 for the model and back, so the output has exactly the
/// input's length. Any failure → nil (the caller sends the original).
enum VoiceNoteDenoise {
    nonisolated static let modelName = "DeepFilterNet3Stream"
    nonisolated static let sampleRate = 48_000
    nonisolated static let fftSize = 960
    nonisolated static let hop = 480
    nonisolated static let bins = 481
    nonisolated static let nbErb = 32
    nonisolated static let nbDf = 96
    nonisolated static let dfOrder = 5
    /// Frames the features are shifted forward (conv look-ahead) = the deep filter's look-ahead.
    nonisolated static let lookahead = 2
    /// Model chunk: `context` frames of the previous chunk + `chunk` new ones.
    nonisolated static let context = 6
    nonisolated static let chunk = 200
    nonisolated static let alpha: Float = 0.99
    nonisolated static let attenuationLimitDb: Float = 24

    enum Failure: Error, Equatable { case noModel, badInput, model }

    struct Report: Equatable {
        var audioMs: Double
        var tookMs: Double
        var inputPeak: Float
        var outputPeak: Float
    }

    // MARK: - Entry points

    /// 16 kHz mono float in → the same length out, denoised. Nil if anything fails.
    nonisolated static func process(_ pcm: AVAudioPCMBuffer) -> (AVAudioPCMBuffer, Report)? {
        guard pcm.format.channelCount == 1, pcm.format.commonFormat == .pcmFormatFloat32, !pcm.format.isInterleaved,
              Int(pcm.format.sampleRate) == 16_000, pcm.frameLength > 0, let d = pcm.floatChannelData?[0] else { return nil }
        let x = Array(UnsafeBufferPointer(start: d, count: Int(pcm.frameLength)))
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let y = try? denoise16k(x), let out = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: pcm.frameLength),
              let o = out.floatChannelData?[0] else { return nil }
        out.frameLength = pcm.frameLength
        y.withUnsafeBufferPointer { o.update(from: $0.baseAddress!, count: y.count) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return (out, Report(audioMs: Double(x.count) / 16, tookMs: ms, inputPeak: peak(x), outputPeak: peak(y)))
    }

    /// 16 kHz samples → denoised 16 kHz samples of the same count (never clipping).
    nonisolated static func denoise16k(_ x: [Float]) throws -> [Float] {
        guard !x.isEmpty, x.allSatisfy(\.isFinite) else { throw Failure.badInput }
        let up = Resample3.up(x)
        var y = try denoise48k(up)
        var down = Resample3.down(y, count: x.count)
        y.removeAll()
        guard down.allSatisfy(\.isFinite) else { throw Failure.model }
        /* No clipping: the model removes energy, but a limit keeps a rare overshoot below full scale. */
        let p = peak(down)
        if p > 0.98 {
            var g = 0.98 / p
            vDSP_vsmul(down, 1, &g, &down, 1, vDSP_Length(down.count))
        }
        return down
    }

    /// 48 kHz samples → denoised 48 kHz samples of the same count (libDF `enhance(pad: true)`).
    nonisolated static func denoise48k(_ x: [Float]) throws -> [Float] {
        guard let model = Model.shared() else { throw Failure.noModel }
        let n = x.count
        /* Padding of one FFT compensates the STFT delay (n_fft − hop), as libDF does. */
        let padded = x + [Float](repeating: 0, count: fftSize)
        let frames = padded.count / hop
        let stft = STFT.shared
        var re = [Float](repeating: 0, count: frames * bins)
        var im = [Float](repeating: 0, count: frames * bins)
        stft.analysis(padded, frames: frames, re: &re, im: &im)
        let feats = Features(re: re, im: im, frames: frames)
        var gains = [Float](repeating: 1, count: frames * nbErb)
        var coefs = [Float](repeating: 0, count: frames * nbDf * dfOrder * 2)
        try model.run(feats, frames: frames, gains: &gains, coefs: &coefs)
        var oRe = re, oIm = im
        applyFilter(re: re, im: im, gains: gains, coefs: coefs, frames: frames, outRe: &oRe, outIm: &oIm)
        let y = stft.synthesis(re: oRe, im: oIm, frames: frames)
        let d = fftSize - hop
        return Array(y[d..<min(y.count, d + n)]) + [Float](repeating: 0, count: max(0, d + n - y.count))
    }

    nonisolated static func peak(_ x: [Float]) -> Float {
        var m: Float = 0
        vDSP_maxmgv(x, 1, &m, vDSP_Length(x.count))
        return m
    }

    /// The ERB gains (above the DF bins), the deep filter (below) and the attenuation limit.
    nonisolated static func applyFilter(re: [Float], im: [Float], gains: [Float], coefs: [Float], frames: Int, outRe: inout [Float], outIm: inout [Float]) {
        let widths = ERB.widths
        var lim = powf(10, -attenuationLimitDb / 20)
        var keep = 1 - lim
        let O2 = dfOrder * 2, back = dfOrder - 1 - lookahead
        re.withUnsafeBufferPointer { xr in
        im.withUnsafeBufferPointer { xi in
        gains.withUnsafeBufferPointer { g in
        coefs.withUnsafeBufferPointer { cf in
        outRe.withUnsafeMutableBufferPointer { yr in
        outIm.withUnsafeMutableBufferPointer { yi in
            let xr = xr.baseAddress!, xi = xi.baseAddress!, g = g.baseAddress!, cf = cf.baseAddress!
            let yr = yr.baseAddress!, yi = yi.baseAddress!
            for t in 0..<frames {
                let row = t * bins
                /* ERB gains for every bin (the deep filter then replaces the low bins). */
                var f = 0
                for (b, w) in widths.enumerated() {
                    var gb = g[t * nbErb + b]
                    vDSP_vsmul(xr + row + f, 1, &gb, yr + row + f, 1, vDSP_Length(w))
                    vDSP_vsmul(xi + row + f, 1, &gb, yi + row + f, 1, vDSP_Length(w))
                    f += w
                }
                /* Deep filter: Σₖ X[t − 2 + k]·c[t, k] over 5 frames, complex. */
                vDSP_vclr(yr + row, 1, vDSP_Length(nbDf))
                vDSP_vclr(yi + row, 1, vDSP_Length(nbDf))
                for k in 0..<dfOrder {
                    let tt = t - back + k
                    guard tt >= 0, tt < frames else { continue }
                    let sr = xr + tt * bins, si = xi + tt * bins
                    /* coefs row: [96 bins][5 orders][re, im] → stride 10 per bin. */
                    var c = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: cf + t * nbDf * O2 + 2 * k),
                                            imagp: UnsafeMutablePointer(mutating: cf + t * nbDf * O2 + 2 * k + 1))
                    var x = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: sr), imagp: UnsafeMutablePointer(mutating: si))
                    var y = DSPSplitComplex(realp: yr + row, imagp: yi + row)
                    vDSP_zvma(&x, 1, &c, vDSP_Stride(O2), &y, 1, &y, 1, vDSP_Length(nbDf))
                }
                /* Attenuation limit: y = lim·x + (1 − lim)·y. */
                vDSP_vsmul(yr + row, 1, &keep, yr + row, 1, vDSP_Length(bins))
                vDSP_vsma(xr + row, 1, &lim, yr + row, 1, yr + row, 1, vDSP_Length(bins))
                vDSP_vsmul(yi + row, 1, &keep, yi + row, 1, vDSP_Length(bins))
                vDSP_vsma(xi + row, 1, &lim, yi + row, 1, yi + row, 1, vDSP_Length(bins))
            }
        }}}}}}
    }

    // MARK: - ERB bands (libDF erb_fb: 48 kHz, 960, 32 bands, ≥ 2 bins each)

    enum ERB {
        nonisolated static let widths: [Int] = {
            func f2e(_ f: Float) -> Float { 9.265 * log1p(f / (24.7 * 9.265)) }
            func e2f(_ e: Float) -> Float { 24.7 * 9.265 * (exp(e / 9.265) - 1) }
            let fw = Float(sampleRate) / Float(fftSize)
            let lo = f2e(0), hi = f2e(Float(sampleRate / 2))
            let step = (hi - lo) / Float(nbErb)
            var out = [Int](repeating: 0, count: nbErb)
            var prev = 0, over = 0
            for i in 1...nbErb {
                let fb = Int((e2f(lo + Float(i) * step) / fw).rounded())
                var nb = fb - prev - over
                if nb < 2 { over = 2 - nb; nb = 2 } else { over = 0 }
                out[i - 1] = nb
                prev = fb
            }
            out[nbErb - 1] += 1
            let tooLarge = out.reduce(0, +) - bins
            if tooLarge > 0 { out[nbErb - 1] -= tooLarge }
            return out
        }()
    }

    // MARK: - Features (libDF feat_erb + feat_cplx, shifted by the look-ahead)

    struct Features {
        /// [frames × 32], already shifted: row t holds frame t + lookahead (zeros at the end).
        var erb: [Float]
        /// [frames × 96] real and imaginary parts, shifted the same way.
        var specRe: [Float]
        var specIm: [Float]

        nonisolated init(re: [Float], im: [Float], frames: Int) {
            let widths = ERB.widths
            let a = VoiceNoteDenoise.alpha
            var erb = [Float](repeating: 0, count: frames * nbErb)
            var sRe = [Float](repeating: 0, count: frames * nbDf)
            var sIm = [Float](repeating: 0, count: frames * nbDf)
            var mean = (0..<nbErb).map { -60 + Float($0) * (-30 / Float(nbErb - 1)) }
            var unit = (0..<nbDf).map { 0.001 + Float($0) * (-0.0009 / Float(nbDf - 1)) }
            var pw = [Float](repeating: 0, count: bins), db = [Float](repeating: 0, count: nbErb)
            var mag = [Float](repeating: 0, count: nbDf), root = mag
            var keepA = a, newA = 1 - a, eps: Float = 1e-10, ten: Float = 10, inv40: Float = 1 / 40
            var nE = Int32(nbErb), nD = Int32(nbDf)
            re.withUnsafeBufferPointer { rp in
            im.withUnsafeBufferPointer { ip in
                for t in 0..<frames {
                    let r = rp.baseAddress! + t * bins, i = ip.baseAddress! + t * bins
                    let dst = t - lookahead
                    /* ERB band energies in dB, then the exponential mean norm. */
                    var x = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: r), imagp: UnsafeMutablePointer(mutating: i))
                    vDSP_zvmags(&x, 1, &pw, 1, vDSP_Length(bins))
                    var f = 0
                    for (b, w) in widths.enumerated() {
                        var m: Float = 0
                        pw.withUnsafeBufferPointer { vDSP_meanv($0.baseAddress! + f, 1, &m, vDSP_Length(w)) }
                        db[b] = m
                        f += w
                    }
                    vDSP_vsadd(db, 1, &eps, &db, 1, vDSP_Length(nbErb))
                    vvlog10f(&db, db, &nE)
                    vDSP_vsmul(db, 1, &ten, &db, 1, vDSP_Length(nbErb))
                    vDSP_vsmsma(db, 1, &newA, mean, 1, &keepA, &mean, 1, vDSP_Length(nbErb))
                    if dst >= 0 {
                        erb.withUnsafeMutableBufferPointer { e in
                            vDSP_vsub(mean, 1, db, 1, e.baseAddress! + dst * nbErb, 1, vDSP_Length(nbErb))
                            vDSP_vsmul(e.baseAddress! + dst * nbErb, 1, &inv40, e.baseAddress! + dst * nbErb, 1, vDSP_Length(nbErb))
                        }
                    }
                    /* The 96 deep-filter bins over the root of their running magnitude. */
                    vDSP_zvabs(&x, 1, &mag, 1, vDSP_Length(nbDf))
                    vDSP_vsmsma(mag, 1, &newA, unit, 1, &keepA, &unit, 1, vDSP_Length(nbDf))
                    if dst >= 0 {
                        vvsqrtf(&root, unit, &nD)
                        sRe.withUnsafeMutableBufferPointer { vDSP_vdiv(root, 1, r, 1, $0.baseAddress! + dst * nbDf, 1, vDSP_Length(nbDf)) }
                        sIm.withUnsafeMutableBufferPointer { vDSP_vdiv(root, 1, i, 1, $0.baseAddress! + dst * nbDf, 1, vDSP_Length(nbDf)) }
                    }
                }
            }}
            self.erb = erb
            specRe = sRe
            specIm = sIm
        }
    }

    // MARK: - STFT (libDF frame_analysis / frame_synthesis)

    final class STFT: @unchecked Sendable {
        nonisolated static let shared = STFT()
        let window: [Float]
        private let fwd: vDSP_DFT_Setup
        private let inv: vDSP_DFT_Setup
        /// vDSP's real inverse ⇄ an unnormalised inverse real FFT (realfft's), measured once.
        private var invScale: Float = 1
        /// The scratch below is shared: one STFT at a time.
        private let lock = NSLock()
        private var ev: [Float], od: [Float], oR: [Float], oI: [Float], frame: [Float]

        nonisolated init() {
            let n = VoiceNoteDenoise.fftSize, h = n / 2
            window = (0..<n).map { i in
                let s = sin(0.5 * Double.pi * (Double(i) + 0.5) / Double(h))
                return Float(sin(0.5 * Double.pi * s * s))
            }
            fwd = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
            inv = vDSP_DFT_zrop_CreateSetup(fwd, vDSP_Length(n), .INVERSE)!
            ev = [Float](repeating: 0, count: h); od = ev; oR = ev; oI = ev
            frame = [Float](repeating: 0, count: n)
            /* Calibrate: forward then inverse of a known frame. */
            let probe = (0..<n).map { Float(sin(Double($0) * 0.37) + 0.5 * cos(Double($0) * 1.9)) }
            var r = [Float](repeating: 0, count: VoiceNoteDenoise.bins), i = r
            probe.withUnsafeBufferPointer { fft($0.baseAddress!, re: &r, im: &i, at: 0, scale: 1) }
            var back = [Float](repeating: 0, count: n)
            back.withUnsafeMutableBufferPointer { ifftRaw(re: r, im: i, at: 0, into: $0.baseAddress!) }
            var num: Float = 0, den: Float = 0
            vDSP_dotpr(back, 1, probe, 1, &num, vDSP_Length(n))
            vDSP_dotpr(probe, 1, probe, 1, &den, vDSP_Length(n))
            /* realfft's inverse of a true spectrum returns n·x. */
            invScale = Float(n) * den / num
        }

        deinit {
            vDSP_DFT_DestroySetup(fwd)
            vDSP_DFT_DestroySetup(inv)
        }

        /// The true one-sided spectrum of n real samples at `x`, times `scale`, into bins [at, at + n/2 + 1).
        nonisolated private func fft(_ x: UnsafePointer<Float>, re: inout [Float], im: inout [Float], at: Int, scale: Float) {
            let n = VoiceNoteDenoise.fftSize, h = n / 2
            /* Even/odd split = the samples read as h complex pairs. */
            ev.withUnsafeMutableBufferPointer { e in
                od.withUnsafeMutableBufferPointer { o in
                    var sc = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                    x.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ctoz($0, 2, &sc, 1, vDSP_Length(h)) }
                }
            }
            vDSP_DFT_Execute(fwd, ev, od, &oR, &oI)
            /* vDSP packs DC in oR[0] and Nyquist in oI[0], all scaled by 2. */
            var s2 = scale / 2
            re.withUnsafeMutableBufferPointer { r in
                im.withUnsafeMutableBufferPointer { i in
                    let r = r.baseAddress! + at, i = i.baseAddress! + at
                    vDSP_vsmul(oR, 1, &s2, r, 1, vDSP_Length(h))
                    vDSP_vsmul(oI, 1, &s2, i, 1, vDSP_Length(h))
                    r[h] = i[0]
                    i[0] = 0
                    i[h] = 0
                }
            }
        }

        /// vDSP's real inverse of bins [at, at + n/2 + 1) into n samples (unscaled).
        nonisolated private func ifftRaw(re: [Float], im: [Float], at: Int, into out: UnsafeMutablePointer<Float>) {
            let h = VoiceNoteDenoise.fftSize / 2
            re.withUnsafeBufferPointer { r in
                im.withUnsafeBufferPointer { i in
                    oR.withUnsafeMutableBufferPointer { a in
                        oI.withUnsafeMutableBufferPointer { b in
                            a.baseAddress!.update(from: r.baseAddress! + at, count: h)
                            b.baseAddress!.update(from: i.baseAddress! + at, count: h)
                            b[0] = r[at + h]
                        }
                    }
                }
            }
            vDSP_DFT_Execute(inv, oR, oI, &ev, &od)
            ev.withUnsafeMutableBufferPointer { e in
                od.withUnsafeMutableBufferPointer { o in
                    var sc = DSPSplitComplex(realp: e.baseAddress!, imagp: o.baseAddress!)
                    out.withMemoryRebound(to: DSPComplex.self, capacity: h) { vDSP_ztoc(&sc, 1, $0, 2, vDSP_Length(h)) }
                }
            }
        }

        /// Frames of `hop` new samples with the previous `hop` before them (zeros at the start).
        nonisolated func analysis(_ x: [Float], frames: Int, re: inout [Float], im: inout [Float]) {
            lock.lock()
            defer { lock.unlock() }
            let n = VoiceNoteDenoise.fftSize, hop = VoiceNoteDenoise.hop, b = VoiceNoteDenoise.bins
            let norm = 1 / (Float(n * n) / Float(2 * hop))
            var buf = [Float](repeating: 0, count: n)
            x.withUnsafeBufferPointer { xp in
                for t in 0..<frames {
                    let s = t * hop - (n - hop)
                    buf.withUnsafeMutableBufferPointer { bp in
                        let lo = max(0, -s), hi = min(n, x.count - s)
                        vDSP_vclr(bp.baseAddress!, 1, vDSP_Length(n))
                        if hi > lo { vDSP_vmul(xp.baseAddress! + s + lo, 1, window.withUnsafeBufferPointer { $0.baseAddress! } + lo, 1, bp.baseAddress! + lo, 1, vDSP_Length(hi - lo)) }
                    }
                    buf.withUnsafeBufferPointer { fft($0.baseAddress!, re: &re, im: &im, at: t * b, scale: norm) }
                }
            }
        }

        nonisolated func synthesis(re: [Float], im: [Float], frames: Int) -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            let n = VoiceNoteDenoise.fftSize, hop = VoiceNoteDenoise.hop, b = VoiceNoteDenoise.bins
            var out = [Float](repeating: 0, count: frames * hop + n)
            var g = invScale
            out.withUnsafeMutableBufferPointer { op in
                frame.withUnsafeMutableBufferPointer { fp in
                    let x = fp.baseAddress!
                    for t in 0..<frames {
                        ifftRaw(re: re, im: im, at: t * b, into: x)
                        vDSP_vsmul(x, 1, &g, x, 1, vDSP_Length(n))
                        window.withUnsafeBufferPointer { vDSP_vmul(x, 1, $0.baseAddress!, 1, x, 1, vDSP_Length(n)) }
                        /* Overlap-add: the first hop goes to output frame t, the rest to the next one. */
                        let o = op.baseAddress! + t * hop
                        vDSP_vadd(o, 1, x, 1, o, 1, vDSP_Length(n))
                    }
                }
            }
            return Array(out[0..<frames * hop])
        }
    }

    // MARK: - The Core ML network, chunk by chunk with its GRU states

    final class Model: @unchecked Sendable {
        private let ml: MLModel
        private let lock = NSLock()
        nonisolated(unsafe) private static var cached: Model?
        nonisolated(unsafe) private static var failed = false
        private static let cacheLock = NSLock()

        nonisolated static var bundledURL: URL? {
            Bundle.main.url(forResource: VoiceNoteDenoise.modelName, withExtension: "mlmodelc")
                ?? Bundle(for: Model.self).url(forResource: VoiceNoteDenoise.modelName, withExtension: "mlmodelc")
        }

        nonisolated static var isAvailable: Bool { bundledURL != nil }

        nonisolated static func shared() -> Model? {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let cached { return cached }
            guard !failed, let url = bundledURL else { return nil }
            let cfg = MLModelConfiguration()
            /* The Neural Engine where it helps; the GRUs fall back to the CPU by themselves. */
            cfg.computeUnits = .cpuAndNeuralEngine
            guard let ml = try? MLModel(contentsOf: url, configuration: cfg) else {
                failed = true
                return nil
            }
            let m = Model(ml)
            cached = m
            return m
        }

        nonisolated private init(_ ml: MLModel) { self.ml = ml }

        nonisolated func run(_ f: Features, frames: Int, gains: inout [Float], coefs: inout [Float]) throws {
            lock.lock()
            defer { lock.unlock() }
            let P = VoiceNoteDenoise.context, C = VoiceNoteDenoise.chunk, T = P + C
            let E = VoiceNoteDenoise.nbErb, D = VoiceNoteDenoise.nbDf, O2 = VoiceNoteDenoise.dfOrder * 2
            func arr(_ shape: [Int]) throws -> MLMultiArray {
                let a = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
                a.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in p.initialize(repeating: 0) }
                return a
            }
            var hEnc = try arr([1, 1, 256]), hErb = try arr([2, 1, 256]), hDf = try arr([2, 1, 256])
            let fe = try arr([1, 1, T, E]), fs = try arr([1, 2, T, D]), valid = try arr([1])
            var s = 0
            while s < frames {
                let a = s - P, hi = min(frames, s + C)
                /* Rows outside [0, hi) are zero (start of the note, or past its end). */
                fe.withUnsafeMutableBufferPointer(ofType: Float.self) { p, st in
                    f.erb.withUnsafeBufferPointer { src in
                        for j in 0..<T {
                            let t = a + j, d = p.baseAddress! + j * st[2]
                            if t >= 0 && t < hi {
                                if st[3] == 1 { d.update(from: src.baseAddress! + t * E, count: E) }
                                else { for b in 0..<E { d[b * st[3]] = src[t * E + b] } }
                            } else {
                                vDSP_vclr(d, vDSP_Stride(st[3]), vDSP_Length(E))
                            }
                        }
                    }
                }
                fs.withUnsafeMutableBufferPointer(ofType: Float.self) { p, st in
                    f.specRe.withUnsafeBufferPointer { sr in
                        f.specIm.withUnsafeBufferPointer { si in
                            for j in 0..<T {
                                let t = a + j
                                let dr = p.baseAddress! + j * st[2], di = p.baseAddress! + st[1] + j * st[2]
                                if !(t >= 0 && t < hi) {
                                    vDSP_vclr(dr, vDSP_Stride(st[3]), vDSP_Length(D))
                                    vDSP_vclr(di, vDSP_Stride(st[3]), vDSP_Length(D))
                                } else if st[3] == 1 {
                                    dr.update(from: sr.baseAddress! + t * D, count: D)
                                    di.update(from: si.baseAddress! + t * D, count: D)
                                } else {
                                    for k in 0..<D { dr[k * st[3]] = sr[t * D + k]; di[k * st[3]] = si[t * D + k] }
                                }
                            }
                        }
                    }
                }
                valid[0] = NSNumber(value: s == 0 ? 0 : 1)
                let inp = try MLDictionaryFeatureProvider(dictionary: [
                    "feat_erb": fe, "feat_spec": fs, "h_enc": hEnc, "h_erb": hErb, "h_df": hDf, "ctx_valid": valid,
                ])
                let out = try ml.prediction(from: inp)
                guard let m = out.featureValue(for: "mask")?.multiArrayValue, let c = out.featureValue(for: "coefs")?.multiArrayValue,
                      let he = out.featureValue(for: "h_enc_out")?.multiArrayValue, let hr = out.featureValue(for: "h_erb_out")?.multiArrayValue,
                      let hd = out.featureValue(for: "h_df_out")?.multiArrayValue else { throw Failure.model }
                let keep = hi - s
                /* mask [1,1,C,32] and coefs [1,C,96,10]: row-major after `flat`. */
                let mf = try Self.flat(m), cf = try Self.flat(c)
                guard mf.count == C * E, cf.count == C * D * O2 else { throw Failure.model }
                gains.withUnsafeMutableBufferPointer { g in
                    mf.withUnsafeBufferPointer { src in
                        g.baseAddress!.advanced(by: s * E).update(from: src.baseAddress!, count: keep * E)
                    }
                }
                coefs.withUnsafeMutableBufferPointer { g in
                    cf.withUnsafeBufferPointer { src in
                        g.baseAddress!.advanced(by: s * D * O2).update(from: src.baseAddress!, count: keep * D * O2)
                    }
                }
                hEnc = try Self.copy(he); hErb = try Self.copy(hr); hDf = try Self.copy(hd)
                s = hi
            }
        }

        /// The array as row-major Float32 (any strides; Float16 or Float32 outputs).
        nonisolated static func flat(_ a: MLMultiArray) throws -> [Float] {
            let r = a.shape.count
            guard (1...4).contains(r) else { throw Failure.model }
            let shape = [Int](repeating: 1, count: 4 - r) + a.shape.map(\.intValue)
            let st = [Int](repeating: 0, count: 4 - r) + a.strides.map(\.intValue)
            let count = shape.reduce(1, *)
            var out = [Float](repeating: 0, count: count)
            let rowMajor = st[3] == 1 && st[2] == shape[3] && st[1] == shape[2] * shape[3] && (shape[0] == 1 || st[0] == shape[1] * shape[2] * shape[3])
            if rowMajor, a.dataType == .float32 {
                a.withUnsafeBufferPointer(ofType: Float.self) { p in out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p.baseAddress!, count: count) } }
                return out
            }
            func gather<T>(_ p: UnsafeBufferPointer<T>, _ conv: (T) -> Float) {
                out.withUnsafeMutableBufferPointer { o in
                    var i = 0
                    for d0 in 0..<shape[0] {
                        for d1 in 0..<shape[1] {
                            for d2 in 0..<shape[2] {
                                let base = d0 * st[0] + d1 * st[1] + d2 * st[2]
                                for d3 in 0..<shape[3] {
                                    o[i] = conv(p[base + d3 * st[3]])
                                    i += 1
                                }
                            }
                        }
                    }
                }
            }
            switch a.dataType {
            case .float32: a.withUnsafeBufferPointer(ofType: Float.self) { gather($0) { $0 } }
            case .float16: a.withUnsafeBufferPointer(ofType: Float16.self) { gather($0) { Float($0) } }
            default: throw Failure.model
            }
            return out
        }

        /// A contiguous Float32 copy (the next chunk's state input).
        nonisolated private static func copy(_ a: MLMultiArray) throws -> MLMultiArray {
            let vals = try flat(a)
            let out = try MLMultiArray(shape: a.shape, dataType: .float32)
            /* `MLMultiArray(shape:dataType:)` is contiguous, row-major. */
            out.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                vals.withUnsafeBufferPointer { p.baseAddress!.update(from: $0.baseAddress!, count: vals.count) }
            }
            return out
        }
    }
}

/// 16 kHz ⇄ 48 kHz by 3 with one linear-phase windowed-sinc low-pass (cut-off 7.8 kHz, 241 taps,
/// Blackman). Delay-compensated, so the lengths are exact and nothing shifts in time.
enum Resample3 {
    nonisolated static let half = 120
    nonisolated static let taps: [Float] = {
        let n = 2 * half + 1
        let fc = 7_800.0 / 48_000.0
        return (0..<n).map { i in
            let m = Double(i - half)
            let sinc = m == 0 ? 2 * fc : sin(2 * Double.pi * fc * m) / (Double.pi * m)
            let w = 0.42 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * Double.pi * Double(i) / Double(n - 1))
            return Float(sinc * w)
        }
    }()

    /// ×3: zero-stuff, low-pass, gain 3.
    nonisolated static func up(_ x: [Float]) -> [Float] {
        let n = x.count * 3
        var z = [Float](repeating: 0, count: n + 2 * half)
        var three: Float = 3
        z.withUnsafeMutableBufferPointer { vDSP_vsmul(x, 1, &three, $0.baseAddress! + half, 3, vDSP_Length(x.count)) }
        return fir(z, count: n)
    }

    /// ÷3: low-pass, keep every third sample; `count` samples out.
    nonisolated static func down(_ y: [Float], count: Int) -> [Float] {
        var z = [Float](repeating: 0, count: y.count + 2 * half + 3)
        z.withUnsafeMutableBufferPointer { zp in y.withUnsafeBufferPointer { (zp.baseAddress! + half).update(from: $0.baseAddress!, count: y.count) } }
        var out = [Float](repeating: 0, count: count)
        let avail = min(count, (y.count + 2) / 3)
        guard avail > 0 else { return out }
        var o = [Float](repeating: 0, count: avail)
        vDSP_desamp(z, 3, taps, &o, vDSP_Length(avail), vDSP_Length(taps.count))
        out.replaceSubrange(0..<avail, with: o)
        return out
    }

    /// out[i] = Σ z[i + k]·h[k] (h symmetric, so this is the centred convolution).
    nonisolated private static func fir(_ z: [Float], count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        vDSP_conv(z, 1, taps, 1, &out, 1, vDSP_Length(count), vDSP_Length(taps.count))
        return out
    }
}
