using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views.Chat;

// The chat window's frame, shared by the open chat (ChatPage) and the New session page, so the
// two are one layout by construction: a change here changes both.
// Rows: 0 = heading/problem line, 1 = the conversation column, 2 = find/unread line, 3 = the box.
internal static class ChatFrame
{
  public static ResourceDictionary Resources() => (ResourceDictionary)XamlReader.Load("""
      <ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
        <Style x:Key="ChatChoiceText" TargetType="TextBlock"><Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}"/><Setter Property="Foreground" Value="{ThemeResource TextFillColorPrimaryBrush}"/></Style>
        <Style x:Key="ChatCanvas" TargetType="Grid"><Setter Property="Background" Value="{ThemeResource DeckCanvasBrush}"/></Style>
        <Style x:Key="ChatCard" TargetType="Border"><Setter Property="Background" Value="{ThemeResource CardBackgroundFillColorDefaultBrush}"/><Setter Property="CornerRadius" Value="16"/><Setter Property="Padding" Value="16"/></Style>
        <Style x:Key="UserText" TargetType="TextBlock"><Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}"/><Setter Property="Foreground" Value="{ThemeResource TextFillColorPrimaryBrush}"/></Style>
        <Style x:Key="UserBubble" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckSelectionBrush}"/><Setter Property="CornerRadius" Value="18,18,6,18"/><Setter Property="Padding" Value="14"/></Style>
        <Style x:Key="ChatSkeleton" TargetType="Border"><Setter Property="Background" Value="{ThemeResource ControlFillColorSecondaryBrush}"/><Setter Property="CornerRadius" Value="6"/></Style>
        <Style x:Key="ComposerGlass" TargetType="Border"><Setter Property="Background" Value="{ThemeResource DeckGlassBrush}"/><Setter Property="CornerRadius" Value="22"/><Setter Property="Padding" Value="16"/></Style>
      </ResourceDictionary>
      """);

  public static void Layout(Grid page)
  {
    page.Resources = Resources();
    page.Style = (Style)page.Resources["ChatCanvas"];
    page.Padding = new Thickness(20, 0, 20, 12); page.RowSpacing = 6;
    page.RowDefinitions.Add(new() { Height = GridLength.Auto }); page.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    page.RowDefinitions.Add(new() { Height = GridLength.Auto }); page.RowDefinitions.Add(new() { Height = GridLength.Auto });
  }

  // The centred conversation column.
  public static StackPanel Column() => new() { Spacing = 20, MaxWidth = 688, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 20, 0, 0) };

  public static ScrollViewer History(StackPanel column, Action fitted)
  {
    var scroll = new ScrollViewer { Content = column, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled, VerticalContentAlignment = VerticalAlignment.Top };
    scroll.SizeChanged += (_, _) =>
    {
      column.Width = Math.Max(0, Math.Min(688, scroll.ActualWidth));
      fitted();
    };
    return scroll;
  }

  // The width rule the open chat has always used for its padding and the choices under the box.
  public static void Fit(Grid page, ChatComposerBox box)
  {
    var compact = page.ActualWidth < 640; page.Padding = new Thickness(compact ? 12 : 24, 12, compact ? 12 : 24, 12);
    box.Text.MinHeight = 36; box.Model.MaxWidth = compact ? 180 : 220; box.Account.MaxWidth = 180;
    Grid.SetColumn(box.Permission, 0); Grid.SetColumn(box.Model, 1); Grid.SetColumn(box.Effort, 2);
    box.Permission.MaxWidth = compact ? 150 : 240;
    box.Model.MaxWidth = compact ? 150 : 220;
    box.Choices.ColumnDefinitions[0].Width = new GridLength(1, GridUnitType.Star);
    box.Choices.ColumnDefinitions[1].Width = GridLength.Auto;
    box.Choices.ColumnDefinitions[2].Width = GridLength.Auto;
  }
}

// The message box and the line under it, exactly as the open chat draws them: "+", the text,
// microphone and stop in the glass box; the permission line on the left and model and effort on the
// right underneath. Each owner wires its own actions; nothing here talks to a session.
internal sealed class ChatComposerBox
{
  public TextBox Text { get; } = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 36, MaxHeight = 180, PlaceholderText = "Message" };
  // Not in the visual tree: Enter sends. The button only carries the "can send now" state.
  public Button Send { get; } = new() { Content = "Send", MinHeight = 40 };
  public Button Stop { get; } = new() { Content = "Stop", MinHeight = 40 };
  public Button Model { get; } = new() { MinHeight = 40, MaxWidth = 240, HorizontalAlignment = HorizontalAlignment.Left };
  public Button Effort { get; } = new() { MinHeight = 40, HorizontalAlignment = HorizontalAlignment.Stretch };
  public Button Account { get; } = new() { MinHeight = 40, MaxWidth = 200, HorizontalAlignment = HorizontalAlignment.Left };
  public Button Permission { get; } = new() { MaxWidth = 170 };
  public Button Attach { get; } = new() { Content = "Add", MinHeight = 40 };
  public Button Dictate { get; } = new() { Content = "Dictate", MinHeight = 40 };
  public TextBlock Feedback { get; } = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed };
  public StackPanel Attachments { get; } = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
  public StackPanel PromptSummary { get; } = new() { Spacing = 4, Visibility = Visibility.Collapsed };
  public Grid Choices { get; } = new() { ColumnSpacing = 4, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };
  public Grid Controls { get; } = new() { ColumnSpacing = 8 };
  public StackPanel Dock { get; } = new() { Spacing = 8, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };

  public ChatComposerBox()
  {
    Send.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    Send.SetResourceReference(Control.BackgroundProperty, "DeckProjectBlueBrush");
  }

  // aboveText: the "/" menu of an open chat (nothing on the New session page).
  public StackPanel Assemble(Style glassStyle, UIElement? aboveText)
  {
    var composition = new StackPanel { Spacing = 8 }; composition.Children.Add(PromptSummary); composition.Children.Add(new ScrollViewer { Content = Attachments, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    if (aboveText is not null) composition.Children.Add(aboveText);
    composition.Children.Add(Text);
    // Mac keeps the choices below the floating box, leaving the text room to breathe.
    Choices.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    Choices.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    Choices.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    foreach (var chip in new[] { Account, Model, Effort, Permission })
    {
      chip.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
      chip.MinHeight = 28; chip.MinWidth = 32; chip.Padding = new Thickness(6, 4, 6, 4); chip.FontSize = 12;
    }
    Account.MaxWidth = 180; Model.MaxWidth = 220; Effort.MaxWidth = 100;
    Choices.Padding = new Thickness(12, 0, 12, 0);
    Choices.Children.Add(Permission); Grid.SetColumn(Model, 1); Choices.Children.Add(Model); Grid.SetColumn(Effort, 2); Choices.Children.Add(Effort);
    Controls.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    Controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); Controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); Controls.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    Attach.HorizontalAlignment = HorizontalAlignment.Left;
    ChatAppearance.IconButton(Attach, "", "Add to message"); Controls.Children.Add(Attach);
    ChatAppearance.IconButton(Stop, "", "Stop the current answer");
    ChatAppearance.IconButton(Send, "", "Send message", accent: true);
    ChatAppearance.IconButton(Dictate, "", "Dictate with Windows voice typing (Win+H)");
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetAutomationId(Dictate, "chat.dictate");
    Grid.SetColumn(Dictate, 1); Controls.Children.Add(Dictate);
    Grid.SetColumn(Stop, 2); Controls.Children.Add(Stop); composition.Children.Add(Controls);
    Text.BorderThickness = new Thickness(0); Text.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    Text.Padding = new Thickness(0); Text.FontSize = 14;
    var glass = new Border { Child = composition, MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch, Style = glassStyle, Margin = new Thickness(0, 8, 0, 0) };
    Dock.Children.Add(glass); Dock.Children.Add(Feedback); Dock.Children.Add(Choices); Grid.SetRow(Dock, 3);
    return Dock;
  }
}
