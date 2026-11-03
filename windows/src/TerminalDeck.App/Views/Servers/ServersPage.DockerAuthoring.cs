using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage
{
  private async Task EditDockerAppAsync(SavedServer server, ServerService service, bool existing)
  {
    var body = Stack(12); var name = Field("App name", "my-app"); var directory = Field("Server folder", server.Access.Folders.FirstOrDefault()?.TrimEnd('/') + "/my-app" ?? "");
    var repository = Field("Repository · optional public HTTPS URL", ""); var branch = Field("Branch · optional", "");
    var compose = Field("Compose configuration", "", true); compose.MinHeight = 180; compose.MaxLength = 1024 * 1024; compose.FontFamily = DeckFonts.Mono;
    var environment = Field("Environment · KEY=value per line", "", true); environment.MaxLength = 256 * 1024; environment.FontFamily = DeckFonts.Mono;
    var templates = new ComboBox { Header = "Start from a template", ItemsSource = ServerService.AppCatalog, DisplayMemberPath = "Name", HorizontalAlignment = HorizontalAlignment.Stretch };
    var port = new NumberBox { Header = "Host port", Minimum = 1, Maximum = 65535, Value = 8080, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
    var notice = Words("Review the complete configuration before deployment. Repository builds and Compose commands run on the selected server.", muted: true);
    body.Children.Add(name); body.Children.Add(directory);
    if (!existing)
    {
      body.Children.Add(templates); body.Children.Add(port);
      body.Children.Add(Button("Use template", () =>
      {
        try { var draft = ServerService.FromTemplate((templates.SelectedItem as DockerAppTemplate)?.Id ?? "", name.Text, directory.Text, (int)port.Value); compose.Text = draft.Compose; environment.Text = draft.Environment; }
        catch (Exception ex) when (ex is ArgumentException or ServerRefusal) { notice.Text = ex.Message; }
        return Task.CompletedTask;
      }));
      body.Children.Add(repository); body.Children.Add(branch);
    }
    else body.Children.Add(Button("Load configuration", async () =>
    {
      try { var draft = await service.ReadAppConfigurationAsync(server.Id, name.Text, directory.Text, ServerCaller.Person); compose.Text = draft.Compose; notice.Text = "Configuration loaded. Leave environment empty to retain the existing .env file, or enter replacement values."; }
      catch (Exception ex) when (ex is IOException or ServerRefusal or ArgumentException) { notice.Text = ex.Message; }
    }));
    body.Children.Add(compose); body.Children.Add(environment); body.Children.Add(notice);
    var operations = new ComboBox { Header = "Action", ItemsSource = existing ? new[] { "update", "validate", "pull", "start", "stop", "restart", "remove" } : new[] { "create", "validate" }, SelectedIndex = 0 }; body.Children.Add(operations);
    var dialog = Dialog(XamlRoot, existing ? "App configuration" : "Create app", new ScrollViewer { Content = body, MaxHeight = 560 }, "Review…");
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    var proposed = new DockerAppDraft(name.Text, directory.Text, compose.Text, environment.Text, string.IsNullOrWhiteSpace(repository.Text) ? null : repository.Text, string.IsNullOrWhiteSpace(branch.Text) ? null : branch.Text);
    await Model.RunAsync(async () =>
    {
      var plan = service.PreviewApp(server.Id, proposed, ServerCaller.Person);
      var review = Stack(12); review.Children.Add(Words(plan.Name + " · " + plan.Directory));
      review.Children.Add(new TextBox { Text = plan.Compose, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 360, FontFamily = DeckFonts.Mono });
      review.Children.Add(Words("Environment names: " + string.Join(", ", plan.Environment.Split('\n').Where(l => l.Contains('=')).Select(l => l[..l.IndexOf('=')])), muted: true));
      if (await Dialog(XamlRoot, "Review " + operations.SelectedItem, review, "Continue").ShowAsync() != ContentDialogResult.Primary) return;
      var result = await service.DeployAppAsync(server.Id, proposed, (string)operations.SelectedItem, ServerCaller.Person);
      await Dialog(XamlRoot, "Deployment result", new ScrollViewer { Content = Words(result.Output), MaxHeight = 420 }, "Done").ShowAsync();
    }, "Waiting for review and server approval…", "App action finished.");
    await Model.LoadAppsAsync();
  }
}
