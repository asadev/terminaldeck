using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class CustomTerminalProvidersTests
{
  [Fact] public void LiteralArgumentsAndEnvironmentNeverBecomeAShellCommand()
  {
    using var fixture = new Fixture(); var registry = new CustomTerminalProviders(new Store());
    registry.Save(fixture.Spec with { Arguments = ["a b", "$(not-run)", "%PATH%"], Environment = new() { ["LITERAL"] = "$HOME; $(not-run)" } });
    var session = fixture.Session; var launch = registry.Plan(session, new Dictionary<string, string> { ["PATH"] = "original" });
    Assert.Equal(fixture.Executable, launch.Executable); Assert.Equal(new[] { "a b", "$(not-run)", "%PATH%" }, launch.Arguments);
    Assert.Equal("$HOME; $(not-run)", launch.Environment["LITERAL"]); Assert.Equal(session.Id, launch.Environment["DECK_SESSION_ID"]);
  }
  [Fact] public void DisabledUnknownAndRemovedDefinitionsCannotLaunch()
  {
    using var fixture = new Fixture(); var registry = new CustomTerminalProviders(new Store());
    Assert.Throws<ArgumentException>(() => registry.Plan(fixture.Session, new Dictionary<string, string>()));
    registry.Save(fixture.Spec with { Enabled = false }); Assert.Throws<ArgumentException>(() => registry.Require(fixture.Spec.Id));
    registry.Save(fixture.Spec); registry.Remove(fixture.Spec.Id); Assert.Throws<ArgumentException>(() => registry.Require(fixture.Spec.Id));
  }
  [Theory] [InlineData("claude")] [InlineData("custom-../escape")] [InlineData("custom-9bad")]
  public void BuiltinAndUnsafeKeysCannotBeRegistered(string id)
  {
    using var fixture = new Fixture(); Assert.Throws<ArgumentException>(() => CustomTerminalProviders.Validate(fixture.Spec with { Id = id }));
  }
  [Fact] public void DefinitionsAreRootScopedAndReturnedCollectionsAreCopies()
  {
    using var fixture = new Fixture(); var first = CustomTerminalProviders.At(AppDataRoot.Explicit(Path.Combine(fixture.Directory, "one"))); var second = CustomTerminalProviders.At(AppDataRoot.Explicit(Path.Combine(fixture.Directory, "two")));
    first.Save(fixture.Spec with { Arguments = ["original"] }); var read = first.List().Single(); read.Arguments[0] = "changed";
    Assert.Equal("original", first.Require(read.Id).Arguments[0]); Assert.Throws<ArgumentException>(() => second.Require(read.Id));
  }
  [Fact] public void InheritOffUsesOnlyConfiguredValuesAndReservedSessionIdentity()
  {
    using var fixture = new Fixture(); var registry = new CustomTerminalProviders(new Store()); registry.Save(fixture.Spec with { InheritEnvironment = false });
    var plan = registry.Plan(fixture.Session, new Dictionary<string, string> { ["UNRELATED"] = "not included" }); Assert.False(plan.Environment.ContainsKey("UNRELATED"));
    Assert.Throws<ArgumentException>(() => CustomTerminalProviders.Validate(fixture.Spec with { Environment = new() { ["DECK_SESSION_ID"] = "forged" } }));
  }
  [Fact] public void CustomTerminalsDoNotPretendToSupportBuiltinChatOrResumeFlags()
  {
    using var fixture = new Fixture(); var registry = new CustomTerminalProviders(new Store()); registry.Save(fixture.Spec); fixture.Session.Validate();
    Assert.Throws<ArgumentException>(() => registry.Plan(fixture.Session with { ConversationId = "saved" }, new Dictionary<string, string>()));
    Assert.Throws<ArgumentException>(() => new ChatDefinition(Guid.NewGuid().ToString(), fixture.Spec.Id, fixture.Directory, "Custom", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new()).Validate());
  }
  private sealed class Store : IStateStore<CustomTerminalProviderState>
  { private CustomTerminalProviderState? state; public CustomTerminalProviderState? Load() => state; public void Save(CustomTerminalProviderState value) => state = value; }
  private sealed class Fixture : IDisposable
  {
    public string Directory { get; } = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-custom-cli-" + Guid.NewGuid().ToString("N"));
    public string Executable => Path.Combine(Directory, "synthetic.exe");
    public CustomTerminalProvider Spec => new("custom-synthetic", "Synthetic CLI", Executable, [], []);
    public SessionDefinition Session { get; }
    public Fixture() { System.IO.Directory.CreateDirectory(Directory); File.WriteAllBytes(Executable, []); Session = new(Guid.NewGuid().ToString(), Spec.Id, Directory, Spec.Name); }
    public void Dispose() { if (System.IO.Directory.Exists(Directory)) System.IO.Directory.Delete(Directory, true); }
  }
}
