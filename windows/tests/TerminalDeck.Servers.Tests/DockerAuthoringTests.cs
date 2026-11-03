using TerminalDeck.Core.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class DockerAuthoringTests
{
  [Fact] public async Task DockerPreviewDoesNotExecuteAndDeployUsesExistingExactApprovalBoundary()
  {
    using var f = new Fixture(); var server = await f.AddAsync(true); var draft = ServerService.FromTemplate("nginx", "web-app", "/srv/test/web-app", 8080);
    var plan = f.Service.PreviewApp(server.Id, draft, ServerCaller.Person); Assert.Equal(draft.Compose, plan.Compose); Assert.Empty(f.Runtime.Commands);
    f.Approval.Allow = false; await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.DeployAppAsync(server.Id, draft, "create", ServerCaller.Person)); Assert.Empty(f.Runtime.Commands);
    f.Approval.Allow = true; await f.Service.DeployAppAsync(server.Id, draft, "create", ServerCaller.Person); Assert.Single(f.Runtime.Commands); Assert.Contains("python3 -c", f.Runtime.Commands.Single().Script);
    Assert.Equal("create Docker app", f.Approval.Actions.Last().Operation);
  }
  [Fact] public async Task LookOnlyOutOfScopeAndAccessChangedDuringApprovalCannotDeploy()
  {
    using var f = new Fixture(); var server = await f.AddAsync(); var draft = ServerService.FromTemplate("nginx", "web-app", "/srv/test/web-app", 8080);
    Assert.Throws<ServerRefusal>(() => f.Service.PreviewApp(server.Id, draft, ServerCaller.Person));
    await f.Store.SetAccessAsync(server.Id, new(false, ["/srv/test"], []), default);
    Assert.Throws<ServerRefusal>(() => f.Service.PreviewApp(server.Id, draft with { Directory = "/other/app" }, ServerCaller.Person));
    f.Approval.During = async () => await f.Store.SetAccessAsync(server.Id, new(true, ["/srv/test"], []), default);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.DeployAppAsync(server.Id, draft, "create", ServerCaller.Person)); Assert.Empty(f.Runtime.Commands);
  }
}
