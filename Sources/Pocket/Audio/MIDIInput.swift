import CoreMIDI
import Foundation

/// CoreMIDI input. Pushes note on/off into the lock-free ring in `Shared`;
/// the renderer drains it at the top of each block.
final class MIDIInput {
    private let shared: Shared
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var sources: [MIDIEndpointRef] = []
    /// UI-side capture hook. The renderer still drains the realtime ring; this callback is only
    /// used by the transport recorder and is nil while not recording.
    var onEvent: ((UInt8, UInt8, UInt8) -> Void)?

    init(shared: Shared) {
        self.shared = shared
        MIDIClientCreateWithBlock("Pocket" as CFString, &client) { _ in }
        MIDIInputPortCreateWithBlock(client, "Pocket In" as CFString, &port) { [weak self] list, _ in
            self?.parse(list)
        }
        rescan()
    }

    deinit {
        MIDIPortDispose(port)
        MIDIClientDispose(client)
    }

    func rescan() {
        for src in sources { MIDIPortDisconnectSource(port, src) }
        sources = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let src = MIDIGetSource(i)
            if src != 0 && MIDIPortConnectSource(port, src, nil) == noErr {
                sources.append(src)
            }
        }
    }

    var sourceCount: Int { sources.count }
    var isConnected: Bool { !sources.isEmpty }

    private func parse(_ listPtr: UnsafePointer<MIDIPacketList>) {
        let list = listPtr.pointee
        var packet = list.packet
        for _ in 0..<Int(list.numPackets) {
            withUnsafeBytes(of: packet.data) { raw in
                var i = 0
                while i < Int(packet.length) {
                    let status = raw[i]
                    if status & 0x80 == 0 { i += 1; continue }
                    let cmd = status & 0xF0
                    // The low nibble is the MIDI channel. Keeping it is what makes MPE work:
                    // a controller puts each note on its own member channel and bends it there.
                    let channel = status & 0x0F
                    switch cmd {
                    case 0x90 where i + 2 < Int(packet.length):
                        let note = raw[i + 1]
                        let vel = raw[i + 2]
                        if vel > 0 {
                            push(0x90 | channel, note, vel)
                        } else {
                            push(0x80 | channel, note, 0)
                        }
                        i += 3
                    case 0x80 where i + 2 < Int(packet.length):
                        push(0x80 | channel, raw[i + 1], 0)
                        i += 3
                    case 0xE0 where i + 2 < Int(packet.length):
                        // 14-bit pitch bend, carried as two 7-bit bytes. The renderer applies it
                        // per note-on channel, which is exactly MPE's per-note bend.
                        push(0xE0 | channel, raw[i + 1], raw[i + 2])
                        i += 3
                    case 0xB0 where i + 2 < Int(packet.length):
                        // Controller number in 1, controller value in 2. The UI maps these to
                        // master/track targets after a learn pass; the renderer ignores them.
                        push(0xB0 | channel, raw[i + 1], raw[i + 2])
                        i += 3
                    case 0xC0, 0xD0:
                        i += 2
                    default:
                        i += 3
                    }
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }

    private func push(_ status: UInt8, _ note: UInt8, _ velocity: UInt8) {
        let head = shared.midiHead.pointee
        let tail = shared.midiTail.pointee
        onEvent?(status, note, velocity)
        if head - tail >= Int32(Shared.midiCapacity) { return }
        let idx = Int(head % Int32(Shared.midiCapacity))
        var event = shared.midiEvents[idx]
        event.status = Int32(status)
        event.note = Int32(note)
        event.velocity = Int32(velocity)
        shared.midiEvents[idx] = event
        shared.midiHead.pointee = head + 1
    }
}
