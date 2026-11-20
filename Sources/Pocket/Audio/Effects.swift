import Foundation

/// Cytomic-style state variable filter (lowpass tap).
struct SVF {
    var ic1: Float = 0
    var ic2: Float = 0

    @inline(__always)
    mutating func lowpass(_ x: Float, g: Float, k: Float) -> Float {
        let a1 = 1 / (1 + g * (g + k))
        let a2 = g * a1
        let a3 = g * a2
        let v3 = x - ic2
        let v1 = a1 * ic1 + a2 * v3
        let v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return v2
    }

    mutating func reset() { ic1 = 0; ic2 = 0 }
}

/// What one return bus runs. Pocket exposes two real returns: A is a tempo delay and B is a
/// Freeverb-style reverb. Each track sends independently to both.
enum ReturnMode {
    case delay
    case reverb
    case both
}

/// Return bus: ping-pong delay and/or a small Freeverb-style reverb.
///
/// All buffers are preallocated in `init`; `process` only reads and writes them.
final class SendFX {
    private let sampleRate: Double
    private let mode: ReturnMode

    // Delay: two planes of `delayPlane` samples, indexed by a power-of-two mask.
    private static let delayPlane = 65_536
    private static let delayMask: Int32 = (1 << 16) - 1
    private let delayBuf: UnsafeMutableBufferPointer<Float>
    private var delayWrite: Int32 = 0
    private var delayLen: Int32 = 8000
    private var delayLP: Float = 0

    // Reverb
    private static let combCount = 4
    private static let allpassCount = 2
    private let combBuf: UnsafeMutableBufferPointer<Float>
    private let combPos: UnsafeMutableBufferPointer<Int32>
    private let combLen: UnsafeMutableBufferPointer<Int32>
    private let combDamp: UnsafeMutableBufferPointer<Float>
    private let apBuf: UnsafeMutableBufferPointer<Float>
    private let apPos: UnsafeMutableBufferPointer<Int32>
    private let apLen: UnsafeMutableBufferPointer<Int32>
    private let maxComb: Int
    private let maxAp: Int

    init(sampleRate: Double, mode: ReturnMode = .both) {
        self.sampleRate = sampleRate
        self.mode = mode
        let scale = sampleRate / 44_100.0

        delayBuf = Shared.alloc(2 * SendFX.delayPlane, Float(0))

        maxComb = Int(1500 * scale) + 8
        maxAp = Int(600 * scale) + 8
        combBuf = Shared.alloc(2 * SendFX.combCount * maxComb, Float(0))
        combPos = Shared.alloc(2 * SendFX.combCount, Int32(0))
        combLen = Shared.alloc(2 * SendFX.combCount, Int32(100))
        combDamp = Shared.alloc(2 * SendFX.combCount, Float(0))
        apBuf = Shared.alloc(2 * SendFX.allpassCount * maxAp, Float(0))
        apPos = Shared.alloc(2 * SendFX.allpassCount, Int32(0))
        apLen = Shared.alloc(2 * SendFX.allpassCount, Int32(50))

        let combTimes: [Int] = [1116, 1188, 1277, 1356]
        let apTimes: [Int] = [556, 441]
        for ch in 0..<2 {
            for i in 0..<SendFX.combCount {
                combLen[ch * SendFX.combCount + i] = Int32(Int(Double(combTimes[i]) * scale))
            }
            for i in 0..<SendFX.allpassCount {
                apLen[ch * SendFX.allpassCount + i] = Int32(Int(Double(apTimes[i]) * scale))
            }
        }
    }

    deinit {
        delayBuf.deallocate()
        combBuf.deallocate()
        combPos.deallocate()
        combLen.deallocate()
        combDamp.deallocate()
        apBuf.deallocate()
        apPos.deallocate()
        apLen.deallocate()
    }

    /// Delay time in output samples, called once per render block.
    func setDelay(samples: Int) {
        delayLen = Int32(max(64, min(samples, SendFX.delayPlane - 128)))
    }

    @inline(__always)
    func process(_ inL: Float, _ inR: Float, _ outL: inout Float, _ outR: inout Float) {
        // --- ping-pong delay ---
        var wetL: Float = 0
        var wetR: Float = 0

        if mode != .reverb {
            let read = (delayWrite - delayLen) & SendFX.delayMask
            let dL = delayBuf[Int(read)]
            let dR = delayBuf[Int(read) + SendFX.delayPlane]
            let fb: Float = 0.38
            delayLP += 0.35 * ((dL + dR) * 0.5 - delayLP)
            delayBuf[Int(delayWrite)] = inL + dR * fb
            delayBuf[Int(delayWrite) + SendFX.delayPlane] = inR + delayLP * fb
            delayWrite = (delayWrite + 1) & SendFX.delayMask
            wetL = dL * 0.35
            wetR = dR * 0.35
        }

        guard mode != .delay else {
            outL = wetL
            outR = wetR
            return
        }

        // --- reverb ---
        for ch in 0..<2 {
            let input = ch == 0 ? (inL + inR) * 0.5 : (inL + inR) * 0.5
            var acc: Float = 0
            for i in 0..<SendFX.combCount {
                let idx = ch * SendFX.combCount + i
                let len = Int(combLen[idx])
                let pos = Int(combPos[idx])
                let base = idx * maxComb
                let out = combBuf[base + pos]
                combDamp[idx] = out * 0.7 + combDamp[idx] * 0.3
                combBuf[base + pos] = input + combDamp[idx] * 0.82
                combPos[idx] = Int32((pos + 1) % len)
                acc += out
            }
            acc *= 0.25

            for i in 0..<SendFX.allpassCount {
                let idx = ch * SendFX.allpassCount + i
                let len = Int(apLen[idx])
                let pos = Int(apPos[idx])
                let base = idx * maxAp
                let bufOut = apBuf[base + pos]
                apBuf[base + pos] = acc + bufOut * 0.5
                apPos[idx] = Int32((pos + 1) % len)
                acc = bufOut - acc
            }

            if ch == 0 { wetL += acc * 0.5 } else { wetR += acc * 0.5 }
        }

        outL = wetL
        outR = wetR
    }
}
