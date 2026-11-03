using System.Text.Json;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneConnectedContractTests : IDisposable
{
  private readonly string directory = Path.Combine(Path.GetTempPath(), "td-panel-wire-test-" + Guid.NewGuid().ToString("N"));
  [Fact]
  public async Task AgentOpenAndProfileViewMatchActualPhoneStringDecodersAndFullGate()
  {
    var root = AppDataRoot.Explicit(Path.Combine(directory, "data"));
    var folder = Directory.CreateDirectory(Path.Combine(directory, "project")).FullName;
    var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
    var project = projects.Create("Example", folder);
    var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
    agents.Save(new("critic", "Critic", "codex", ProjectId: project.Id));
    var artifacts = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts"), _ => project.Id,
      (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    var host = new PhoneConnectedFeatures(projects, agents, artifacts, (_, id) => id == project.Id, (_, _) => false);
    var full = new ApprovedDevice("device", "Phone", "ios", PhoneAccess.Full);
    var directoryReply = Assert.Single(await host.HandleAsync("phone", full, "panel.read", JsonSerializer.SerializeToElement(new { t = "panel.read", panel = "agents" }), null, default));
    // iOS panelScopeString and Android PanelRow.open both require a JSON string.
    Assert.Equal("agent:critic", Assert.Single(directoryReply["rows"]!.AsArray())!["open"]!.GetValue<string>());
    var profile = Assert.Single(await host.HandleAsync("phone", full, "panel.read", JsonSerializer.SerializeToElement(new { t = "panel.read", panel = "agents", scope = "agent:critic" }), null, default));
    Assert.Equal("agent:critic", profile["view"]!.GetValue<string>());
    Assert.Equal("Critic", profile["title"]!.GetValue<string>());
    Assert.False(host.Permits(PhoneAccess.Work, "panel.read")); Assert.False(host.Permits(PhoneAccess.Look, "panel.read"));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("phone", full with { Access = PhoneAccess.Work }, "panel.read", JsonSerializer.SerializeToElement(new { panel = "agents" }), null, default));
  }
  public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
