using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Hoot;

public sealed partial class HootPage
{
  private readonly StackPanel imageAttachments = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
  private static void CopyMessage(string text)
  { var content = new DataPackage(); content.SetText(text); Clipboard.SetContent(content); }
  private void ShowMessageError(string message) { feedback.Text = message; feedback.Visibility = Visibility.Visible; }
  private async Task BranchLineAsync(HootLine line, bool rewind)
  {
    if (rewind)
    {
      var dialog = Dialog("Rewind to this message?", Words("The complete conversation is kept in History. Project files stay as they are."), "Rewind");
      dialog.DefaultButton = ContentDialogButton.Close;
      if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
    }
    await Model.BranchAsync(line.Id, rewind);
  }
  private void InitializeImagePaste(StackPanel composerPanel)
  {
    composerPanel.Children.Add(new ScrollViewer { Content = imageAttachments, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
    composer.Paste += async (_, args) =>
    {
      try
      {
        var data = Clipboard.GetContent();
        if (data.Contains(StandardDataFormats.Bitmap))
        {
          args.Handled = true;
          var image = await ChatImageScaler.PrepareClipboardAsync(await data.GetBitmapAsync());
          Model.AddAttachment(new(image.Name, image.MimeType, image.Bytes, image.Width, image.Height));
        }
        else if (data.Contains(StandardDataFormats.StorageItems))
        {
          args.Handled = true;
          foreach (var file in (await data.GetStorageItemsAsync()).OfType<Windows.Storage.StorageFile>())
          {
            var image = await ChatImageScaler.PrepareAsync(file);
            Model.AddAttachment(new(image.Name, image.MimeType, image.Bytes, image.Width, image.Height));
          }
        }
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { ShowMessageError("This image could not be pasted. " + ex.Message); }
    };
    Model.PropertyChanged += (_, args) => { if (args.PropertyName == nameof(HootViewModel.Attachments)) RenderImageAttachments(); };
  }
  private void RenderImageAttachments()
  {
    imageAttachments.Children.Clear();
    foreach (var attachment in Model.Attachments)
    {
      var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
      var preview = new Image { Width = 48, Height = 40, Stretch = Stretch.Uniform };
      row.Children.Add(preview);
      var remove = ActionButton("Remove " + attachment.Name, () => { Model.RemoveAttachment(attachment); return Task.CompletedTask; });
      ChatAppearance.IconButton(remove, "\uE711", "Remove " + attachment.Name); row.Children.Add(remove); imageAttachments.Children.Add(row);
      _ = LoadAsync();
      async Task LoadAsync()
      {
        try
        {
          using var stream = new InMemoryRandomAccessStream();
          using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(attachment.Data); await writer.StoreAsync(); }
          stream.Seek(0); var bitmap = new BitmapImage(); await bitmap.SetSourceAsync(stream); preview.Source = bitmap;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { ShowMessageError("The image preview could not load."); }
      }
    }
  }
}
