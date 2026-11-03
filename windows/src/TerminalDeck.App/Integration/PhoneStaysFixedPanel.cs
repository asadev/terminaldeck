using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Quality;
using TerminalDeck.Core.Remote;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly Dictionary<string, string> phoneQualityResults = [];
  private JsonObject[] QualityPhoneTargetFields(string folder) =>
  [PanelField("provider", "Coding AI for a new session", General.Read().DefaultProvider, true, ["claude", "codex", "gemini"]),
   PanelField("existingSessionId", "Existing coding-AI session ID · empty starts a new session", "", choices: new[] { "" }.Concat(ProjectSessions().Where(r => r.Provider != "shell" && r.Status is not ("Exited" or "ended") && string.Equals(Path.GetFullPath(r.Folder), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)).Select(r => r.Id)).ToArray()),
   PanelField("accountId", "Account ID · empty uses the selected AI's preferred account"), PanelField("model", "Model ID · empty uses Automatic"), PanelField("effort", "Effort · empty uses Automatic"), PanelField("chat", "New session type", "Chat", true, ["Chat", "Terminal"]), PanelField("addRule", "Job", "Fix findings", true, ["Fix findings", "Add a regression rule"])];
  private static QualityAiTarget QualityPhoneTarget(Dictionary<string, string> fields) => new(fields.GetValueOrDefault("provider") ?? "claude", string.IsNullOrWhiteSpace(fields.GetValueOrDefault("accountId")) ? null : fields["accountId"], fields.GetValueOrDefault("model") ?? "", fields.GetValueOrDefault("effort") ?? "", string.IsNullOrWhiteSpace(fields.GetValueOrDefault("existingSessionId")) ? null : fields["existingSessionId"], fields.GetValueOrDefault("chat") != "Terminal", fields.GetValueOrDefault("addRule") == "Add a regression rule");
  private PhonePanelOwner PhoneStaysFixedPanel() => new("staysfixed", false, (device, request, ct) =>
  {
    var folder = PanelText(request, "path")!; var report = StaysFixed.FullReport(folder).GetRawText(); var rows = new JsonArray(new JsonObject { ["id"] = "report", ["title"] = "Latest report", ["body"] = report[..Math.Min(16000, report.Length)], ["bodyStyle"] = "code" });
    lock (phoneQualityResults) if (phoneQualityResults.TryGetValue(device.Id + ":" + folder, out var result)) rows.Insert(0, new JsonObject { ["id"] = "outcome", ["title"] = "Last action", ["body"] = result[..Math.Min(12000, result.Length)], ["bodyStyle"] = "code" });
    var actions = new JsonArray();
    if (device.Access == PhoneAccess.Full)
    {
      foreach (var (id, label) in new[] { ("doctor", "Doctor"), ("preview", "Preview setup"), ("setup", "Set up"), ("check", "Check"), ("coverage", "Coverage"), ("repair", "Repair setup") }) actions.Add(PanelAction(id, label));
      actions.Add(PanelAction("set-ai-access", "Let AI sessions use Stays Fixed", PanelField("enabled", "Enabled after project setup", StaysFixed.AiSessionsEnabled(folder) ? "true" : "false", true, ["true", "false"])));
      actions.Add(PanelAction("mark-good", "Mark reviewed build as good", PanelField("reason", "Why this is the good baseline", required: true)));
      actions.Add(PanelAction("accept-diff", "Accept an intended difference", PanelField("finding", "Finding ID", required: true), PanelField("reason", "Why this difference is intended", required: true)));
      actions.Add(PanelAction("explain", "Explain a finding", PanelField("finding", "Finding ID", required: true)));
      actions.Add(PanelAction("intent", "Record an intended change", PanelField("summary", "What you intend to change", required: true), PanelField("touches", "Touched files or areas · one per line", required: true)));
      actions.Add(PanelAction("rule", "Add a rule", PanelField("name", "A short sentence naming the rule", required: true), PanelField("reason", "Why it matters", required: true), PanelField("executable", "Executable", required: true), PanelField("arguments", "JSON argument array", "[]", true)));
      actions.Add(PanelAction("ai-fix", "Ask an AI to fix findings", QualityPhoneTargetFields(folder)));
    }
    return ValueTask.FromResult(Panel("Stays Fixed", rows, actions));
  }, async (device, request, ct) =>
  {
    await RequirePhoneCurrentAsync(device, ct); var folder = PanelText(request, "path")!; var action = PanelText(request, "action")!; var fields = PanelFields(request); object? result;
    if (action == "set-ai-access") { StaysFixed.SetAiSessionsEnabled(folder, fields.GetValueOrDefault("enabled") == "true"); result = new { enabled = StaysFixed.AiSessionsEnabled(folder) }; }
    else if (action == "rule") result = new { path = await StaysFixed.AddRuleAsync(folder, fields.GetValueOrDefault("name") ?? "", fields.GetValueOrDefault("reason") ?? "", fields.GetValueOrDefault("executable") ?? "", JsonSerializer.Deserialize<string[]>(fields.GetValueOrDefault("arguments") ?? "[]")!, ct) };
    else if (action == "ai-fix") result = new { sessionId = await RunQualityFixAsync(folder, "staysfixed", QualityPhoneTarget(fields), ct) };
    else result = await StaysFixed.RunAsync(folder, new StaysFixedRequest(action, fields.GetValueOrDefault("finding"), fields.GetValueOrDefault("reason"), fields.GetValueOrDefault("summary"), fields.GetValueOrDefault("touches")?.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries)), ct);
    lock (phoneQualityResults) phoneQualityResults[device.Id + ":" + folder] = JsonSerializer.Serialize(result);
  });
}
