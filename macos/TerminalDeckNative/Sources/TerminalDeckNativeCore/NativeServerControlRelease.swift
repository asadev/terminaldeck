/// 0.20.0 release fence. DKA enables this only after the current contract/focused
/// gates and a demo live run pass with before/after cleanup in LIVE-LOG.md.
/// Caller payloads and preferences cannot enable an unverified server feature.
public enum NativeServerControlRelease {
    // DKA: FullFake40 622/622, Focused39 373/373, Live41 passed with cleanup.
    public static let enabled = true
}
