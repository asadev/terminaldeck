namespace TerminalDeck.App.Views.Settings;

// Each device row's glyph from the device's KIND (C-5): its platform first, then the model words in its name only to
// tell a laptop from a desktop. Plain .NET, tested in Core.Tests.
public enum DeviceKind { Desktop, Laptop, Pc, Phone, Tablet, Web }

public static class DeviceKinds
{
  public static DeviceKind Of(string? platform, string? name)
  {
    var p = (platform ?? "").ToLowerInvariant();
    var n = (name ?? "").ToLowerInvariant();
    bool Has(params string[] words) => words.Any(n.Contains);
    if (p is "ios" or "iphone" or "android") return Has("ipad", "tablet", "tab ") ? DeviceKind.Tablet : DeviceKind.Phone;
    if (p is "ipados") return DeviceKind.Tablet;
    if (p is "web" or "browser") return DeviceKind.Web;
    if (p is "windows") return Has("laptop", "surface", "notebook", "thinkpad", "xps") ? DeviceKind.Laptop : DeviceKind.Pc;
    if (p is "macos" or "mac") return Has("macbook", "book", "air", "laptop") ? DeviceKind.Laptop : DeviceKind.Desktop;
    // No platform: the name alone.
    if (Has("iphone", "android", "pixel", "galaxy", "phone")) return DeviceKind.Phone;
    if (Has("ipad", "tablet")) return DeviceKind.Tablet;
    if (Has("macbook", "laptop")) return DeviceKind.Laptop;
    if (Has("mac")) return DeviceKind.Desktop;
    return DeviceKind.Pc;
  }

  /// Segoe Fluent Icons: a desktop computer (monitor), a laptop, a PC tower, a phone, a tablet, the web.
  public static string Glyph(DeviceKind kind) => kind switch
  {
    DeviceKind.Desktop => "", DeviceKind.Laptop => "", DeviceKind.Phone => "", DeviceKind.Tablet => "", DeviceKind.Web => "",
    _ => ""
  };
}
