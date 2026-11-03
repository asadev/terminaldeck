using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Notifications;

namespace TerminalDeck.App.Views.Notifications;
public sealed class NotificationPreferencesPage : UserControl
{
  public NotificationPreferencesPage(SessionNotifications owner)
  {
    var panel = new StackPanel { Spacing = 16, Padding = new Thickness(24), MaxWidth = 900 };
    var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
    panel.Children.Add(new TextBlock { Text = "Notifications", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    void Toggle(string label, Func<NotificationPreferences, bool> read, Func<NotificationPreferences, bool, NotificationPreferences> change)
    { var toggle = new ToggleSwitch { Header = label, IsOn = read(owner.Read()) }; toggle.Toggled += (_, _) => owner.Save(change(owner.Read(), toggle.IsOn)); panel.Children.Add(toggle); }
    Toggle("A session needs you", p => p.NeedsYou, (p, v) => p with { NeedsYou = v }); Toggle("A session finishes", p => p.Finished, (p, v) => p with { Finished = v });
    Toggle("Hoot replies", p => p.Hoot, (p, v) => p with { Hoot = v }); Toggle("Task mentions", p => p.TaskMentions, (p, v) => p with { TaskMentions = v });
    Toggle("Show a short preview", p => p.Preview, (p, v) => p with { Preview = v }); Toggle("Only while I am away from this app", p => p.OnlyWhenAway, (p, v) => p with { OnlyWhenAway = v });
    Toggle("Play notification sounds", p => p.PlaySound, (p, v) => p with { PlaySound = v });
    var currentSound = owner.Read().Sound switch { "default" => "chime", "im" => "blip", "reminder" => "knock", var value => value };
    var sound = new ComboBox { Header = "Finish sound", ItemsSource = new[] { "chime", "blip", "knock" }, SelectedItem = currentSound, MinWidth = 220 };
    sound.SelectionChanged += (_, _) => { if (sound.SelectedItem is string selected) owner.Save(owner.Read() with { Sound = selected }); }; panel.Children.Add(sound);
    async Task CheckAsync(Button button, bool soundOnly)
    {
      button.IsEnabled = false; notice.Text = soundOnly ? "Playing…" : "Checking Windows notification delivery…";
      try { notice.Text = (await owner.TestAsync(soundOnly)).Message; }
      catch (Exception e) when (e is InvalidOperationException or System.Runtime.InteropServices.COMException or IOException) { notice.Text = "Windows could not complete this check. Check notification permissions and audio output."; }
      finally { button.IsEnabled = true; }
    }
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var banner = new Button { Content = "Test banner" }; banner.Click += async (_, _) => await CheckAsync(banner, false);
    var testSound = new Button { Content = "Test sound" }; testSound.Click += async (_, _) => await CheckAsync(testSound, true);
    var settings = new Button { Content = "Open Windows notification settings" }; settings.Click += async (_, _) =>
    { try { if (!await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:notifications"))) notice.Text = "Windows could not open notification settings."; } catch (System.Runtime.InteropServices.COMException) { notice.Text = "Windows could not open notification settings."; } };
    actions.Children.Add(banner); actions.Children.Add(testSound); actions.Children.Add(settings); panel.Children.Add(actions); panel.Children.Add(notice); Content = new ScrollViewer { Content = panel };
  }
}
