using TerminalDeck.Core.Agents;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Integration;
public sealed partial class AppRuntime
{
  private async ValueTask DispatchRoutineAsync(HootRoutine routine, CancellationToken ct)
  {
    var runId = routine.ExecutionId ?? throw new InvalidOperationException("The routine has no persisted execution receipt.");
    var prompt = RoutinePrompt(routine.Text);
    if (string.IsNullOrWhiteSpace(prompt)) throw new InvalidOperationException("This routine has no instruction below its header.");
    if (routine.AgentId == "@hoot")
    {
      var settings = Hoot.Read().Settings ?? throw new InvalidOperationException("Configure Hoot first.");
      if (!TerminalDeck.Core.Projects.ProjectPaths.Equal(settings.Folder, routine.Folder)) throw new InvalidOperationException("This routine's folder no longer matches Hoot's folder.");
      var completed = new TaskCompletionSource<HootTurn>(TaskCreationOptions.RunContinuationsAsynchronously);
      void ChangedState(HootState state)
      {
        var turn = state.Turns.FirstOrDefault(t => t.Id == runId);
        if (turn?.ChatId is { } session && Routines.List().FirstOrDefault(r => r.Id == routine.Id)?.Runs.FirstOrDefault(r => r.Id == runId)?.SessionId != session) Routines.BindSession(routine.Id, runId, session);
        if (turn is { State: HootTurnState.Finished or HootTurnState.Failed or HootTurnState.Stopped or HootTurnState.Uncertain }) completed.TrySetResult(turn);
      }
      Hoot.Changed += ChangedState;
      try
      {
        await Hoot.BackgroundTurnAsync(runId, "background", routine.Id, routine.Name, prompt, cancellationToken: ct);
        ChangedState(Hoot.Read()); var outcome = await completed.Task.WaitAsync(ct);
        if (outcome.State != HootTurnState.Finished) throw new InvalidOperationException(outcome.Problem ?? "The routine did not finish successfully.");
      }
      catch (OperationCanceledException) when (ct.IsCancellationRequested)
      {
        // This cancels this exact background turn, never unrelated owner work.
        await Hoot.CancelBackgroundAsync(runId, CancellationToken.None); throw;
      }
      finally { Hoot.Changed -= ChangedState; }
      return;
    }
    var agent = Agents.Get(routine.AgentId);
    if (agent.Status != SavedAgentStatus.Active) throw new InvalidOperationException("The routine's saved agent is paused or archived.");
    var project = Projects.Get(agent.ProjectId);
    if (!project.Folders.Any(f => McpCallerScopes.Within(f, routine.Folder))) throw new InvalidOperationException("The routine's folder is outside its saved agent's project.");
    var run = await Agents.StartAsync(new(agent.Id, agent.ProjectId, routine.Folder, Mode: "chat", Job: prompt, Title: routine.Name, Permission: AiPermissionMode.Ask), ct,
      (plan, token) =>
      {
        token.ThrowIfCancellationRequested(); var current = Agents.Get(agent.Id);
        if (current.Status != SavedAgentStatus.Active || current.ProjectId != agent.ProjectId || !Projects.Get(current.ProjectId).Folders.Any(f => McpCallerScopes.Within(f, plan.Folder))) throw new InvalidOperationException("The routine's agent or project changed before it started.");
        return ValueTask.CompletedTask;
      });
    Routines.BindSession(routine.Id, runId, run.SessionId);
    try
    {
      await foreach (var chat in Chats.WatchAsync(run.SessionId, ct))
      {
        if (chat.Problem is not null || chat.Messages.Any(m => m.State is ChatMessageState.Failed or ChatMessageState.Uncertain)) throw new InvalidOperationException(chat.Problem ?? "The agent could not confirm delivery. It was not sent again.");
        if (chat.Ended) throw new InvalidOperationException("The routine's agent chat ended before completion.");
        if (!chat.Busy && chat.Events.Any(e => e.Kind == "complete")) return;
      }
      throw new IOException("The routine's chat disconnected before its result was confirmed.");
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { await Chats.StopAsync(run.SessionId, CancellationToken.None); throw; }
  }
  private static string RoutinePrompt(string text)
  {
    var lines = text.Split('\n'); var separators = lines.Select((line, index) => (line, index)).Where(p => p.line.Trim() == "---").Select(p => p.index).ToArray();
    if (separators.Length == 0) return text;
    var boundary = lines[0].Trim() == "---" && separators.Length > 1 ? separators[1] : separators[0];
    return string.Join('\n', lines.Skip(boundary + 1)).Trim();
  }
}
