using TerminalDeck.Core.Quality;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Quality;

public sealed class QualityTests
{
  [Fact] public void PreviewDoesNotWriteAndApplyNeverOverwritesANewFile()
  {
    var folder = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "quality-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(folder);
    try
    {
      var service = new ProjectReadiness(); var preview = service.Preview(folder, "readme");
      var path = Path.Combine(folder, "README.md"); Assert.False(File.Exists(path));
      File.WriteAllText(path, "Someone wrote this while the preview was open.");
      Assert.Throws<IOException>(() => service.Apply(folder, preview.Token));
      Assert.Equal("Someone wrote this while the preview was open.", File.ReadAllText(path));
    }
    finally { Directory.Delete(folder, true); }
  }
  [Fact] public async Task StaysFixedUsesExplicitEngineCommandsAndDoesNotTreatFailedReportsAsPassing()
  {
    var runner = new Runner(); var service = new StaysFixedService(runner);
    var result = await service.RunAsync(Path.GetTempPath(), "preview", CancellationToken.None);
    Assert.Equal(new[] { "init", "--dry-run", "--json" }, runner.Arguments);
    Assert.False(result.Ok); Assert.NotNull(result.Report);
  }
  [Fact] public void DeploymentReportsPreserveScopeAndRealCountsAcrossReload()
  {
    var store = new Store(); var ledger = new Deployments(store);
    var run = ledger.Report("project", "session", null, "Release", "caller", [new("tests", "Tests", "dotnet", "failed", "One failed", 9, 1)]);
    Assert.Equal(1, new Deployments(store).Read("project", "session").Single().Steps.Single().Failed);
    Assert.Throws<ArgumentException>(() => ledger.Report("other", "session", run.Id, "Release", "caller", run.Steps));
    run.Steps[0] = run.Steps[0] with { Failed = 0 };
    Assert.Equal(1, ledger.Read().Single().Steps.Single().Failed);
  }
  private sealed class Runner : IQualityRunner
  {
    public IReadOnlyList<string>? Arguments;
    public Task<QualityCommandResult> RunAsync(string folder, IReadOnlyList<string> arguments, CancellationToken ct)
    { Arguments = arguments; return Task.FromResult(new QualityCommandResult(1, "{\"status\":\"regression\"}", "")); }
  }
  private sealed class Store : IStateStore<DeploymentLedger>
  {
    private DeploymentLedger? state;
    public DeploymentLedger? Load() => state;
    public void Save(DeploymentLedger value) => state = value;
  }
}
