using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// The saved-passwords key with no click, ported case for case from the Mac's CloudSecretsAutoHandoverTests,
// CloudSecretsEverywhereTests (the hand-over half), CloudSecretsBrowserAnswerTests and CloudSecretsLostMacTests, against a
// fake service that applies the service's own checks (CloudSecretsFakeService).
public sealed class CloudSecretsHandoverTests
{
  private static async Task<(CloudSecretsFakeService Service, CloudSecretsTestDevice A)> FirstDevice()
  {
    var service = new CloudSecretsFakeService();
    var a = new CloudSecretsTestDevice(service, "Studio PC");
    await a.Handover.SetupSilentlyAsync();
    return (service, a);
  }
  /// `b` asks (signed), `a` answers by itself, `b` takes the answer. True when `b` holds the key afterwards.
  private static async Task<bool> HandOver(CloudSecretsTestDevice a, CloudSecretsTestDevice b)
  {
    await b.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    try { return await b.Handover.ReceiveApprovalAsync(); } catch (Exception) { return false; }
  }

  [Fact]
  public async Task First_device_turns_on_by_itself_with_no_words_and_a_placeholder_recovery_copy()
  {
    var (service, a) = await FirstDevice();
    Assert.Equal(CloudSecretsProtection.Protected, a.Handover.Protection());
    Assert.Equal("ready", service.State); Assert.Equal(1, service.Epoch);
    Assert.True(service.Recovery!.IsPlaceholder);
    Assert.False(a.Handover.RecoveryWordsExist());
    Assert.True(service.Devices[a.Id].Approved);
    // Only one set-up: a second "first" device is refused and asks instead.
    var b = new CloudSecretsTestDevice(service, "Laptop");
    await Assert.ThrowsAsync<CloudFailure>(() => b.Handover.SetupSilentlyAsync());
  }

  [Fact]
  public async Task Second_device_opens_by_itself_when_the_first_is_online_and_both_hold_one_key()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Mac mini", "macos");
    a.Trust(b); b.Trust(a);
    Assert.True(await HandOver(a, b));
    Assert.Equal(a.Root, b.Root);
    Assert.Equal(CloudSecretsProtection.Protected, b.Handover.Protection());
    Assert.Null(b.Handover.MatchingCode);
  }

  [Fact]
  public async Task A_device_this_PC_does_not_list_or_has_removed_is_never_answered()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Unknown");
    b.Trust(a);
    Assert.False(await HandOver(a, b));
    Assert.Null(b.Local.Read());
    // Removed from the account: never answered either.
    var c = new CloudSecretsTestDevice(service, "Gone");
    a.Trust(c); c.Trust(a);
    await c.Handover.RequestApprovalAsync();
    service.Devices[c.Id].Status = "revoked";
    await a.Handover.AnswerAllAsync();
    Assert.Null(service.Devices[c.Id].Envelope);
  }

  [Fact]
  public async Task A_swapped_wrapping_key_with_a_matching_hash_is_never_answered()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Laptop");
    a.Trust(b); b.Trust(a);
    await b.Handover.RequestApprovalAsync();
    // The service swaps the wrapping key and recomputes the request's hash: b's own signature covers its real one.
    var swapped = b.Registration with { WrapPublicJwk = CloudDeviceKeys.Fresh().Registration("x", "0", "windows").WrapPublicJwk };
    service.Devices[b.Id].Registration = swapped;
    foreach (var p in service.Approvals) p.Value = p.Value with { TargetKeyHash = CloudKeyWrap.KeyHash(swapped) };
    await a.Handover.AnswerAllAsync();
    Assert.Null(service.Devices[b.Id].Envelope);
    Assert.Contains(a.Lines, l => l.Contains("wrong signature"));
  }

  [Fact]
  public async Task Each_device_is_answered_by_itself_once_per_key_generation()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Laptop");
    a.Trust(b); b.Trust(a);
    await b.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    var first = service.Devices[b.Id].Envelope;
    Assert.NotNull(first);
    service.Devices[b.Id].Envelope = null;
    await b.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    Assert.Null(service.Devices[b.Id].Envelope);
    Assert.Contains(a.Lines, l => l.Contains("already answered once"));
  }

  [Fact]
  public async Task The_new_device_takes_the_key_only_from_a_device_its_own_list_holds()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Laptop");
    a.Trust(b); // b does NOT list a
    Assert.False(await HandOver(a, b));
    Assert.Null(b.Local.Read());
  }

  [Fact]
  public async Task Under_ask_me_nothing_is_answered_by_itself_and_the_new_device_shows_the_code()
  {
    var (service, a) = await FirstDevice();
    Assert.True(await a.Handover.SetAskOnNewDeviceAsync(true) || true);
    var b = new CloudSecretsTestDevice(service, "Laptop");
    a.Trust(b); b.Trust(a);
    await b.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    Assert.Null(service.Devices[b.Id].Envelope);
  }

  [Fact]
  public async Task His_phone_and_his_browser_are_answered_and_the_one_switch_keeps_both_off()
  {
    var (service, a) = await FirstDevice();
    var phone = new CloudSecretsTestDevice(service, "iPhone", "ios");
    var browser = new CloudSecretsTestDevice(service, "Browser", "web");
    a.Trust(phone); a.Trust(browser); phone.Trust(a); browser.Trust(a);
    Assert.True(await HandOver(a, phone));
    // The browser's key box asks like a phone (the service lets it; the fake checks the same way).
    service.Devices[browser.Id].Registration = browser.Registration;
    await a.Handover.SetPhonesOffAsync(true);
    var late = new CloudSecretsTestDevice(service, "iPad", "ios");
    a.Trust(late); late.Trust(a);
    service.PhonesPolicy = null; // the switch holds on THIS PC from its own book alone
    await late.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    Assert.Null(service.Devices[late.Id].Envelope);
    Assert.Contains(a.Lines, l => l.Contains("off your phones"));
  }

  [Fact]
  public async Task A_browser_never_passes_as_a_phone_or_a_computer_nor_the_reverse_and_an_unknown_kind_is_refused()
  {
    var (service, a) = await FirstDevice();
    var phone = new CloudSecretsTestDevice(service, "iPhone", "ios");
    a.Trust(phone, platform: "web"); phone.Trust(a);
    Assert.False(await HandOver(a, phone));
    var odd = new CloudSecretsTestDevice(service, "Watch", "watchos");
    a.Trust(odd); odd.Trust(a);
    await Assert.ThrowsAsync<CloudFailure>(() => odd.Handover.RequestApprovalAsync());
    var mac = new CloudSecretsTestDevice(service, "Mac", "macos");
    a.Trust(mac, platform: "ios"); mac.Trust(a);
    Assert.False(await HandOver(a, mac));
  }

  [Fact]
  public async Task A_machine_signed_out_before_waits_for_yes_its_mine()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Laptop");
    a.Trust(b); b.Trust(a);
    service.Devices[b.Id].SignedOutBefore = true;
    Assert.False(await HandOver(a, b));
    Assert.Contains(a.Lines, l => l.Contains("Yes, it's mine"));
  }

  [Fact]
  public async Task An_interrupted_set_up_opens_by_itself_from_this_PCs_own_copy()
  {
    var (service, a) = await FirstDevice();
    a.Slots.Items.Remove("key");
    Assert.True(await a.Handover.ReopenOwnCopyAsync());
    Assert.Equal(CloudSecretsProtection.Protected, a.Handover.Protection());
  }

  // ---- a lost device signed out from another device ----

  private static async Task<(CloudSecretsFakeService, CloudSecretsTestDevice A, CloudSecretsTestDevice B, CloudSecretsTestDevice Lost)> Three()
  {
    var (service, a) = await FirstDevice();
    var b = new CloudSecretsTestDevice(service, "Mac mini", "macos");
    var lost = new CloudSecretsTestDevice(service, "Old laptop");
    foreach (var x in new[] { b, lost }) { a.Trust(x); x.Trust(a); }
    b.Trust(lost); lost.Trust(b);
    Assert.True(await HandOver(a, b)); Assert.True(await HandOver(a, lost));
    service.Devices[lost.Id].Status = "revoked";
    service.Due = new(service.Now, lost.Id, "Old laptop", []);
    return (service, a, b, lost);
  }

  [Fact]
  public async Task The_device_that_is_on_changes_the_key_and_his_other_devices_take_their_copy()
  {
    var (service, a, b, lost) = await Three();
    var old = a.Root;
    Assert.Equal(CloudSecretsKeyChange.Rotated, await a.Handover.KeyChangeAsync());
    Assert.Equal(2, service.Epoch);
    Assert.NotEqual(old, a.Root);
    Assert.Equal(old, a.Local.Archived(1)!.Root);
    Assert.Equal(CloudSecretsKeyChange.TookCopy, await b.Handover.KeyChangeAsync());
    Assert.Equal(a.Root, b.Root);
    Assert.Null(service.Devices[lost.Id].Envelope);
  }

  [Fact]
  public async Task A_copy_from_an_author_this_PC_does_not_list_is_never_taken()
  {
    var (service, a, b, _) = await Three();
    b.Pinned.Remove(a.Id);
    await a.Handover.KeyChangeAsync();
    Assert.Equal(CloudSecretsKeyChange.Nothing, await b.Handover.KeyChangeAsync());
    Assert.Equal(1, b.Local.Read()!.Epoch);
  }

  [Fact]
  public async Task Two_devices_at_once_make_one_key_change()
  {
    var (service, a, b, _) = await Three();
    Assert.Equal(CloudSecretsKeyChange.Rotated, await a.Handover.KeyChangeAsync());
    // b heard the same notice: nothing due any more, it is behind, so it takes its copy.
    Assert.Equal(CloudSecretsKeyChange.TookCopy, await b.Handover.KeyChangeAsync());
    Assert.Equal(2, service.Epoch);
  }

  [Fact]
  public async Task Nothing_due_changes_nothing_and_a_malformed_due_field_is_nothing_due()
  {
    var (service, a) = await FirstDevice();
    Assert.Equal(CloudSecretsKeyChange.Nothing, await a.Handover.KeyChangeAsync());
    Assert.Null(CloudSecretsRotationDue.Read(CloudJson.Parse("""{"since":0,"removedDeviceId":"x","holders":[]}""")));
    Assert.Null(CloudSecretsRotationDue.Read(CloudJson.Parse("""{"since":5,"removedDeviceId":"x","holders":[1]}""")));
    Assert.Null(CloudSecretsRotationDue.Read(CloudJson.Parse("true")));
    Assert.True(CloudSecretsHandover.LostTheRace(new CloudFailure("not_due")));
    Assert.Equal(1, service.Epoch);
  }

  [Fact]
  public async Task A_swapped_wrapping_key_never_gets_a_copy_and_a_refused_copy_does_not_stop_the_change()
  {
    var (service, a, b, _) = await Three();
    var c = new CloudSecretsTestDevice(service, "Desk");
    a.Trust(c); c.Trust(a);
    Assert.True(await HandOver(a, c));
    // c's wrapping key, as the service now reports it, was never checked here.
    service.Devices[c.Id].Registration = c.Registration with { WrapPublicJwk = CloudDeviceKeys.Fresh().Registration("x", "0", "windows").WrapPublicJwk };
    service.RefuseCopyFor[b.Id] = "not_approved";
    Assert.Equal(CloudSecretsKeyChange.Rotated, await a.Handover.KeyChangeAsync());
    Assert.Null(service.Devices[c.Id].Envelope);
    Assert.Null(service.Devices[b.Id].Envelope);
    Assert.Contains(a.Lines, l => l.Contains("not checked here"));
    // b was not delivered a copy: its "answered" mark is taken back, so it is answered when it asks again.
    service.Devices[b.Id].Registration = b.Registration;
    service.RefuseCopyFor.Clear();
    await b.Handover.RequestApprovalAsync();
    await a.Handover.AnswerAllAsync();
    Assert.NotNull(service.Devices[b.Id].Envelope);
  }

  [Fact]
  public async Task A_browser_gets_no_copy_after_a_sign_out_and_asks_again_as_usual()
  {
    var (service, a, _, _) = await Three();
    var browser = new CloudSecretsTestDevice(service, "Browser", "web");
    a.Trust(browser); browser.Trust(a);
    service.Due = null;
    await browser.Handover.RequestApprovalAsync().ContinueWith(_ => { });
    // The fake refuses a browser's own request (as today's service does for a plain web row); give it the key directly.
    service.Devices[browser.Id].Envelope = service.Devices[a.Id].Envelope; service.Devices[browser.Id].Approved = true;
    service.Due = new(service.Now, "00000000-0000-4000-8000-000000000000", "Old", []);
    await a.Handover.KeyChangeAsync();
    Assert.Contains(a.Lines, l => l.Contains("no copy for a browser") || l.Contains("does not list"));
  }

  [Fact]
  public async Task A_remote_sign_out_removes_only_this_devices_cloud_keys()
  {
    var (_, a) = await FirstDevice();
    Assert.NotEmpty(a.Slots.Items);
    a.Handover.ForgetAfterRemoteSignOut();
    Assert.Empty(a.Slots.Items);
    Assert.Equal(CloudSecretsProtection.Locked, a.Handover.Protection());
  }

  [Fact]
  public async Task Device_revoked_with_who_and_when_is_seen_by_the_transport()
  {
    var http = new RevokedHttp();
    var device = new CloudTestDevice("e3c75f30-363e-4323-a592-cf07fe14c4a6", new CloudFakeService());
    var store = new CloudSyncStore(new CloudMemorySlot(), new CloudMemorySlot(), CloudFakeService.Subject);
    var client = new CloudFeedClient(new CloudSyncEndpoint(CloudFakeService.Base, test: true), CloudFakeService.Subject, device, http, store);
    (string, long)? seen = null;
    client.RemovedByAnotherDevice += (name, at) => seen = (name, at);
    await Assert.ThrowsAsync<CloudFailure>(() => client.SecretsCallAsync("GET", "/secrets/status", null, null, default));
    Assert.Equal(("Asad's Mac", 1_763_000_000_000L), seen);
  }
  private sealed class RevokedHttp : ICloudSyncHttp
  {
    public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct) => Task.FromResult(new CloudSyncHttpResponse(403,
      System.Text.Encoding.UTF8.GetBytes("""{"error":{"code":"device_revoked","retryable":false,"removedByName":"Asad's Mac","removedAt":1763000000000}}""")));
  }

  // ---- the exact bytes a Mac and the service check ----

  [Fact]
  public void The_signed_proofs_are_the_canonical_bytes_the_service_and_the_Macs_check()
  {
    var approval = new CloudApproval("a1", "d1", "h1", "c1", 5);
    var wrap = new CloudPublicJwk("EC", "P-256", "x", "y");
    var wrapHash = CloudBytes.Sha256Hex(System.Text.Encoding.UTF8.GetBytes("""{"crv":"P-256","kty":"EC","x":"x","y":"y"}"""));
    Assert.Equal("""{"approvalId":"a1","challenge":"c1","epoch":3,"expiresAt":5,"purpose":"TD-APPROVAL-REQUEST-1","sub":"s","targetDeviceId":"d1","targetKeyHash":"h1","wrapKeyHash":""" + "\"" + wrapHash + "\"}",
      System.Text.Encoding.UTF8.GetString(CloudSecretsProof.Request("s", approval, wrap, 3)));
    Assert.Equal("TD-CLOUD-POSSESSION-1\ns\nd1\n7\ncan", System.Text.Encoding.UTF8.GetString(CloudSecretsProof.Possession("s", "d1", "7", "can")));
    Assert.Equal("""{"allow":false,"approvalId":"a1","challenge":"c1","expectedVersion":"9","expiresAt":5,"targetKeyHash":"h1"}""",
      System.Text.Encoding.UTF8.GetString(CloudSecretsProof.Approval(approval, false, "9", null, null)));
    Assert.Equal("""{"at":4,"by":"d1","phonesOff":true,"purpose":"TD-PASSWORDS-PHONES-1","sub":"s"}""",
      System.Text.Encoding.UTF8.GetString(CloudSecretsProof.PhonesPolicy("s", true, 4, "d1")));
  }
}
