import Foundation
import Accelerate

/// Acoustic echo canceller: learns the path from what the Mac plays (the reference) to the microphone with a
/// partitioned-block frequency-domain adaptive filter (overlap-save NLMS) and subtracts the predicted echo, so a
/// voice quieter than the music in the microphone survives. 10 ms blocks at 24 kHz, 480-point transforms,
/// 24 partitions (a 240 ms echo path: built-in, USB and display speakers; slower Bluetooth speakers are left to the
/// gate). Adaptation is frozen while the user speaks (`adapt: false`), slowed when the residual is mostly not echo,
/// and the filter is reset if it ever makes the signal louder.
public final class EchoCanceller {
    public static let blockSize = 240
    static let fftSize = 480
    let partitions: Int
    /// Step size (normalized).
    var mu: Float = 0.5

    private let forward: vDSP.DiscreteFourierTransform<Float>
    private let inverse: vDSP.DiscreteFourierTransform<Float>
    private var xr: [[Float]], xi: [[Float]]       // reference spectra, newest first
    private var wr: [[Float]], wi: [[Float]]       // filter partitions
    private var power: [Float]                      // smoothed reference power per bin
    private var previousReference: [Float]
    private let zeros: [Float]
    /// Times the filter was thrown away because it made the signal louder.
    public private(set) var resets = 0
    /// Smoothed microphone and residual energies, for the echo return loss enhancement.
    private var micEnergy: Float = 0, residualEnergy: Float = 0

    public init(partitions: Int = 24) {
        self.partitions = partitions
        let n = EchoCanceller.fftSize
        forward = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        inverse = try! vDSP.DiscreteFourierTransform(count: n, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
        zeros = [Float](repeating: 0, count: n)
        xr = Array(repeating: zeros, count: partitions); xi = xr
        wr = xr; wi = xr
        power = [Float](repeating: 0, count: n)
        previousReference = [Float](repeating: 0, count: EchoCanceller.blockSize)
    }

    private func dft(_ t: vDSP.DiscreteFourierTransform<Float>, _ re: [Float], _ im: [Float]) -> (real: [Float], imaginary: [Float]) {
        var outR = [Float](repeating: 0, count: re.count)
        var outI = [Float](repeating: 0, count: re.count)
        t.transform(inputReal: re, inputImaginary: im, outputReal: &outR, outputImaginary: &outI)
        return (outR, outI)
    }

    public func reset() {
        xr = Array(repeating: zeros, count: partitions); xi = xr
        wr = xr; wi = xr
        power = [Float](repeating: 0, count: EchoCanceller.fftSize)
        previousReference = [Float](repeating: 0, count: EchoCanceller.blockSize)
        micEnergy = 0; residualEnergy = 0
    }

    /// How much quieter the echo is after cancellation (dB), smoothed over about a second.
    public var enhancementDB: Float { residualEnergy > 0 && micEnergy > 0 ? 10 * log10(micEnergy / residualEnergy) : 0 }

    /// One block: the microphone `mic` and the reference played at the same moment (`reference`, same length).
    /// Returns the microphone without the predicted echo.
    public func process(mic: [Float], reference: [Float], adapt: Bool) -> [Float] {
        let n = EchoCanceller.fftSize, l = EchoCanceller.blockSize
        // Reference spectrum of the last two blocks (overlap-save).
        let window = previousReference + reference
        previousReference = reference
        let x = dft(forward, window, zeros)
        xr.removeLast(); xi.removeLast()
        xr.insert(x.real, at: 0); xi.insert(x.imaginary, at: 0)
        // Echo estimate: Σ W_p · X_p, back to time, last block.
        var yr = zeros, yi = zeros
        for p in 0..<partitions {
            let a = wr[p], b = wi[p], c = xr[p], d = xi[p]
            for k in 0..<n {
                let re: Float = a[k] * c[k] - b[k] * d[k]
                let im: Float = a[k] * d[k] + b[k] * c[k]
                yr[k] += re
                yi[k] += im
            }
        }
        let yt = dft(inverse, yr, yi).real
        let scale = 1 / Float(n)
        var e = [Float](repeating: 0, count: l)
        for i in 0..<l { e[i] = mic[i] - yt[l + i] * scale }

        // Reference power per bin, on every block (also while frozen): it normalizes the step. It follows a sudden
        // rise at once and decays slowly, so a loud passage can never meet a stale, small normalization and overshoot.
        for k in 0..<n {
            let p2: Float = x.real[k] * x.real[k] + x.imaginary[k] * x.imaginary[k]
            power[k] = max(p2, 0.9 * power[k] + 0.1 * p2)
        }
        let dE = mic.reduce(0) { $0 + $1 * $1 }, eE = e.reduce(0) { $0 + $1 * $1 }
        let refE = reference.reduce(0) { $0 + $1 * $1 }
        if refE > 1e-7 {
            micEnergy = 0.98 * micEnergy + 0.02 * dE
            residualEnergy = 0.98 * residualEnergy + 0.02 * eE
        }
        // A filter that keeps making things louder (over ~0.5 s) has diverged, e.g. the echo path changed: start over.
        if residualEnergy > 2 * micEnergy, micEnergy > 1e-6 {
            resets += 1
            reset()
            return mic
        }

        guard adapt, refE > 1e-7 else { return e }
        // Error spectrum (first half zero: overlap-save).
        let err = dft(forward, [Float](repeating: 0, count: l) + e, zeros)
        // Once converged, slower when the residual is mostly not echo (a voice the gate has not caught yet);
        // full speed until then, so the first seconds of music are learned quickly.
        var estimate: Float = 0
        for i in 0..<l { let v = yt[l + i] * scale; estimate += v * v }
        let ratio = enhancementDB < 6 ? 1 : min(1, max(0.15, estimate / max(eE, 1e-9)))
        let step = mu * ratio
        let reg = Float(partitions) * 1e-4
        let er = err.real, ei = err.imaginary
        // Normalized by the reference power over the whole filter span (Σ over partitions), at least the peak-held
        // current power: exact NLMS normalization, never smaller than what a loud passage needs.
        var total = [Float](repeating: 0, count: n)
        for p in 0..<partitions {
            let c = xr[p], d = xi[p]
            for k in 0..<n { total[k] += c[k] * c[k] + d[k] * d[k] }
        }
        var gain = [Float](repeating: 0, count: n)
        for k in 0..<n { gain[k] = step / (max(total[k], power[k]) + reg) }
        for p in 0..<partitions {
            let c = xr[p], d = xi[p]
            var a = wr[p], b = wi[p]
            for k in 0..<n {
                // W += μ · conj(X) · E / power
                let re: Float = c[k] * er[k] + d[k] * ei[k]
                let im: Float = c[k] * ei[k] - d[k] * er[k]
                a[k] += gain[k] * re
                b[k] += gain[k] * im
            }
            wr[p] = a; wi[p] = b
        }
        // Gradient constraint on every partition (keeps the filter causal and the convolution linear, not circular).
        for p in 0..<partitions {
            var w = dft(inverse, wr[p], wi[p])
            for i in 0..<n {
                w.real[i] = i < l ? w.real[i] * scale : 0
                w.imaginary[i] = i < l ? w.imaginary[i] * scale : 0
            }
            let wc = dft(forward, w.real, w.imaginary)
            wr[p] = wc.real; wi[p] = wc.imaginary
        }
        return e
    }
}
