import Darwin

/** One `proc_pidinfo` read of a fixed-layout flavor into `empty`'s type. Nil
    unless the kernel filled exactly the whole struct: a short read means the
    pid is gone or this kernel lays the flavor out differently, and a partly
    filled struct would read as real ids. */
func readProcInfo<Info>(pid: pid_t, flavor: Int32, argument: UInt64, into empty: Info) -> Info? {
    var info = empty
    let size = Int32(MemoryLayout<Info>.size)
    let filled = withUnsafeMutableBytes(of: &info) { buffer -> Int32 in
        guard let base = buffer.baseAddress else { return 0 }
        return proc_pidinfo(pid, flavor, argument, base, size)
    }
    return filled == size ? info : nil
}
