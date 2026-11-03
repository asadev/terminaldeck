using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

public sealed record ScreenElement(string Role, string Name, string Identifier, double X, double Y, double Width, double Height)
{
  public JsonObject Wire() => new() { ["r"] = Role, ["n"] = Name, ["i"] = Identifier, ["x"] = X, ["y"] = Y, ["w"] = Width, ["h"] = Height };
}
public sealed record ScreenInspection(IReadOnlyList<ScreenElement> Elements, string App = "", string Screen = "", string Note = "");
public sealed record ScreenRegion(int X, int Y, int Width, int Height);

// Optional platform features (Android devices, inspection, power, recording). Screens go as H.264 only (§11.7).
public interface IExtendedScreenHost
{
  ScreenDisplay? Device(string id);
  ScreenInspection Inspect(string id);
  ValueTask PowerAsync(string id, bool on, CancellationToken ct);
  bool CanRecord { get; }
  ValueTask RecordStartAsync(string id, string lease, CancellationToken ct);
  ValueTask<byte[]> RecordStopAsync(string id, string lease, CancellationToken ct);
  ValueTask RecordCancelAsync(string id, string lease);
}
