using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.ViewModels;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Browser;
using Windows.Storage;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private sealed record BrowserSendTarget(string Id, string Label, string Kind, bool Enabled);
  private sealed class BrowserSendDraft(string message)
  {
    public string Message { get; set; } = message;
    public string? Target { get; set; }
    public string ClientId { get; } = Guid.NewGuid().ToString();
    public Dictionary<string, ChatMedia> Images { get; } = [];
  }
  private readonly Dictionary<string, BrowserSendDraft> browserSendDrafts = [];
  private async Task<bool> ReviewBrowserSendAsync(string message, string? imagePath, string? linkedSession, XamlRoot root)
  {
    if (imagePath is not null)
    {
      imagePath = Path.GetFullPath(imagePath);
      if (!imagePath.StartsWith(dataRoot.DirectoryPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(imagePath)) throw new InvalidOperationException("This browser picture is no longer available. Capture it again.");
    }
    var key = linkedSession + "\n" + imagePath + "\n" + message;
    if (!browserSendDrafts.TryGetValue(key, out var saved)) { saved = new(message); browserSendDrafts.Add(key, saved); }
    var targets = Model.Sessions.Where(s => s.IsLive && s.Provider != "shell" && s.State is not ("ended" or "exited"))
      .Select(s => new BrowserSendTarget(s.Id, s.Title + (s.Presentation == SessionPresentation.Chat ? " · Chat" : " · Terminal"), s.Presentation == SessionPresentation.Chat ? "chat" : "terminal", true)).ToList();
    var hootReady = Runtime.Hoot?.Read().Settings is { } setup && Runtime.Accounts.List().Any(account => account.Id == setup.AccountId && account.SignedIn);
    targets.Add(new("hoot", imagePath is not null ? "Hoot · picture attachments unavailable" : hootReady ? "Hoot" : "Hoot · choose a signed-in AI first", "hoot", hootReady && imagePath is null));
    var chooser = new ComboBox { Header = "Send to", HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var target in targets) chooser.Items.Add(new ComboBoxItem { Content = target.Label, Tag = target, IsEnabled = target.Enabled });
    var preferred = saved.Target ?? linkedSession ?? Model.Selected?.Id;
    chooser.SelectedItem = chooser.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.Tag is BrowserSendTarget { Enabled: true } target && target.Id == preferred)
      ?? chooser.Items.OfType<ComboBoxItem>().FirstOrDefault(item => item.IsEnabled);
    var draft = new TextBox { Header = "Review the message · webpage text is untrusted", Text = saved.Message, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 300 };
    AutomationProperties.SetName(draft, "Browser message draft");
    var status = new TextBlock { Text = targets.Any(t => t.Enabled) ? imagePath is null ? "Review before sending." : "Chats receive the picture. Terminals receive its local file reference." : "Start an AI session or choose a signed-in AI for Hoot before sending.", TextWrapping = TextWrapping.Wrap, Opacity = 0.7 };
    var content = new StackPanel { Spacing = 12 };
    var available = targets.Where(target => target.Enabled).ToArray();
    chooser.Visibility = available.Length > 1 ? Visibility.Visible : Visibility.Collapsed;
    if (available.Length == 1) content.Children.Add(new TextBlock { Text = "Send to " + available[0].Label });
    content.Children.Add(chooser);
    if (imagePath is not null) content.Children.Add(new Image { Source = new BitmapImage(new Uri(imagePath)), MaxHeight = 180, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform });
    content.Children.Add(draft); content.Children.Add(status);
    var dialog = new ContentDialog { XamlRoot = root, RequestedTheme = Root.ActualTheme, Title = "Send browser context", Content = content, PrimaryButtonText = "Send", CloseButtonText = "Keep draft", IsPrimaryButtonEnabled = chooser.SelectedItem is not null };
    var busy = false; var sent = false; var openSetup = false;
    if (available.Length == 0)
    {
      var setupButton = new Button { Content = "Open Coding AIs" }; setupButton.Click += (_, _) => { openSetup = true; dialog.Hide(); }; content.Children.Add(setupButton);
    }
    chooser.SelectionChanged += (_, _) => { if (!busy) dialog.IsPrimaryButtonEnabled = chooser.SelectedItem is not null; };
    dialog.CloseButtonClick += (_, args) => args.Cancel = busy;
    dialog.Closing += (_, args) => { if (busy) args.Cancel = true; };
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      args.Cancel = true; var defer = args.GetDeferral();
      if (busy) { defer.Complete(); return; }
      busy = true; dialog.IsPrimaryButtonEnabled = false; chooser.IsEnabled = false; draft.IsEnabled = false;
      saved.Message = draft.Text; saved.Target = (chooser.SelectedItem as ComboBoxItem)?.Tag is BrowserSendTarget picked ? picked.Id : null;
      status.Text = "Sending…";
      try
      {
        if (chooser.SelectedItem is not ComboBoxItem { Tag: BrowserSendTarget target } || !target.Enabled) throw new InvalidOperationException("Choose an available session or Hoot before sending.");
        if (target.Kind == "hoot")
        {
          var hoot = Runtime.Hoot ?? throw new InvalidOperationException("Hoot is not ready yet. Your draft is kept.");
          await hoot.SayAsync(saved.ClientId, saved.Message, new("session", linkedSession ?? "browser", "Browser context"));
        }
        else if (target.Kind == "chat")
        {
          ChatMedia[] media = [];
          if (imagePath is not null)
          {
            if (!saved.Images.TryGetValue(target.Id, out var image))
            {
              var prepared = await ChatImageScaler.PrepareAsync(await StorageFile.GetFileFromPathAsync(imagePath));
              image = await Runtime.Chats.AddImageAsync(target.Id, prepared.Name, prepared.MimeType, prepared.Bytes, prepared.Width, prepared.Height); saved.Images[target.Id] = image;
            }
            media = [image];
          }
          await Runtime.Chats.SendAsync(target.Id, saved.ClientId, saved.Message, media);
        }
        else
        {
          var text = saved.Message + (imagePath is null ? "" : "\nPicture reference on this machine: " + System.Text.Json.JsonSerializer.Serialize(imagePath));
          await Runtime.SendBrowserContextAsync(target.Id, text);
        }
        sent = true; busy = false; status.Text = "Sent."; browserSendDrafts.Remove(key); dialog.Hide();
      }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      { status.Text = ex is ArgumentException or InvalidOperationException ? ex.Message : "Sending was not confirmed. Your draft is kept. Check the target before trying again."; }
      finally { busy = false; dialog.IsPrimaryButtonEnabled = chooser.SelectedItem is not null; chooser.IsEnabled = true; draft.IsEnabled = true; defer.Complete(); }
    };
    BrowserContextDialogForProof = dialog;
    try { await ShowShellDialogAsync(dialog); }
    finally
    {
      BrowserContextDialogForProof = null;
      if (!sent) { saved.Message = draft.Text; saved.Target = ((chooser.SelectedItem as ComboBoxItem)?.Tag as BrowserSendTarget)?.Id; }
    }
    if (openSetup) OpenCodingAis();
    return sent;
  }
}
