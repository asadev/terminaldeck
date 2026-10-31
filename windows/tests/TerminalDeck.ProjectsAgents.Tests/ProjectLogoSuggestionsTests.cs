using TerminalDeck.Core.Projects;

namespace TerminalDeck.ProjectsAgents.Tests;

public sealed class ProjectLogoSuggestionsTests
{
  [Fact] public void SuggestionsStayBoundedAndDoNotFollowLinkedAssets()
  {
    using var f = new Fixture(); var assets = Path.Combine(f.Home, "assets"); Directory.CreateDirectory(assets);
    File.WriteAllBytes(Path.Combine(f.Home, "logo.png"), [1]); File.WriteAllBytes(Path.Combine(assets, "icon.ico"), [1]); File.WriteAllBytes(Path.Combine(f.Home, "notes.png"), [1]);
    var external = Path.Combine(f.Directory, "external-assets"); Directory.CreateDirectory(external); File.WriteAllBytes(Path.Combine(external, "external-logo.png"), [1]); Directory.CreateSymbolicLink(Path.Combine(f.Home, "public"), external);
    var paths = ProjectLogoSuggestions.Find(f.Home); Assert.Equal(2, paths.Count); Assert.DoesNotContain(paths, p => p.EndsWith("notes.png", StringComparison.Ordinal));
    for (var i = 0; i < 20; i++) File.WriteAllBytes(Path.Combine(assets, $"logo-{i}.png"), [1]); Assert.Equal(12, ProjectLogoSuggestions.Find(f.Home).Count);
  }
}
