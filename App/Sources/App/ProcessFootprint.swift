import Darwin
import Foundation

/// Zetty's own memory footprint — the same quantity `footprint -p <pid>`
/// reports, read in-process so the task manager needs no subprocess for it.
///
/// This is a MEASUREMENT. The per-pane figures recorded in CLAUDE.md
/// (~110 MB fixed plus ~37 MB per live pane) are a MODEL, because per-pane GPU
/// buffers live inside libghostty and are unreachable from Swift. Do not
/// present the two as the same kind of number.
enum ProcessFootprint {

    static func current() -> Int64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int64(info.phys_footprint)
    }
}
