using System.Text;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  // Same destinations and grants as screenshot delivery. A video stays a video and is never passed to AddImage.
  private async ValueTask<string> DeliverPhoneRecordingAsync(byte[] video, string note, string to, ApprovedDevice device, CancellationToken ct)
  {
    if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Recording needs Full control.");
    if (video.Length is < 12 or > 32_000_000 || Encoding.ASCII.GetString(video, 4, 4) != "ftyp") throw new PhoneRefusal("unavailable", "The recording is not a usable MP4 video.");
    // Check the destination before keeping a file; a refusal must not leave a recording behind.
    var chat = Chats?.List().FirstOrDefault(c => c.Definition.Id == to && !c.Ended);
    var terminal = Sessions.FirstOrDefault(s => s.Definition.Id == to && s.State == SessionState.Running);
    if (to == "hoot")
    {
      if (Hoot.Read().Settings is null) throw new PhoneRefusal("unavailable", "Hoot is not set up on this PC yet.");
      if (!PhoneHootGrants.Allows(device, Hoot.Read())) throw new PhoneRefusal("unauthorized", "Hoot is not shared with this phone.");
    }
    else if (chat is null && terminal is null) throw new PhoneRefusal("unknown-session", "That session is not on this PC any more.");
    var folder = Path.Combine(Root.DirectoryPath, "phone-recordings");
    TerminalDeck.Platform.Windows.WindowsPrivateDirectory.Ensure(folder);
    var path = Path.Combine(folder, DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N")[..8] + ".mp4");
    await File.WriteAllBytesAsync(path, video, ct);
    var text = (string.IsNullOrWhiteSpace(note) ? "Look at this recording from " + device.Name + "." : note.Trim()) + "\n\nEmulator recording (MP4): " + path;
    try
    {
      if (to == "hoot")
      {
        await Hoot.SayAsync(Guid.NewGuid().ToString(), text, new TerminalDeck.Core.Hoot.HootSource("person") { DeviceId = device.Id, Restricted = device.Access != PhoneAccess.Full }, ct);
        return "Recording sent to Hoot.";
      }
      if (chat is not null)
      {
        await Chats!.SendAsync(chat.Definition.Id, Guid.NewGuid().ToString(), text, [], ct);
        return "Recording sent to " + chat.Definition.Title + ".";
      }
      await Keeper.WriteAsync(terminal!.Definition.Id, Encoding.UTF8.GetBytes(text.Replace('\n', ' ') + "\r"), ct);
      return "Recording sent to " + terminal.Definition.Title + ".";
    }
    catch { try { File.Delete(path); } catch (IOException) { } throw; }
  }
}
