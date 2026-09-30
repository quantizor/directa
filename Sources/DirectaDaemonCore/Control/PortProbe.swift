/** The listen probe behind the Router's port checks. A seam so a test can hold
    one probe open while another request moves a server's phase, which is the
    only way to pin the order the pre-check reads its evidence in, and can name
    the unmanaged process a scripted listener belongs to without lsof. */
public struct PortProbe: Sendable {
    public var isListening: @Sendable (Int) async -> Bool
    /** The process listening on a port, for a message naming an unmanaged
        holder; nil when none can be read. */
    public var listenerInfo: @Sendable (Int) async -> (pid: Int, command: String)?

    public init(
        isListening: @escaping @Sendable (Int) async -> Bool,
        listenerInfo: @escaping @Sendable (Int) async -> (pid: Int, command: String)? = { _ in nil }
    ) {
        self.isListening = isListening
        self.listenerInfo = listenerInfo
    }

    public static let live = PortProbe(
        isListening: { await PortGuard.isListening(port: $0) },
        listenerInfo: { await PortGuard.listenerInfo(port: $0) })
}
