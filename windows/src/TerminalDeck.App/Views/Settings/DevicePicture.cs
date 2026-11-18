using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Path = Microsoft.UI.Xaml.Shapes.Path;

namespace TerminalDeck.App.Views.Settings;

// One hand-drawn family at 28 px. Model facts win; the friendly name is a fallback for older Cloud answers.
internal static class DevicePicture
{
  internal static string KindName(string? platform, string? name, string? reported = null) => DeviceModels.Of(platform, name, reported) switch
  {
    DeviceModel.MacMini => "Mac mini", DeviceModel.MacStudio => "Mac Studio", DeviceModel.MacPro => "Mac Pro", DeviceModel.MacBook => "MacBook",
    DeviceModel.IMac => "Mac", DeviceModel.WindowsDesktop => "PC", DeviceModel.WindowsLaptop => "Windows laptop", DeviceModel.IPhone => "iPhone", DeviceModel.IPad => "iPad",
    DeviceModel.AndroidPhone => "Android phone", DeviceModel.AndroidTablet => "Android tablet", DeviceModel.Phone => "Phone", DeviceModel.Browser => "Browser", _ => "Computer"
  };

  internal static FrameworkElement Create(string? platform, string? name, string? reported = null)
  {
    var model = DeviceModels.Of(platform, name, reported);
    var path = model switch
    {
      DeviceModel.MacMini => "M4 12 H24 Q26 12 26 14 V18 Q26 20 24 20 H4 Q2 20 2 18 V14 Q2 12 4 12 Z M20 16 H21 M5 22 H23",
      DeviceModel.MacStudio => "M5 8 H23 Q25 8 25 10 V20 Q25 22 23 22 H5 Q3 22 3 20 V10 Q3 8 5 8 Z M8 17 H10 M13 17 H15 M21 17 H22",
      DeviceModel.MacPro => "M7 5 H21 V25 H7 Z M10 5 V2 H18 V5 M11 10 V20 M15 10 V20 M19 10 V20",
      DeviceModel.MacBook or DeviceModel.WindowsLaptop => "M6 4 H22 Q23 4 23 5 V20 H5 V5 Q5 4 6 4 Z M2 21 H26 L24 24 H4 Z M12 22 H16",
      DeviceModel.WindowsDesktop => "M2 6 H19 V19 H2 Z M8 19 V23 M4 24 H16 M22 8 H27 V24 H22 Z M24 11 H25 M24 20 H25",
      DeviceModel.IPhone => "M9 2 H19 Q21 2 21 4 V24 Q21 26 19 26 H9 Q7 26 7 24 V4 Q7 2 9 2 Z M12 4 H16 M11 23 H17",
      DeviceModel.IPad => "M5 2 H23 Q25 2 25 4 V24 Q25 26 23 26 H5 Q3 26 3 24 V4 Q3 2 5 2 Z M14 4 V4.2",
      DeviceModel.AndroidPhone => "M9 2 H19 Q21 2 21 4 V24 Q21 26 19 26 H9 Q7 26 7 24 V4 Q7 2 9 2 Z M14 5 V5.3",
      DeviceModel.AndroidTablet => "M5 3 H23 Q25 3 25 5 V23 Q25 25 23 25 H5 Q3 25 3 23 V5 Q3 3 5 3 Z M14 5 V5.3",
      DeviceModel.Phone => "M9 2 H19 Q21 2 21 4 V24 Q21 26 19 26 H9 Q7 26 7 24 V4 Q7 2 9 2 Z M11 23 H17",
      DeviceModel.Browser => "M4 4 H24 Q26 4 26 6 V23 Q26 25 24 25 H4 Q2 25 2 23 V6 Q2 4 4 4 Z M2 10 H26 M5 7 H5.2 M8 7 H8.2 M11 7 H11.2 M7 14 H21 Q23 14 23 16 Q23 18 21 18 H7 Q5 18 5 16 Q5 14 7 14 Z",
      _ => "M3 4 H25 Q26 4 26 5 V20 H2 V5 Q2 4 3 4 Z M2 17 H26 M14 20 V24 M9 25 H19"
    };
    var drawing = (Path)XamlReader.Load("<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Width=\"28\" Height=\"28\" Stroke=\"{ThemeResource DeckInkBrush}\" Opacity=\"0.78\" StrokeThickness=\"1.35\" StrokeLineJoin=\"Round\" StrokeStartLineCap=\"Round\" StrokeEndLineCap=\"Round\" Data=\"" + path + "\"/>");
    var box = new Grid { Width = 28, Height = 28, VerticalAlignment = VerticalAlignment.Center };
    box.Children.Add(drawing);
    AutomationProperties.SetName(box, KindName(platform, name, reported));
    return box;
  }
}
