using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Quality;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Quality;

public static class QualityAiTargetDialog
{
  private sealed record Destination(string Id, string Label) { public override string ToString() => Label; }
  public static async Task ShowAsync(AppRuntime runtime, string folder, string kind, XamlRoot root, Action<string> openSession, string provider = "codex")
  {
    var targets = new[] { new Destination("", "Start a new AI session") }.Concat(runtime.ProjectSessions().Where(r => r.Provider != "shell" && r.Status is not ("Exited" or "ended") && string.Equals(Path.GetFullPath(r.Folder), Path.GetFullPath(folder), StringComparison.OrdinalIgnoreCase)).Select(r => new Destination(r.Id, r.Title + " · " + r.Provider + " · " + r.Status))).ToArray();
    var destination = new ComboBox { Header = "Send to", ItemsSource = targets, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var providers = new ComboBox { Header = "Coding AI", ItemsSource = new[] { "claude", "codex", "gemini" }, SelectedItem = provider, HorizontalAlignment = HorizontalAlignment.Stretch };
    var account = new ComboBox { Header = "Account", DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    var model = new ComboBox { Header = "Model", DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    var effort = new ComboBox { Header = "Effort", HorizontalAlignment = HorizontalAlignment.Stretch };
    var mode = new ComboBox { Header = "Open as", ItemsSource = new[] { "Chat", "Terminal" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var job = new ComboBox { Header = "Job", ItemsSource = kind == "staysfixed" ? new[] { "Fix findings", "Add a regression rule" } : new[] { "Fix findings" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var form = Stack(12); foreach (var element in new FrameworkElement[] { destination, job, providers, account, model, effort, mode }) form.Children.Add(element);
    var notice = Words("Existing sessions keep their account and model. New sessions use your selected signed-in account and supported model choices.", muted: true); form.Children.Add(notice);
    var modelRead = 0;
    void FillEffort()
    {
      var ai = (string?)providers.SelectedItem ?? "codex"; var selected = model.SelectedItem as ProviderModel;
      var choices = TerminalDeck.Core.Accounts.ModelEfforts.For(ai, selected).ToArray(); effort.ItemsSource = choices; effort.SelectedIndex = choices.Length > 0 ? 0 : -1; effort.Visibility = choices.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
    }
    async Task FillModelsAsync()
    {
      var revision = ++modelRead;
      try
      {
        var ai = (string?)providers.SelectedItem ?? "codex"; var chosen = account.SelectedItem as AccountProfile;
        var rows = runtime.Accounts.InstantModels(ai, chosen?.Id).Models; model.ItemsSource = rows; model.SelectedItem = rows.FirstOrDefault(r => r.IsDefault) ?? rows.FirstOrDefault(); FillEffort();
        if (chosen is not null)
        {
          var live = await runtime.Accounts.ModelsAsync(chosen.Id); if (revision != modelRead || (account.SelectedItem as AccountProfile)?.Id != chosen.Id) return;
          model.ItemsSource = live.Models; model.SelectedItem = live.Models.FirstOrDefault(r => r.IsDefault) ?? live.Models.FirstOrDefault(); FillEffort();
        }
      }
      catch (Exception error) when (error is not OutOfMemoryException) { notice.Text = error.Message; }

    }
    void FillAccounts()
    {
      var ai = (string?)providers.SelectedItem ?? "codex"; var rows = runtime.Accounts.List(ai).Where(a => a.SignedIn).ToArray(); account.ItemsSource = rows; account.SelectedItem = rows.FirstOrDefault(a => a.Id == runtime.Accounts.Preferred(ai, folder)?.Id) ?? rows.FirstOrDefault();
    }
    providers.SelectionChanged += (_, _) => FillAccounts(); account.SelectionChanged += async (_, _) => await FillModelsAsync(); model.SelectionChanged += (_, _) => FillEffort();
    destination.SelectionChanged += (_, _) => { var existing = destination.SelectedItem is Destination { Id.Length: > 0 }; foreach (var element in new FrameworkElement[] { providers, account, model, effort, mode }) element.Visibility = existing ? Visibility.Collapsed : Visibility.Visible; };
    FillAccounts(); _ = FillModelsAsync();
    var dialog = Dialog(root, "Choose an AI for " + kind, new ScrollViewer { Content = form, MaxHeight = 520 }, "Send job");
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    var target = new QualityAiTarget((string?)providers.SelectedItem ?? "codex", (account.SelectedItem as AccountProfile)?.Id, (model.SelectedItem as ProviderModel)?.Id ?? "", effort.SelectedItem as string ?? "", (destination.SelectedItem as Destination)?.Id is { Length: > 0 } id ? id : null, mode.SelectedIndex == 0, job.SelectedIndex == 1);
    try { openSession(await runtime.RunQualityFixAsync(folder, kind, target)); }
    catch (Exception error) when (error is not OutOfMemoryException) { await Dialog(root, "Could not send this job", Words(error.Message), "Done").ShowAsync(); }
  }
}
