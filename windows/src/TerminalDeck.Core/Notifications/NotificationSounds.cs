namespace TerminalDeck.Core.Notifications;

public static class NotificationSounds
{
  // Original small synthesized tones; no OS/vendor audio assets are bundled.
  public static byte[] Wave(string name)
  {
    name = name switch { "default" => "chime", "im" => "blip", "reminder" => "knock", _ => name };
    if (name is not ("chime" or "blip" or "knock")) throw new ArgumentException("Choose Chime, Blip or Knock.");
    const int rate = 22050; var seconds = name == "chime" ? 0.65 : name == "blip" ? 0.18 : 0.13; var count = (int)(seconds * rate);
    using var data = new MemoryStream(); using var writer = new BinaryWriter(data);
    writer.Write("RIFF"u8); writer.Write(36 + count * 2); writer.Write("WAVEfmt "u8); writer.Write(16); writer.Write((short)1); writer.Write((short)1);
    writer.Write(rate); writer.Write(rate * 2); writer.Write((short)2); writer.Write((short)16); writer.Write("data"u8); writer.Write(count * 2);
    for (var i = 0; i < count; i++)
    {
      var t = i / (double)rate; var fade = Math.Min(1, i / 100d) * Math.Min(1, (count - i) / 300d);
      var sample = name switch
      {
        "chime" => Math.Sin(t * Math.Tau * 660) * Math.Exp(-t * 6) + (t >= 0.2 ? 0.6 * Math.Sin((t - 0.2) * Math.Tau * 880) * Math.Exp(-(t - 0.2) * 8) : 0),
        "blip" => Math.Sin(t * Math.Tau * (1050 - t * 900)) * Math.Exp(-t * 14),
        _ => (Math.Sin(t * Math.Tau * 150) + 0.25 * Math.Sin(t * Math.Tau * 913)) * Math.Exp(-t * 35)
      };
      writer.Write((short)Math.Clamp(sample * fade * 6000, short.MinValue, short.MaxValue));
    }
    writer.Flush(); return data.ToArray();
  }
}

public sealed partial class SessionNotifications
{
  // Only explicit UI/MCP test actions call this. Saving preferences never emits
  // a real notification, starts a provider, or consumes a paid AI turn.
  public ValueTask<NotificationTestResult> TestAsync(bool soundOnly = false, CancellationToken ct = default)
  { ct.ThrowIfCancellationRequested(); return sink.TestAsync(Read().Sound, soundOnly, ct); }
}
