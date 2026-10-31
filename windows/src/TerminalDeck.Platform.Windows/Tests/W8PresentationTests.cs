using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Windows.Tests;

public sealed class W8PresentationTests
{
  [Fact] public void SidebarUsesTheSavedProjectAndAgentWithoutChangingTheSession()
  {
    var row = new SessionDraft("Review changes", "codex", @"C:\TD\sample", SessionPresentation.Chat) { State = "working" };
    var id = row.Id; var changed = new List<string?>();
    row.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
    row.SetAppearance("Sample", @"C:\TD\pictures\sample.png", "Reviewer");
    Assert.Equal("S", row.ProjectInitial); Assert.Equal(@"C:\TD\pictures\sample.png", row.PicturePath);
    Assert.Equal("Reviewer · working", row.Subtitle); Assert.Equal(id, row.Id); Assert.Equal("Review changes", row.Title);
    Assert.Contains(nameof(SessionDraft.Subtitle), changed); Assert.Contains(nameof(SessionDraft.PicturePath), changed);
  }

  [Fact] public void RefreshUpdatesTheStateAndCanRemoveAnOldProjectPicture()
  {
    var chat = new ChatRecord(1, new("chat-id", "claude", @"C:\TD\sample", "Chat", "account", "home", new()), "key", [], []);
    var model = new ShellViewModel(); model.Sync([], [chat]); var selected = model.Selected!;
    selected.SetAppearance("Old", @"C:\old.png", "Old agent");
    var changed = new List<string?>(); selected.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
    model.Sync([], [chat with { Busy = true }]); selected.SetAppearance("Independent", null, "Claude Code");
    Assert.Same(selected, model.Selected); Assert.Null(selected.PicturePath); Assert.Equal("Claude Code · working", selected.Subtitle);
    Assert.Contains(nameof(SessionDraft.State), changed);
  }

  [Fact] public void ProjectInitialKeepsAWholeUnicodeCharacterAndFallsBackToTheSessionTitle()
  {
    var row = new SessionDraft("Session", "shell", @"C:\TD", SessionPresentation.Terminal);
    row.SetAppearance("🚀 Launch", null, "PowerShell"); Assert.Equal("🚀", row.ProjectInitial);
    row.SetAppearance("", null, "PowerShell"); Assert.Equal("S", row.ProjectInitial);
    row.SetAppearance("   ", null, "PowerShell"); Assert.Equal("S", row.ProjectInitial);
    var unicode = new SessionDraft("🚀 Session", "shell", @"C:\TD", SessionPresentation.Terminal);
    unicode.SetAppearance("", null, "PowerShell"); Assert.Equal("🚀", unicode.ProjectInitial);
    var unnamed = new SessionDraft("", "shell", @"C:\TD", SessionPresentation.Terminal);
    unnamed.SetAppearance("", null, "PowerShell"); Assert.Equal("?", unnamed.ProjectInitial);
  }
}
