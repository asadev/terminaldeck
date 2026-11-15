namespace TerminalDeck.Core.Cloud;

// Who may hold the saved-passwords key, by the kind of device THIS PC recorded with its key (the Mac's
// CloudSecretsAutoTrust kinds and Pinned, passwords-in-browser-design.md C3). His computers always; his own signed-in
// phones and his browsers' key box (the web app's separate page, platform "web") unless his one switch keeps saved
// passwords off his phones and browsers; an unknown kind never. A browser is answered exactly like a phone, but as its
// own kind: a pinned browser never passes as a phone or a computer, nor the reverse. A browser never gets a copy at a
// key change made after a sign-out from another device (CloudSecretsLostDevice). Nothing here trusts the service's word.

public enum CloudSecretsKind { Computer, Phone, Browser }

public static class CloudSecretsKinds
{
  public static bool IsComputer(string? platform) => platform is "macos" or "windows";
  public static bool IsPhone(string? platform) => platform is "ios" or "android";
  public static bool IsBrowser(string? platform) => platform == "web";
  public static CloudSecretsKind? Kind(string? platform) =>
    IsComputer(platform) ? CloudSecretsKind.Computer : IsPhone(platform) ? CloudSecretsKind.Phone : IsBrowser(platform) ? CloudSecretsKind.Browser : null;
  /// The kind THIS PC recorded and the kind the account lists now are the same known kind (an iPhone and an Android
  /// phone are one kind).
  public static bool SameKind(string? recorded, string? listed) => Kind(recorded) is { } a && Kind(listed) is { } b && a == b;
}

/// A device on THIS PC's own trusted list: the name and signing key stored when it was trusted, and the kind of device
/// recorded with that key (null = not recorded: never taken for any kind).
public sealed record CloudSecretsPinned(string Name, CloudPublicJwk SignKey, string? Platform)
{
  public bool IsComputer => CloudSecretsKinds.IsComputer(Platform);
  public bool SameKey(CloudPublicJwk key) => SignKey.Kty == key.Kty && SignKey.Crv == key.Crv && SignKey.X == key.X && SignKey.Y == key.Y;
}

/// What the hand-over asks of this PC's own knowledge (CloudSecretsAutoTrust). `On`: the automatic hand-over is wired
/// (the app: always). `Pinned`: the trusted entry for a device id, null when unknown, stopped, or the list unreadable.
public sealed class CloudSecretsAutoTrust(Func<bool> on, Func<string, CloudSecretsPinned?> pinned)
{
  public bool On => on();
  public CloudSecretsPinned? Pinned(string deviceId) => pinned(deviceId);
  /// From this PC's trusted list: only a trusted entry, with the kind it recorded.
  public static CloudSecretsAutoTrust FromList(Func<CloudTrustStore?> list) => new(() => true, id =>
  {
    var entry = list()?.Entry(id) ?? list()?.Entry(id.ToLowerInvariant());
    return entry is { Trusted: true } ? new CloudSecretsPinned(entry.Name, entry.SignKey, entry.Platform) : null;
  });
}
