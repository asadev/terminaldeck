using System.Diagnostics;
using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;

// td-team-import --data-root <TerminalDeck data folder> [--plan <team.json>] [--old-app <Roaming\terminaldeck>]
// Brings projects, seats, instructions and seat memory into a Terminal Deck data folder
// through the app's own services. Run it only while that Terminal Deck is closed.
string? Arg(string name) { var i = Array.IndexOf(args, name); return i >= 0 && i + 1 < args.Length ? args[i + 1] : null; }
var rootPath = Arg("--data-root"); var planPath = Arg("--plan"); var oldApp = Arg("--old-app");
if (rootPath is null || planPath is null && oldApp is null) { Console.Error.WriteLine("Usage: td-team-import --data-root <folder> [--plan <team.json>] [--old-app <old data folder>]"); return 2; }
var running = Process.GetProcesses().Where(p => p.ProcessName.StartsWith("TerminalDeck", StringComparison.OrdinalIgnoreCase)).Select(p => p.ProcessName).Distinct().ToArray();
if (running.Length > 0) { Console.Error.WriteLine("Close Terminal Deck first (running: " + string.Join(", ", running) + ")."); return 3; }
var root = AppDataRoot.Explicit(rootPath);
var state = Path.Combine(root.DirectoryPath, "state");
var backup = Path.Combine(state, "backup-team-import-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssZ"));
foreach (var name in new[] { "projects.json", "agents.json", "browser-core.json", "appearance.json" })
  if (File.Exists(Path.Combine(state, name))) { Directory.CreateDirectory(backup); File.Copy(Path.Combine(state, name), Path.Combine(backup, name)); }
if (planPath is not null)
{
  var plan = TeamImport.Read(File.ReadAllText(planPath));
  var projects = new ProjectService(new JsonStateStore<ProjectState>(root, "projects"), new LocalProjectFolders(root));
  var agents = new AgentService(new JsonStateStore<AgentState>(root, "agents"), projects, new AgentInstructions(root));
  foreach (var line in TeamImport.Apply(projects, agents, plan)) Console.WriteLine(line);
  Console.WriteLine($"team: {projects.List().Count} projects, {agents.List().Count} agents");
}
if (oldApp is not null)
{
  var history = Path.Combine(oldApp, "browser-history.json");
  if (File.Exists(history)) Console.WriteLine($"browser history: {OldAppImport.History(new JsonStateStore<BrowserState>(root, "browser-core"), File.ReadAllText(history))} visits added");
  var oldState = Path.Combine(oldApp, "state.json");
  if (File.Exists(oldState)) Console.WriteLine("theme: " + (OldAppImport.Theme(new JsonStateStore<OldAppImport.AppearanceFile>(root, "appearance"), File.ReadAllText(oldState)) ?? "kept"));
}
Console.WriteLine("done" + (Directory.Exists(backup) ? ", backup " + backup : ""));
return 0;
