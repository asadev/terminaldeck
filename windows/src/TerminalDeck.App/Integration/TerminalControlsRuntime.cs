using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public async Task ApplyTerminalControlAsync(string id, string control, string value, CancellationToken ct = default)
  {
    var gate = inputGates.GetOrAdd(id, _ => new(1)); await gate.WaitAsync(ct);
    try
    {
      var rows = await Keeper.ListAsync(ct);
      var row = rows.Sessions?.FirstOrDefault(s => s.Definition.Id == id) ?? throw new InvalidOperationException("That terminal is no longer open.");
      var activity = (await Keeper.ActivityAsync(ct)).Activity?.FirstOrDefault(s => s.Id == id);
      if (activity?.ProviderBusy == true || activity?.InputAgeMs is >= 0 and < 500)
        throw new InvalidOperationException("Wait for Claude to finish before changing its controls.");
      var command = TerminalControls.Command(row, control, value);
      await Keeper.WriteAsync(id, Encoding.UTF8.GetBytes(command), ct);
    }
    finally { gate.Release(); }
  }

  private void InitializeTerminalControlTools()
  {
    Door.Register("agents.controls", async (context, args, ct) =>
    {
      var id = args.GetProperty("sessionId").GetString()!; context.Require("sessions", id);
      var row = (await Keeper.ListAsync(ct)).Sessions?.FirstOrDefault(s => s.Definition.Id == id) ?? throw new McpRefusal("That terminal is no longer open.");
      context.Require("folders", row.Definition.Cwd);
      if (row.Definition.AccountId is { } account) context.Require("accounts", account);
      return JsonSerializer.SerializeToElement(new { model = Usage.Context(id).Model, modelSource = "last-reply", effort = (string?)null,
        unavailableReason = TerminalControls.Unavailable(row), whenItChanges = "Choices are sent to Claude's terminal. Its own confirmation reports the applied value." });
    });
    Door.Register("agents.set_control", async (context, args, ct) =>
    {
      var id = args.GetProperty("sessionId").GetString()!; context.Require("sessions", id);
      var row = Sessions.FirstOrDefault(s => s.Definition.Id == id) ?? throw new McpRefusal("That terminal is no longer open.");
      context.Require("folders", row.Definition.Cwd);
      if (row.Definition.AccountId is { } account) context.Require("accounts", account);
      await context.EnsureCurrentAsync(ct);
      await ApplyTerminalControlAsync(id, args.GetProperty("control").GetString()!, args.GetProperty("value").GetString()!, ct);
      return JsonSerializer.SerializeToElement(new { sent = true, applied = false, message = "Control sent to Claude. Its terminal shows the confirmation." });
    });
  }
}
