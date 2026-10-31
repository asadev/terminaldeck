using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.App.Views;

// Only the explicitly marked shell proof can substitute this in-memory service.
// The real scratch chat remains the sidebar/tab identity; this service has no
// keeper, account provider, data directory or delivery implementation.
internal static class UiConsistencyChatFixture
{
  internal static ChatPage Create(ChatRecord shellChat, AppDataRoot proofRoot, Func<nint> currentWindowHandle)
  {
    var output = Environment.GetEnvironmentVariable("TD_UI_CONSISTENCY_PROOF");
    if (output is null || !proofRoot.DirectoryPath.StartsWith(@"C:\TD-UiConsistencyProof\", StringComparison.OrdinalIgnoreCase) ||
      !Guid.TryParse(Path.GetFileName(Path.GetDirectoryName(proofRoot.DirectoryPath)), out _) ||
      !File.Exists(Path.Combine(proofRoot.DirectoryPath, ".ui-consistency-allow")) ||
      File.ReadAllText(Path.Combine(proofRoot.DirectoryPath, ".ui-consistency-allow")).Trim() != "UI CONSISTENCY SCRATCH ONLY" ||
      !Path.GetFullPath(output).StartsWith(proofRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("Populated chat visuals require the marked UI consistency scratch proof.");
    var service = DispatchProxy.Create<IChatSessions, UiConsistencyChatSessionProxy>();
    var fixture = (UiConsistencyChatSessionProxy)(object)service;
    fixture.Initialize(shellChat);
    var page = new ChatPage(service, shellChat.Definition.Id, currentWindowHandle: currentWindowHandle);
    page.Model.Draft = "Please check the narrow layout too.";
    return page;
  }
}

public class UiConsistencyChatSessionProxy : DispatchProxy
{
  private ChatRecord? record;
  private AccountProfile? account;
  private static readonly DateTimeOffset FixtureTime = new(2026, 10, 30, 1, 0, 0, TimeSpan.Zero);

  internal void Initialize(ChatRecord source)
  {
    if (record is not null) throw new InvalidOperationException("The visual chat fixture was already initialized.");
    var definition = source.Definition with { Options = new("gpt-6.1", "high") };
    account = new(definition.AccountId, definition.Provider, "Personal", null, AccountAuthentication.Subscription, true, definition.AccountHome);
    record = source with
    {
      Definition = definition,
      Events = [
        new(1, "user", "fixture-user", "Review the dashboard and check the layout.", "fixture-user", At: FixtureTime),
        new(2, "toolCall", "fixture-read", "Read Dashboard.cs", Data: JsonSerializer.SerializeToElement(new { path = "Dashboard.cs" }), At: FixtureTime.AddSeconds(1)),
        new(3, "toolResult", "fixture-read", "The summary cards, spacing and keyboard order are ready to inspect.", Data: JsonSerializer.SerializeToElement(new { status = "completed" }), At: FixtureTime.AddSeconds(2)),
        new(4, "message", "fixture-answer", "The summary cards look good. I checked the spacing and keyboard order. Next I will run the focused layout check.", At: FixtureTime.AddSeconds(3)),
        new(5, "approval", "fixture-approval", "Run the focused layout check", Data: JsonSerializer.SerializeToElement(new { command = "dotnet test --filter DashboardLayout", cwd = definition.Cwd }), At: FixtureTime.AddSeconds(4))
      ],
      Messages = [
        new("fixture-user", "Review the dashboard and check the layout.", [], ChatMessageState.Sent),
        new("fixture-queued", "Then compare the light and dark themes.", [])
      ],
      Busy = true,
      ActiveClientId = "fixture-user",
      WorkerSequence = 5,
      WaitingSince = FixtureTime.AddSeconds(4),
      Problem = null,
      Paused = false,
      Stopping = false,
      Ended = false
    };
  }

  protected override object? Invoke(MethodInfo? method, object?[]? args)
  {
    var name = method?.Name ?? throw new InvalidOperationException("Missing visual fixture call.");
    var snapshot = record ?? throw new InvalidOperationException("Initialize the visual fixture before using it.");
    if (name is not ("get_DataRoot" or "List") && (args is not { Length: > 0 } || args[0] as string != snapshot.Definition.Id))
      throw new InvalidOperationException("This visual fixture serves only its own scratch chat identity.");
    return name switch
    {
      "get_DataRoot" => null,
      "Get" => snapshot,
      "ReadAsync" => ValueTask.FromResult(snapshot),
      "List" => new ChatRecord[] { snapshot },
      "Accounts" => new AccountProfile[] { account! },
      "ModelsAsync" => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("gpt-6.1", "GPT-6.1", 200000, Efforts: ["low", "medium", "high", "xhigh"])]),
      "WatchAsync" => Watch(snapshot, (CancellationToken)args![1]!),
      _ => throw new InvalidOperationException("Visual proof only: " + name + " cannot deliver, change accounts or start a provider.")
    };
  }

  private static async IAsyncEnumerable<ChatRecord> Watch(ChatRecord snapshot, [EnumeratorCancellation] CancellationToken cancellationToken)
  {
    await Task.Yield();
    cancellationToken.ThrowIfCancellationRequested();
    yield return snapshot;
    await Task.Delay(Timeout.Infinite, cancellationToken);
  }
}
