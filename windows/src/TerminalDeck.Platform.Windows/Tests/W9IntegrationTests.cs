using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Integration;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class W9IntegrationTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w9-" + Guid.NewGuid().ToString("N")));
  [Fact]
  public void ProtectedConnectionReadUsesTheLatestAddressAndGrantWithoutPlaintextOnDisk()
  {
    var id = Guid.NewGuid().ToString(); var first = new ChatToolConnection("http://127.0.0.1:32101/mcp", new string('x', 64));
    HootToolConnection.Save(root, id, first);
    Assert.Equal(first, HootToolConnection.Read(root, id));
    var next = new ChatToolConnection("http://127.0.0.1:32102/mcp", new string('y', 64));
    HootToolConnection.Save(root, id, next); Assert.Equal(next, HootToolConnection.Read(root, id));
    var disk = File.ReadAllBytes(Path.Combine(root.DirectoryPath, "mcp", "chat-tools", id + ".bin"));
    Assert.DoesNotContain(next.Token, System.Text.Encoding.UTF8.GetString(disk));
    Assert.DoesNotContain(next.Token, next.ToString());
  }
  [Fact]
  public async Task KeeperToolRequestAuthenticatesAndBindsTheBackingChat()
  {
    var credential = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32); string? received = null;
    await using var server = new HootToolConnectionServer(root, credential, (id, _) => { received = id; return ValueTask.CompletedTask; });
    server.Start(); var chat = Guid.NewGuid().ToString();
    await new HootToolConnection(root, credential).PrepareAsync(chat, CancellationToken.None);
    Assert.Equal(chat, received);
  }
  [Fact]
  public void ServerLaunchIdentityCannotTurnAnAiSessionIntoAnArbitraryCommand()
  {
    var id = Guid.NewGuid().ToString(); var server = Guid.NewGuid().ToString("N");
    new SessionDefinition(id, "shell", root.DirectoryPath, "SSH", ServerId: server).Validate();
    Assert.Throws<ArgumentException>(() => new SessionDefinition(id, "codex", root.DirectoryPath, "SSH", ServerId: server).Validate());
    Assert.Throws<ArgumentException>(() => new SessionDefinition(id, "shell", root.DirectoryPath, "SSH", ServerId: "../other").Validate());
  }
  [Fact]
  public void KeeperBuildCarriesBothHelperExecutablesAndRuntimeManifests()
  {
    var keeper = Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new IOException("Choose the scratch keeper build.");
    foreach (var helper in new[] { ("tools-bridge", "TerminalDeck.ToolBridge"), ("askpass", "TerminalDeck.Servers.Askpass") })
      foreach (var extension in new[] { ".exe", ".dll", ".deps.json", ".runtimeconfig.json" })
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(keeper)!, helper.Item1, helper.Item2 + extension)), helper.Item1 + extension);
  }
  public void Dispose() { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
}
