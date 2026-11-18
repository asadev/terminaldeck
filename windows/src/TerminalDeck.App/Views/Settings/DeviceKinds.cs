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

  /// Segoe Fluent Icons: a desktop computer (monitor, E7FB), a laptop (E7F8), a PC (E977), a phone (E8EA), a tablet (E70A),
  /// the web (E774). Never E7F4 (TV monitor): DeckIcon's catalog lists it under "bell" and draws a bell.
  public const string DesktopGlyph = "\uE7FB", LaptopGlyph = "\uE7F8", PcGlyph = "\uE977", PhoneGlyph = "\uE8EA", TabletGlyph = "\uE70A", WebGlyph = "\uE774";
  public static string Glyph(DeviceKind kind) => kind switch
  {
    DeviceKind.Desktop => DesktopGlyph, DeviceKind.Laptop => LaptopGlyph, DeviceKind.Phone => PhoneGlyph, DeviceKind.Tablet => TabletGlyph, DeviceKind.Web => WebGlyph,
    _ => PcGlyph
  };
}

public enum DeviceModel { Computer, MacMini, MacStudio, MacPro, MacBook, IMac, WindowsDesktop, WindowsLaptop, IPhone, IPad, AndroidPhone, AndroidTablet, Phone, Browser }

public static class DeviceModels
{
  public static DeviceModel Of(string? platform, string? name, string? reported = null)
  {
    var model = From(reported);
    if (model is not null) return model.Value;
    var p = platform?.ToLowerInvariant() ?? "";
    var n = name?.ToLowerInvariant() ?? "";
    if (p is "web" or "browser") return DeviceModel.Browser;
    if (p == "windows") return DeviceKinds.Of(p, n) == DeviceKind.Laptop ? DeviceModel.WindowsLaptop : DeviceModel.WindowsDesktop;
    if (p == "android") return DeviceKinds.Of(p, n) == DeviceKind.Tablet ? DeviceModel.AndroidTablet : DeviceModel.AndroidPhone;
    if (p is "ios" or "iphone") return n.Contains("ipad") ? DeviceModel.IPad : DeviceModel.IPhone;
    if (p == "ipados") return DeviceModel.IPad;
    model = From(name);
    if (model is not null) return model.Value;
    return p switch
    {
      "windows" => DeviceKinds.Of(p, n) == DeviceKind.Laptop ? DeviceModel.WindowsLaptop : DeviceModel.WindowsDesktop,
      "mac" or "macos" => DeviceModel.IMac,
      "ios" or "iphone" => DeviceModel.IPhone,
      "ipados" => DeviceModel.IPad,
      "android" => DeviceKinds.Of(p, n) == DeviceKind.Tablet ? DeviceModel.AndroidTablet : DeviceModel.AndroidPhone,
      _ => DeviceModel.Computer
    };
  }

  private static DeviceModel? From(string? value)
  {
    var s = value?.ToLowerInvariant().Replace("_", "-") ?? "";
    if (s.Length == 0) return null;
    if (s.Contains("browser") || s.Contains("chrome") || s.Contains("firefox") || s.Contains("safari") || s.Contains("edge on")) return DeviceModel.Browser;
    if (s.Contains("mac-mini") || s.Contains("mac mini") || s.StartsWith("macmini")) return DeviceModel.MacMini;
    if (s.Contains("mac-studio") || s.Contains("mac studio")) return DeviceModel.MacStudio;
    if (s.Contains("mac-pro") || s.Contains("mac pro") || s.StartsWith("macpro")) return DeviceModel.MacPro;
    if (s.Contains("macbook")) return DeviceModel.MacBook;
    if (s.Contains("imac")) return DeviceModel.IMac;
    if (s.Contains("iphone")) return DeviceModel.IPhone;
    if (s.Contains("ipad")) return DeviceModel.IPad;
    if (s.Contains("android-tablet") || s.Contains("galaxy tab")) return DeviceModel.AndroidTablet;
    if (s.Contains("android-phone") || s.Contains("pixel") || s.Contains("galaxy")) return DeviceModel.AndroidPhone;
    if (s.Contains("windows-laptop") || s.Contains("laptop") || s.Contains("surface") || s.Contains("thinkpad") || s.Contains("notebook")) return DeviceModel.WindowsLaptop;
    if (s.Contains("windows-desktop") || s.Contains(" pc") || s == "pc") return DeviceModel.WindowsDesktop;
    if (s.Contains("phone")) return DeviceModel.Phone;
    return null;
  }
}
