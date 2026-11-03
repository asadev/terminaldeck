using System.Text.Json;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Core.Tests.Quality;

public sealed class DockerAuthoringTests
{
  [Fact] public void TemplateProducesRealComposeConfigurationAndEnvironmentNames()
  {
    var draft = ServerService.FromTemplate("postgres", "my-db", "/srv/my-db", 5433); using var json = JsonDocument.Parse(draft.Compose);
    Assert.Equal("postgres:17-alpine", json.RootElement.GetProperty("services").GetProperty("my-db").GetProperty("image").GetString());
    Assert.Contains("POSTGRES_PASSWORD=", draft.Environment); Assert.DoesNotContain("password123", draft.Environment);
  }
  [Theory] [InlineData("BAD NAME", "/srv/app", 80)] [InlineData("app", "relative", 80)] [InlineData("app", "/srv/app", 0)]
  public void TemplateRefusesInvalidTargetsBeforeAnyServerWork(string name, string path, int port) => Assert.Throws<ServerRefusal>(() => ServerService.FromTemplate("nginx", name, path, port));
}
