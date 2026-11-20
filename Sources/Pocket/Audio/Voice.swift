import Foundation

/// One polyphonic synth voice. Plain-old-data so the renderer can hold a
/// preallocated buffer of these and never allocate on the audio thread.
struct Voice {
    var active: Bool = false
    var track: Int32 = 0
    var midiNote: Int32 = -1
    /// MIDI channel the note arrived on, so MPE bends can be applied per note.
    var channel: Int32 = 0
    var held: Bool = false
    var phase: Double = 0
    var inc: Double = 0
    /// MPE / channel pitch bend as a frequency ratio. 1 = no bend.
    var bend: Float = 1
    var env: Float = 0
    var stage: Int32 = 3        // 0 attack, 1 decay, 2 sustain, 3 release
    var sustain: Float = 0
    var attackInc: Float = 0
    var decayInc: Float = 0
    var releaseInc: Float = 0
    var gate: Int32 = 0
    var wave: Int32 = 1
    var amp: Float = 0
    var gainL: Float = 0
    var gainR: Float = 0
}

/// PolyBLEP residual, removes most of the harshness of naive saw/square.
@inline(__always)
func polyBLEP(_ t: Double, _ dt: Double) -> Double {
    if dt <= 0 { return 0 }
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1
    } else if t > 1 - dt {
        let x = (t - 1) / dt
        return x * x + x + x + 1
    }
    return 0
}

/// Transparent safety limiter. Everything below full scale is passed bit-for-bit; only true
/// overs are rounded off. The old 0.75 knee colored loud but valid material.
@inline(__always)
func softClip(_ x: Float) -> Float {
    if x > 1 { return tanhf(x) }
    if x < -1 { return -tanhf(-x) }
    return x
}

@inline(__always)
func renderVoice(_ v: inout Voice, _ left: inout Float, _ right: inout Float) {
    switch v.stage {
    case 0:
        v.env += v.attackInc
        if v.env >= 1 { v.env = 1; v.stage = 1 }
    case 1:
        v.env -= v.decayInc
        if v.env <= v.sustain { v.env = v.sustain; v.stage = 2 }
    case 2:
        if !v.held {
            v.gate -= 1
            if v.gate <= 0 { v.stage = 3 }
        }
    default:
        v.env -= v.releaseInc
        if v.env <= 0 { v.env = 0; v.active = false; return }
    }

    let step = v.inc * Double(v.bend)
    var sample: Double
    switch v.wave {
    case 0:
        sample = sin(v.phase * 2 * Double.pi)
    case 1:
        sample = 2 * v.phase - 1 - polyBLEP(v.phase, step)
    default:
        sample = v.phase < 0.5 ? 1 : -1
        sample += polyBLEP(v.phase, step)
        var half = v.phase + 0.5
        if half >= 1 { half -= 1 }
        sample -= polyBLEP(half, step)
    }

    v.phase += step
    if v.phase >= 1 { v.phase -= 1 }

    let out = Float(sample) * v.env * v.amp
    left += out * v.gainL
    right += out * v.gainR
}
