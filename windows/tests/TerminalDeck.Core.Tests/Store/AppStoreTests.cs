using System.Security.Cryptography;
using System.Text.Json;
using TerminalDeck.Core.Store;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Store;

public sealed class AppStoreTests
{
  [Fact] public async Task ApprovalRefusalNeverCallsInstallerAndApprovedChangesKeepRealReceipts()
  {
    var state = new State(); var installer = new Installer(); var approval = new Approval(); var service = new AppStoreService(state, installer, approval); service.SetCatalog([Entry()]);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.ChangeAsync("tool", "install")); Assert.Empty(installer.Actions);
    approval.Allow = true; var installed = await service.ChangeAsync("tool", "install"); Assert.Equal("actual-1.2", installed!.Version); Assert.Equal("receipt", installed.Receipt);
    Assert.Single(new AppStoreService(state, installer, approval).Browse(installed: true));
    await service.ChangeAsync("tool", "update"); await service.ChangeAsync("tool", "remove"); Assert.Equal(new[] { "install", "update", "remove:receipt" }, installer.Actions); Assert.Empty(service.Browse(installed: true));
  }
  [Fact] public void CatalogFingerprintIsCheckedBeforeAnyEntryIsUsed()
  {
    var bytes = JsonSerializer.SerializeToUtf8Bytes(new[] { Entry() }); var digest = SHA256.HashData(bytes);
    Assert.Single(AppStoreService.ParseCatalog(bytes, digest)); bytes[0] ^= 1; Assert.Throws<IOException>(() => AppStoreService.ParseCatalog(bytes, digest));
  }
  [Fact] public void DistinctDepartmentsAndFacetsFilterTheOwningCatalogue()
  {
    var service = new AppStoreService(new State(), new Installer(), new Approval()); service.SetCatalog([Entry(), Entry() with { Id = "extension", Department = "Browser tools", Delivery = "browser-extension", Category = "Privacy" }]);
    Assert.Single(service.Browse("Browser tools", category: "Privacy")); Assert.Single(service.Browse("Community", "Tool"));
    Assert.Throws<ArgumentException>(() => service.SetCatalog([Entry() with { Department = "Not a department" }]));
  }
  private static StoreEntry Entry() => new("tool", "Tool", "An app tool", "Community", "Developer", "1.0", "tool-archive", "trusted", Artifact: "https://example.com/tool.zip", Sha256: new string('a', 64), Bytes: 10, Executable: "tool.exe");
  private sealed class State : IStateStore<StoreLedger> { private StoreLedger? value; public StoreLedger? Load() => value; public void Save(StoreLedger state) => value = state; }
  private sealed class Approval : IStoreAuthorizer { public bool Allow; public ValueTask<bool> ApproveAsync(StoreEntry entry, string action, CancellationToken ct) => ValueTask.FromResult(Allow); }
  private sealed class Installer : IAppStoreInstaller
  {
    public List<string> Actions = [];
    public ValueTask<StoreInstallation> InstallAsync(StoreEntry entry, bool update, CancellationToken ct, StoreInstallOptions? options = null) { Actions.Add(update ? "update" : "install"); return ValueTask.FromResult(new StoreInstallation("receipt", "actual-1.2")); }
    public ValueTask RemoveAsync(StoreEntry entry, string receipt, CancellationToken ct) { Actions.Add("remove:" + receipt); return ValueTask.CompletedTask; }
  }
}
