using System.Security.Cryptography;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Storage;
using TerminalDeck.Hoot.Tests;
using TerminalDeck.Platform.Windows.Hoot;

namespace TerminalDeck.Hoot.Windows.Tests;

public sealed class HootPipeTests
{
  [Fact] public async Task PhoneSourceAndActualMediaSurviveAuthenticatedKeeperPipe()
  {
    await using var f = new Fixture(Scratch()); await f.Ready(); var root = AppDataRoot.Explicit(f.Folder);
    var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var server = new HootPipeServer(root, f.Hoot, credential).RunAsync(stop.Token);
    try
    {
      await using var client = await WindowsHootClient.ConnectAsync(root, credential);
      var source = new HootSource("person") { DeviceId = "synthetic-phone", Restricted = true };
      var id = Guid.NewGuid().ToString(); var file = ChatAttachmentData.Read("proof.pdf", "%PDF-1.7\nsynthetic"u8.ToArray());
      await client.SayWithAttachmentsAsync(id, "", [file], source);
      Assert.Equal(source, f.Hoot.Read().Active!.Source);
      var sent = Assert.Single(f.Process.Sent); var media = Assert.Single(sent.Message.Media);
      Assert.Equal(file.Data, f.Chats.ReadImage(sent.Chat.Definition.Id, media));
      f.Complete(id); await Fixture.Wait(client, state => !state.Busy);
      var next = Guid.NewGuid().ToString(); await client.SayAsync(next, "Keep the caller", source);
      Assert.Equal(source, f.Hoot.Read().Active!.Source);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); }
  }

  private static string Scratch() => Path.Combine(Environment.GetEnvironmentVariable("TD_HOOT_TEST_ROOT") ?? throw new InvalidOperationException("Name a scratch root under C:\\TD."), Guid.NewGuid().ToString("N"));
  [Fact] public async Task PipeKeepsBackgroundTurnAliveWhenViewDetachesAndAnotherViewAttaches()
  {
    await using var f = new Fixture(Scratch()); await f.Ready(); var root = AppDataRoot.Explicit(f.Folder);
    var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var server = new HootPipeServer(root, f.Hoot, credential).RunAsync(stop.Token);
    try
    {
      var id = Guid.NewGuid().ToString();
      await using (var first = await WindowsHootClient.ConnectAsync(root, credential))
      {
        await first.BackgroundTurnAsync(id, "task", "task-1", "Windows pipe proof", "Check the isolated task turn.");
        Assert.True(first.Read().Busy);
      }
      Assert.True(f.Hoot.Read().Busy); Assert.Single(f.Process.Sent);
      await using var second = await WindowsHootClient.ConnectAsync(root, credential); Assert.Equal(id, second.Read().Active?.Id);
      f.Complete(id, "The task stayed alive."); await Fixture.Wait(second, s => s.Turns.Single().State == HootTurnState.Finished);
      Assert.Equal("The task stayed alive.", second.Read().Turns.Single().Answer); Assert.Single(f.Process.Sent);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); }
  }
  [Fact] public async Task WrongCredentialCannotReadOrChangeHoot()
  {
    await using var f = new Fixture(Scratch()); await f.Ready(); var root = AppDataRoot.Explicit(f.Folder);
    var credential = RandomNumberGenerator.GetBytes(32); var wrong = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var server = new HootPipeServer(root, f.Hoot, credential).RunAsync(stop.Token);
    try
    {
      await Assert.ThrowsAnyAsync<IOException>(async () => { await using var client = await WindowsHootClient.ConnectAsync(root, wrong); });
      Assert.Empty(f.Process.Sent); Assert.Empty(f.Hoot.Read().Lines);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); CryptographicOperations.ZeroMemory(wrong); }
  }
  [Fact] public async Task PipeMemoryAndBoardStayUnderTheirOwnDataRoot()
  {
    await using var f = new Fixture(Scratch()); await f.Ready(); var root = AppDataRoot.Explicit(f.Folder);
    var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource(); var server = new HootPipeServer(root, f.Hoot, credential).RunAsync(stop.Token);
    try
    {
      await using var client = await WindowsHootClient.ConnectAsync(root, credential);
      await client.SaveMemoryAsync("Windows desk card", "Use the chosen coding AI."); await client.SaveBoardAsync(new("row-1", "Review", "waiting", "Waiting for review", null, default));
      var disk = HootStorage.At(root).Load()!; Assert.Equal("Windows desk card", disk.Memory.Card); Assert.Single(disk.Memory.Board);
      Assert.NotEqual(HootPipeServer.Name(root), HootPipeServer.Name(AppDataRoot.Explicit(f.Folder + "-other")));
      Assert.Empty(f.Process.Sent);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); }
  }
  [Fact] public async Task ModelCatalogueAndExplicitNewChatUseTheAuthenticatedPipe()
  {
    await using var f = new Fixture(Scratch()); await f.Ready(); var root = AppDataRoot.Explicit(f.Folder);
    var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
    var server = new HootPipeServer(root, f.Hoot, credential).RunAsync(stop.Token);
    try
    {
      await using var client = await WindowsHootClient.ConnectAsync(root, credential);
      Assert.Equal("fixture", Assert.Single(await client.ModelsAsync(f.AccountId)).Id);
      var id = Guid.NewGuid().ToString(); await client.SayAsync(id, "Keep the old conversation."); f.Complete(id, "It stays in history.");
      await Fixture.Wait(client, s => !s.Busy && s.Lines.Any(l => l.Kind == "assistant"));
      var before = client.Read(); await client.RefreshAsync();
      await Fixture.Wait(client, s => s.History.Length == 1 && s.ChatId is null);
      Assert.Empty(client.Read().Lines); Assert.Equal(before.ConversationId, client.Read().History[0].Id);
      Assert.Equal(before.Lines.ToArray(), client.Read().History[0].Lines.ToArray()); Assert.Single(f.Process.Sent);
      Assert.Equal(before.ConversationId, Assert.Single(HootStorage.At(root).Load()!.History).Id);
    }
    finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); }
  }
}
