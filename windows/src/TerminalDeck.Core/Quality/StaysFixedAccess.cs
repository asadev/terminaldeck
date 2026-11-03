using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Quality;

public sealed record StaysFixedPreferences(Dictionary<string, bool> Projects);
public sealed partial class StaysFixedService
{
  private readonly object preferenceGate = new();
  public bool AiSessionsEnabled(string folder)
  {
    folder = QualityFolder.Require(folder);
    var setup = new[] { "staysfixed.config.js", "staysfixed.config.mjs", "staysfixed.config.json" }.Any(f => File.Exists(Path.Combine(folder, f)));
    lock (preferenceGate)
    {
      var map = preferences?.Load()?.Projects;
      if (map is not null) foreach (var pair in map) if (string.Equals(pair.Key, folder, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) return setup && pair.Value;
      return setup;
    }
  }
  public void SetAiSessionsEnabled(string folder, bool enabled)
  {
    folder = QualityFolder.Require(folder);
    lock (preferenceGate)
    {
      if (preferences is null) throw new InvalidOperationException("The app's Stays Fixed settings owner is unavailable.");
      var map = new Dictionary<string, bool>(preferences.Load()?.Projects ?? [], OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal); map[folder] = enabled; preferences.Save(new(map));
    }
    Changed?.Invoke(folder);
  }
}
public sealed record QualityAiTarget(string Provider, string? AccountId = null, string Model = "", string Effort = "", string? ExistingSessionId = null, bool Chat = true, bool AddRule = false);
