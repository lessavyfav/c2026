import Foundation

/// Writes a sample as a standard MIDI Sample Dump `.syx` file — the same bytes the sender puts on
/// the wire (header, optional Extended SDS / SPS-1UW name, data packets). The original C6 could only
/// convert while sending; this lets users keep sample backups as SysEx.
public extension SDSSample {
    func sdsFileBytes(sampleNumber: Int, options: SDSSender.Options = .init()) -> [UInt8] {
        final class Recorder: MIDITransport {
            var onReceive: (([UInt8]) -> Void)?
            var bytes: [UInt8] = []
            func sendStream(_ b: ArraySlice<UInt8>, at hostTime: UInt64?) { bytes += b }
            func flushScheduled() {}
        }
        var o = options
        o.handshake = false            // nothing to wait for
        o.interPacketDelayMs = 0
        o.lineRate = 1e12              // no pacing
        o.startSampleNumber = sampleNumber
        let rec = Recorder()
        SDSSender(transport: rec, options: o).send([self])
        return rec.bytes
    }
}
