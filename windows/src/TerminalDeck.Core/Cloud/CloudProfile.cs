using System.Globalization;
using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Settings > Profile (Mac, 14 Nov): picture, name, e-mail and the ways he signs in, as the site's
// GET https://api.terminaldeck.dev/profile/v1/me gives them. Names and dates only: a way's id is
// kept only for the site's own remove call and never shown; no code, key or account id is shown.
public sealed record CloudSignInWay(string ProviderName, string Account, DateTimeOffset? ConnectedSince);
public sealed record CloudProfile(string Name, string? Email, Uri? Picture, IReadOnlyList<CloudSignInWay> Ways, DateTimeOffset? MemberSince)
{
  public static CloudProfile Read(byte[] json)
  {
    using var doc = JsonDocument.Parse(json);
    var root = doc.RootElement;
    if (root.ValueKind != JsonValueKind.Object) throw new JsonException("A profile is an object.");
    string? Text(JsonElement parent, string name) => parent.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s ? s : null;
    DateTimeOffset? When(JsonElement parent, string name) => Text(parent, name) is { } s && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var at) ? at : null;
    // Only an https address on the site's own host is loaded (the gateway fetches provider pictures itself).
    var picture = Text(root, "picture") is { } address && Uri.TryCreate(address, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps
      && uri.Host.Equals("api.terminaldeck.dev", StringComparison.OrdinalIgnoreCase) ? uri : null;
    var ways = new List<CloudSignInWay>();
    if (root.TryGetProperty("waysToSignIn", out var list) && list.ValueKind == JsonValueKind.Array)
      foreach (var way in list.EnumerateArray().Where(w => w.ValueKind == JsonValueKind.Object))
        ways.Add(new(Text(way, "providerName") ?? ProviderName(Text(way, "provider")), Text(way, "account") ?? "", When(way, "connectedSince")));
    var email = Text(root, "email");
    return new(Text(root, "name") ?? email ?? "Your account", email, picture, ways, When(root, "memberSince"));
  }

  public static string ProviderName(string? provider) => provider switch
  {
    "github" => "GitHub", "google" => "Google", "apple" => "Apple", "email" => "E-mail", null or "" => "Sign-in", _ => provider![..1].ToUpperInvariant() + provider[1..]
  };

  // Before the site answers (or when it cannot be reached), the sign-in this PC already holds says
  // at least the name, the e-mail and the one way it used.
  public static CloudProfile FromSnapshot(CloudSnapshot snapshot) =>
    new(snapshot.DisplayName is { Length: > 0 } name ? name : snapshot.Email ?? "Your account", snapshot.Email, null,
      snapshot.Provider is { Length: > 0 } provider ? new CloudSignInWay[] { new(ProviderName(provider), "", null) } : Array.Empty<CloudSignInWay>(), null);

  public static string Initials(string name)
  {
    var words = name.Split(new[] { ' ', '.', '_', '-', '@' }, StringSplitOptions.RemoveEmptyEntries);
    return words.Length switch { 0 => "?", 1 => words[0][..1].ToUpperInvariant(), _ => (words[0][..1] + words[1][..1]).ToUpperInvariant() };
  }

  // "@pat · connected 3 Nov 2026": the account as the site names it and a date, never an id.
  public static string WayDetails(CloudSignInWay way) =>
    string.Join(" · ", new[] { way.Account, way.ConnectedSince is { } at ? "connected " + at.ToLocalTime().ToString("d MMM yyyy", CultureInfo.InvariantCulture) : "" }.Where(s => s.Length > 0));
}

public sealed partial class CloudAccountClient
{
  // The profile, read with this PC's own sign-in. Null when signed out or when the site does not
  // answer (the page then keeps what the sign-in already says).
  public async Task<CloudProfile?> ProfileAsync(CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Load() || saved is not { } record) return null;
      record = await RefreshTokenAsync(record, ct);
      var body = await SendAsync(HttpMethod.Get, new Uri(configuration.Endpoints.Token, "/profile/v1/me"), [], Bearer(record.Session.AccessToken), ct);
      return CloudProfile.Read(body);
    }
    catch (Exception ex) when (ex is CloudFailure or HttpRequestException or TaskCanceledException or JsonException && !ct.IsCancellationRequested) { return null; }
    finally { work.Release(); }
  }
}
