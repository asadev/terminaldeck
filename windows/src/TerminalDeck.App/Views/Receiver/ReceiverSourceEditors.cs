using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Receiver;
using U = TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Receiver;

internal sealed class ReceiverProofEditor : StackPanel
{
  private readonly ComboBox scheme = Pick("Sender proof", ["token", "hmac", "basic", "none"]), algorithm = Pick("HMAC algorithm", ["sha256", "sha512", "sha1"]), encoding = Pick("Signature encoding", ["hex", "base64"]);
  private readonly TextBox header = U.Field("Proof header"), prefix = U.Field("Proof prefix"), signed = U.Field("Signed bytes template"), timestamp = U.Field("Timestamp header · optional"), user = U.Field("Basic-auth username"), ips = U.Field("Allowed addresses / CIDR ranges · one per line", "", true);
  private readonly NumberBox tolerance = new() { Header = "Timestamp tolerance · seconds", Minimum = 1, Maximum = 3600, Value = 300, SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
  public ReceiverProofEditor(ReceiverProof value) { Spacing = 8; foreach (var control in new UIElement[] { scheme, header, prefix, algorithm, encoding, signed, timestamp, tolerance, user, ips }) Children.Add(control); Load(value); scheme.SelectionChanged += (_, _) => VisibilityForProof(); }
  public void Load(ReceiverProof value) { scheme.SelectedItem = value.Scheme; header.Text = value.Header; prefix.Text = value.Prefix; algorithm.SelectedItem = value.Algorithm; encoding.SelectedItem = value.Encoding; signed.Text = value.SignedPayload; timestamp.Text = value.TimestampHeader ?? ""; tolerance.Value = value.ToleranceSeconds; user.Text = value.BasicUser ?? ""; ips.Text = string.Join('\n', value.IpAllow ?? []); VisibilityForProof(); }
  private void VisibilityForProof() { var hmac = (string?)scheme.SelectedItem == "hmac"; foreach (var control in new FrameworkElement[] { algorithm, encoding, signed, timestamp, tolerance }) control.Visibility = hmac ? Visibility.Visible : Visibility.Collapsed; user.Visibility = (string?)scheme.SelectedItem == "basic" ? Visibility.Visible : Visibility.Collapsed; }
  public ReceiverProof Read() => new((string?)scheme.SelectedItem ?? "token", header.Text, prefix.Text, (string?)algorithm.SelectedItem ?? "sha256", (string?)encoding.SelectedItem ?? "hex", signed.Text, string.IsNullOrWhiteSpace(timestamp.Text) ? null : timestamp.Text, (int)tolerance.Value, user.Text, ips.Text.Split('\n', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries));
  internal static ComboBox Pick(string title, string[] choices) => new() { Header = title, ItemsSource = choices, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
}
internal sealed class ReceiverMappingEditor : StackPanel
{
  private readonly Dictionary<string, TextBox> slots = new();
  private readonly TextBox fields = U.Field("Named fields · JSON name-to-template map", "{}", true), overrides = U.Field("Per-field overrides · JSON name-to-template map", "{}", true), ignored = U.Field("Ignore these event kinds · one per line", "", true), conditions = U.Field("Other ignore conditions · JSON list", "[]", true);
  public ReceiverMappingEditor(ReceiverPayloadMapping value)
  {
    Spacing = 8;
    foreach (var (id, label) in new[] { ("split", "Split an array · optional payload path"), ("kind", "Event kind"), ("severity", "Severity"), ("title", "Title"), ("text", "Message"), ("time", "Event time"), ("upstreamId", "Sender's event ID") }) { var field = U.Field(label); slots[id] = field; Children.Add(field); }
    foreach (var control in new UIElement[] { fields, overrides, ignored, conditions }) Children.Add(control); fields.MaxLength = overrides.MaxLength = conditions.MaxLength = 24000; Load(value);
  }
  public void Load(ReceiverPayloadMapping value)
  {
    foreach (var (id, text) in new Dictionary<string, string> { ["split"] = value.Split ?? "", ["kind"] = value.Kind, ["severity"] = value.Severity, ["title"] = value.Title, ["text"] = value.Text, ["time"] = value.Time, ["upstreamId"] = value.UpstreamId }) slots[id].Text = text;
    fields.Text = JsonSerializer.Serialize(value.Fields ?? [], ReceiverJson.Options); overrides.Text = JsonSerializer.Serialize(value.Overrides ?? [], ReceiverJson.Options);
    ignored.Text = string.Join('\n', (value.Ignore ?? []).Where(c => c.Path == "kind" && c.Operation == ReceiverConditionOperation.Is).Select(c => c.Value)); conditions.Text = JsonSerializer.Serialize((value.Ignore ?? []).Where(c => c.Path != "kind" || c.Operation != ReceiverConditionOperation.Is), ReceiverJson.Options);
  }
  public ReceiverPayloadMapping Read() => new(string.IsNullOrWhiteSpace(slots["split"].Text) ? null : slots["split"].Text, slots["kind"].Text, slots["severity"].Text, slots["title"].Text, slots["text"].Text, slots["time"].Text, slots["upstreamId"].Text, JsonSerializer.Deserialize<Dictionary<string, string>>(fields.Text, ReceiverJson.Options), JsonSerializer.Deserialize<Dictionary<string, string>>(overrides.Text, ReceiverJson.Options), (JsonSerializer.Deserialize<ReceiverCondition[]>(conditions.Text, ReceiverJson.Options) ?? []).Concat(ignored.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(kind => new ReceiverCondition("kind", ReceiverConditionOperation.Is, kind))).ToArray());
}
internal sealed class ReceiverReplyEditor : StackPanel
{
  private readonly ComboBox via = ReceiverProofEditor.Pick("Reply through", ["off", "http", "github"]), method = ReceiverProofEditor.Pick("HTTP method", ["POST", "PUT", "PATCH"]);
  private readonly TextBox url = U.Field("HTTPS reply address"), headers = U.Field("Header templates · JSON map", "{}", true), body = U.Field("Reply body template", "", true), repository = U.Field("GitHub repository template"), number = U.Field("GitHub issue / pull-request number template");
  public ReceiverReplyEditor(ReceiverReplyChannel? value) { Spacing = 8; foreach (var control in new UIElement[] { via, method, url, headers, body, repository, number }) Children.Add(control); Load(value); via.SelectionChanged += (_, _) => SetVisibility(); }
  public void Load(ReceiverReplyChannel? value) { via.SelectedItem = value?.Via ?? "off"; method.SelectedItem = value?.Method ?? "POST"; url.Text = value?.Url ?? ""; headers.Text = JsonSerializer.Serialize(value?.Headers ?? [], ReceiverJson.Options); body.Text = value?.Body ?? "{\"text\":\"{{reply}}\"}"; repository.Text = value?.Repository ?? "{{fields.repo}}"; number.Text = value?.Number ?? "{{fields.number}}"; SetVisibility(); }
  private void SetVisibility() { var mode = (string?)via.SelectedItem; foreach (var control in new FrameworkElement[] { method, url, headers }) control.Visibility = mode == "http" ? Visibility.Visible : Visibility.Collapsed; foreach (var control in new FrameworkElement[] { repository, number }) control.Visibility = mode == "github" ? Visibility.Visible : Visibility.Collapsed; body.Visibility = mode == "off" ? Visibility.Collapsed : Visibility.Visible; }
  public ReceiverReplyChannel? Read() => (string?)via.SelectedItem == "off" ? null : new((string?)via.SelectedItem ?? "http", (string?)method.SelectedItem ?? "POST", url.Text, JsonSerializer.Deserialize<Dictionary<string, string>>(headers.Text, ReceiverJson.Options), body.Text, repository.Text, number.Text);
}
