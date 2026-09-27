extension Duration {
    /** Seconds at millisecond resolution, which keeps telemetry lines short
        and stable. */
    public var roundedSeconds: Double {
        (self / .milliseconds(1)).rounded() / 1000
    }

    /** Whole microseconds, the fraction truncated. */
    public var wholeMicroseconds: Int {
        Int(self / .microseconds(1))
    }
}
