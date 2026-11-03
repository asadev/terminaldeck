using System.Text.RegularExpressions;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Sessions;

public sealed record CustomTerminalProvider(string Id, string Name, string Executable, string[] Arguments, Dictionary<string, string> Environment, bool Enabled = true, bool InheritEnvironment = true);
public sealed record CustomTerminalProviderState(CustomTerminalProvider[] Providers);

// Custom CLIs use a real terminal. Structured chat remains owned by its three
// protocol adapters; a command is never relabelled as a supported chat adapter.
public sealed class CustomTerminalProviders(IStateStore<CustomTerminalProviderState> store)
{
  private readonly object gate = new();
  public event Action? Changed;
  public static bool IsKey(string id) => Regex.IsMatch(id, "^custom-[a-z][a-z0-9-]{0,31}$", RegexOptions.CultureInvariant);
  public static CustomTerminalProviders At(AppDataRoot root) => new(new JsonStateStore<CustomTerminalProviderState>(root, "custom-terminal-providers"));
  public IReadOnlyList<CustomTerminalProvider> List()
  {
    lock (gate) return (store.Load()?.Providers ?? []).Select(p => p with { Arguments = [.. p.Arguments], Environment = new(p.Environment, StringComparer.OrdinalIgnoreCase) }).OrderBy(p => p.Name).ToArray();
  }
  public static void Validate(CustomTerminalProvider value)
  {
    if (!IsKey(value.Id) || string.IsNullOrWhiteSpace(value.Name) || value.Name.Length > 80 || value.Name.Any(char.IsControl) || !Path.IsPathFullyQualified(value.Executable) || !value.Executable.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || value.Executable.Any(char.IsControl)) throw new ArgumentException("Choose a custom-key, name and full path to a Windows executable (.exe).");
    if (value.Arguments.Length > 128 || value.Arguments.Any(a => a.Length > 8192 || a.Any(c => c is '\0' or '\r' or '\n')) || value.Environment.Count > 128 || value.Environment.Any(p => !Regex.IsMatch(p.Key, "^[A-Za-z_][A-Za-z0-9_]{0,127}$") || p.Key.Equals("DECK_SESSION_ID", StringComparison.OrdinalIgnoreCase) || p.Value.Length > 8192 || p.Value.Any(c => c is '\0' or '\r' or '\n'))) throw new ArgumentException("Use at most 128 literal arguments and environment values. The app owns DECK_SESSION_ID.");
    if (value.Environment.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != value.Environment.Count) throw new ArgumentException("Environment names must be unique, ignoring case.");
  }
  public CustomTerminalProvider Require(string id) => List().FirstOrDefault(p => p.Id == id && p.Enabled) is { } value ? value : throw new ArgumentException("Choose an enabled custom CLI from Settings or New session.");
  public void Save(CustomTerminalProvider value)
  {
    Validate(value);
    lock (gate)
    {
      var rows = List().Where(p => p.Id != value.Id).ToArray(); if (rows.Length >= 128) throw new InvalidOperationException("Remove an unused custom CLI before adding another.");
      store.Save(new([.. rows, value with { Arguments = [.. value.Arguments], Environment = new(value.Environment, StringComparer.OrdinalIgnoreCase) }]));
    }
    Changed?.Invoke();
  }
  public void Remove(string id) { lock (gate) store.Save(new(List().Where(p => p.Id != id).ToArray())); Changed?.Invoke(); }
  public ProcessLaunch Plan(SessionDefinition definition, IReadOnlyDictionary<string, string> inherited)
  {
    var value = Require(definition.Provider); Validate(value);
    if (!File.Exists(value.Executable) || !Directory.Exists(definition.Cwd)) throw new ArgumentException("The custom CLI executable or working folder is no longer available.");
    if (definition.ConversationId is not null || definition.Purpose is not null || definition.Model is not null || definition.Effort is not null || definition.Permission is not null || definition.AccountId is not null || definition.InitialPrompt is not null) throw new ArgumentException("Custom CLIs use their configured command and terminal input. Built-in account/model/resume switches do not apply.");
    var environment = value.InheritEnvironment ? new Dictionary<string, string>(inherited, StringComparer.OrdinalIgnoreCase) : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    foreach (var pair in value.Environment) environment[pair.Key] = pair.Value;
    environment["DECK_SESSION_ID"] = definition.Id;
    // Arguments and values stay exact strings. No shell, interpolation, PATH
    // executable lookup, variable substitution or implicit prompt argument.
    return new(value.Executable, value.Arguments.ToArray(), environment, definition.Cwd);
  }
}
