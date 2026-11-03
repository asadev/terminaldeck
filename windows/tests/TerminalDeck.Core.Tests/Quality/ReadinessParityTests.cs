using TerminalDeck.Core.Quality;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Quality;

public sealed class ReadinessParityTests
{
  [Fact] public void WeightedWarningsReceiveHalfCreditAndSecretGateCapsTheScore()
  {
    Assert.Equal(75, ReadinessScoring.Score([new("one", "One", "pass", "", Weight: 10), new("two", "Two", "warn", "", Weight: 10)]));
    Assert.Equal(39, ReadinessScoring.Score([new("one", "One", "pass", "", Weight: 100), new("secrets", "Secrets", "fail", "", Weight: 1, Gate: true)]));
    Assert.Equal(79, ReadinessScoring.Score([new("one", "One", "pass", "", Weight: 100), new("secrets", "Secrets", "warn", "", Weight: 1, Gate: true)]));
  }
  [Fact] public void ExistingFilePatchKeepsOriginalAndRefusesToEraseSubsequentEdits()
  {
    using var project = new Project(); var file = Path.Combine(project.Folder, ".gitignore"); File.WriteAllText(file, "custom/\n");
    var service = new ProjectReadiness(); var preview = service.PreviewChange(project.Folder, "patch-ignore"); Assert.Equal("custom/\n", preview.Before); Assert.Equal("custom/\n", File.ReadAllText(file));
    service.ApplyChange(project.Folder, preview.Token); Assert.Contains("custom/", File.ReadAllText(file)); service.RollbackChange(project.Folder, preview.Token); Assert.Equal("custom/\n", File.ReadAllText(file));
    preview = service.PreviewChange(project.Folder, "patch-ignore"); File.AppendAllText(file, "later/\n"); Assert.Throws<IOException>(() => service.ApplyChange(project.Folder, preview.Token)); Assert.Contains("later/", File.ReadAllText(file));
    preview = service.PreviewChange(project.Folder, "patch-ignore"); service.ApplyChange(project.Folder, preview.Token); File.AppendAllText(file, "even-later/\n"); Assert.Throws<IOException>(() => service.RollbackChange(project.Folder, preview.Token));
  }
  [Fact] public void ScriptFixUsesTheDeclaredRunnerAndNeverReplacesAUsefulCommand()
  {
    using var project = new Project(); var file = Path.Combine(project.Folder, "package.json"); File.WriteAllText(file, "{\"scripts\":{\"test\":\"echo no test specified\"},\"devDependencies\":{\"jest\":\"1\"}}");
    var service = new ProjectReadiness(); var report = service.Scan(project.Folder); Assert.Equal("script-test", report.Checks.Single(c => c.Id == "test").Fix);
    var preview = service.PreviewChange(project.Folder, "script-test"); service.ApplyChange(project.Folder, preview.Token); Assert.Contains("jest", File.ReadAllText(file)); Assert.DoesNotContain("no test specified", File.ReadAllText(file));
    Assert.Throws<InvalidOperationException>(() => service.PreviewChange(project.Folder, "script-test")); service.RollbackChange(project.Folder, preview.Token); Assert.Contains("no test specified", File.ReadAllText(file));
  }
  [Fact] public async Task TrackedCredentialNamesFailGateWithoutReadingTheirContents()
  {
    using var project = new Project(); var runner = new Probe(); var report = await new ProjectReadiness().ScanAsync(project.Folder, "codex", runner);
    Assert.Equal("fail", report.Checks.Single(c => c.Id == "secrets").Status); Assert.True(report.Score <= 39);
    Assert.Contains(runner.Commands, c => c.Contains("ls-files")); Assert.Contains(runner.Commands, c => c == "codex --version");
  }
  [Fact] public async Task EngineAcceptanceAndBaselineUseActualSupportedCommands()
  {
    using var project = new Project(); var engineData = Path.Combine(project.Folder, ".staysfixed", "v2"); var journey = Path.Combine(engineData, "builds", "build-1", "journey"); Directory.CreateDirectory(journey);
    File.WriteAllText(Path.Combine(engineData, "last-check.json"), "{\"coverage\":{\"paths\":1},\"candidate\":{\"id\":\"build-1\"}}");
    File.WriteAllText(Path.Combine(journey, "001.jsonl"), "{\"kind\":\"capture\"}\n{\"path\":\"screen\",\"channel\":\"meaning\",\"value\":\"observed\"}\n{\"kind\":\"end\",\"count\":1}\n");
    var runner = new Engine(); var service = new StaysFixedService(runner);
    await service.RunAsync(project.Folder, new StaysFixedRequest("mark-good", Reason: "Reviewed the release", Force: true)); Assert.Equal(new[] { "ship", "--why", "Reviewed the release", "--json", "--force" }, runner.Command);
    await service.RunAsync(Path.GetTempPath(), new StaysFixedRequest("accept-diff", Finding: "f-123", Reason: "Expected label")); Assert.Equal(new[] { "waive", "f-123", "--because", "Expected label" }, runner.Command);
    await Assert.ThrowsAsync<ArgumentException>(() => service.RunAsync(Path.GetTempPath(), new StaysFixedRequest("intent", Summary: "Edit")));
  }
  [Fact] public async Task ForcedBaselineStillRefusesAnEmptyOrUnrecordedCheck()
  {
    using var project = new Project(); var service = new StaysFixedService(new Engine());
    await Assert.ThrowsAsync<InvalidOperationException>(() => service.RunAsync(project.Folder, new StaysFixedRequest("mark-good", Reason: "Reviewed", Force: true)));
    var directory = Path.Combine(project.Folder, ".staysfixed", "v2"); Directory.CreateDirectory(directory);
    File.WriteAllText(Path.Combine(directory, "last-check.json"), "{\"coverage\":{\"paths\":0},\"candidate\":{\"id\":\"build-1\"}}");
    await Assert.ThrowsAsync<InvalidOperationException>(() => service.RunAsync(project.Folder, new StaysFixedRequest("mark-good", Reason: "Reviewed", Force: true)));
    File.WriteAllText(Path.Combine(directory, "last-check.json"), "{\"coverage\":{\"paths\":1},\"candidate\":{\"id\":\"build-1\"}}");
    await Assert.ThrowsAsync<InvalidOperationException>(() => service.RunAsync(project.Folder, new StaysFixedRequest("mark-good", Reason: "Reviewed", Force: true)));
  }
  [Fact] public void RuleIsAnActualEngineGuardAndValuesCannotBecomeJavaScript()
  {
    using var project = new Project(); var service = new StaysFixedService(new Engine()); var path = service.AddRule(project.Folder, "checkout totals stay correct", "Keep the total correct", "dotnet", ["test", "a'; throw 1; '"]);
    var source = File.ReadAllText(path); Assert.EndsWith(".mjs", path); Assert.Contains("execFile", source); Assert.DoesNotContain("shell: true", source); Assert.Throws<IOException>(() => service.AddRule(project.Folder, "checkout totals stay correct", "Keep", "dotnet", []));
  }
  [Fact] public void AiSessionAccessPersistsPerProjectAndRequiresProjectSetup()
  {
    using var project = new Project(); var preferences = new Preferences(); var service = new StaysFixedService(new Engine(), preferences);
    Assert.False(service.AiSessionsEnabled(project.Folder)); service.SetAiSessionsEnabled(project.Folder, false);
    File.WriteAllText(Path.Combine(project.Folder, "staysfixed.config.json"), "{}"); Assert.False(new StaysFixedService(new Engine(), preferences).AiSessionsEnabled(project.Folder));
    service.SetAiSessionsEnabled(project.Folder, true); Assert.True(new StaysFixedService(new Engine(), preferences).AiSessionsEnabled(project.Folder));
  }
  private sealed class Preferences : TerminalDeck.Core.Storage.IStateStore<StaysFixedPreferences>
  { private StaysFixedPreferences? value; public StaysFixedPreferences? Load() => value; public void Save(StaysFixedPreferences state) => value = state; }
  private sealed class Engine : IQualityRunner
  {
    public IReadOnlyList<string>? Command;
    public Task<QualityCommandResult> RunAsync(string folder, IReadOnlyList<string> arguments, CancellationToken ct) { Command = arguments; return Task.FromResult(new QualityCommandResult(0, "{}", "")); }
  }
  private sealed class Probe : ICodeProcessRunner
  {
    public List<string> Commands = [];
    public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
    { Commands.Add(executable + " " + string.Join(' ', arguments)); return Task.FromResult(new CodeProcessResult(0, arguments.Contains("ls-files") ? ".env\0src/app.cs\0" : arguments.Contains("status") ? "" : "1.2.3", "")); }
  }
  private sealed class Project : IDisposable
  {
    public string Folder { get; } = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "readiness-" + Guid.NewGuid().ToString("N"));
    public Project() => Directory.CreateDirectory(Folder);
    public void Dispose() => Directory.Delete(Folder, true);
  }
}
