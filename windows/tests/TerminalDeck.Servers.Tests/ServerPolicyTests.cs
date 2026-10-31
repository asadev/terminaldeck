using System.Text;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Servers.Tests;

public sealed class ServerPolicyTests
{
  [Fact] public async Task SavePersistsOnlyMetadataAndDefaultsClosed()
  {
    using var f = new Fixture(); var row = await f.AddAsync();
    var loaded = new ServerStore(f.Root, f.Secrets).Get(row.Id);
    Assert.True(loaded.Access.LookOnly); Assert.Empty(loaded.Access.Folders); Assert.Empty(loaded.Access.AiApps);
    Assert.DoesNotContain("fixture-password", File.ReadAllText(Path.Combine(f.Path, "state", "servers-v2.json")), StringComparison.Ordinal);
    Assert.Equal("fixture-password", Encoding.UTF8.GetString(f.Secrets.Values[f.Store.PasswordName(row.Id)]));
    Assert.Empty(new ServerStore(AppDataRoot.Explicit(Path.Combine(f.Path, "other")), f.Secrets).List());
  }
  [Fact] public async Task FailedExplicitKeyImportRollsBackMetadataAndSecret()
  {
    using var f = new Fixture(); f.Runtime.ImportFails = true;
    await Assert.ThrowsAsync<IOException>(async () => await f.Service.AddAsync(new("Test", "example.test", 22, "tester", ServerAuthentication.Key), "/explicit/pick", "passphrase"u8.ToArray()));
    Assert.Empty(f.Store.List()); Assert.Empty(f.Secrets.Values); Assert.Single(f.Runtime.Removed);
  }
  [Fact] public async Task LookOnlyRefusesBeforeApprovalOrNetwork()
  {
    using var f = new Fixture(); var row = await f.AddAsync();
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, Runtime.AppId, "restart", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.OpenTerminalAsync(row.Id, ServerCaller.Person));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task DefaultAuthorizerDeniesChange()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var denied = new ServerService(f.Store, f.Runtime);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await denied.ControlAsync(row.Id, Runtime.AppId, "stop", ServerCaller.Person));
    Assert.All(f.Runtime.Commands, c => Assert.StartsWith("docker ps ", c.Script));
  }
  [Fact] public async Task ExternalAiNeedsItsOwnServerAccessAndPairedDevicesRefuse()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    Assert.Single(f.Service.List(new("connected-ai"))); Assert.Empty(f.Service.List(new("other-ai")));
    Assert.Single(f.Service.List(new("session", LocalSession: true)));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.TestAsync(row.Id, new("phone", Owner: true, PairedDevice: true)));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.SetAccessAsync(row.Id, ServerAccess.Default, new("connected-ai")));
    Assert.Empty(f.Runtime.Commands); Assert.Empty(f.Approval.Actions);
  }
  [Fact] public async Task RevokedAccessDuringApprovalNeverRunsTheWrite()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    f.Approval.During = async () => await f.Store.SetAccessAsync(row.Id, row.Access with { LookOnly = true }, default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, Runtime.AppId, "restart", new("connected-ai")));
    Assert.DoesNotContain(f.Runtime.Commands, c => c.Script.StartsWith("docker restart", StringComparison.Ordinal));
  }
  [Fact] public async Task FolderRevokedDuringReadDoesNotReleaseTheResult()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    f.Runtime.Reply = _ =>
    {
      f.Store.SetAccessAsync(row.Id, row.Access with { Folders = [] }, default).AsTask().GetAwaiter().GetResult();
      return new(0, "{\"path\":\"/srv/test/readme\",\"base64\":\"c2FtcGxl\",\"truncated\":false}");
    };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ReadAsync(row.Id, "/srv/test/readme", ServerCaller.Person));
  }
  [Fact] public async Task ValidContainerRechecksChangedAccessAndReplacementAfterApproval()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    f.Approval.During = async () => await f.Store.SetAccessAsync(row.Id, row.Access with { LookOnly = true }, default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, Runtime.AppId, "restart", ServerCaller.Person));
    Assert.Single(f.Approval.Actions); Assert.Single(f.Runtime.Commands); Assert.StartsWith("docker ps ", f.Runtime.Commands[0].Script);
    await f.Store.SetAccessAsync(row.Id, row.Access, default); f.Approval.Actions.Clear(); f.Runtime.Commands.Clear();
    f.Approval.During = () => { f.Runtime.Reply = _ => new(0, ""); return ValueTask.CompletedTask; };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, Runtime.AppId, "stop", ServerCaller.Person));
    Assert.Single(f.Approval.Actions); Assert.Equal(2, f.Runtime.Commands.Count); Assert.All(f.Runtime.Commands, c => Assert.StartsWith("docker ps ", c.Script));
  }
  [Fact] public async Task ValidContainerStillCannotBypassTheDefaultDenyAuthorizer()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var service = new ServerService(f.Store, f.Runtime);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await service.ControlAsync(row.Id, Runtime.AppId, "start", ServerCaller.Person));
    Assert.Single(f.Runtime.Commands); Assert.StartsWith("docker ps ", f.Runtime.Commands[0].Script);
  }
  [Fact] public async Task ControlNamesExactContainerAndKeepsRoutingUntouched()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    await f.Service.ControlAsync(row.Id, Runtime.AppId, "restart", ServerCaller.Person);
    Assert.Single(f.Approval.Actions); Assert.Contains(Runtime.AppId, f.Approval.Actions[0].Target, StringComparison.Ordinal);
    Assert.Equal("docker restart -- '" + Runtime.AppId + "'", f.Runtime.Commands.Last().Script);
    Assert.DoesNotContain(f.Runtime.Commands, c => c.Script.Contains("caddy", StringComparison.OrdinalIgnoreCase) || c.Script.Contains("volume", StringComparison.OrdinalIgnoreCase));
  }
  [Fact] public async Task ReplacedContainerAfterApprovalCannotBeControlled()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    f.Approval.During = () => { f.Runtime.Reply = _ => new(0, ""); return ValueTask.CompletedTask; };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, Runtime.AppId, "stop", ServerCaller.Person));
    Assert.DoesNotContain(f.Runtime.Commands, c => c.Script.StartsWith("docker stop", StringComparison.Ordinal));
  }
  [Theory]
  [InlineData("bad;reboot", "start")]
  [InlineData(Runtime.AppId, "start;reboot")]
  [InlineData("--all", "stop")]
  public async Task ArbitraryCommandsAndOptionTargetsAreRefused(string id, string action)
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(row.Id, id, action, ServerCaller.Person));
    Assert.Empty(f.Runtime.Commands); Assert.Empty(f.Approval.Actions);
  }
  [Fact] public async Task ForgetRequiresExactNameAndRemovesOnlyOwnedCredentials()
  {
    using var f = new Fixture(); var row = await f.AddAsync();
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.RemoveAsync(row.Id, "wrong", ServerCaller.Person));
    Assert.Empty(f.Approval.Actions); await f.Service.RemoveAsync(row.Id, row.Name, ServerCaller.Person);
    Assert.Empty(f.Store.List()); Assert.Empty(f.Secrets.Values); Assert.Equal(row.Id, Assert.Single(f.Runtime.Removed));
  }
  [Theory]
  [InlineData("-oProxyCommand=oops", "tester", 22)]
  [InlineData("example.test", "user;reboot", 22)]
  [InlineData("example.test", "tester", 0)]
  [InlineData("example.test\nHost *", "tester", 22)]
  public async Task InvalidConnectionFieldsNeverReachTheRuntime(string host, string user, int port)
  {
    using var f = new Fixture();
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.AddAsync(new("Test", host, port, user, ServerAuthentication.Password), null, "fixture"u8.ToArray()));
    Assert.Empty(f.Approval.Actions); Assert.Empty(f.Store.List());
  }
  [Theory]
  [InlineData("Authorization: Bearer sensitive-example")]
  [InlineData("{\"token\":\"sensitive-example\"}")]
  [InlineData("password='sensitive-example'")]
  [InlineData("https://user:sensitive-example@example.test/path")]
  [InlineData("token sensitive-example")]
  public void CommonStructuredLogsAndAuthorizationHeadersMaskCompleteValues(string text)
  { Assert.DoesNotContain("sensitive-example", ServerText.Mask(text), StringComparison.Ordinal); }
  [Fact] public async Task SensitiveLogsAreMaskedAndBounded()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true);
    f.Runtime.Reply = c => new(0, c.Script.StartsWith("docker ps", StringComparison.Ordinal) ? Runtime.Container : "token=fixture-value\npassword: sample\nready\n");
    var log = await f.Service.LogsAsync(row.Id, Runtime.AppId, 100, ServerCaller.Person);
    Assert.DoesNotContain("fixture-value", log, StringComparison.Ordinal); Assert.DoesNotContain("sample", log, StringComparison.Ordinal); Assert.Contains("ready", log, StringComparison.Ordinal);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.LogsAsync(row.Id, Runtime.AppId, 2001, ServerCaller.Person));
  }
}
