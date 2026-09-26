import Darwin
import DirectaKit
import Foundation

/** Reads the daemon's own threads, memory, and descriptors from the kernel.
    Confined to the sampler thread (it reuses buffers between samples), so it
    is deliberately not Sendable. Every read that the kernel refuses comes back
    nil rather than zero. */
final class ProcessSampler {
    private var descriptorBuffer: [proc_fdinfo] = []
    private let pageSize = Int(getpagesize())
    /** Offset of the label pointer inside a dispatch queue object, found once
        at init by locating a known label in a queue this sampler creates. Nil
        when the search fails, and then threads are named by pthread name only. */
    private let queueLabelOffset: Int?

    init() {
        queueLabelOffset = Self.discoverQueueLabelOffset()
    }

    struct Threads {
        var detail: [ThreadDetail]
        var sample: ThreadSample
    }

    /** Every thread of this task. `withDetail` adds one `ThreadDetail` per
        thread for a threshold snapshot. */
    func threads(limit: Int?, withDetail: Bool) -> Threads? {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let list else { return nil }
        defer {
            for index in 0..<Int(count) {
                mach_port_deallocate(mach_task_self_, list[index])
            }
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var byName: [String: Int] = [:]
        var byState: [String: Int] = [:]
        var detail: [ThreadDetail] = []
        for index in 0..<Int(count) {
            let thread = list[index]
            let basic = Self.basicInfo(thread)
            let state = basic.map { ThreadRunState(machState: $0.run_state) } ?? .unknown
            let name = threadName(thread)
            byName[name, default: 0] += 1
            byState[state.rawValue, default: 0] += 1
            if withDetail {
                detail.append(
                    ThreadDetail(
                        cpuPercent: basic.map { Double($0.cpu_usage) / Double(TH_USAGE_SCALE) * 100 } ?? 0,
                        name: name, state: state,
                        systemSeconds: basic.map { Self.seconds($0.system_time) } ?? 0,
                        userSeconds: basic.map { Self.seconds($0.user_time) } ?? 0))
            }
        }
        return Threads(
            detail: detail,
            sample: ThreadSample(
                byName: byName, byState: byState, limit: limit, total: Int(count), workqueue: workqueue()))
    }

    func memory() -> MemorySample? {
        var usage = rusage_info_v6()
        let usageResult = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        var vm = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        guard usageResult == 0, vmResult == KERN_SUCCESS else { return nil }
        return MemorySample(
            compressed: vm.compressed, compressedLifetime: vm.compressed_lifetime,
            compressedPeak: vm.compressed_peak, footprint: usage.ri_phys_footprint,
            footprintLifetimePeak: usage.ri_lifetime_max_phys_footprint, internal: vm.internal,
            internalPeak: vm.internal_peak, resident: usage.ri_resident_size)
    }

    /** Open descriptors. The size-only call over-reports (it returns a
        padded buffer size), so the count comes from a real fill, into a
        buffer kept between samples and grown only when the table grows. */
    func fileDescriptors() -> Int? {
        let pid = getpid()
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return nil }
        let slots = Int(needed) / MemoryLayout<proc_fdinfo>.stride + 16
        if descriptorBuffer.count < slots {
            descriptorBuffer = [proc_fdinfo](repeating: proc_fdinfo(), count: slots * 2)
        }
        let filled = descriptorBuffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard filled >= 0 else { return nil }
        return Int(filled) / MemoryLayout<proc_fdinfo>.stride
    }

    func system() -> SystemSample {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure =
            sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
            ? SystemSample.pressureName(level: level) : "unreadable"
        var loads = [Double](repeating: 0, count: 3)
        let read = getloadavg(&loads, 3)
        return SystemSample(
            loadAverage: read == 3 ? loads.map { ($0 * 100).rounded() / 100 } : [],
            memoryPressure: pressure)
    }

    private func workqueue() -> WorkqueueSample? {
        var info = proc_workqueueinfo()
        let size = Int32(MemoryLayout<proc_workqueueinfo>.size)
        guard proc_pidinfo(getpid(), PROC_PIDWORKQUEUEINFO, 0, &info, size) == size else { return nil }
        return WorkqueueSample(
            blocked: Int(info.pwq_blockedthreads),
            limitsExceeded: WorkqueueSample.limitNames(state: info.pwq_state),
            running: Int(info.pwq_runthreads), total: Int(info.pwq_nthreads))
    }

    private static func basicInfo(_ thread: thread_act_t) -> thread_basic_info? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /** The pthread name, else the label of the dispatch queue the thread is
        serving, else `(unnamed)`. */
    private func threadName(_ thread: thread_act_t) -> String {
        var extended = thread_extended_info()
        var extendedCount = mach_msg_type_number_t(
            MemoryLayout<thread_extended_info>.size / MemoryLayout<natural_t>.size)
        let extendedResult = withUnsafeMutablePointer(to: &extended) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                thread_info(thread, thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
            }
        }
        if extendedResult == KERN_SUCCESS {
            let name = withUnsafeBytes(of: extended.pth_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if !name.isEmpty { return name }
        }
        return queueLabel(thread) ?? "(unnamed)"
    }

    /** The queue label via the thread's dispatch slot. Every pointer is read
        with `vm_read_overwrite`, which fails instead of faulting, because the
        queue can be released between reading the slot and reading its label:
        a stale read yields a wrong or unreadable label, never a crash. */
    private func queueLabel(_ thread: thread_act_t) -> String? {
        guard let offset = queueLabelOffset else { return nil }
        var identifier = thread_identifier_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &identifier) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, identifier.dispatch_qaddr != 0,
            let queue = Self.readWord(UInt(identifier.dispatch_qaddr)), queue != 0,
            let label = Self.readWord(queue + UInt(offset)), label != 0
        else { return nil }
        return readCString(label)
    }

    private static func readWord(_ address: UInt) -> UInt? {
        var value: UInt = 0
        var copied: vm_size_t = 0
        let result = withUnsafeMutablePointer(to: &value) {
            vm_read_overwrite(
                mach_task_self_, vm_address_t(address), vm_size_t(MemoryLayout<UInt>.size),
                vm_address_t(UInt(bitPattern: $0)), &copied)
        }
        return result == KERN_SUCCESS ? value : nil
    }

    /** Up to 96 printable ASCII bytes, never crossing into the next page (it
        may be unmapped). Nil for anything else. */
    private func readCString(_ address: UInt) -> String? {
        Self.readCString(address, pageSize: pageSize)
    }

    private static func readCString(_ address: UInt, pageSize: Int) -> String? {
        let length = min(96, pageSize - Int(address % UInt(pageSize)))
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: length) { buffer -> String? in
            var copied: vm_size_t = 0
            let result = vm_read_overwrite(
                mach_task_self_, vm_address_t(address), vm_size_t(length),
                vm_address_t(UInt(bitPattern: buffer.baseAddress)), &copied)
            guard result == KERN_SUCCESS else { return nil }
            let text = buffer.prefix(Int(copied)).prefix { $0 != 0 }
            guard !text.isEmpty, text.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
            return String(decoding: text, as: UTF8.self)
        }
    }

    private static func discoverQueueLabelOffset() -> Int? {
        let label = "dev.quantizor.directa.telemetry.label-probe"
        let queue = DispatchQueue(label: label)
        let base = UInt(bitPattern: Unmanaged.passUnretained(queue).toOpaque())
        let pageSize = Int(getpagesize())
        return withExtendedLifetime(queue) {
            stride(from: 0, to: 256, by: MemoryLayout<UInt>.size).first { offset in
                guard let pointer = readWord(base + UInt(offset)), pointer != 0 else { return false }
                return readCString(pointer, pageSize: pageSize) == label
            }
        }
    }

    private static func seconds(_ value: time_value_t) -> Double {
        ((Double(value.seconds) + Double(value.microseconds) / 1e6) * 1000).rounded() / 1000
    }
}
