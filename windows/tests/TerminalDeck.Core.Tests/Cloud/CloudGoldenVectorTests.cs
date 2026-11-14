using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

// W2: the byte-exact core against the Mac's golden vectors (td-ship-0220 macos/TerminalDeckNative/Tests/Fixtures/
// cloud-golden-vectors.json, made by CloudGoldenVectorsTests.swift). Every vector passes, including the ones that must
// be refused or must fail. All keys in the file are TEST-ONLY constants.
public sealed class CloudGoldenVectorTests
{
  /// The fixture is a byte-identical copy of the Swift side's file.
  private const string FixtureSha256 = "2a613ed312dd1288eb17696744d3e0e55bea363f1ce22194a0f23baa591ae8f5";
  private static readonly byte[] FixtureBytes = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "cloud-golden-vectors.json"));
  private static readonly JsonElement Root = JsonDocument.Parse(FixtureBytes).RootElement;
  private static JsonElement Inputs => Root.GetProperty("testOnlyInputs");
  private static string Input(string name) => Inputs.GetProperty(name).GetString()!;
  private static byte[] InputHex(string name) => Convert.FromHexString(Input(name));
  private static JsonElement[] Group(string name) => Root.GetProperty(name).EnumerateArray().ToArray();
  private static JsonElement Vector(string group, string name) => Group(group).Single(v => v.GetProperty("name").GetString() == name);
  private static string S(JsonElement v, string key) => v.GetProperty(key).GetString()!;
  private static byte[] Utf8(string text) => Encoding.UTF8.GetBytes(text);
  private static string Hex(byte[] bytes) => Convert.ToHexStringLower(bytes);
  private static CloudPublicJwk Jwk(JsonElement e) => new(S(e, "kty"), S(e, "crv"), S(e, "x"), S(e, "y"));
  private static string Subject => Input("subject");
  private static void AllHandled(string group, IEnumerable<string> handled) =>
    Assert.Equal(Group(group).Select(v => S(v, "name")).OrderBy(n => n, StringComparer.Ordinal), handled.OrderBy(n => n, StringComparer.Ordinal));

  [Fact]
  public void FixtureIsTheSwiftFileByteForByte()
  {
    Assert.Equal(FixtureSha256, Convert.ToHexStringLower(SHA256.HashData(FixtureBytes)));
    Assert.Equal("td-cloud-golden-1", Root.GetProperty("format").GetString());
  }

  [Fact]
  public void Canonical_AllSeventeen()
  {
    var handled = new List<string>();
    foreach (var v in Group("canonical"))
    {
      var name = S(v, "name");
      if (v.TryGetProperty("expect", out var expect) && expect.GetString() == "error")
      {
        if (name == "non-finite")
        {
          foreach (var bad in new[] { double.NaN, double.PositiveInfinity, double.NegativeInfinity })
          {
            Assert.Throws<CloudFailure>(() => CloudCanonical.Encode(new CloudJson.Number(bad)));
            Assert.Throws<CloudFailure>(() => CloudCanonical.Encode(CloudJson.Obj(("n", new CloudJson.Number(bad)))));
          }
          foreach (var text in new[] { "NaN", "Infinity", "-Infinity", "[1e400]" }) Assert.Throws<CloudFailure>(() => CloudCanonical.EncodeJson(text));
        }
        else Assert.Throws<CloudFailure>(() => CloudCanonical.EncodeJson(Utf8(S(v, "input"))));
      }
      else
      {
        var output = CloudCanonical.EncodeJson(Utf8(S(v, "input")));
        Assert.Equal(S(v, "outputHex"), Hex(output));
        Assert.Equal(Utf8(S(v, "output")), output);
        Assert.Equal(S(v, "outputSha256"), CloudBytes.Sha256Hex(output));
      }
      handled.Add(name);
    }
    Assert.Equal(17, handled.Count);
    AllHandled("canonical", handled);
  }

  [Fact]
  public void Canonical_ExactDuplicateKeysAreRefusedToo()
  {
    Assert.Throws<CloudFailure>(() => CloudCanonical.EncodeJson("{\"a\":1,\"a\":2}"));
    Assert.Throws<CloudFailure>(() => CloudCanonical.EncodeJson("[\"\\ud800\"]"));
  }

  /// The two records of the td-ops-1 pack, rebuilt from their parts (payload hashes computed here).
  private static IReadOnlyList<CloudOperation> GoldenRecords()
  {
    var deviceA = Input("deviceA");
    var payload1 = CloudJson.Parse(S(Vector("derived", "record-payload-hash"), "payload"));
    var payload2 = CloudJson.Parse("{\"body\":\"edited\",\"n\":4,\"tags\":[],\"title\":\"Golden note\"}");
    const string first = "dca7d011-0cd3-4477-b17d-0e8fa56ed7d6", second = "b919e08b-c7a0-4232-a95c-7ff37ab0dffe";
    var source = new CloudSourceReference("memory-notes", "note-1");
    return
    [
      new(1, first, deviceA, "memory", "note-1", first, [], "put", null, null, source, Inputs.GetProperty("createdAt").GetInt64(), payload1, CloudOperation.PayloadHashOf(payload1)),
      new(1, second, deviceA, "memory", "note-1", second, [first], "put", null, null, source, 1763000001000, payload2, CloudOperation.PayloadHashOf(payload2)),
    ];
  }

  [Fact]
  public void PackSignature_AllEight()
  {
    var handled = new List<string>();
    var subject = Subject;
    // pack-bytes
    var packVector = Vector("packSignature", "pack-bytes");
    var packBytes = CloudPackFormat.Encode(GoldenRecords());
    Assert.Equal(S(packVector, "outputHex"), Hex(packBytes));
    Assert.Equal(packBytes, CloudPackFormat.Encode(CloudPackFormat.Decode(packBytes)));
    handled.Add("pack-bytes");

    // brain-envelope-identity: sealed with the fixed nonce, byte for byte.
    var identity = Vector("packSignature", "brain-envelope-identity");
    var brainRoot = Convert.FromHexString(S(identity, "brainRootHex"));
    Assert.Equal(Input("brainRootHex"), S(identity, "brainRootHex"));
    var sealedEnvelope = CloudBrainContent.Seal(packBytes, S(identity, "blobId"), "brain", 1, "identity", S(identity, "subject"), brainRoot, Convert.FromHexString(S(identity, "nonceHex")));
    var envelopeBytes = sealedEnvelope.Canonical();
    Assert.Equal(Utf8(S(identity, "envelope")), envelopeBytes);
    Assert.Equal(identity.GetProperty("envelopeBytes").GetInt32(), envelopeBytes.Length);
    Assert.Equal(S(identity, "envelopeSha256"), CloudBytes.Sha256Hex(envelopeBytes));
    Assert.Equal(packBytes, CloudBrainContent.Open(CloudContentEnvelope.Parse(envelopeBytes), subject, brainRoot));
    Assert.Throws<CloudFailure>(() => CloudBrainContent.Open(sealedEnvelope, Input("deviceB"), brainRoot));
    handled.Add("brain-envelope-identity");

    // brain-envelope-gzip: decrypt-only; compared after decompressing.
    var gzip = Vector("packSignature", "brain-envelope-gzip");
    var zipped = CloudContentEnvelope.Parse(Utf8(S(gzip, "envelope")));
    Assert.Equal("gzip", zipped.Codec);
    Assert.Equal(packBytes, CloudBrainContent.Open(zipped, subject, brainRoot));
    var ownZip = CloudBrainContent.Seal(packBytes, CloudBytes.NewTransportId(), "brain", 1, "gzip", subject, brainRoot);
    Assert.Equal("gzip", ownZip.Codec);
    Assert.Equal(packBytes, CloudBrainContent.Open(ownZip, subject, brainRoot));
    handled.Add("brain-envelope-gzip");

    // signing-bytes
    var signing = Vector("packSignature", "signing-bytes");
    var unsigned = CloudSegmentDescriptor.Parse(Utf8(S(signing, "descriptorUnsigned")));
    Assert.Equal(S(signing, "outputHex"), Hex(unsigned.SigningBytes(S(signing, "subject"))));
    Assert.Equal(CloudBytes.Sha256Hex(envelopeBytes), unsigned.Sha256);
    Assert.Equal(envelopeBytes.Length, unsigned.Bytes);
    handled.Add("signing-bytes");

    // signature-valid: verified, never regenerated.
    var valid = Vector("packSignature", "signature-valid");
    var keyA = Jwk(valid.GetProperty("publicKey"));
    var descriptor = CloudSegmentDescriptor.Parse(Utf8(S(valid, "descriptor")));
    Assert.Equal(S(valid, "signatureB64u"), descriptor.Signature);
    Assert.Equal(Root.GetProperty("randomOutputs").GetProperty("pack.signature").GetString(), descriptor.Signature);
    Assert.Equal(CloudSignatureCheck.Valid, descriptor.Check(keyA, subject));
    // The test-only private key A is the one behind that public key; a fresh signature of ours verifies too.
    Assert.Equal(keyA, CloudP256.PublicKey(InputHex("signAPrivateHex")));
    using (var signer = CloudP256.Signer(InputHex("signAPrivateHex")))
    {
      var ours = unsigned.Sign(subject, signer);
      Assert.Equal(CloudSignatureCheck.Valid, ours.Check(keyA, subject));
      Assert.Equal(CloudSignatureCheck.BadSignature, ours.Check(CloudP256.PublicKey(InputHex("signBPrivateHex")), subject));
    }
    Assert.Equal(CloudSignatureCheck.BadKey, descriptor.Check(keyA with { Y = null }, subject));
    handled.Add("signature-valid");

    foreach (var name in new[] { "tampered-opcount", "tampered-signature" })
    {
      var bad = CloudSegmentDescriptor.Parse(Utf8(S(Vector("packSignature", name), "descriptor")));
      Assert.Equal("bad-signature", S(Vector("packSignature", name), "expect"));
      Assert.Equal(CloudSignatureCheck.BadSignature, bad.Check(keyA, subject));
      handled.Add(name);
    }
    var wrongSubject = Vector("packSignature", "wrong-subject");
    Assert.Equal(CloudSignatureCheck.BadSignature, descriptor.Check(keyA, S(wrongSubject, "subject")));
    handled.Add("wrong-subject");

    Assert.Equal(8, handled.Count);
    AllHandled("packSignature", handled);
  }

  [Fact]
  public void DeviceCode_AllFour()
  {
    var handled = new List<string>();
    var keyA = Jwk(Vector("deviceCode", "device-a").GetProperty("signPublicJwk"));
    foreach (var v in Group("deviceCode"))
    {
      if (v.TryGetProperty("expect", out var expect))
      {
        Assert.Equal("no-code", expect.GetString());
        Assert.Null(CloudDeviceCode.Code(S(v, "deviceId"), keyA));
      }
      else
      {
        var key = Jwk(v.GetProperty("signPublicJwk"));
        Assert.Equal(S(v, "keyId"), CloudDeviceCode.KeyId(key));
        Assert.Equal(S(v, "code"), CloudDeviceCode.Code(S(v, "deviceId"), key));
        Assert.Equal(S(v, "code"), CloudDeviceCode.Code(S(v, "deviceId"), S(v, "keyId")));
      }
      handled.Add(S(v, "name"));
    }
    // The three public keys are the test-only private keys A, B and C.
    Assert.Equal(Jwk(Vector("deviceCode", "device-b").GetProperty("signPublicJwk")), CloudP256.PublicKey(InputHex("signBPrivateHex")));
    Assert.Equal(Jwk(Vector("deviceCode", "device-c").GetProperty("signPublicJwk")), CloudP256.PublicKey(InputHex("signCPrivateHex")));
    Assert.Equal(4, handled.Count);
    AllHandled("deviceCode", handled);
  }

  private static byte[] SharedWith(string privateHexInput, CloudPublicJwk peer) => CloudP256.SharedSecret(InputHex(privateHexInput), peer);

  [Fact]
  public void AccountKeyWrap_AllThree()
  {
    var handled = new List<string>();
    var v = Vector("accountKeyWrap", "wrap-for-device-b");
    var target = CloudKeyWrap.RegistrationFromJson(CloudJson.Parse(S(v, "target")));
    var authorKey = Jwk(v.GetProperty("authorSignPublicJwk"));
    var golden = CloudDeviceKeyEnvelope.Parse(Utf8(S(v, "envelope")));
    var root = Convert.FromHexString(S(v, "rootKeyHex"));
    Assert.Equal(target.WrapPublicJwk, CloudP256.PublicKey(InputHex("wrapBPrivateHex")));

    // Wrap with the fixed ephemeral key, salt, nonce and canary: same AAD, ciphertext and tag.
    using var signerA = CloudP256.Signer(InputHex("signAPrivateHex"));
    var (ours, canaryHash) = CloudKeyWrap.Wrap(root, S(v, "subject"), target, 1, S(v, "recoveryVersion"), S(v, "author"),
      bytes => signerA.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation),
      InputHex("ephemeralPrivateHex"), InputHex("saltHex"), CloudBytes.Unbase64(golden.Nonce), InputHex("canaryHex"));
    Assert.Equal(Utf8(S(v, "aad")), ours.Aad());
    Assert.Equal(Utf8(S(v, "aad")), golden.Aad());
    Assert.Equal(golden.Ciphertext, ours.Ciphertext);
    Assert.Equal(golden.Tag, ours.Tag);
    Assert.Equal(golden with { Signature = ours.Signature }, ours);
    Assert.Equal(S(v, "canaryHash"), canaryHash);
    // A's signature on the golden envelope (verify-only) and on ours both check; B opens both to the root key.
    Assert.Equal(Root.GetProperty("randomOutputs").GetProperty("wrap.signature").GetString(), golden.Signature);
    foreach (var envelope in new[] { golden, ours })
    {
      var opened = CloudKeyWrap.Unwrap(envelope, S(v, "subject"), Input("deviceB"), 1, S(v, "recoveryVersion"), S(v, "author"), authorKey, peer => SharedWith("wrapBPrivateHex", peer));
      Assert.Equal(CloudBytes.Base64Url(root), opened.RootKey);
      var body = CloudCanonical.Encode(CloudJson.Obj(("epoch", CloudJson.From(opened.Epoch)), ("rootKey", CloudJson.From(opened.RootKey)),
        ("recoveryVersion", CloudJson.From(opened.RecoveryVersion)), ("canary", CloudJson.From(opened.Canary))));
      Assert.Equal(Utf8(S(v, "plainBody")), body);
    }
    // Another expected version is refused after opening.
    Assert.Throws<CloudFailure>(() => CloudKeyWrap.Unwrap(golden, S(v, "subject"), Input("deviceB"), 1, "8", S(v, "author"), authorKey, peer => SharedWith("wrapBPrivateHex", peer)));
    handled.Add("wrap-for-device-b");

    var wrongKey = Assert.Throws<CloudFailure>(() => CloudKeyWrap.Unwrap(golden, S(v, "subject"), Input("deviceB"), 1, S(v, "recoveryVersion"), S(v, "author"), authorKey,
      peer => SharedWith("wrongWrapPrivateHex", peer)));
    Assert.Equal("checksum_mismatch", wrongKey.Code);
    handled.Add("wrong-device-key");

    var tampered = CloudDeviceKeyEnvelope.Parse(Utf8(S(Vector("accountKeyWrap", "tampered-ciphertext"), "envelope")));
    var badSignature = Assert.Throws<CloudFailure>(() => CloudKeyWrap.Unwrap(tampered, S(v, "subject"), Input("deviceB"), 1, S(v, "recoveryVersion"), S(v, "author"), authorKey,
      peer => SharedWith("wrapBPrivateHex", peer)));
    Assert.Equal("checksum_mismatch", badSignature.Code);
    handled.Add("tampered-ciphertext");

    Assert.Equal(3, handled.Count);
    AllHandled("accountKeyWrap", handled);
  }

  [Fact]
  public void SavedPasswordEnvelope_AllThree()
  {
    var handled = new List<string>();
    var v = Vector("savedPasswordEnvelope", "seal-secret");
    var root = Convert.FromHexString(S(v, "rootKeyHex"));
    Assert.Equal(Input("secretsRootHex"), S(v, "rootKeyHex"));
    var plain = Convert.FromHexString(S(v, "plainHex"));
    Assert.Equal(Utf8(S(v, "plain")), plain);
    var sealedEnvelope = CloudSecretEnvelope.Seal(plain, root, S(v, "subject"), S(v, "blobId"), "secret", 1, "identity", Convert.FromHexString(S(v, "nonceHex")));
    Assert.Equal(Utf8(S(v, "envelope")), sealedEnvelope.Canonical());
    var golden = CloudContentEnvelope.Parse(Utf8(S(v, "envelope")));
    Assert.Equal(plain, CloudSecretEnvelope.Open(golden, root, S(v, "subject"), 1));
    Assert.Throws<CloudFailure>(() => CloudSecretEnvelope.Open(golden, root, S(v, "subject"), 2));
    var zipped = CloudSecretEnvelope.Seal(plain, root, S(v, "subject"), CloudBytes.NewTransportId(), "secret", 1, "gzip");
    Assert.Equal(plain, CloudSecretEnvelope.Open(zipped, root, S(v, "subject"), 1));
    handled.Add("seal-secret");

    var tampered = CloudContentEnvelope.Parse(Utf8(S(Vector("savedPasswordEnvelope", "tampered-tag"), "envelope")));
    Assert.Equal("checksum_mismatch", Assert.Throws<CloudFailure>(() => CloudSecretEnvelope.Open(tampered, root, S(v, "subject"), 1)).Code);
    handled.Add("tampered-tag");

    var wrongSubject = S(Vector("savedPasswordEnvelope", "wrong-subject"), "subject");
    Assert.Equal("checksum_mismatch", Assert.Throws<CloudFailure>(() => CloudSecretEnvelope.Open(golden, root, wrongSubject, 1)).Code);
    handled.Add("wrong-subject");

    Assert.Equal(3, handled.Count);
    AllHandled("savedPasswordEnvelope", handled);
  }

  [Fact]
  public void Derived_AllEight()
  {
    var handled = new List<string>();
    var records = GoldenRecords();

    var payloadHash = Vector("derived", "record-payload-hash");
    Assert.Equal(S(payloadHash, "output"), CloudOperation.PayloadHashOf(CloudJson.Parse(S(payloadHash, "payload"))));
    handled.Add("record-payload-hash");

    var record = Vector("derived", "record-canonical");
    var recordBytes = CloudCanonical.Encode(records[0].ToJson());
    Assert.Equal(Utf8(S(record, "output")), recordBytes);
    Assert.Equal(S(record, "outputSha256"), CloudBytes.Sha256Hex(recordBytes));
    Assert.Equal(recordBytes, CloudCanonical.Encode(CloudOperation.FromJson(CloudJson.Parse(recordBytes)).ToJson()));
    handled.Add("record-canonical");

    var envelope = Utf8(S(Vector("packSignature", "brain-envelope-identity"), "envelope"));
    Assert.Equal(S(Vector("derived", "pack-sha256"), "output"), CloudBytes.Sha256Hex(CloudContentEnvelope.Parse(envelope).Canonical()));
    handled.Add("pack-sha256");

    var keyHash = Vector("derived", "device-key-hash");
    var target = CloudKeyWrap.RegistrationFromJson(CloudJson.Parse(S(keyHash, "input")));
    Assert.Equal(S(keyHash, "output"), CloudKeyWrap.KeyHash(target));
    Assert.Equal(Utf8(S(keyHash, "input")), CloudCanonical.Encode(CloudKeyWrap.RegistrationJson(target)));
    handled.Add("device-key-hash");

    var matching = Vector("derived", "matching-code");
    var approvalJson = (CloudJson.Object)CloudJson.Parse(S(matching, "approval"));
    var approval = new CloudApproval(approvalJson["approvalId"]!.AsString!, approvalJson["targetDeviceId"]!.AsString!, approvalJson["targetKeyHash"]!.AsString!,
      approvalJson["challenge"]!.AsString!, approvalJson["expiresAt"]!.AsInteger!.Value);
    Assert.Equal(Utf8(S(matching, "approval")), CloudCanonical.Encode(approval.ToJson()));
    Assert.Equal(S(matching, "output"), CloudKeyWrap.MatchingCode(approval));
    handled.Add("matching-code");

    var transfer = Vector("derived", "transfer-code");
    var wrap = Vector("accountKeyWrap", "wrap-for-device-b");
    Assert.Equal(S(transfer, "output"), CloudKeyWrap.TransferCode(S(transfer, "issuer"), Subject, approval,
      CloudKeyWrap.RegistrationFromJson(CloudJson.Parse(S(wrap, "target"))), Jwk(wrap.GetProperty("authorSignPublicJwk")),
      CloudDeviceKeyEnvelope.Parse(Utf8(S(wrap, "envelope")))));
    Assert.Equal(CloudWire.Issuer, S(transfer, "issuer"));
    handled.Add("transfer-code");

    var pkce = Vector("derived", "callback-pkce-challenge");
    Assert.Equal(S(pkce, "output"), CloudBytes.Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(S(pkce, "verifier")))));
    handled.Add("callback-pkce-challenge");

    // random-ids: fresh lower-case v4 UUIDs, never derived; anything that is not v4 is refused as a transport id.
    Assert.Equal("not-derived", S(Vector("derived", "random-ids"), "expect"));
    var ids = Enumerable.Range(0, 64).Select(_ => CloudBytes.NewTransportId()).ToArray();
    Assert.All(ids, id => { Assert.True(CloudBytes.IsTransportId(id)); Assert.Equal(id.ToLowerInvariant(), id); });
    Assert.Equal(ids.Length, ids.Distinct().Count());
    Assert.False(CloudBytes.IsTransportId("dca7d011-0cd3-1477-b17d-0e8fa56ed7d6")); // version 1
    Assert.False(CloudBytes.IsTransportId("dca7d011-0cd3-4477-717d-0e8fa56ed7d6")); // not the RFC variant
    Assert.False(CloudBytes.IsTransportId("{dca7d011-0cd3-4477-b17d-0e8fa56ed7d6}"));
    handled.Add("random-ids");

    Assert.Equal(8, handled.Count);
    AllHandled("derived", handled);
  }
}
