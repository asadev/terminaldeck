using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math.EC.Rfc7748;

namespace TerminalDeck.Core.Remote;

public sealed class NoiseIdentity : IDisposable
{
  private readonly byte[] privateKey;
  public byte[] PublicKey { get { RequireOpen(); return PublicFrom(privateKey); } }
  internal byte[] PrivateKey => privateKey;
  private bool disposed;

  public NoiseIdentity(ReadOnlySpan<byte> key)
  {
    if (key.Length != 32) throw new ArgumentException("An identity key must be 32 bytes.");
    privateKey = key.ToArray();
  }

  public static NoiseIdentity Generate()
  {
    var seed = RandomNumberGenerator.GetBytes(32);
    try { return new(seed); }
    finally { CryptographicOperations.ZeroMemory(seed); }
  }
  internal void RequireOpen() => ObjectDisposedException.ThrowIf(disposed, this);
  internal static byte[] PublicFrom(byte[] key)
  {
    var result = new byte[32];
    X25519.ScalarMultBase(key, 0, result, 0);
    return result;
  }

  public void Dispose()
  {
    CryptographicOperations.ZeroMemory(privateKey);
    disposed = true;
  }
}

public sealed class NoisePending : IDisposable
{
  internal byte[] Ephemeral { get; }
  internal byte[] Device { get; }
  internal byte[] ChainingKey { get; }
  internal byte[] Hash { get; }
  internal bool Used { get; private set; }

  internal NoisePending(byte[] ephemeral, byte[] device, byte[] key, byte[] hash)
  {
    Ephemeral = (byte[])ephemeral.Clone();
    Device = (byte[])device.Clone();
    ChainingKey = (byte[])key.Clone();
    Hash = hash;
  }

  public void Dispose()
  {
    Used = true;
    CryptographicOperations.ZeroMemory(Ephemeral);
    CryptographicOperations.ZeroMemory(Device);
    CryptographicOperations.ZeroMemory(ChainingKey);
  }
}

public sealed record NoiseStart(byte[] Message, NoisePending Pending);
public sealed record NoiseResponse(byte[] Reply, byte[] PeerPublicKey, NoiseTransport Transport);

// Fresh implementation of the product's fixed Noise wire contract. Crypto primitives
// come from Bouncy Castle; the recorded product vectors test the key schedule.
public static class NoiseChannel
{
  public const string ProtocolName = "Noise_IK_25519_ChaChaPoly_SHA256";
  public const ulong CounterLimit = 1UL << 48;

  private static byte[] Hash(params byte[][] parts)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    foreach (var part in parts) hash.AppendData(part);
    return hash.GetHashAndReset();
  }

  // The schedule owns every intermediate, including failure paths. Only
  // cloned pending/transport keys outlive this scope.
  private sealed class Schedule : IDisposable
  {
    private readonly List<byte[]> secrets = [];
    public byte[] Keep(byte[] value) { secrets.Add(value); return value; }
    public (byte[] Key, byte[] Temporary) Mix(byte[] key, byte[] input)
    {
      byte[]? output = null;
      try
      {
        output = HKDF.DeriveKey(HashAlgorithmName.SHA256, input, 64, key, []);
        return (Keep(output[..32]), Keep(output[32..]));
      }
      finally
      {
        CryptographicOperations.ZeroMemory(input);
        if (output is not null) CryptographicOperations.ZeroMemory(output);
      }
    }
    public void Dispose() { foreach (var secret in secrets) CryptographicOperations.ZeroMemory(secret); }
  }

  private static byte[] Agree(byte[] secret, byte[] peer)
  {
    if (peer.Length != 32) throw new ProtocolException("The sealed channel could not be opened.");
    var result = new byte[32];
    if (!X25519.CalculateAgreement(secret, 0, peer, 0, result, 0))
    {
      CryptographicOperations.ZeroMemory(result);
      throw new ProtocolException("The sealed channel could not be opened.");
    }
    return result;
  }

  private static (byte[] Key, byte[] Hash) Initial(byte[] host)
  {
    var key = Hash(Encoding.ASCII.GetBytes(ProtocolName));
    return (key, Hash(key, host));
  }

  public static NoiseStart Start(NoiseIdentity device, ReadOnlySpan<byte> hostPublicKey, NoiseIdentity? ephemeral = null)
  {
    device.RequireOpen();
    if (hostPublicKey.Length != 32) throw new ProtocolException("The host key must be 32 bytes.");
    using var generated = ephemeral is null ? NoiseIdentity.Generate() : null;
    var temporary = ephemeral ?? generated!;
    temporary.RequireOpen();
    var host = hostPublicKey.ToArray();
    using var schedule = new Schedule();
    var (key, hash) = Initial(host);
    schedule.Keep(key);
    hash = Hash(hash, temporary.PublicKey);
    var es = schedule.Mix(key, Agree(temporary.PrivateKey, host));
    var encrypted = Crypt(true, es.Temporary, 0, device.PublicKey, hash);
    hash = Hash(hash, encrypted);
    var ss = schedule.Mix(es.Key, Agree(device.PrivateKey, host));
    return new NoiseStart([..temporary.PublicKey, ..encrypted],
      new NoisePending(temporary.PrivateKey, device.PrivateKey, ss.Key, hash));
  }

  public static NoiseTransport Finish(NoisePending pending, ReadOnlySpan<byte> reply)
  {
    if (pending.Used) throw new ProtocolException("This handshake has already ended.");
    try
    {
      if (reply.Length != 48) throw new ProtocolException("The handshake reply has the wrong length.");
      using var schedule = new Schedule();
      var peer = reply[..32].ToArray();
      var confirmation = reply[32..].ToArray();
      var hash = Hash(pending.Hash, peer);
      var ee = schedule.Mix(pending.ChainingKey, Agree(pending.Ephemeral, peer));
      var se = schedule.Mix(ee.Key, Agree(pending.Device, peer));
      _ = Crypt(false, se.Temporary, 0, confirmation, hash);
      var split = schedule.Mix(se.Key, []);
      return new NoiseTransport(split.Key, split.Temporary, Hash(hash, confirmation));
    }
    finally { pending.Dispose(); }
  }

  public static NoiseResponse Respond(NoiseIdentity host, ReadOnlySpan<byte> message,
    IReadOnlyCollection<byte[]> knownPeers, bool permitPairing = false, NoiseIdentity? ephemeral = null)
  {
    host.RequireOpen();
    if (message.Length != 80) throw new ProtocolException("The handshake has the wrong length.");
    using var generated = ephemeral is null ? NoiseIdentity.Generate() : null;
    var temporary = ephemeral ?? generated!;
    temporary.RequireOpen();
    var peer = message[..32].ToArray();
    var encrypted = message[32..].ToArray();
    using var schedule = new Schedule();
    var (key, hash) = Initial(host.PublicKey);
    schedule.Keep(key);
    hash = Hash(hash, peer);
    var es = schedule.Mix(key, Agree(host.PrivateKey, peer));
    var device = Crypt(false, es.Temporary, 0, encrypted, hash);
    hash = Hash(hash, encrypted);
    var ss = schedule.Mix(es.Key, Agree(host.PrivateKey, device));
    if (!permitPairing && !knownPeers.Any(p => CryptographicOperations.FixedTimeEquals(p, device)))
      throw new ProtocolException("The sealed channel could not be opened.");
    hash = Hash(hash, temporary.PublicKey);
    var ee = schedule.Mix(ss.Key, Agree(temporary.PrivateKey, peer));
    var se = schedule.Mix(ee.Key, Agree(temporary.PrivateKey, device));
    var confirmation = Crypt(true, se.Temporary, 0, [], hash);
    var split = schedule.Mix(se.Key, []);
    return new NoiseResponse([..temporary.PublicKey, ..confirmation], device,
      new NoiseTransport(split.Temporary, split.Key, Hash(hash, confirmation)));
  }

  internal static byte[] Crypt(bool encrypt, byte[] key, ulong counter, byte[] data, byte[] aad)
  {
    if (!encrypt && data.Length < 16) throw new ProtocolException("The sealed channel could not be opened.");
    var nonce = new byte[12];
    BinaryPrimitives.WriteUInt64LittleEndian(nonce.AsSpan(4), counter);
    var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
    cipher.Init(encrypt, new AeadParameters(new KeyParameter(key), 128, nonce, aad));
    var output = new byte[cipher.GetOutputSize(data.Length)];
    try
    {
      var written = cipher.ProcessBytes(data, 0, data.Length, output, 0);
      written += cipher.DoFinal(output, written);
      return output[..written];
    }
    catch (InvalidCipherTextException)
    {
      CryptographicOperations.ZeroMemory(output);
      throw new ProtocolException("The sealed channel could not be opened.");
    }
  }
}

public sealed class NoiseTransport : IDisposable
{
  private readonly byte[] sendKey;
  private readonly byte[] receiveKey;
  private readonly object gate = new();
  private ulong sent;
  private ulong received;
  private bool closed;
  public byte[] ChannelBinding { get; }

  internal NoiseTransport(byte[] send, byte[] receive, byte[] binding)
  {
    sendKey = (byte[])send.Clone();
    receiveKey = (byte[])receive.Clone();
    ChannelBinding = binding;
  }

  public byte[] Send(ReadOnlySpan<byte> plaintext)
  {
    lock (gate)
    {
      RequireOpen(sent);
      var frame = NoiseChannel.Crypt(true, sendKey, sent, plaintext.ToArray(), []);
      sent++;
      return frame;
    }
  }

  public byte[] Receive(ReadOnlySpan<byte> frame)
  {
    lock (gate)
    {
      RequireOpen(received);
      try
      {
        var plaintext = NoiseChannel.Crypt(false, receiveKey, received, frame.ToArray(), []);
        received++;
        return plaintext;
      }
      catch { Dispose(); throw; }
    }
  }

  private void RequireOpen(ulong counter)
  {
    if (closed || counter >= NoiseChannel.CounterLimit)
      throw new ProtocolException("The sealed channel has ended. Reconnect to continue.");
  }

  public void Dispose()
  {
    lock (gate)
    {
      closed = true;
      CryptographicOperations.ZeroMemory(sendKey);
      CryptographicOperations.ZeroMemory(receiveKey);
    }
  }
}
