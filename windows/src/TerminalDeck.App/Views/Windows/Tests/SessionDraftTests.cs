using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Sessions;
using Xunit;
namespace TerminalDeck.App.Shell;
public sealed class SessionDraftTests
{
  [Theory]
  [InlineData("shell", false, null, null, "")]
  [InlineData("SHELL", true, "old@example.test", "Old account", "")]
  [InlineData("codex", false, "old@example.test", "Work", "Not signed in")]
  [InlineData("codex", true, "work@example.test", "Work", "work@example.test")]
  [InlineData("claude", true, null, "Work", "Work")]
  public void AccountChipUsesSignInIdentityAndNeverLeaksOntoShells(string provider, bool signedIn, string? email, string? name, string expected) =>
    Assert.Equal(expected, WorkspaceText.AccountIdentity(provider, signedIn, email, name));

  [Fact] public void UnreadTracksChangedOutputRatherThanStatusOrRepeatedUsage()
  {
    var draft = new SessionDraft("Review", "codex", "/scratch", SessionPresentation.Terminal);
    var row = new SessionRecord(new(draft.Id, "codex", "/scratch", "Review"), "creation", SessionState.Running, Replay: "hello");
    draft.Update(row); Assert.False(draft.Unread);
    draft.Update(row with { State = SessionState.Held }); Assert.False(draft.Unread);
    draft.Update(row with { Replay = "hello world" }); Assert.True(draft.Unread);
    draft.MarkRead(); draft.Update(row with { Replay = "hello world" }); Assert.False(draft.Unread);
    draft.Rename("Release"); Assert.Equal("Release", draft.Title); Assert.StartsWith("Release", draft.Label);
  }
  [Fact] public void PicturesDistinguishSavedAgentPlainShellAndIndependent()
  {
    var row = new SessionDraft("Review", "shell", "/scratch", SessionPresentation.Terminal);
    row.SetAppearance("Demo", null, "PowerShell", "demo");
    Assert.False(row.HasAgent); Assert.True(row.HasProject); Assert.Equal("PowerShell", row.DisplaySubtitle);
    row.SetAppearance("Demo", "/tmp/logo.png", "Alex", "demo", "emoji:🦊@purple");
    Assert.True(row.HasAgent); Assert.Equal("Alex · PowerShell", row.DisplaySubtitle); Assert.Equal("emoji:🦊@purple", row.AgentIcon);
    row.SetAppearance("Independent", null, "Hoot", TerminalDeck.Core.Projects.ProjectIdentity.IndependentId, "hoot", true);
    Assert.True(row.IsHoot); Assert.True(row.HasAgent); Assert.False(row.HasProject);
    row.SetAppearance("Independent", null, "PowerShell", TerminalDeck.Core.Projects.ProjectIdentity.IndependentId);
    Assert.False(row.HasAgent); Assert.False(row.IsHoot); Assert.Null(row.PicturePath);
  }
  [Theory]
  [InlineData("claude", "Claude Code")]
  [InlineData("codex", "Codex")]
  [InlineData("shell", "PowerShell")]
  public void SubtitleNamesWhoAndProviderWithoutRepeatingProvider(string provider, string expected)
  {
    var row = new SessionDraft("Review", provider, "/scratch", SessionPresentation.Terminal);
    Assert.Equal(expected, row.DisplaySubtitle);
    row.SetAppearance("Demo", null, "Decker", "demo", "terminal@teal");
    Assert.Equal("Decker · " + expected, row.DisplaySubtitle);
    row.SetAppearance("Demo", null, expected, "demo"); Assert.Equal(expected, row.DisplaySubtitle);
  }
}
