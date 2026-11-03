using System.Text.Json.Nodes;
using TerminalDeck.Core.Hooks;

namespace TerminalDeck.Core.Tests.Hooks;
public sealed class ProviderHooksTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-hooks-unit-" + Guid.NewGuid().ToString("N"));
  [Theory] [InlineData("claude")] [InlineData("codex")] [InlineData("gemini")]
  public void InstallRepairAndRemovePreserveForeignHooksAndUserSettings(string provider)
  {
    Directory.CreateDirectory(root); var config = Path.Combine(root, provider + ".json");
    const string input = """{"custom":{"neverLose":"yes"},"hooks":{"Stop":[{"matcher":"something","hooks":[{"type":"command","command":"my-own-hook"}]}],"ForeignEvent":[{"hooks":[{"command":"other"}]}]}}""";
    File.WriteAllText(config, input);
    string Command(string p, string e) => "powershell.exe -File scratch-send.ps1 -Provider " + p + " -Event " + e + " -DeckHook " + ProviderHooks.Marker;
    var hooks = new ProviderHooks(new Dictionary<string, string> { [provider] = config }, Path.Combine(root, "backups"), Command);
    Assert.Equal("none", hooks.Status(provider).State);
    Assert.Equal("complete", hooks.Install(provider).State); var first = File.ReadAllText(config);
    Assert.Equal("complete", hooks.Install(provider).State); Assert.Equal(first, File.ReadAllText(config));
    Assert.Equal(input, File.ReadAllText(hooks.Status(provider).BackupPath!));
    var repaired = JsonNode.Parse(File.ReadAllText(config))!.AsObject(); Assert.Equal("yes", repaired["custom"]!["neverLose"]!.GetValue<string>());
    hooks.Remove(provider); var after = JsonNode.Parse(File.ReadAllText(config))!;
    Assert.True(JsonNode.DeepEquals(JsonNode.Parse(input), after));
    Assert.DoesNotContain(ProviderHooks.Marker, File.ReadAllText(config));
  }
  [Fact] public void InvalidOrOversizedSettingsStayByteExactAndCannotBeReportedInstalled()
  {
    Directory.CreateDirectory(root); var path = Path.Combine(root, "settings.json"); const string invalid = "{not json"; File.WriteAllText(path, invalid);
    var hooks = new ProviderHooks(new Dictionary<string, string> { ["claude"] = path }, Path.Combine(root, "backups"), (_, _) => ProviderHooks.Marker);
    Assert.Equal("error", hooks.Status("claude").State); Assert.ThrowsAny<Exception>(() => hooks.Install("claude")); Assert.Equal(invalid, File.ReadAllText(path));
    File.WriteAllBytes(path, new byte[8 * 1024 * 1024 + 1]); Assert.Throws<IOException>(() => hooks.Install("claude")); Assert.Equal(8 * 1024 * 1024 + 1, new FileInfo(path).Length);
    File.WriteAllText(path, "{\"hooks\":[]}"); Assert.Throws<IOException>(() => hooks.Install("claude")); Assert.Equal("{\"hooks\":[]}", File.ReadAllText(path));
  }
  [Fact] public void StaleCommandsAreRepairedAndAccountBackupsDoNotCollide()
  {
    Directory.CreateDirectory(root); var first = Path.Combine(root, "one.json"); var second = Path.Combine(root, "two.json");
    File.WriteAllText(first, "{\"account\":1}"); File.WriteAllText(second, "{\"account\":2}");
    ProviderHooks Owner(string path, string version) => new(new Dictionary<string, string> { ["codex"] = path }, Path.Combine(root, "backups"), (_, e) => version + " " + e + " " + ProviderHooks.Marker);
    Owner(first, "old").Install("codex"); var current = Owner(first, "new"); Assert.Equal("stale", current.Status("codex").State); current.Install("codex"); Assert.Equal("complete", current.Status("codex").State);
    var other = Owner(second, "new"); other.Install("codex"); Assert.NotEqual(current.Status("codex").BackupPath, other.Status("codex").BackupPath);
  }
  public void Dispose() { if (Directory.Exists(root)) Directory.Delete(root, true); }
}
