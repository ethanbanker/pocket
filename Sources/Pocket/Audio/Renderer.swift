import Foundation
import AudioToolbox

/// The whole instrument: sample-accurate step clock, clip launching, voice allocation,
/// polyphonic note triggering, sample playback, timeline playback, plugin inserts,
/// per-track inserts, send FX and the master bus.
///
/// Realtime rules observed here: no allocation, no locks, no Objective-C dispatch,
/// no Swift collections, no printing.
///
/// Signal flow: per-track buffers (synthesis) -> plugin inserts (block based) ->
/// drive/filter/volume -> sum + send FX -> master.
final class Renderer: @unchecked Sendable {
    private let s: Shared
    private let sampleRate: Double
    private static let voiceCount = 128
    static let maximumFrames = 8192
    private static let maxBlock = Renderer.maximumFrames

    private let voices: UnsafeMutableBufferPointer<Voice>
    private let trkL: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    private let trkR: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    private let lvAcc: UnsafeMutableBufferPointer<Float>
    private let filtL: UnsafeMutableBufferPointer<SVF>
    private let filtR: UnsafeMutableBufferPointer<SVF>
    private let smoothVol: UnsafeMutableBufferPointer<Float>
    private let smoothSend: UnsafeMutableBufferPointer<Float>
    private let smoothSendB: UnsafeMutableBufferPointer<Float>
    private let gCoef: UnsafeMutableBufferPointer<Float>
    private let kCoef: UnsafeMutableBufferPointer<Float>
    private let panL: UnsafeMutableBufferPointer<Float>
    private let panR: UnsafeMutableBufferPointer<Float>
    private let audible: UnsafeMutableBufferPointer<Int32>
    private let sampleTL: UnsafeMutableBufferPointer<Int32>   // per track, up to sampleStack clips
    private let pendingOffs: UnsafeMutableBufferPointer<PendingInstrumentOff>
    private let fxA: SendFX
    private let fxB: SendFX
    /// Per-channel pitch bend (14-bit) for MPE and the built-in synth.
    private let channelBend: UnsafeMutableBufferPointer<Int32>
    private let arpChord: UnsafeMutableBufferPointer<Int32>
    private let arpChordCount: UnsafeMutableBufferPointer<Int32>
    private let arpIndex: UnsafeMutableBufferPointer<Int32>
    private let arpDir: UnsafeMutableBufferPointer<Int32>

    /// Delay compensation. Every track is delayed to the slowest plugin path, so a look-ahead
    /// limiter on one insert does not make that track late against the rest of the song.
    private static let maxPDC = 65_536
    private let pdcL: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    private let pdcR: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>
    private let pdcPos: UnsafeMutableBufferPointer<Int>
    private let groupL: UnsafeMutableBufferPointer<Float>
    private let groupR: UnsafeMutableBufferPointer<Float>

    /// How many sample clips can sound at once on a single track (stacked placements).
    private static let sampleStack = 4

    /// A note that an AU instrument still has to release. Step resolution matches the sequencer.
    private struct PendingInstrumentOff {
        var note: Int32 = -1
        var track: Int32 = -1
        var endStep: Int32 = -1
        var channel: Int32 = 0
    }

    private var globalStep = -1
    private var previewNote: Int32 = -1
    private var previewInstrumentTrack = -1
    private var lastPreviewOn: Int32 = 0
    private var lastPreviewOff: Int32 = 0
    private var samplesPerStep = 6000.0
    private var currentBPM = 112.0
    /// Position inside the current step, in steps. This is advanced by the exact reciprocal of
    /// samplesPerStep for every rendered sample, so a fractional samples-per-step never rounds
    /// at a block or step boundary. The old integer `samplesUntilStep` count drifted.
    private var stepPhase = 0.0
    private var wasPlaying = false
    private var lastSeekSeq: Int32 = 0
    private var inputPhase = 0.0
    private var lastInputL: Float = 0
    private var lastInputR: Float = 0

    init(shared: Shared, sampleRate: Double) {
        self.s = shared
        self.sampleRate = sampleRate
        let tracks = Shared.maxTracks

        voices = Shared.alloc(Renderer.voiceCount, Voice())
        lvAcc = Shared.alloc(tracks, Float(0))
        filtL = Shared.alloc(tracks, SVF())
        filtR = Shared.alloc(tracks, SVF())
        smoothVol = Shared.alloc(tracks, Float(1))
        smoothSend = Shared.alloc(tracks, Float(0))
        smoothSendB = Shared.alloc(tracks, Float(0))
        gCoef = Shared.alloc(tracks, Float(0.5))
        kCoef = Shared.alloc(tracks, Float(2))
        panL = Shared.alloc(tracks, Float(0.7))
        panR = Shared.alloc(tracks, Float(0.7))
        audible = Shared.alloc(tracks, Int32(1))
        sampleTL = Shared.alloc(tracks * Renderer.sampleStack, Int32(-1))
        pendingOffs = Shared.alloc(256, PendingInstrumentOff())
        pdcL = Shared.alloc(tracks, UnsafeMutablePointer<Float>.allocate(capacity: 1))
        pdcR = Shared.alloc(tracks, UnsafeMutablePointer<Float>.allocate(capacity: 1))
        pdcPos = Shared.alloc(tracks, 0)
        groupL = Shared.alloc(Shared.maxGroups + 1, Float(0))
        groupR = Shared.alloc(Shared.maxGroups + 1, Float(0))

        trkL = Shared.alloc(tracks, UnsafeMutablePointer<Float>.allocate(capacity: 1))
        trkR = Shared.alloc(tracks, UnsafeMutablePointer<Float>.allocate(capacity: 1))
        for t in 0..<tracks {
            let l = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxBlock)
            let r = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxBlock)
            l.initialize(repeating: 0, count: Renderer.maxBlock)
            r.initialize(repeating: 0, count: Renderer.maxBlock)
            trkL[t] = l
            trkR[t] = r
            let dl = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxPDC)
            let dr = UnsafeMutablePointer<Float>.allocate(capacity: Renderer.maxPDC)
            dl.initialize(repeating: 0, count: Renderer.maxPDC)
            dr.initialize(repeating: 0, count: Renderer.maxPDC)
            pdcL[t] = dl
            pdcR[t] = dr
        }

        fxA = SendFX(sampleRate: sampleRate, mode: .delay)
        fxB = SendFX(sampleRate: sampleRate, mode: .reverb)
        channelBend = Shared.alloc(16, Int32(8_192))
        arpChord = Shared.alloc(tracks * Shared.arpChordMax, Int32(0))
        arpChordCount = Shared.alloc(tracks, Int32(0))
        arpIndex = Shared.alloc(tracks, Int32(0))
        arpDir = Shared.alloc(tracks, Int32(1))
    }

    deinit {
        for t in 0..<Shared.maxTracks {
            trkL[t].deallocate()
            trkR[t].deallocate()
            pdcL[t].deallocate()
            pdcR[t].deallocate()
        }
        voices.deallocate()
        trkL.deallocate()
        trkR.deallocate()
        lvAcc.deallocate()
        filtL.deallocate()
        filtR.deallocate()
        smoothVol.deallocate()
        smoothSend.deallocate()
        smoothSendB.deallocate()
        gCoef.deallocate()
        kCoef.deallocate()
        panL.deallocate()
        panR.deallocate()
        audible.deallocate()
        sampleTL.deallocate()
        pendingOffs.deallocate()
        channelBend.deallocate()
        arpChord.deallocate()
        arpChordCount.deallocate()
        arpIndex.deallocate()
        arpDir.deallocate()
        pdcL.deallocate()
        pdcR.deallocate()
        pdcPos.deallocate()
        groupL.deallocate()
        groupR.deallocate()
    }

    // MARK: - Render

    func render(frames: Int, abl: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        guard buffers.count > 0, let first = buffers[0].mData else { return noErr }
        for i in 0..<buffers.count {
            if let data = buffers[i].mData { memset(data, 0, Int(buffers[i].mDataByteSize)) }
        }
        let left = first.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1
            ? buffers[1].mData!.assumingMemoryBound(to: Float.self)
            : left

        guard frames > 0, frames <= Renderer.maxBlock else { return noErr }

        let bpm = min(max(s.bpm.pointee, 20), 300)
        currentBPM = bpm
        samplesPerStep = sampleRate * 60.0 / bpm / 4.0
        let playing = s.playing.pointee != 0
        let trackCount = min(max(Int(s.trackCount.pointee), 0), Shared.maxTracks)

        let seekSeq = s.seekSeq.pointee
        if seekSeq != lastSeekSeq {
            lastSeekSeq = seekSeq
            let target = max(Int(s.seekTo.pointee), 0)
            releaseAllVoices()
            allInstrumentsOff()
            globalStep = target - 1
            // One sample of phase puts the very first rendered sample exactly on `target`.
            stepPhase = 1.0
            s.playhead.pointee = Int64(target)
        }

        if playing && !wasPlaying {
            let target = max(Int(s.seekTo.pointee), 0)
            globalStep = target - 1
            stepPhase = 1.0
        } else if !playing && wasPlaying {
            for t in 0..<Shared.maxTracks {
                s.activeClip[t] = -1
                s.stopReq[t] = 0
            }
            for i in 0..<sampleTL.count { sampleTL[i] = -1 }
            allInstrumentsOff()
            releaseAllVoices()
        }

        let solo = s.soloMask.pointee
        let mute = s.muteMask.pointee
        let openCut = Float(sampleRate * 0.23)

        for t in 0..<trackCount {
            var cut = s.cutoff[t]
            if cut > openCut { cut = openCut }
            if cut < 40 { cut = 40 }
            gCoef[t] = tanf(Float.pi * cut / Float(sampleRate))
            kCoef[t] = 2 - 2 * min(max(s.resonance[t], 0), 0.95)

            let muted = (mute >> t) & 1 == 1
            let soloedOut = solo != 0 && (solo >> t) & 1 == 0
            audible[t] = (muted || soloedOut) ? 0 : 1

            let pan = min(max(Double(s.trackParams[t].pan), -1), 1)
            let angle = (pan + 1) * 0.25 * Double.pi
            panL[t] = Float(cos(angle))
            panR[t] = Float(sin(angle))
            lvAcc[t] = 0
        }

        fxA.setDelay(samples: Int(samplesPerStep * 3))
        drainMIDI(trackCount: trackCount)
        drainPreview()

        let master = s.masterGain.pointee
        let stepSeconds = samplesPerStep / sampleRate

        // MARK: per-sample synthesis into per-track buffers
        for i in 0..<frames {
            if playing {
                // The phase reaches 1.0 on the sample that belongs to the next step. Advancing
                // there and subtracting one keeps every later step on the exact fractional
                // sample grid; the phase carries the remainder instead of rounding it away.
                if stepPhase >= 1.0 {
                    advanceStep(trackCount: trackCount, sampleOffset: i)
                    stepPhase -= 1.0
                }
            }

            for t in 0..<trackCount {
                trkL[t][i] = 0
                trkR[t][i] = 0
            }

            if s.monitorOn.pointee != 0 {
                let input = nextMonitorSample()
                let track = Int(s.monitorTrack.pointee)
                if track >= 0, track < trackCount {
                    let gain = s.monitorGain.pointee
                    trkL[track][i] += input.0 * gain * panL[track]
                    trkR[track][i] += input.1 * gain * panR[track]
                }
            }

            for v in 0..<Renderer.voiceCount where voices[v].active {
                let t = Int(voices[v].track)
                if t < 0 || t >= trackCount { continue }
                var l: Float = 0
                var r: Float = 0
                renderVoice(&voices[v], &l, &r)
                trkL[t][i] += l
                trkR[t][i] += r
                let amp = max(abs(l), abs(r))
                if amp > lvAcc[t] { lvAcc[t] = amp }
            }

            let posInSteps = Double(globalStep) + stepPhase
            if playing && posInSteps >= 0 {
                let step = posInSteps
                for t in 0..<trackCount {
                    for k in 0..<Renderer.sampleStack {
                        let index = Int(sampleTL[t * Renderer.sampleStack + k])
                        if index < 0 { continue }
                        let base = t * Shared.maxTimeline + index
                        let start = Double(s.tlStart[base])
                        let span = Double(max(Int(s.tlLen[base]), 1))
                        let local = step - start + Double(s.tlOffset[base])
                        if local < 0 || local >= span { continue }
                        let scene = Int(s.tlScene[base])
                        if scene < 0 || scene >= Shared.sceneCount { continue }
                        let clip = Shared.clipIndex(track: t, scene: scene)
                        mixSample(track: t, clip: clip, position: local * stepSeconds,
                                  positionSteps: local, spanSeconds: span * stepSeconds, frame: i)
                    }
                }
            }

            if playing { stepPhase += 1.0 / samplesPerStep }
        }

        // MARK: AU instruments, one block at a time, into the same track bus
        for t in 0..<trackCount {
            guard let inst = instrumentSlot(t) else { continue }
            let peak = inst.render(frames: frames, left: trkL[t], right: trkR[t])
            if peak > lvAcc[t] { lvAcc[t] = peak }
        }

        // MARK: plugin inserts, one block at a time
        for t in 0..<trackCount {
            for k in 0..<Shared.maxInserts {
                let index = t * Shared.maxInserts + k
                if s.pluginOn[index] == 0 { continue }
                guard let raw = s.pluginPtr[index] else { continue }
                let slot = Unmanaged<PluginSlot>.fromOpaque(raw).takeUnretainedValue()
                slot.process(frames: frames, left: trkL[t], right: trkR[t])
            }
        }

        applyDelayCompensation(frames: frames, trackCount: trackCount)

        // MARK: mix
        for i in 0..<frames {
            var mixL: Float = 0
            var mixR: Float = 0
            var sendAccL: Float = 0
            var sendAccR: Float = 0
            var sendAccBL: Float = 0
            var sendAccBR: Float = 0
            for g in 0...Shared.maxGroups {
                groupL[g] = 0
                groupR[g] = 0
            }

            for t in 0..<trackCount {
                var l = trkL[t][i]
                var r = trkR[t][i]

                let d = s.drive[t]
                if d > 1.01 {
                    l = tanhf(l * d) / d
                    r = tanhf(r * d) / d
                }
                if s.cutoff[t] < openCut {
                    l = filtL[t].lowpass(l, g: gCoef[t], k: kCoef[t])
                    r = filtR[t].lowpass(r, g: gCoef[t], k: kCoef[t])
                }

                let targetVol = s.volume[t] * Float(audible[t])
                smoothVol[t] += (targetVol - smoothVol[t]) * 0.0025
                let targetSend = s.send[t]
                smoothSend[t] += (targetSend - smoothSend[t]) * 0.0025
                let targetSendB = s.sendB[t]
                smoothSendB[t] += (targetSendB - smoothSendB[t]) * 0.0025

                l *= smoothVol[t]
                r *= smoothVol[t]
                sendAccL += l * smoothSend[t]
                sendAccR += r * smoothSend[t]
                sendAccBL += l * smoothSendB[t]
                sendAccBR += r * smoothSendB[t]
                let group = Int(s.groupOf[t])
                if group > 0, group <= Shared.maxGroups {
                    groupL[group] += l
                    groupR[group] += r
                } else {
                    mixL += l
                    mixR += r
                }
            }

            for g in 1...Shared.maxGroups {
                let volume = s.groupVolume[g]
                let pan = min(max(Double(s.groupPan[g]), -1), 1)
                let angle = (pan + 1) * 0.25 * Double.pi
                mixL += groupL[g] * volume * Float(cos(angle))
                mixR += groupR[g] * volume * Float(sin(angle))
            }

            var wetL: Float = 0
            var wetR: Float = 0
            fxA.process(sendAccL, sendAccR, &wetL, &wetR)
            var wetBL: Float = 0
            var wetBR: Float = 0
            fxB.process(sendAccBL, sendAccBR, &wetBL, &wetBR)

            left[i] = softClip((mixL + wetL * s.returnLevel.pointee
                                + wetBL * s.returnLevelB.pointee) * master)
            right[i] = softClip((mixR + wetR * s.returnLevel.pointee
                                 + wetBR * s.returnLevelB.pointee) * master)
        }

        if stepPhase >= 1.0 {
            s.playhead.pointee = Int64(max(0, globalStep + 1))
            s.playheadFrac.pointee = 0
        } else {
            s.playhead.pointee = Int64(max(0, globalStep))
            s.playheadFrac.pointee = Float(min(max(stepPhase, 0), 1))
        }

        for t in 0..<trackCount {
            let decayed = s.trackLevel[t] * 0.72
            s.trackLevel[t] = max(decayed, lvAcc[t])
        }

        wasPlaying = playing
        return noErr
    }

    /// Reads the selected input through the lock-free ring. The input device can run at a
    /// different rate than the output device, so this is a fractional read with linear
    /// interpolation. When the producer has not delivered a block yet, the last sample is held
    /// for one render quantum instead of clicking to zero.
    private func nextMonitorSample() -> (Float, Float) {
        let inputRate = max(s.inputRate.pointee, 8_000)
        inputPhase += inputRate / sampleRate
        while inputPhase >= 1 {
            let head = Int(s.inputHead.pointee)
            let tail = Int(s.inputTail.pointee)
            if head < tail {
                let slot = head % Shared.inputRingFrames
                lastInputL = s.inputL[slot]
                lastInputR = s.inputR[slot]
                s.inputHead.pointee = Int32(head + 1)
            } else {
                lastInputL = 0
                lastInputR = 0
            }
            inputPhase -= 1
        }
        return (lastInputL, lastInputR)
    }

    /// Aligns all audible tracks to the slowest instrument/insert chain. Latency values come
    /// from the Audio Units themselves, not a guess; zero-latency projects take the fast path.
    private func applyDelayCompensation(frames: Int, trackCount: Int) {
        guard frames > 0, trackCount > 0 else { return }
        var maximum = 0
        for t in 0..<trackCount {
            var latency = max(Int(s.instrumentLatency[t]), 0)
            for k in 0..<Shared.maxInserts {
                latency += max(Int(s.pluginLatency[t * Shared.maxInserts + k]), 0)
            }
            if latency > maximum { maximum = latency }
        }
        guard maximum > 0 else { return }

        for t in 0..<trackCount {
            var latency = max(Int(s.instrumentLatency[t]), 0)
            for k in 0..<Shared.maxInserts {
                latency += max(Int(s.pluginLatency[t * Shared.maxInserts + k]), 0)
            }
            let delay = min(max(maximum - latency, 0), Renderer.maxPDC - 1)
            guard delay > 0 else { continue }
            var position = pdcPos[t]
            for i in 0..<frames {
                let read = (position + Renderer.maxPDC - delay) % Renderer.maxPDC
                pdcL[t][position] = trkL[t][i]
                pdcR[t][position] = trkR[t][i]
                trkL[t][i] = pdcL[t][read]
                trkR[t][i] = pdcR[t][read]
                position += 1
                if position >= Renderer.maxPDC { position = 0 }
            }
            pdcPos[t] = position
        }
    }

    // MARK: - Sequencing

    private func advanceStep(trackCount: Int, sampleOffset: Int) {
        globalStep += 1
        if s.loopEnabled.pointee != 0 {
            let start = max(Int(s.loopStart.pointee), 0)
            let length = max(Int(s.loopLength.pointee), 1)
            if globalStep >= start + length {
                globalStep = start + (globalStep - start) % length
            }
        }
        flushInstrumentOffs(step: globalStep, sampleOffset: sampleOffset)
        let step = globalStep
        if step < 0 { return }

        for t in 0..<trackCount {
            let autoIndex = t * Shared.maxAutoSteps + min(step, Shared.maxAutoSteps - 1)
            let auto = s.autoVol[autoIndex]
            s.volume[t] = auto >= 0 ? auto : s.baseVolume[t]
            let pan = s.autoPan[autoIndex]
            s.trackParams[t].pan = pan >= 0 ? pan * 2 - 1 : s.basePan[t]
            let send = s.autoSend[autoIndex]
            s.send[t] = send >= 0 ? send : s.baseSend[t]
            let sendB = s.autoSendB[autoIndex]
            s.sendB[t] = sendB >= 0 ? sendB : s.baseSendB[t]
            let cutoff = s.autoCutoff[autoIndex]
            s.cutoff[t] = cutoff >= 0 ? 80 * powf(18000 / 80, cutoff) : s.baseCutoff[t]

            for k in 0..<Renderer.sampleStack { sampleTL[t * Renderer.sampleStack + k] = -1 }
            var slot = 0
            var top: Int32 = -1
            let count = min(Int(s.tlCount[t]), Shared.maxTimeline)
            let base = t * Shared.maxTimeline
            for i in 0..<count {
                let start = Int(s.tlStart[base + i])
                let len = Int(s.tlLen[base + i])
                if step < start || step >= start + len { continue }
                let scene = Int(s.tlScene[base + i])
                if scene < 0 || scene >= Shared.sceneCount { continue }
                if top < 0 { top = Int32(scene) }
                let clip = Shared.clipIndex(track: t, scene: scene)
                if (s.clipSample[clip] >= 0 || s.clipRegionCount[clip] > 0)
                    && slot < Renderer.sampleStack {
                    sampleTL[t * Renderer.sampleStack + slot] = Int32(i)
                    slot += 1
                }
            }
            s.activeClip[t] = top
        }

        for t in 0..<trackCount where audible[t] != 0 {
            let count = min(Int(s.tlCount[t]), Shared.maxTimeline)
            let base = t * Shared.maxTimeline
            for i in 0..<count {
                let start = Int(s.tlStart[base + i])
                let len = Int(s.tlLen[base + i])
                if step < start || step >= start + len { continue }
                let scene = Int(s.tlScene[base + i])
                if scene < 0 || scene >= Shared.sceneCount { continue }
                let clip = Shared.clipIndex(track: t, scene: scene)
                let local = step - start + Int(s.tlOffset[base + i])
                if local < 0 { continue }
                if s.arpMode[t] != 0 {
                    arpTick(track: t, clip: clip, step: local, sampleOffset: sampleOffset)
                } else {
                    triggerNotes(track: t, clip: clip, step: local, sampleOffset: sampleOffset)
                }
            }
        }
    }

    /// Spawns every note whose start lands on `step`.
    private func triggerNotes(track t: Int, clip: Int, step: Int, sampleOffset: Int) {
        let count = min(Int(s.noteCount[clip]), Shared.maxNotes)
        if count == 0 { return }
        let base = clip * Shared.maxNotes
        let p = s.trackParams[t]

        for i in 0..<count {
            if Int(s.noteStart[base + i]) != step { continue }
            let pitch = Int(s.notePitch[base + i])
            // Clip gain automation scales MIDI velocity at the note start; on audio clips the
            // same envelope is applied sample-accurately while the file plays.
            let envelope = clipGain(clip: clip, localStep: Double(step))
            let velocity = max(1, min(127, Int((Double(max(Int(s.noteVel[base + i]), 1))
                * Double(envelope)).rounded())))
            let length = max(Int(s.noteLen[base + i]), 1)

            // Deterministic probability so playback and an offline bounce agree. The hash is
            // based on musical position, pitch and source clip rather than wall-clock time.
            let probability = Int(s.noteProb[base + i])
            if probability < 100 {
                var seed = UInt32(truncatingIfNeeded: step &* 1_103_515_245)
                seed ^= UInt32(truncatingIfNeeded: pitch &* 12_345)
                seed ^= UInt32(truncatingIfNeeded: clip &* 2_654_435_761)
                if Int(seed % 100) >= probability { continue }
            }
            let groove = Double(s.noteGroove[base + i])
            let noteOffset = sampleOffset + Int(max(0, min(groove, 0.9)) * samplesPerStep)

            // MIDI effects are note transformers, not a separate fake track: every generated
            // note goes through the same instrument/voice path and the same offline bounce.
            let effect = s.midiEffect[t]
            for voice in 0..<3 {
                guard let interval = Renderer.effectInterval(effect, voice: voice) else { break }
                let sounding = pitch + interval
                guard sounding >= 0, sounding <= 127 else { continue }
                if let inst = instrumentSlot(t) {
                    scheduleInstrumentNote(track: t, inst: inst, note: sounding,
                                           velocity: velocity, length: length,
                                           sampleOffset: noteOffset)
                    continue
                }

                let freq = 440.0 * pow(2.0, (Double(sounding) - 69.0) / 12.0)
                let amp = Float(pow(Double(velocity) / 127.0, 1.4)) * p.gain
                let gate = max(Int(samplesPerStep * Double(length)), 1)
                spawn(track: t, freq: freq, amp: amp, params: p, gate: gate)
            }
        }
    }

    @inline(__always)
    private static func effectInterval(_ code: Int32, voice: Int) -> Int? {
        switch code {
        case 1: return voice == 0 ? 0 : (voice == 1 ? 12 : nil)       // octave
        case 2: return voice == 0 ? 0 : (voice == 1 ? 7 : nil)        // fifth
        case 3: return voice == 0 ? 0 : (voice == 1 ? 4 : (voice == 2 ? 7 : nil))
        default: return voice == 0 ? 0 : nil                         // off
        }
    }

    /// Reads one sample slot into the track bus. `positionSteps` is the local position inside
    /// the source clip and `position` the same instant in seconds; comp regions and the clip
    /// gain envelope resolve from steps, while warp reads resolve in seconds.
    private func mixSample(track t: Int, clip: Int, position: Double, positionSteps: Double,
                           spanSeconds: Double, frame i: Int) {
        guard let slot = sampleSlot(clip: clip, localStep: positionSteps) else { return }
        guard let leftPtr = s.samplePtr[slot] else { return }
        let rightPtr = s.samplePtrR[slot] ?? leftPtr
        let count = Int(s.sampleLen[slot])
        if count <= 1 { return }

        let duration = Double(count) / sampleRate
        guard duration > 0.0001 else { return }

        let sourceBPM = max(Double(s.clipSampleBPM[clip]), 20)
        let warp = s.clipWarp[clip] != 0
        let rate = warp ? min(max(currentBPM / sourceBPM, 0.25), 4) : 1
        let offset = Double(s.clipSampleStart[clip]) * duration
        let stepSeconds = 60.0 / currentBPM / 4.0
        let reverse = s.clipReverse[clip] != 0

        var smpL: Float = 0
        var smpR: Float = 0

        if warp && s.clipStretch[clip] != 0 && !reverse {
            // Pitch-preserving time-stretch: two grains, each reading the file at 1x so the
            // pitch never changes, crossfaded with a raised cosine. The grain starts follow
            // the warp/anchor mapping, so anchors still line up. Reverse stays repitch-only.
            let hop = max(64.0, 0.03 * sampleRate)
            let frames = position * sampleRate
            let hopIndex = floor(frames / hop)
            let fraction = frames - hopIndex * hop
            let weight = Float(0.5 - 0.5 * cos(Double.pi * min(max(fraction / hop, 0), 1)))
            let newer = granularComponent(clip: clip, position: position,
                                          positionSteps: positionSteps,
                                          stepSeconds: stepSeconds,
                                          startFrames: hopIndex * hop, rate: rate,
                                          offset: offset, count: count, duration: duration,
                                          left: leftPtr, right: rightPtr)
            let older = granularComponent(clip: clip, position: position,
                                          positionSteps: positionSteps,
                                          stepSeconds: stepSeconds,
                                          startFrames: (hopIndex - 1) * hop, rate: rate,
                                          offset: offset, count: count, duration: duration,
                                          left: leftPtr, right: rightPtr)
            smpL = newer.0 * weight + older.0 * (1 - weight)
            smpR = newer.1 * weight + older.1 * (1 - weight)
        } else {
            let played = reverse
                ? duration - min(warpedSource(clip: clip, position: position,
                                             positionSteps: positionSteps, rate: rate,
                                             offset: offset, stepSeconds: stepSeconds), duration)
                : warpedSource(clip: clip, position: position,
                               positionSteps: positionSteps, rate: rate,
                               offset: offset, stepSeconds: stepSeconds)
            if played >= duration || played < 0 { return }

            let src = played / duration * Double(count)
            var i0 = Int(src)
            if i0 >= count { i0 = count - 1 }
            if i0 < 0 { i0 = 0 }
            var i1 = i0 + 1
            if i1 >= count { i1 = 0 }
            let frac = Float(src - Double(i0))
            smpL = leftPtr[i0] * (1 - frac) + leftPtr[i1] * frac
            smpR = rightPtr[i0] * (1 - frac) + rightPtr[i1] * frac
        }

        var gain = s.clipSampleGain[clip] * clipGain(clip: clip, localStep: positionSteps)
        let edge = 0.003
        if position < edge { gain *= Float(max(position, 0) / edge) }
        let fadeIn = Double(s.clipFadeIn[clip])
        if fadeIn > 0.0001 && position < fadeIn { gain *= Float(position / fadeIn) }
        let fadeOut = Double(s.clipFadeOut[clip])
        if fadeOut > 0.0001 && spanSeconds - position < fadeOut {
            gain *= Float(max(0, (spanSeconds - position) / fadeOut))
        }

        trkL[t][i] += smpL * gain * panL[t]
        trkR[t][i] += smpR * gain * panR[t]
        let amp = max(abs(smpL * gain), abs(smpR * gain))
        if amp > lvAcc[t] { lvAcc[t] = amp }
    }

    /// The comped take region covering this step, falling back to the clip's active take.
    @inline(__always)
    private func sampleSlot(clip: Int, localStep: Double) -> Int? {
        let regions = min(Int(s.clipRegionCount[clip]), Shared.maxCompRegions)
        if regions > 0 {
            let base = clip * Shared.maxCompRegions
            var chosen = -1
            for i in 0..<regions {
                let start = Double(s.clipRegionStart[base + i])
                let end = Double(s.clipRegionEnd[base + i])
                if localStep >= start - 0.0001 && localStep < end - 0.0001 {
                    let slot = Int(s.clipRegionSlot[base + i])
                    if slot >= 0, slot < Shared.sampleSlots { chosen = slot }
                }
            }
            if chosen >= 0 { return chosen }
        }
        let slot = Int(s.clipSample[clip])
        return slot >= 0 && slot < Shared.sampleSlots ? slot : nil
    }

    /// One grain of the time-stretch. The source is read at 1x from the mapped grain start, so
    /// the grain keeps the original pitch while the grain start advances at the warp rate.
    @inline(__always)
    private func granularComponent(clip: Int, position: Double, positionSteps: Double,
                                   stepSeconds: Double, startFrames: Double, rate: Double,
                                   offset: Double, count: Int, duration: Double,
                                   left: UnsafeMutablePointer<Float>,
                                   right: UnsafeMutablePointer<Float>) -> (Float, Float) {
        let startSeconds = startFrames / sampleRate
        let stepsAtGrain = positionSteps - (position - startSeconds) / stepSeconds
        let sourceStart = warpedSource(clip: clip, position: startSeconds,
                                       positionSteps: stepsAtGrain, rate: rate,
                                       offset: offset, stepSeconds: stepSeconds)
        let source = sourceStart + (position - startSeconds)
        guard source >= 0, source < duration else { return (0, 0) }
        let src = source / duration * Double(count)
        let i0 = max(0, min(Int(src), count - 1))
        let i1 = i0 + 1 >= count ? 0 : i0 + 1
        let frac = Float(src - Double(i0))
        return (left[i0] * (1 - frac) + left[i1] * frac,
                right[i0] * (1 - frac) + right[i1] * frac)
    }

    /// Piecewise linear source mapping. With no anchors this is a constant read rate; with
    /// anchors, the user's match points win and the surrounding regions interpolate between
    /// them. Anchors are stored in clip steps, so the comparison is in steps too.
    @inline(__always)
    private func warpedSource(clip: Int, position: Double, positionSteps: Double,
                              rate: Double, offset: Double, stepSeconds: Double) -> Double {
        let count = Int(s.clipWarpCount[clip])
        guard count > 0 else { return offset + position * rate }
        let base = clip * Shared.maxWarpMarkers
        var previousStep = 0.0
        var previousSource = offset
        var mapped: Double?
        for i in 0..<min(count, Shared.maxWarpMarkers) {
            let step = Double(s.clipWarpTimeline[base + i])
            let source = Double(s.clipWarpSource[base + i])
            if step <= 0 {
                previousStep = step
                previousSource = source
                continue
            }
            if positionSteps <= step {
                let span = max(step - previousStep, 0.000_001)
                let amount = min(max((positionSteps - previousStep) / span, 0), 1)
                mapped = previousSource + (source - previousSource) * amount
                break
            }
            previousStep = step
            previousSource = source
        }
        return mapped ?? (previousSource + (positionSteps - previousStep) * stepSeconds * rate)
    }

    /// Clip gain automation, normalized 0...1 mapped to 0...2 with 0.5 = unity.
    @inline(__always)
    private func clipGain(clip: Int, localStep: Double) -> Float {
        let count = min(Int(s.clipGainCount[clip]), Shared.maxClipPoints)
        guard count > 0 else { return 1 }
        let base = clip * Shared.maxClipPoints
        let position = Float(localStep)
        if position <= s.clipGainStep[base] { return s.clipGainValue[base] * 2 }
        var previousStep = s.clipGainStep[base]
        var previousValue = s.clipGainValue[base]
        for i in 1..<count {
            let step = s.clipGainStep[base + i]
            let value = s.clipGainValue[base + i]
            if position <= step {
                let span = max(step - previousStep, 0.0001)
                let amount = (position - previousStep) / span
                return (previousValue + (value - previousValue) * amount) * 2
            }
            previousStep = step
            previousValue = value
        }
        return previousValue * 2
    }

    // MARK: - Audition

    /// Piano roll keys: press spawns a held voice on the selected track, release lets it go.
    private func drainPreview() {
        let on = s.previewOnSeq.pointee
        if on != lastPreviewOn {
            lastPreviewOn = on
            let track = Int(s.previewTrack.pointee)
            let pitch = Int(s.previewPitch.pointee)
            guard track >= 0, track < Shared.maxTracks, pitch >= 0 else { return }
            if previewNote >= 0 { releasePreview() }
            let velocity = max(Int(s.previewVel.pointee), 1)
            previewNote = Int32(pitch)
            if let inst = instrumentSlot(track) {
                previewInstrumentTrack = track
                inst.noteOn(pitch, velocity: min(velocity + 15, 127))
                return
            }
            let p = s.trackParams[track]
            let freq = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
            let amp = Float(pow(Double(velocity) / 127.0, 1.4)) * p.gain * 1.8
            previewInstrumentTrack = -1
            spawn(track: track, freq: freq, amp: amp, params: p, gate: 1 << 30, held: true,
                  midiNote: 1000 + Int32(pitch))
            return
        }

        let off = s.previewOffSeq.pointee
        if off != lastPreviewOff {
            lastPreviewOff = off
            guard previewNote >= 0 else { return }
            releasePreview()
            previewNote = -1
        }
    }

    // MARK: - MIDI

    private func drainMIDI(trackCount: Int) {
        var tail = s.midiTail.pointee
        let head = s.midiHead.pointee
        while tail != head {
            let event = s.midiEvents[Int(tail % Int32(Shared.midiCapacity))]
            tail += 1
            let kind = event.status & 0xF0
            let channel = Int(event.status & 0x0F)
            if kind == 0x90 {
                noteOn(note: Int(event.note), velocity: Int(event.velocity),
                       channel: channel, trackCount: trackCount)
            } else if kind == 0x80 {
                noteOff(note: Int(event.note), channel: channel)
            } else if kind == 0xE0 {
                applyPitchBend(channel: channel,
                               value: Int(event.note) | (Int(event.velocity) << 7))
            }
        }
        s.midiTail.pointee = tail
    }

    /// MPE: a bend belongs to one channel, so every voice tagged with that channel follows it
    /// and every hosted AU receives the bend on that channel. That is a real per-note bend, not
    /// a global wheel pretending to be MPE.
    private func applyPitchBend(channel: Int, value: Int) {
        let clamped = min(max(value, 0), 16_383)
        channelBend[min(max(channel, 0), 15)] = Int32(clamped)
        let semitones = Float(clamped - 8_192) / 8_192 * 2
        let ratio = powf(2, semitones / 12)
        for i in 0..<Renderer.voiceCount where voices[i].active
            && voices[i].channel == Int32(channel) {
            voices[i].bend = ratio
        }
        for t in 0..<Shared.maxTracks {
            instrumentSlot(t)?.pitchBend(channel: channel, value: clamped)
        }
    }

    private func bendRatio(channel: Int) -> Float {
        let value = Int(channelBend[min(max(channel, 0), 15)])
        let semitones = Float(value - 8_192) / 8_192 * 2
        return powf(2, semitones / 12)
    }

    private func noteOn(note: Int, velocity: Int, channel: Int = 0, trackCount: Int) {
        var armed = -1
        for t in 0..<trackCount where s.arm[t] != 0 {
            armed = t
            break
        }
        if armed < 0 { return }
        if let inst = instrumentSlot(armed) {
            inst.noteOn(note, velocity: velocity, channel: channel)
            return
        }
        let p = s.trackParams[armed]
        let freq = 440.0 * pow(2.0, (Double(note) - 69.0) / 12.0)
        let amp = Float(pow(Double(velocity) / 127.0, 1.4)) * p.gain * 2.2
        spawn(track: armed, freq: freq, amp: amp, params: p, gate: 1 << 30, held: true,
              midiNote: Int32(note), channel: channel)
    }

    private func noteOff(note: Int, channel: Int = 0) {
        for t in 0..<Shared.maxTracks {
            instrumentSlot(t)?.noteOff(note, channel: channel)
        }
        for i in 0..<Renderer.voiceCount where voices[i].active
            && voices[i].midiNote == Int32(note) && voices[i].held
            && (channel == 0 || voices[i].channel == Int32(channel)) {
            voices[i].held = false
            voices[i].gate = 0
            if voices[i].stage == 2 { voices[i].stage = 3 }
        }
    }

    /// Real arpeggiator. It reads the notes actually sounding in the clip at this step, plays
    /// one of them per tick, and advances through the chord in the selected pattern. Routed
    /// through the same instrument/voice path, so the offline bounce matches playback.
    private func arpTick(track t: Int, clip: Int, step: Int, sampleOffset: Int) {
        let rate = max(Int(s.arpRate[t]), 1)
        guard step >= 0, step % rate == 0 else { return }
        let count = min(Int(s.noteCount[clip]), Shared.maxNotes)
        let base = clip * Shared.maxNotes
        let chordBase = t * Shared.arpChordMax
        var size = 0
        var velocity = 90
        for i in 0..<count {
            let start = Int(s.noteStart[base + i])
            let length = max(Int(s.noteLen[base + i]), 1)
            if step < start || step >= start + length { continue }
            let pitch = Int(s.notePitch[base + i])
            if size < Shared.arpChordMax {
                var slot = size
                while slot > 0 && Int(arpChord[chordBase + slot - 1]) > pitch {
                    arpChord[chordBase + slot] = arpChord[chordBase + slot - 1]
                    slot -= 1
                }
                arpChord[chordBase + slot] = Int32(pitch)
                size += 1
            }
            velocity = max(velocity, Int(s.noteVel[base + i]))
        }
        guard size > 0 else {
            arpChordCount[t] = 0
            arpIndex[t] = 0
            arpDir[t] = 1
            return
        }
        if Int(arpChordCount[t]) != size {
            arpIndex[t] = 0
            arpDir[t] = 1
        }
        arpChordCount[t] = Int32(size)
        var index = min(max(Int(arpIndex[t]), 0), size - 1)
        let pitch = Int(arpChord[chordBase + index])
        switch Int(s.arpMode[t]) {
        case 2:
            index -= 1
            if index < 0 { index = size - 1 }
        case 3:
            let direction = Int(arpDir[t]) >= 0 ? 1 : -1
            index += direction
            if index >= size {
                index = max(0, size - 2)
                arpDir[t] = -1
            } else if index < 0 {
                index = min(1, size - 1)
                arpDir[t] = 1
            }
        default:
            index = (index + 1) % size
        }
        arpIndex[t] = Int32(index)

        let envelope = clipGain(clip: clip, localStep: Double(step))
        let soundingVelocity = max(1, min(127, Int((Double(velocity) * Double(envelope)).rounded())))
        let length = rate
        if let instrument = instrumentSlot(t) {
            scheduleInstrumentNote(track: t, inst: instrument, note: pitch,
                                   velocity: soundingVelocity, length: length,
                                   sampleOffset: sampleOffset)
            return
        }
        let p = s.trackParams[t]
        let freq = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
        let amp = Float(pow(Double(soundingVelocity) / 127.0, 1.4)) * p.gain
        let gate = max(Int(samplesPerStep * Double(length)), 1)
        spawn(track: t, freq: freq, amp: amp, params: p, gate: gate)
    }

    // MARK: - AU instruments

    @inline(__always) private func instrumentSlot(_ track: Int) -> InstrumentSlot? {
        guard track >= 0, track < Shared.maxTracks, s.instOn[track] != 0,
              let raw = s.instPtr[track] else { return nil }
        return Unmanaged<InstrumentSlot>.fromOpaque(raw).takeUnretainedValue()
    }

    /// Starts an instrument note and remembers when to release it. Offs are flushed at step
    /// boundaries, matching how the sequencer places notes.
    private func scheduleInstrumentNote(track: Int, inst: InstrumentSlot, note: Int,
                                        velocity: Int, length: Int, sampleOffset: Int,
                                        channel: Int = 0) {
        inst.scheduleNoteOn(note, velocity: velocity, channel: channel,
                            sampleOffset: sampleOffset)
        let endStep = globalStep + max(length, 1)
        for i in 0..<pendingOffs.count where pendingOffs[i].note < 0 {
            pendingOffs[i].track = Int32(track)
            pendingOffs[i].note = Int32(note)
            pendingOffs[i].endStep = Int32(endStep)
            pendingOffs[i].channel = Int32(channel)
            return
        }
        inst.scheduleNoteOff(note, channel: channel, sampleOffset: sampleOffset)
    }

    private func flushInstrumentOffs(step: Int, sampleOffset: Int) {
        for i in 0..<pendingOffs.count {
            let pending = pendingOffs[i]
            if pending.note < 0 || Int(pending.endStep) > step { continue }
            instrumentSlot(Int(pending.track))?
                .scheduleNoteOff(Int(pending.note), channel: Int(pending.channel),
                                 sampleOffset: sampleOffset)
            pendingOffs[i].note = -1
        }
    }

    private func allInstrumentsOff() {
        for i in 0..<pendingOffs.count { pendingOffs[i].note = -1 }
        for t in 0..<Shared.maxTracks { instrumentSlot(t)?.allNotesOff() }
        if previewInstrumentTrack >= 0, previewNote >= 0 {
            instrumentSlot(previewInstrumentTrack)?.noteOff(Int(previewNote))
        }
        previewInstrumentTrack = -1
        previewNote = -1
    }

    private func releasePreview() {
        if previewInstrumentTrack >= 0 {
            instrumentSlot(previewInstrumentTrack)?.noteOff(Int(previewNote))
            previewInstrumentTrack = -1
        } else if previewNote >= 0 {
            noteOff(note: 1000 + Int(previewNote))
        }
    }

    // MARK: - Voices

    private func spawn(track: Int, freq: Double, amp: Float, params p: TrackParams, gate: Int,
                       held: Bool = false, midiNote: Int32 = -1, channel: Int = 0) {
        var slot = -1
        for i in 0..<Renderer.voiceCount where !voices[i].active {
            slot = i
            break
        }
        if slot < 0 {
            var quietest = Float.greatestFiniteMagnitude
            for i in 0..<Renderer.voiceCount where voices[i].env < quietest {
                quietest = voices[i].env
                slot = i
            }
        }
        guard slot >= 0 else { return }

        let pan = min(max(Double(p.pan), -1), 1)
        let angle = (pan + 1) * 0.25 * Double.pi

        var v = Voice()
        v.active = true
        v.track = Int32(track)
        v.midiNote = midiNote
        v.channel = Int32(channel)
        v.bend = bendRatio(channel: channel)
        v.held = held
        v.phase = 0
        v.env = 0
        v.stage = 0
        v.inc = freq / sampleRate
        v.sustain = p.sustain
        v.attackInc = 1 / (max(p.attack, 0.0005) * Float(sampleRate))
        v.decayInc = max(0, 1 - p.sustain) / (max(p.decay, 0.005) * Float(sampleRate))
        v.releaseInc = 1 / (max(p.release, 0.005) * Float(sampleRate))
        v.gate = Int32(gate)
        v.wave = p.waveform
        v.amp = amp
        v.gainL = Float(cos(angle))
        v.gainR = Float(sin(angle))
        voices[slot] = v
    }

    /// UI-side hook: when a track is deleted, let its sounding voices release instead of
    /// sitting in the pool forever (they are outside trackCount, so the mixer skips them).
    func releaseVoices(onTrack track: Int) {
        releaseVoices(ofTrack: track)
    }

    private func releaseVoices(ofTrack track: Int) {
        for i in 0..<Renderer.voiceCount where voices[i].active && voices[i].track == Int32(track) {
            voices[i].held = false
            voices[i].stage = 3
            voices[i].gate = 0
        }
    }

    private func releaseAllVoices() {
        for i in 0..<Renderer.voiceCount where voices[i].active {
            voices[i].held = false
            voices[i].stage = 3
            voices[i].gate = 0
        }
    }
}
