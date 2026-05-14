import Foundation
import Darwin

/// Monotonic nanosecond clock based on mach_absolute_time, converted to
/// real nanoseconds via mach_timebase_info. Both iPhone and Mac sample this
/// clock independently; their clock domains differ, so a one-shot offset
/// estimate (clockProbe/clockProbeReply) is needed before cross-machine
/// latency math is meaningful.
public enum MachClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Current monotonic time in nanoseconds.
    public static func nowNs() -> Int64 {
        let raw = mach_absolute_time()
        let ns = raw &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return Int64(bitPattern: ns)
    }
}
