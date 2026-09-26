import DirectaKit

/** The listen probe behind the Router's port checks. A seam so a test can hold
    one probe open while another request moves a server's phase, which is the
    only way to pin the order the pre-check reads its evidence in. */
public struct PortProbe: Sendable {
    public var isListening: @Sendable (Int) async -> Bool

    public init(isListening: @escaping @Sendable (Int) async -> Bool) {
        self.isListening = isListening
    }

    public static let live = PortProbe { await PortGuard.isListening(port: $0) }
}
