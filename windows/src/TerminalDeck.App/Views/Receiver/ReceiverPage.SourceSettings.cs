using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Receiver;
using U = TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Receiver;

public sealed partial class ReceiverPage
{
  private async Task EditAdvancedSourceAsync(ReceiverSource? source)
  {
    var service = sourceSettings!; var presets = service.Presets(); var form = U.Stack(12);
    var name = U.Field("Name", source?.Name ?? ""); var project = new ComboBox { Header = "Project", ItemsSource = projects.Select(p => new SourceChoice(p.Id, p.Label)).ToArray(), DisplayMemberPath = "Name", SelectedValuePath = "Id", SelectedValue = source?.ProjectId ?? Model.ProjectFilter ?? projects.FirstOrDefault().Id, HorizontalAlignment = HorizontalAlignment.Stretch };
    var preset = new ComboBox { Header = "Source type / preset", ItemsSource = presets, DisplayMemberPath = "Name", SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var saved = source is null ? null : service.Read(source.Id); if (saved is not null) preset.SelectedItem = presets.FirstOrDefault(p => p.Id == saved.Preset) ?? presets[0];
    form.Children.Add(name); if (source is null) form.Children.Add(project); form.Children.Add(preset);
    var proof = new ReceiverProofEditor(saved?.Proof ?? presets[0].Proof);
    var mapping = new ReceiverMappingEditor(saved?.Mapping ?? presets[0].Mapping);
    var reply = new ReceiverReplyEditor(saved?.Reply ?? presets[0].Reply);
    var credential = new PasswordBox { Header = "Proof secret · empty keeps current credential" }; var replyKey = new PasswordBox { Header = "Reply credential · empty keeps current credential" };
    var notice = U.Words("Default mappings are editable. Templates use {{path|fallback|\"literal\"}}; split selects an array; ignore conditions can suppress event kinds. Source secrets stay in the protected credential store.", muted: true);
    preset.SelectionChanged += (_, _) => { if (preset.SelectedItem is ReceiverSourcePreset chosen) { proof.Load(chosen.Proof); mapping.Load(chosen.Mapping); reply.Load(chosen.Reply); } };
    foreach (var (label, content) in new[] { ("Proof", (UIElement)proof), ("Read payload fields", mapping), ("Replies", reply) }) form.Children.Add(new Expander { Header = label, IsExpanded = label == "Read payload fields", Content = content, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    form.Children.Add(credential); form.Children.Add(replyKey); form.Children.Add(notice);
    var sample = U.Field("Sample payload · preview only", "{\"title\":\"Example event\",\"message\":\"Preview only\",\"id\":\"sample-1\"}", true); sample.MaxLength = 80000;
    var sampleHeaders = U.Field("Sample event headers · JSON map", "{}", true);
    var previewResult = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 240 };
    var previewForm = U.Stack(8); previewForm.Children.Add(sample); previewForm.Children.Add(sampleHeaders);
    previewForm.Children.Add(U.Button("Preview mapping", () =>
    {
      try
      {
        var headers = JsonSerializer.Deserialize<Dictionary<string, string>>(sampleHeaders.Text) ?? new();
        foreach (var key in headers.Keys.Where(k => k.Equals(proof.Read().Header, StringComparison.OrdinalIgnoreCase) || k.Equals("Authorization", StringComparison.OrdinalIgnoreCase) || k.Equals("Cookie", StringComparison.OrdinalIgnoreCase)).ToArray()) headers[key] = "[redacted]";
        var results = ReceiverPayloadMapper.Map(new(source?.Id ?? "preview", headers, System.Text.Encoding.UTF8.GetBytes(sample.Text)), mapping.Read()); previewResult.Text = "Preview only. Nothing was received or delivered.\n" + JsonSerializer.Serialize(results, ReceiverJson.Options);
      }
      catch (Exception error) when (error is ArgumentException or JsonException) { previewResult.Text = error.Message; }
      return Task.CompletedTask;
    })); previewForm.Children.Add(previewResult); form.Children.Add(new Expander { Header = "Try a payload", Content = previewForm, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    if (source is not null)
    {
      var tools = U.Horizontal();
      tools.Children.Add(U.Button("Learn from latest event", () => { try { mapping.Load(service.Learn(source.Id).Mapping); notice.Text = "Suggested mapping loaded. Review it before saving."; } catch (Exception error) when (error is ArgumentException or InvalidOperationException) { notice.Text = error.Message; } return Task.CompletedTask; }));
      var presetName = U.Field("New preset name", source.Name); form.Children.Add(presetName);
      tools.Children.Add(U.Button("Save stored settings as preset", () => { service.SavePreset(source.Id, presetName.Text); notice.Text = "Preset saved from the last committed settings; credentials were excluded."; return Task.CompletedTask; }));
      tools.Children.Add(U.Button("Copy saved proof credential", async () => { var value = await service.ReadCredentialForClipboardAsync(source.Id); var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(value); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); notice.Text = "Saved proof credential copied for the sender's settings."; }));
      tools.Children.Add(U.Button("Replace and copy proof secret", async () => { var value = await service.GenerateCredentialAsync(source.Id); var data = new Windows.ApplicationModel.DataTransfer.DataPackage(); data.SetText(value); Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(data); notice.Text = "New proof secret copied. Paste it into the sender's settings."; }));
      tools.Children.Add(U.Button("Remove proof credential", async () => { await service.SetCredentialAsync(source.Id, ""); notice.Text = "Proof credential removed. This source cannot receive signed or token-protected events until a new credential is saved."; }));
      tools.Children.Add(U.Button("Remove reply credential", async () => { await service.SetCredentialAsync(source.Id, "", true); notice.Text = "Reply credential removed."; })); form.Children.Add(tools);
      var latest = Model.Receiver.Items(source.Id, limit: 1).FirstOrDefault(); if (latest?.Payload is { } payload) form.Children.Add(new Expander { Header = "Latest observed payload", Content = new TextBox { Text = payload.GetRawText(), IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 240 }, HorizontalAlignment = HorizontalAlignment.Stretch });
    }
    if (await U.Dialog(XamlRoot, source is null ? "Add a Receiver source" : "Edit " + source.Name, new ScrollViewer { Content = form, MaxHeight = 560 }, "Save source").ShowAsync() != ContentDialogResult.Primary) return;
    await Model.RunAsync(async () =>
    {
      var proofValue = proof.Read(); var mappingValue = mapping.Read(); var replyValue = reply.Read();
      var selected = (ReceiverSourcePreset)preset.SelectedItem; var target = source ?? await service.CreateAsync(name.Text, project.SelectedValue as string ?? throw new ArgumentException("Choose a project."), selected.Id);
      if (source is not null) Model.Receiver.SaveSource(target with { Name = name.Text });
      service.Save(new(target.Id, selected.Id, proofValue, mappingValue, replyValue));
      if (credential.Password.Length > 0) await service.SetCredentialAsync(target.Id, credential.Password);
      if (replyKey.Password.Length > 0) await service.SetCredentialAsync(target.Id, replyKey.Password, true);
    }, "Source saved. Its relay registration will refresh after the current connection is ready.");
  }
  private sealed record SourceChoice(string Id, string Name);
}
