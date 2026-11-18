using System.Text.Json;
using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Cloud;

public sealed class CloudProfileManagementTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-profile-management-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private sealed class ProfileHttp : ICloudHttp
  {
    public readonly CloudServiceFake Service = new();
    public readonly List<CloudHttpRequest> ProfileRequests = [];
    public string Name = "Pat Doe", Username = "pat";
    public bool RenameAccepted = true, RotationRequired;
    public int ProfileRefusals;
    private static CloudHttpResponse Json(object value, int status = 200) => new(status, JsonSerializer.SerializeToUtf8Bytes(value));
    private CloudHttpResponse Me() => Json(new { name = Name, username = Username, usernameCanChange = true, email = "pat@example.com", waysToSignIn = new[] { new { id = "way-google", provider = "google", account = "pat@example.com", canRemove = true }, new { id = "way-github", provider = "github", account = "@pat", canRemove = true } } });
    public Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
    {
      var path = request.Url.AbsolutePath;
      if (path.StartsWith("/profile/", StringComparison.Ordinal))
      {
        ProfileRequests.Add(request);
        Assert.StartsWith("Bearer ", request.Headers["Authorization"]);
        if (ProfileRefusals-- > 0) return Task.FromResult(Json(new { message = "Refresh your sign-in." }, 401));
        if (request.Method == HttpMethod.Patch)
        {
          using var body = JsonDocument.Parse(request.Body);
          if (body.RootElement.TryGetProperty("name", out var name)) Name = name.GetString()!;
          if (body.RootElement.TryGetProperty("username", out var username))
          {
            if (username.GetString() == "taken") return Task.FromResult(Json(new { code = "taken", message = "That username is taken." }, 409));
            Username = username.GetString()!;
          }
        }
        return Task.FromResult(Me());
      }
      if (path == "/auth/v1/settings") return Task.FromResult(Json(new { external = new { google = true, github = true, apple = false } }));
      if (path == "/v1/devices/rename")
      {
        Assert.True(request.Headers.ContainsKey("X-TD-Signature"));
        using var body = JsonDocument.Parse(request.Body);
        Assert.Equal(new[] { "device_id", "name" }, body.RootElement.EnumerateObject().Select(p => p.Name));
        return Task.FromResult(Json(new { ok = RenameAccepted }));
      }
      if (path == "/v1/devices/remove" && RotationRequired) return Task.FromResult(Json(new { error = new { code = "rotation_required" } }, 409));
      return Service.SendAsync(request, ct);
    }
  }

  private async Task<(CloudAccountClient Account, ProfileHttp Http)> SignedInAsync()
  {
    var http = new ProfileHttp();
    var account = new CloudAccountClient(CloudConfiguration.Today("PC", "1"), new ProtectedCloudSecretStore(Path.Combine(folder, Guid.NewGuid().ToString("N")), new XorProtector()), http, new CountingRandom(), new FakeBrowser());
    var start = await account.BeginSignInAsync();
    var query = start.Query.TrimStart('?').Split('&').Select(p => p.Split('=', 2)).ToDictionary(p => p[0], p => Uri.UnescapeDataString(p[1]));
    Assert.True(await account.FinishAppReturnAsync(new Uri($"terminaldeck://cloud/return/{query["callback"]}?code=Q29kZUZyb21UaGVXZWJzaXRlX19fX19fX19fX19fX19&state={query["state"]}")));
    return (account, http);
  }

  [Fact]
  public async Task Profile_edits_use_the_account_and_keep_its_refusal_words()
  {
    var setup = await SignedInAsync(); using var account = setup.Account;
    var profile = await account.ProfileAsync();
    Assert.Equal(new[] { "github", "google" }, profile!.Addable);
    Assert.Equal("way-google", profile.Ways[0].Id); Assert.True(profile.Ways[0].CanRemove);
    var changed = await account.SaveProfileNameAsync("  Sam Rivera  ");
    Assert.Equal("Sam Rivera", changed.Name); Assert.Equal("Sam Rivera", account.Snapshot.DisplayName);
    changed = await account.SaveProfileUsernameAsync(" @sam "); Assert.Equal("sam", changed.Username);
    var refused = await Assert.ThrowsAsync<CloudProfileRefusal>(() => account.SaveProfileUsernameAsync("taken"));
    Assert.Equal("That username is taken.", refused.Words);
    Assert.Equal("Sam Rivera", account.Snapshot.DisplayName);
    await account.DisconnectSignInWayAsync("way-google");
    Assert.Equal("/profile/v1/me/ways/way-google", setup.Http.ProfileRequests[^1].Url.AbsolutePath);
    Assert.Equal(HttpMethod.Delete, setup.Http.ProfileRequests[^1].Method);
  }

  [Fact]
  public async Task Device_rename_requires_an_acknowledgement_and_sign_out_uses_a_fresh_vault_version()
  {
    var setup = await SignedInAsync(); using var account = setup.Account;
    var other = account.Snapshot.DeviceRows.Single(d => !d.ThisDevice);
    setup.Http.RenameAccepted = false;
    await Assert.ThrowsAsync<CloudFailure>(() => account.RenameDeviceAsync(other.DeviceId, "Office Mac"));
    Assert.Equal(other.Name, account.Snapshot.DeviceRows.Single(d => d.DeviceId == other.DeviceId).Name);
    setup.Http.RenameAccepted = true;
    await account.RenameDeviceAsync(other.DeviceId, "Office Mac");
    Assert.Equal("Office Mac", account.Snapshot.DeviceRows.Single(d => d.DeviceId == other.DeviceId).Name);
    setup.Http.Service.RemoveConflicts = 1;
    await account.SignOutDeviceAsync(other.DeviceId);
    Assert.Equal(new[] { other.DeviceId }, setup.Http.Service.Removed);
    Assert.DoesNotContain(account.Snapshot.DeviceRows, d => d.DeviceId == other.DeviceId);
    Assert.Contains(account.Snapshot.DeviceRows, d => d.ThisDevice);
    await Assert.ThrowsAsync<CloudProfileRefusal>(() => account.SignOutDeviceAsync(account.Snapshot.ThisDeviceId!));
  }

  [Fact]
  public async Task A_saved_password_key_refusal_keeps_the_device_signed_in()
  {
    var setup = await SignedInAsync(); using var account = setup.Account;
    var other = account.Snapshot.DeviceRows.Single(d => !d.ThisDevice);
    setup.Http.RotationRequired = true;
    var refusal = await Assert.ThrowsAsync<CloudProfileRefusal>(() => account.SignOutDeviceAsync(other.DeviceId));
    Assert.Contains("key", refusal.Words);
    Assert.Contains(account.Snapshot.DeviceRows, d => d.DeviceId == other.DeviceId);
  }

  [Theory]
  [InlineData("macos", "Renamed", "mac-mini", DeviceModel.MacMini)]
  [InlineData("windows", "Mac mini", null, DeviceModel.WindowsDesktop)]
  [InlineData("windows", "Office", "windows-laptop", DeviceModel.WindowsLaptop)]
  [InlineData("web", "iPhone", null, DeviceModel.Browser)]
  [InlineData("android", "ASAD Pixel8", null, DeviceModel.AndroidPhone)]
  [InlineData("ios", "Sam's iPad", null, DeviceModel.IPad)]
  public void A_reported_model_wins_and_platform_keeps_an_old_name_in_the_right_family(string platform, string name, string? reported, DeviceModel expected) => Assert.Equal(expected, DeviceModels.Of(platform, name, reported));

  [Fact]
  public void Edits_ask_and_reads_remain_free()
  {
    foreach (var spec in CloudTools.ProfileSpecs)
    {
      var read = JsonSerializer.SerializeToElement(new { action = spec.Id == "cloud.profile" ? "read" : "list" });
      var edit = JsonSerializer.SerializeToElement(new { action = spec.Id == "cloud.profile" ? "username" : "rename" });
      Assert.Equal(McpTier.Read, McpCatalogue.EffectiveTier(spec, read));
      Assert.Equal(McpTier.Alter, McpCatalogue.EffectiveTier(spec, edit));
    }
    Assert.Equal("profile", SettingsNavigation.Canonical("devices.older"));
  }

  [Fact]
  public void Missing_file_rows_group_only_when_the_name_is_unknown()
  {
    var unknown = new CloudContentsRow("task|a", CloudContentsKind.Tasks, "A task not on this PC", [], 1, null, null, CloudItemState.NotOnThisPc);
    Assert.True(YourCloudRules.Nameless(unknown));
    Assert.False(YourCloudRules.Nameless(unknown with { Name = "Ship the Windows app" }));
    Assert.Equal("9 tasks that are not on this PC", YourCloudRules.MissingName(CloudContentsKind.Tasks, 9));
    Assert.Equal("Some saved passwords are not in your Cloud yet", CloudCalmWords.Summary("Waiting: saved passwords could not be sent"));
  }
}
