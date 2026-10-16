import Darwin

/// mach_absolute_time based clock, the time base CoreMIDI timestamps use.
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static var now: UInt64 { mach_absolute_time() }

    public static func ticks(fromSeconds s: Double) -> UInt64 {
        UInt64(max(0, s) * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    public static func seconds(fromTicks t: UInt64) -> Double {
        Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// Sleeps the calling thread until the given host time (precise, unlike usleep).
    public static func wait(until t: UInt64) {
        if t > mach_absolute_time() { mach_wait_until(t) }
    }
}
