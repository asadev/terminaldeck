using TerminalDeck.App.Views.Settings;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Cloud;

/// The start-up wiring: the composition the Windows app uses must construct nothing of Cloud's until Sign in.
public sealed class CloudWiringTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-wiring-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private sealed class Watched : ICloudSecretStore, ICloudBrowser, ICloudRandom
  {
    public readonly List<string> Calls = [];
    public bool Exists { get { Calls.Add("exists"); return false; } }
    public byte[]? Read() { Calls.Add("read"); return null; }
    public void Write(ReadOnlySpan<byte> plaintext) => Calls.Add("write");
    public void Remove() => Calls.Add("remove");
    public Task OpenAsync(Uri url, CancellationToken ct) { Calls.Add("browser"); return Task.CompletedTask; }
    public void Fill(Span<byte> buffer) => Calls.Add("random");
  }

  [Fact]
  public async Task StartUpConstructsNothingUntilSignIn()
  {
    var watched = new Watched(); var httpMade = 0;
    var http = new LazyCloudHttp(() => { httpMade++; throw new InvalidOperationException("No request may be made at start-up."); });
    using var account = CloudComposition.Create(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), watched, watched, http, watched);
    var door = new McpDoor(new NeverAsked());
    CloudTools.Register(account, door);
    await account.ResumeAsync();

    Assert.Equal(["exists"], watched.Calls);
    Assert.False(http.Created); Assert.Equal(0, httpMade);
    Assert.Equal(CloudPhase.Dormant, account.Snapshot.Phase);
    Assert.False(Directory.Exists(folder));
  }

  [Fact]
  public void DefaultCompositionMakesNoHttpClientAndNoFile()
  {
    var store = new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new NoProtector());
    using var account = CloudComposition.Create(CloudConfiguration.Today("PC", "1"), store, new Watched());
    Assert.Equal(CloudPhase.Dormant, account.Snapshot.Phase);
    Assert.False(Directory.Exists(folder));
  }

  [Fact]
  public void AgentToolsAreReadOnly()
  {
    Assert.All(CloudTools.Specs, s => Assert.Equal(McpTier.Read, s.Tier));
    var cloud = McpCatalogue.Load().Where(s => s.Id.StartsWith("cloud.", StringComparison.Ordinal)).ToArray();
    Assert.Equal(["cloud.status"], cloud.Select(s => s.Id));
    Assert.All(cloud, s => Assert.Equal(McpTier.Read, s.Tier));
    var door = new McpDoor(new NeverAsked());
    using var account = CloudComposition.Create(CloudConfiguration.Today("PC", "1"), new Watched(), new Watched());
    CloudTools.Register(account, door);
  }

  [Fact]
  public void CloudIsSecondAfterGeneral()
  {
    var list = SettingsNavigation.Categories;
    Assert.Equal(["general", "cloud", "appearance"], list.Take(3).Select(c => c.Id));
    Assert.Equal("Cloud", list[1].Title);
    // Same group as General: no divider between them.
    Assert.Equal(list[0].Group, list[1].Group);
    Assert.Contains(SettingsNavigation.Matching("account"), c => c.Id == "cloud");
    Assert.Equal("cloud", SettingsNavigation.Canonical("cloud"));
    Assert.Equal("Sign in with your Terminal Deck account to keep your work on all your devices.", CloudPageText.SignedOutLine);
  }

  private sealed class NoProtector : TerminalDeck.Core.Platform.IDataProtector
  {
    public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray();
    public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
  }
  private sealed class NeverAsked : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken cancellationToken) => throw new InvalidOperationException("Not asked here.");
  }
}
