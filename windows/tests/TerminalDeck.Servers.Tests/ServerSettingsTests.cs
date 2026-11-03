using System.Text.Json;
using TerminalDeck.Core.Servers;
namespace TerminalDeck.Servers.Tests;

public sealed class ServerSettingsTests
{
  [Fact] public async Task ShownAppsPersistsAndHiddenContainersCannotBeControlledOrRead()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true);
    await f.Service.SaveSettingsAsync(server.Id, new() { SetShownApps = true, ShownApps = [] }, ServerCaller.Person);
    Assert.Empty(await f.Service.AppsAsync(server.Id, ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(server.Id, Runtime.AppId, "stop", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.LogsAsync(server.Id, Runtime.AppId, 10, ServerCaller.Person));
    Assert.DoesNotContain(f.Runtime.Commands, c => c.Script.StartsWith("docker stop", StringComparison.Ordinal));
    await f.Service.SaveSettingsAsync(server.Id, new() { SetShownApps = true, ShownApps = null }, ServerCaller.Person);
    Assert.Single(await f.Service.AppsAsync(server.Id, ServerCaller.Person));
  }
  [Fact] public async Task HootGrantCoversOnlyCurrentNamedControlsAndRevokesImmediately()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true);
    await f.Service.SaveSettingsAsync(server.Id, new() { SetHootGrant = true, HootGrantUntil = DateTimeOffset.UtcNow.AddMinutes(30) }, ServerCaller.Person);
    f.Approval.Allow = false; f.Approval.Actions.Clear(); var hoot = new ServerCaller("hoot") { IsHoot = true };
    await f.Service.ControlAsync(server.Id, Runtime.AppId, "restart", hoot); Assert.Empty(f.Approval.Actions);
    Assert.Contains(f.Runtime.Commands, c => c.Script.StartsWith("docker restart", StringComparison.Ordinal));
    Assert.False(ServerSettingsRules.TimedGrantAllows(f.Store.Get(server.Id), hoot, "open terminal", DateTimeOffset.UtcNow));
    Assert.False(ServerSettingsRules.TimedGrantAllows(f.Store.Get(server.Id), hoot, "remove server", DateTimeOffset.UtcNow));
    await f.Store.UpdateSettingsAsync(server.Id, s => s with { HootGrantUntil = null }, default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(server.Id, Runtime.AppId, "stop", hoot));
    Assert.NotEmpty(f.Approval.Actions);
  }
  [Fact] public async Task ExpiryAndLookOnlyRemainStrongerThanTheTemporaryGrant()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var hoot = new ServerCaller("hoot") { IsHoot = true };
    await f.Store.UpdateSettingsAsync(server.Id, s => s with { HootGrantUntil = DateTimeOffset.UtcNow.AddSeconds(-1) }, default); f.Approval.Allow = false;
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(server.Id, Runtime.AppId, "start", hoot));
    await f.Store.UpdateSettingsAsync(server.Id, s => s with { HootGrantUntil = DateTimeOffset.UtcNow.AddMinutes(30), Access = s.Access with { LookOnly = true } }, default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(server.Id, Runtime.AppId, "start", hoot));
  }
  [Fact] public async Task RevocationDuringTheFinalCallerCheckPreventsTheEffect()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true);
    await f.Store.UpdateSettingsAsync(server.Id, s => s with { HootGrantUntil = DateTimeOffset.UtcNow.AddMinutes(30) }, default);
    var hoot = new ServerCaller("hoot", EnsureCurrent: async _ => await f.Store.UpdateSettingsAsync(server.Id, s => s with { HootGrantUntil = null }, default)) { IsHoot = true };
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.ControlAsync(server.Id, Runtime.AppId, "stop", hoot));
    Assert.DoesNotContain(f.Runtime.Commands, c => c.Script.StartsWith("docker stop", StringComparison.Ordinal));
  }
  private sealed class Terminal : IServerTerminal
  {
    public ServerTerminalRequest? Request;
    public ValueTask<string> OpenAsync(ServerTerminalRequest request, CancellationToken ct) { Request = request; return ValueTask.FromResult("fixture-session"); }
  }
  [Fact] public async Task LandingFolderIsValidatedAndDeliveredToTheActualTerminalOwner()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var terminal = new Terminal(); var owner = new ServerService(f.Store, f.Runtime, f.Approval, terminal);
    await owner.SaveSettingsAsync(server.Id, new() { SetLandingFolder = true, LandingFolder = "/srv/test" }, ServerCaller.Person);
    await owner.OpenTerminalAtAsync(server.Id, "/srv/test/another", ServerCaller.Person);
    Assert.Equal("/srv/test/another", terminal.Request!.StartIn); Assert.Equal("/srv/test/another", terminal.Request.Server.LandingFolder);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await owner.OpenTerminalAtAsync(server.Id, "/srv/../private", ServerCaller.Person));
    Assert.Equal("/srv/test", f.Store.Get(server.Id).LandingFolder);
  }
  [Fact] public async Task HostingWritesRefuseLookOnlyBeforeAnyRemoteRequest()
  {
    using var f = new Fixture(); var server = await f.AddAsync();
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.HostingAsync(server.Id, "setup", ServerCaller.Person));
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.SaveAlertsAsync(server.Id, new(), ServerCaller.Person));
    Assert.Empty(f.Runtime.Commands);
  }
  [Fact] public async Task EvenAnUnexpectedRemoteSecretIsNeverReturnedBySettingsRead()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true);
    f.Runtime.Reply = c => c.Script.StartsWith("if command", StringComparison.Ordinal) ? new(0, Runtime.Container) : new(0, JsonSerializer.Serialize(new { hosting = new ServerHostingStatus(true,true,true,"Docker","fixture","1","1",null,[]), alerts = new ServerAlertSettings(true,[new("hook","webhook","Example") { Url="https://example.test", Secret="never-return-this" }]), history=Array.Empty<ServerAlertEntry>() }));
    var snapshot = await f.Service.SettingsAsync(server.Id, ServerCaller.Person);
    Assert.Equal(ServerSettingsRules.SecretMask, snapshot.Alerts.Channels![0].Secret); Assert.DoesNotContain("never-return-this", JsonSerializer.Serialize(snapshot));
  }
  [Fact] public async Task BrowserConsentIsSavedAndPublishedToTheLiveOwner()
  {
    using var f = new Fixture(); var server = await f.AddAsync(); SavedServer? updated = null; f.Service.SettingsChanged += row => updated = row;
    Assert.True(server.DrivesBrowser);
    await f.Service.SaveSettingsAsync(server.Id, new() { DrivesBrowser = false }, ServerCaller.Person);
    Assert.False(f.Store.Get(server.Id).DrivesBrowser); Assert.False(updated!.DrivesBrowser);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.SaveSettingsAsync(server.Id, new() { DrivesBrowser = true }, new("phone", Owner:true, PairedDevice:true)));
  }
}

public sealed class ServerSshAliasTests
{
  [Fact] public void AliasInventoryParsesLiteralAliasesAndNeverExecutesCommands()
  {
    var rows = TerminalDeck.Platform.Windows.Servers.WindowsSshAliases.Parse("Host prod docs\n HostName example.test\n User deploy\n Port 2222\n IdentityFile ~/.ssh/private-example\n ProxyCommand never-execute-this\nHost *\n HostName global.test\nMatch exec never-execute-that\n HostName unsafe.test\n");
    Assert.Equal(2, rows.Count); Assert.All(rows, row => { Assert.Equal("example.test", row.Host); Assert.Equal("deploy", row.User); Assert.Equal(2222, row.Port); Assert.Equal(["private-example"], row.KeyNames); });
  }
  [Fact] public async Task UnknownSettingsAndUntrustedGrantDoNotSave()
  {
    using var f = new Fixture(); var server = await f.AddAsync();
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.SaveSettingsAsync(server.Id, new() { SetShownApps = true, ShownApps = ["bad\nname"] }, ServerCaller.Person));
    Assert.Null(f.Store.Get(server.Id).ShownApps);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.SaveSettingsAsync(server.Id, new() { SetHootGrant = true, HootGrantUntil = DateTimeOffset.UtcNow.AddHours(2) }, ServerCaller.Person));
  }
}
