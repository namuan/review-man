import Foundation
import Darwin.Mach

/// Lightweight timing and process-footprint helpers for the Phase 4 spike and
/// benchmark. Not for shipping code.
public enum Measurement {

    /// Runs `body`, returning its value and elapsed wall time in seconds.
    public static func time<T>(_ body: () throws -> T) rethrows -> (elapsed: TimeInterval, value: T) {
        let start = DispatchTime.now()
        let value = try body()
        let end = DispatchTime.now()
        let elapsed = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
        return (elapsed, value)
    }

    /// Process physical footprint in bytes (Mach `phys_footprint`).
    public static func physicalFootprintBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { p in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), p, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.phys_footprint)
    }

    public static func miB(_ bytes: Int64) -> Double {
        Double(bytes) / (1024 * 1024)
    }
}
