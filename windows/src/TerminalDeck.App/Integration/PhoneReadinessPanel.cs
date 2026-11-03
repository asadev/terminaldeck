using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Quality;
using TerminalDeck.Core.Remote;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private sealed record PhoneFixReview(ReviewedProjectChange? File, ReadinessCommandPreview? Command, bool Applied = false);
  private readonly Dictionary<string, PhoneFixReview> phoneFixPreviews = [];
  private PhonePanelOwner PhoneReadinessPanel() => new("readiness", false, async (device, request, ct) =>
  {
    var folder = PanelText(request, "path")!; var report = await ProjectReadiness.ScanAsync(folder, runner: ReadinessRunner, ct: ct); var hidden = ReadinessDismissals.Hidden(folder); var rows = new JsonArray();
    foreach (var check in report.Checks.Where(c => !hidden.Contains(c.Id)))
      rows.Add(new JsonObject { ["id"] = check.Id, ["title"] = check.Title, ["detail"] = check.Detail, ["badge"] = check.Status,
        ["actions"] = device.Access != PhoneAccess.Full ? new JsonArray() : check.Fix is null ? new JsonArray(PanelAction("dismiss", "Dismiss")) : new JsonArray(PanelAction("preview", "Preview fix"), PanelAction("dismiss", "Dismiss")) });
    PhoneFixReview? review; lock (phoneFixPreviews) phoneFixPreviews.TryGetValue(device.Id + ":" + folder, out review);
    if (review is not null)
    {
      var token = review.File?.Token ?? review.Command!.Token; var body = review.File is { } file ? (file.Before is null ? "Create " : "Replace ") + file.File + "\n\nBefore:\n" + (file.Before ?? "File does not exist") + "\n\nAfter:\n" + file.After : review.Command!.Summary + "\n" + review.Command.Executable + " " + string.Join(' ', review.Command.Arguments);
      var actions = device.Access != PhoneAccess.Full ? new JsonArray() : review.Applied ? review.File is null ? new JsonArray() : new JsonArray(PanelAction("rollback", "Roll back reviewed file change")) : new JsonArray(PanelAction("apply", "Apply reviewed fix"));
      rows.Insert(0, new JsonObject { ["id"] = "preview:" + token, ["title"] = review.File?.File ?? review.Command!.Fix, ["body"] = body.Length > 18000 ? body[..18000] + "\n[Preview excerpt; open the complete file for full review.]" : body, ["bodyStyle"] = "code", ["actions"] = actions });
    }
    return Panel("Readiness · " + report.Score + "% · " + report.Band, rows, device.Access != PhoneAccess.Full ? new JsonArray() : new JsonArray(PanelAction("restore-dismissed", "Restore dismissed findings"), PanelAction("ai-fix", "Ask an AI to fix findings", QualityPhoneTargetFields(folder))));
  }, async (device, request, ct) =>
  {
    await RequirePhoneCurrentAsync(device, ct); var folder = PanelText(request, "path")!; var id = PanelText(request, "id"); var action = PanelText(request, "action")!; var key = device.Id + ":" + folder;
    if (action == "restore-dismissed") { foreach (var hidden in ReadinessDismissals.Hidden(folder)) ReadinessDismissals.Set(folder, hidden, false); return; }
    if (action == "ai-fix") { await RunQualityFixAsync(folder, "readiness", QualityPhoneTarget(PanelFields(request)), ct); return; }
    if (action == "dismiss") { ReadinessDismissals.Set(folder, id!, true); return; }
    if (action == "preview")
    {
      var report = await ProjectReadiness.ScanAsync(folder, runner: ReadinessRunner, ct: ct);
      var fix = report.Checks.Single(c => c.Id == id).Fix ?? throw new PhoneRefusal("unavailable", "This finding has no automatic fix.");
      var preview = fix is "git-init" or "create-lockfile" or "untrack-secrets" ? new PhoneFixReview(null, await ProjectReadiness.PreviewCommandAsync(folder, fix, ReadinessRunner, ct)) : new(ProjectReadiness.PreviewChange(folder, fix), null);
      lock (phoneFixPreviews) phoneFixPreviews[key] = preview; return;
    }
    PhoneFixReview review; lock (phoneFixPreviews) review = phoneFixPreviews[key];
    if (id != "preview:" + (review.File?.Token ?? review.Command!.Token)) throw new PhoneRefusal("unauthorized", "Review this fix again.");
    await RequirePhoneCurrentAsync(device, ct);
    if (action == "rollback") ProjectReadiness.RollbackChange(folder, review.File!.Token);
    else if (review.File is { } file) ProjectReadiness.ApplyChange(folder, file.Token);
    else { var result = await ProjectReadiness.ApplyCommandAsync(folder, review.Command!.Token, ReadinessRunner, ct); if (!result.Ok) throw new IOException("The reviewed command failed. Inspect Readiness and Changes before retrying."); }
    lock (phoneFixPreviews) { if (action == "rollback") phoneFixPreviews.Remove(key); else phoneFixPreviews[key] = review with { Applied = true }; }
  });
}
