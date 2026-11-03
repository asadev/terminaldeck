using System.Diagnostics;
using TerminalDeck.Core.Receiver;
using Windows.Storage;
using Windows.System;

namespace TerminalDeck.Platform.Windows.Receiver;

public static class WindowsArtifactOpener
{
  // ReceiverArtifacts checks project access and the path. Recheck the handler
  // here so no caller can send source text through Windows file associations.
  public static async ValueTask OpenAsync(string path, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (ArtifactOpenPolicy.HandlerFor(path) == ArtifactOpenHandler.TextEditor)
    {
      using var process = Process.Start(TextEditorStartInfo(path)) ?? throw new IOException("Windows could not open the text editor.");
      return;
    }
    var file = await StorageFile.GetFileFromPathAsync(path);
    ct.ThrowIfCancellationRequested();
    if (!await Launcher.LaunchFileAsync(file)) throw new IOException("Windows could not find an app to open this file.");
  }
  public static ProcessStartInfo TextEditorStartInfo(string path)
  {
    if (!Path.IsPathFullyQualified(path) || ArtifactOpenPolicy.HandlerFor(path) != ArtifactOpenHandler.TextEditor)
      throw new ArgumentException("Choose a text file in the project.");
    var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "notepad.exe")) { UseShellExecute = false };
    info.ArgumentList.Add(path); return info;
  }
}
