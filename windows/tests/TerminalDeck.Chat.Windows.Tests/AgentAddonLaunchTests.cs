using TerminalDeck.Platform.Windows;

namespace TerminalDeck.Chat.Windows.Tests;

public sealed class AgentAddonLaunchTests : IDisposable
{
  private readonly string home = Path.Combine(Path.GetTempPath(), "td-addon-fixture-" + Guid.NewGuid().ToString("N"));
  public AgentAddonLaunchTests() => Directory.CreateDirectory(home);
  public void Dispose() { if (Directory.Exists(home)) Directory.Delete(home, true); }

  [Fact]
  public void Claude_and_Gemini_exclude_extra_children_but_keep_the_apps_own_door()
  {
    Assert.Equal(new[] { "--strict-mcp-config", "--disable-slash-commands" }, AgentAddonLaunch.Restrict("claude", home));
    Assert.Equal(new[] { "--allowed-mcp-server-names", "deck-tools", "--extensions", "none" }, AgentAddonLaunch.Restrict("gemini", home));
  }

  [Fact]
  public void Codex_disables_each_other_configured_server_and_never_disables_deck_tools()
  {
    var path = Path.Combine(home, "config.toml");
    var original = "[mcp_servers.crm]\ncommand = 'crm.exe'\n[mcp_servers.deck-tools]\ncommand = 'deck.exe'\n[mcp_servers.\"local_search\"]\ncommand = 'search.exe'\n";
    File.WriteAllText(path, original);
    Assert.Equal(new[] { "-c", "mcp_servers.crm.enabled=false", "-c", "mcp_servers.local_search.enabled=false" }, AgentAddonLaunch.Restrict("codex", home));
    Assert.Equal(original, File.ReadAllText(path));
  }

  [Theory]
  [InlineData("[mcp_servers.\"server.with.dots\"]\ncommand = 'x'")]
  [InlineData("[plugins.\"plugin@market\"]\nenabled = true")]
  [InlineData("mcp_servers = { crm = { command = 'crm' } }")]
  public void Unsupported_configurations_refuse_instead_of_pretending_addons_are_off(string text)
  {
    File.WriteAllText(Path.Combine(home, "config.toml"), text);
    Assert.Throws<InvalidOperationException>(() => AgentAddonLaunch.Restrict("codex", home));
  }

  [Fact]
  public void A_plugin_cache_refuses_even_when_no_config_section_names_it()
  {
    Directory.CreateDirectory(Path.Combine(home, "plugins"));
    File.WriteAllText(Path.Combine(home, "plugins", "installed.json"), "{}");
    Assert.Throws<InvalidOperationException>(() => AgentAddonLaunch.Restrict("codex", home));
  }
  [Fact]
  public void Codex_project_layers_are_measured_and_an_unconfigured_effective_plugin_refuses()
  {
    var project = Path.Combine(home, "project"); var nested = Path.Combine(project, "child");
    Directory.CreateDirectory(Path.Combine(project, ".codex")); Directory.CreateDirectory(nested);
    File.WriteAllText(Path.Combine(project, ".codex", "config.toml"), "[mcp_servers.project_tools]\ncommand = 'local.exe'");
    var configured = AgentAddonLaunch.CodexConfigured(home, nested);
    Assert.Contains("project_tools", configured);
    using var valid = System.Text.Json.JsonDocument.Parse("""[{"name":"project_tools","enabled":true,"transport":{"type":"stdio"}},{"name":"deck-tools","enabled":true,"transport":{"type":"stdio"}}]""");
    Assert.Equal(new[] { "-c", "mcp_servers.project_tools.enabled=false" }, AgentAddonInventory.FromExport(valid.RootElement, configured));
    using var plugin = System.Text.Json.JsonDocument.Parse("""[{"name":"plugin_tools","enabled":true,"transport":{"type":"stdio"}}]""");
    Assert.Throws<InvalidOperationException>(() => AgentAddonInventory.FromExport(plugin.RootElement, configured));
    using var incomplete = System.Text.Json.JsonDocument.Parse("""[{"name":"project_tools","enabled":true}]""");
    Assert.Throws<IOException>(() => AgentAddonInventory.FromExport(incomplete.RootElement, configured));
  }

}
