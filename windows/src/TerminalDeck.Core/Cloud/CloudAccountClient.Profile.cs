using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

public sealed class CloudProfileRefusal(string words) : Exception(words)
{
  public string Words { get; } = words;
}

// The profile service owns validation and returns the updated profile. A refused edit leaves the old facts intact.
public sealed partial class CloudAccountClient
{
  public Task ConnectSignInWayAsync(CancellationToken ct = default) => browser.OpenAsync(new Uri("https://terminaldeck.dev/account#ways"), ct);

  public Task<CloudProfile> SaveProfileNameAsync(string name, CancellationToken ct = default)
  {
    var clean = name.Trim();
    if (clean.Length is < 1 or > 60) throw new CloudProfileRefusal("Use a name between 1 and 60 characters.");
    return EditProfileAsync(HttpMethod.Patch, "/profile/v1/me", CloudWire.Canonical(new { name = clean }), "application/json", ct);
  }

  public Task<CloudProfile> SaveProfileUsernameAsync(string username, CancellationToken ct = default)
  {
    var clean = username.Trim().TrimStart('@');
    if (clean.Length is < 1 or > 40) throw new CloudProfileRefusal("Use a username between 1 and 40 characters.");
    return EditProfileAsync(HttpMethod.Patch, "/profile/v1/me", CloudWire.Canonical(new { username = clean }), "application/json", ct);
  }

  public Task<CloudProfile> SaveProfilePictureAsync(byte[] jpeg, CancellationToken ct = default)
  {
    if (jpeg.Length is < 4 or > 500_000 || jpeg[0] != 0xff || jpeg[1] != 0xd8) throw new CloudProfileRefusal("That picture could not be read. Try a PNG or JPEG.");
    return EditProfileAsync(HttpMethod.Put, "/profile/v1/me/picture", jpeg, "image/jpeg", ct);
  }

  public Task<CloudProfile> RemoveProfilePictureAsync(CancellationToken ct = default) => EditProfileAsync(HttpMethod.Delete, "/profile/v1/me/picture", [], null, ct);

  public Task<CloudProfile> DisconnectSignInWayAsync(string id, CancellationToken ct = default)
  {
    if (string.IsNullOrWhiteSpace(id)) throw new CloudProfileRefusal("That way to sign in is no longer available.");
    return EditProfileAsync(HttpMethod.Delete, "/profile/v1/me/ways/" + Uri.EscapeDataString(id), [], null, ct);
  }

  private async Task<CloudProfile> EditProfileAsync(HttpMethod method, string path, byte[] body, string? contentType, CancellationToken ct)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Load() || saved is not { } record) throw new CloudProfileRefusal("Sign in to change your profile.");
      record = await RefreshTokenAsync(record, ct);
      for (var attempt = 0; attempt < 2; attempt++)
      {
        var headers = Bearer(record.Session.AccessToken);
        if (contentType is not null) headers["content-type"] = contentType;
        var response = await http.SendAsync(new(method, new Uri(configuration.Endpoints.Token, path), headers, body), ct);
        if (response.Status == 401 && attempt == 0) { record = await RefreshTokenAsync(record, ct, force: true); continue; }
        if (response.Status is < 200 or > 299)
          throw new CloudProfileRefusal(ProfileMessage(response.Body) ?? "Could not save that change. Try again.");
        var profile = CloudProfile.Read(response.Body);
        var user = record.Session.User with { DisplayName = profile.Name, Email = profile.Email ?? record.Session.User.Email };
        Save(record with { Session = record.Session with { User = user } });
        Publish(Snapshot with { DisplayName = user.DisplayName, Email = user.Email });
        return profile;
      }
      throw new CloudProfileRefusal("Sign in again to change your profile.");
    }
    catch (Exception error) when (error is HttpRequestException or JsonException or CloudFailure)
    { throw new CloudProfileRefusal("Could not save that change. Check your connection."); }
    finally { work.Release(); }
  }

  private static string? ProfileMessage(byte[] body)
  {
    try
    {
      using var doc = JsonDocument.Parse(body);
      return doc.RootElement.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.String && message.GetString()?.Trim() is { Length: > 0 } words ? words[..Math.Min(words.Length, 200)] : null;
    }
    catch (JsonException) { return null; }
  }
}
