using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Projects;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Invoked only after W13's GUID scratch-root and marker checks have passed.
  private async Task RunSessionIconsProofAsync(string output)
  {
    var passed = new List<string>(); var failed = new List<string>(); var frames = new List<object>();
    void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
    try
    {
      await Ready; AppWindow.Move(new(-20000, -20000));
      using var renderWindow = new W13RenderWindow(this);
      var folder = Path.Combine(Path.GetDirectoryName(dataRoot.DirectoryPath)!, "sample-project"); Directory.CreateDirectory(folder);
      var project = Runtime.Projects.Create("Picture review", folder);
      Runtime.Projects.SetPicture(project.Id, Path.Combine(AppContext.BaseDirectory, "Assets", "icons", "app.png"));
      var logo = Runtime.Projects.PicturePath(project.Id);
      SessionDraft Add(string title, string provider, string name, string? icon, bool independent = false, bool hoot = false, string state = "running", bool chat = false)
      {
        var row = Model.AddDraft(provider, folder, chat ? SessionPresentation.Chat : SessionPresentation.Terminal);
        row.Rename(title); row.State = state;
        row.SetAppearance(project.Name, independent ? null : logo, name, independent ? ProjectIdentity.IndependentId : project.Id, icon, hoot);
        return row;
      }
      var agent = Add("Build the next release", "claude", "Decker", "hammer@purple");
      var shell = Add("PowerShell", "shell", "PowerShell", null);
      var hoot = Add("Plan with Hoot", "codex", "Hoot", "hoot", hoot: true);
      var independent = Add("Independent agent", "codex", "Alex", "emoji:🦊@orange", independent: true);
      Add("Chat without an agent", "codex", "Codex", null, chat: true);
      var ended = Add("Archived agent chat", "codex", "Commander", "shield@teal", state: "ended", chat: true);
      sidebar.ArchiveChat(ended.Id, true);
      Add("Project without a logo", "codex", "Alex", "bolt@green").SetAppearance("No logo", null, "Alex", project.Id, "bolt@green");
      UpdateSidebarSessions();
      foreach (var width in new[] { 1920, 1280 })
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      foreach (var selected in new[] { agent, shell, hoot, independent })
      {
        SetTheme(theme); renderWindow.Resize(width, width == 1920 ? 1080 : 840);
        W10SelectSession(selected.Id); UpdateSidebarSessions();
        await sessionPanes[selected.Id].Ready.WaitAsync(TimeSpan.FromSeconds(40));
        ArchivedChatRows.Visibility = Visibility.Visible;
        Model.Notice = ""; await Task.Delay(300); Root.UpdateLayout();
        var name = "icons-" + width + "-" + selected.AgentName.ToLowerInvariant();
        frames.Add(await Verification.W10Proof.CaptureAsync(Root, output, name, theme.ToString().ToLowerInvariant(), "Synthetic scratch sessions only; no AI or terminal process started", _ => { }));
        var pictures = WorkspaceVisuals.Tree(SessionList).OfType<SessionPicture>().ToArray();
        Check(name + theme + " all running rows share SessionPicture", pictures.Length == 6);
        var face = pictures.FirstOrDefault(p => p.Session == agent);
        Check(name + theme + " quiet agent tile", face is not null && face.Children.FirstOrDefault() is Border tile && ReferenceEquals(tile.Background, ShellTheme.Resource(face, "DeckSessionAvatarBrush")) && Math.Abs(tile.CornerRadius.TopLeft - 28 * 0.28) < 0.001);
        Check(name + theme + " agent colour survives selection and theme", face is not null && face.Children.FirstOrDefault() is Border { Child: DeckIcon symbol } && ReferenceEquals(symbol.Foreground, ShellTheme.Resource(face, "DeckProjectPurpleBrush")));
        Check(name + theme + " project logo, badge scale, ring and offset", face?.Children.LastOrDefault() is Border { Padding.Left: 1.5, Child: Border { Width: 15, Child: Image }, RenderTransform: TranslateTransform offset } && Math.Abs(offset.X - 5.6) < 0.001 && Math.Abs(offset.Y - 5.6) < 0.001);
        Check(name + theme + " plain shell has glyph without a tile", pictures.FirstOrDefault(p => p.Session == shell)?.Children.FirstOrDefault() is DeckIcon);
        Check(name + theme + " independent has no badge", pictures.FirstOrDefault(p => p.Session == independent)?.Children.Count == 1);
        Check(name + theme + " Hoot has owl on quiet tile", pictures.FirstOrDefault(p => p.Session == hoot)?.Children.FirstOrDefault() is Border { Child: Image });
        Check(name + theme + " selected picture follows row surface", pictures.SingleOrDefault(p => p.Session == selected)?.OnAccent == true);
        Check(name + theme + " ended row uses same picture", WorkspaceVisuals.Tree(ArchivedChatRows).OfType<SessionPicture>().Any(p => p.Session == ended));
        Check(name + theme + " selected subtitle names who and provider", selected.DisplaySubtitle == (selected == shell ? "PowerShell" : selected.AgentName + " · " + (selected == agent ? "Claude Code" : "Codex")));
      }
      Check("No sessions, chat messages or Hoot turns started", Runtime.Sessions.Count == 0 && Runtime.Chats.List().Count == 0 && Runtime.Hoot.Read().Turns.Length == 0);
      var log = Path.Combine(dataRoot.DirectoryPath, "logs", "errors.log");
      Check("No recovered UI errors", !File.Exists(log) || new FileInfo(log).Length == 0);
    }
    catch (Exception error) when (error is not OutOfMemoryException) { failed.Add(error.ToString()); }
    finally
    {
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed, frames }, new JsonSerializerOptions { WriteIndented = true }));
      closingShell = true; Close();
    }
  }
}
