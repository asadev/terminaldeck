using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

public sealed partial class ChatViewModel
{
  public async ValueTask<ChatRecord> CreateSideQuestionAsync(CancellationToken ct)
  {
    var source = await chats.ReadAsync(Id, ct);
    _ = SideQuestion.ForCopy(source);
    var question = SideQuestion.Read().Question.Trim();
    var title = "Side question: " + string.Join(" ", question.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
    if (title.Length > 110) title = title[..(char.IsHighSurrogate(title[109]) ? 109 : 110)];
    return await chats.CreateAsync(source.Definition with { Id = Guid.NewGuid().ToString(), Title = title, ForkSession = false }, cancellationToken: ct);
  }
  public ValueTask SendSideQuestionAsync(string sideId, CancellationToken ct) => chats.SendAsync(sideId, Guid.NewGuid().ToString(), SideQuestion.ForCopy(Snapshot), cancellationToken: ct);
  public IAsyncEnumerable<ChatRecord> WatchSideQuestionAsync(string sideId, CancellationToken ct) => chats.WatchAsync(sideId, ct);
  public ValueTask StopSideQuestionAsync(string sideId, CancellationToken ct = default) => chats.StopAsync(sideId, ct);
}
