using TerminalDeck.App.ViewModels.Servers;

namespace TerminalDeck.Servers.Tests;

public sealed class ServersViewModelTests
{
  [Fact] public async Task BusyStateIsImmediateAndDuplicateRequestsDoNotStart()
  {
    using var f = new Fixture(); var model = new ServersViewModel(f.Service); var gate = new TaskCompletionSource();
    var first = model.RunAsync(async () => await gate.Task, "Reading apps…"); Assert.True(model.IsBusy); Assert.Equal("Reading apps…", model.Message);
    var secondRan = false; Assert.False(await model.RunAsync(() => { secondRan = true; return Task.CompletedTask; })); Assert.False(secondRan);
    gate.SetResult(); Assert.True(await first); Assert.False(model.IsBusy);
  }
  [Fact] public async Task RefusalsAreVisibleAndChangingServersClearsOldContent()
  {
    using var f = new Fixture(); var row = await f.AddAsync(); var model = new ServersViewModel(f.Service); model.Select(row.Id);
    Assert.False(await model.LoadFilesAsync("/outside")); Assert.True(model.IsError); Assert.NotEmpty(model.Message);
    model.Select(null); Assert.Null(model.Files); Assert.Null(model.Apps); Assert.Empty(model.Preview); Assert.Null(model.Selected);
  }
  [Fact] public async Task FolderHistoryOnlyChangesAfterASuccessfulReadAndResetsPerServer()
  {
    using var f = new Fixture(); var row = await f.AddAsync(true); var model = new ServersViewModel(f.Service); model.Select(row.Id);
    f.Runtime.Reply = command =>
    {
      using var input = System.Text.Json.JsonDocument.Parse(command.Input!); var path = input.RootElement.GetProperty("path").GetString();
      return new(0, System.Text.Json.JsonSerializer.Serialize(new { path, entries = Array.Empty<object>(), more = false }));
    };
    Assert.True(await model.LoadFilesAsync("/srv/test")); Assert.False(model.CanGoBack);
    Assert.True(await model.LoadFilesAsync("/srv/test/nested")); Assert.True(model.CanGoBack);
    Assert.False(await model.LoadFilesAsync("/outside")); Assert.Equal("/srv/test/nested", model.Files!.Path);
    Assert.True(await model.BackAsync()); Assert.Equal("/srv/test", model.Folder); Assert.False(model.CanGoBack);
    Assert.True(await model.RefreshFilesAsync()); Assert.False(model.CanGoBack);
    model.Select(null); Assert.False(model.CanGoBack); Assert.Null(model.Files);
  }
}
