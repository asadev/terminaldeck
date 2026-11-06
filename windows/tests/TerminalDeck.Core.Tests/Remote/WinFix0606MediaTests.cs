using System.Text.Json;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class WinFix0606MediaTests
{
  [Theory] [InlineData(false)] [InlineData(true)]
  public async Task PanelOffersOnlyPreviewsTheHostCanServe(bool mediaAvailable)
  {
    var directory = Path.Combine(OperatingSystem.IsMacOS() && Path.GetTempPath().StartsWith("/var/", StringComparison.Ordinal) ? "/private" + Path.GetTempPath() : Path.GetTempPath(), "winfix-media-" + Guid.NewGuid().ToString("N"));
    try
    {
      var root = AppDataRoot.Explicit(Path.Combine(directory, "data"));
      var folder = Directory.CreateDirectory(Path.Combine(directory, "project")).FullName;
      var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
      var project = projects.Create("Example", folder);
      var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
      var artifacts = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts"), _ => project.Id, (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
      foreach (var name in new[] { "text.html", "image.png", "document.pdf", "video.mp4" })
      {
        await File.WriteAllTextAsync(Path.Combine(folder, name), "<p>Output</p>");
        artifacts.Record(folder, name, "session", DateTimeOffset.UtcNow);
      }
      using var server = mediaAvailable ? new PhoneArtifactServer(artifacts, (_, _) => true) : null;
      var host = new PhoneConnectedFeatures(projects, agents, artifacts, (_, id) => id == project.Id, (_, _) => false, artifactServer: server);
      var device = new ApprovedDevice("device", "Phone", "ios", PhoneAccess.Full);
      var listed = Assert.Single(await host.HandleAsync("test", device, "panel.read", JsonSerializer.SerializeToElement(new { t = "panel.read", panel = "artifacts", path = folder }), null, default));
      Assert.Equal(mediaAvailable ? 4 : 1, listed["rows"]!.AsArray().Count);
      Assert.Contains(listed["rows"]!.AsArray(), row => row!["title"]!.GetValue<string>() == "text.html");
      if (!mediaAvailable)
      {
        var image = artifacts.List(folder).Single(a => a.RelPath == "image.png");
        await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("test", device, "panel.act", JsonSerializer.SerializeToElement(new { t = "panel.act", panel = "artifacts", path = folder, action = "preview", id = image.Id }), null, default));
        var text = artifacts.List(folder).Single(a => a.RelPath == "text.html");
        var preview = Assert.Single(await host.HandleAsync("test", device, "panel.act", JsonSerializer.SerializeToElement(new { t = "panel.act", panel = "artifacts", path = folder, action = "preview", id = text.Id }), null, default));
        Assert.Contains(preview["rows"]!.AsArray(), row => row!["body"]?.GetValue<string>() == "<p>Output</p>");
      }
    }
    finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
  }
}
