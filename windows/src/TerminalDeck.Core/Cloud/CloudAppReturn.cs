namespace TerminalDeck.Core.Cloud;

/// The website's return link `terminaldeck://cloud/return/<token>?code=…&state=…` (13 Nov, owner: sign-in returns through
/// the official website, one "Open Terminal Deck" click, nothing to accept in the app). Windows hands it to the running
/// copy by protocol activation. Parsing only says what the link carries; whether it answers anything is decided by
/// `CloudAccountClient.FinishAppReturnAsync`, against the sign-in this app itself started.
public sealed record CloudAppReturn(string Token, string Code, string State)
{
  public override string ToString() => "<Cloud sign-in return>";

  /// The shape alone (scheme, host, `/return/`), so activation can route the link; nothing here is trusted.
  public static bool IsReturnLink(Uri? uri) => uri is { IsAbsoluteUri: true, Scheme: "terminaldeck", Host: "cloud" } && uri.AbsolutePath.StartsWith("/return/", StringComparison.Ordinal);

  /// Null for anything that is not exactly one well-formed return: a 22-character token, `code` and `state` once each and
  /// nothing else, base64url text only, a 43-character state, a code of at most 256 characters.
  public static CloudAppReturn? Parse(Uri? link)
  {
    if (link is null || !IsReturnLink(link) || link.OriginalString.Length > 2048 || !string.IsNullOrEmpty(link.UserInfo) || !string.IsNullOrEmpty(link.Fragment) || link.Port != -1)
      return null;
    var token = link.AbsolutePath["/return/".Length..];
    if (token.Length != 22 || !Base64Url(token)) return null;
    var pairs = link.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Split('=', 2)).ToArray();
    if (pairs.Length != 2 || pairs.Any(p => p.Length != 2) || pairs.Select(p => p[0]).Distinct(StringComparer.Ordinal).Count() != 2
      || !pairs.All(p => p[0] is "code" or "state")) return null;
    var code = pairs.Single(p => p[0] == "code")[1];
    var state = pairs.Single(p => p[0] == "state")[1];
    if (code.Length is 0 or > 256 || !Base64Url(code) || state.Length != 43 || !Base64Url(state)) return null;
    return new(token, code, state);
  }

  private static bool Base64Url(string text) => text.All(c => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_');

  /// Compares without stopping at the first different character.
  internal static bool Same(string a, string b)
  {
    if (a.Length != b.Length) return false;
    var diff = 0;
    for (var i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
    return diff == 0;
  }
}
