using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PairingTests
{
  [Theory]
  [InlineData("482913", "PNN7FEFPVPEPG8J6JD5LTK22CW", "PluJUUCYOIi9dWOnMK0Sq8NrO635DqyD0yTLIyeLlAU=")]
  [InlineData("000000", "ESVP7D6GDHN28MLNU5AEGRGGC7", "AFF3srTJviOR9zEbStt+iPZuTjl1Gp595oLklTIfLgc=")]
  [InlineData("999999", "UAFTGU2WS5MN5GYUKF48KJG5SK", "bleS0Mpc5kqiW5FJ7wNs6uardUbhJgcrjUN583t7Zx4=")]
  public void RendezvousMatchesTheMacAndPhoneVectors(string code, string host, string key)
  {
    using var identity = PairingCode.Derive(code);
    Assert.Equal(host, identity.HostId);
    Assert.Equal(key, Convert.ToBase64String(identity.Keys.PublicKey));
  }

  [Theory]
  [InlineData("482-913", "482913")]
  [InlineData(" 482 913 ", "482913")]
  [InlineData("482–913", "482913")]
  [InlineData("000000", "000000")]
  [InlineData("48291", null)]
  [InlineData("4829131", null)]
  [InlineData("O82913", null)]
  [InlineData("H4K9-2FQT", null)]
  [InlineData("", null)]
  public void NormalizePreservesDigitsAndRefusesTypos(string raw, string? expected) => Assert.Equal(expected, PairingCode.Normalize(raw));

  [Fact]
  public void OversizedInputIsRefusedBeforeDerivation() => Assert.Null(PairingCode.Normalize(new string(' ', 300) + "482913"));

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public void OfferReadsStandardBase64AndTheOlderUrlSafeSpelling(bool legacy)
  {
    const string publicKey = "AFF3srTJviOR9zEbStt+iPZuTjl1Gp595oLklTIfLgc=";
    var encoded = legacy ? publicKey.Replace('+', '-').TrimEnd('=') : publicKey;
    var bytes = JsonSerializer.SerializeToUtf8Bytes(new { t = "machine", relayUrl = "wss://relay.terminaldeck.dev", hostId = "PNN7FEFPVPEPG8J6JD5LTK22CW", publicKey = encoded });
    var offer = MachineOffer.Decode(bytes);
    Assert.Equal(Convert.FromBase64String(publicKey), offer.PublicKey);
    using var encodedOffer = JsonDocument.Parse(offer.Encode());
    Assert.Equal(publicKey, encodedOffer.RootElement.GetProperty("publicKey").GetString());
  }

  [Theory]
  [InlineData("https://relay.example")]
  [InlineData("ws://relay.example")]
  [InlineData("wss://user:password@relay.example")]
  public void UnsafeRelayAddressesAreRefused(string address) => Assert.Throws<ProtocolException>(() => RelayEndpoint.Host(new Uri(address)));

  [Fact]
  public void RelayRoutesDiscardOldPathsQueriesAndFragments()
  {
    var relay = new Uri("wss://relay.example/old?bad=1#old");
    Assert.Equal("wss://relay.example/v1/host", RelayEndpoint.Host(relay).AbsoluteUri);
    Assert.Equal("wss://relay.example/v1/join?host=PNN7FEFPVPEPG8J6JD5LTK22CW", RelayEndpoint.Join(relay, "PNN7FEFPVPEPG8J6JD5LTK22CW").AbsoluteUri);
    Assert.Throws<ProtocolException>(() => MachineOffer.Decode(Encoding.UTF8.GetBytes(new string('x', 4097))));
  }

  [Fact]
  public void PairingIsSingleUseAndExactlySixtySeconds()
  {
    var clock = new TestClock(); var pairing = new PairingWindow(clock);
    var first = pairing.Create();
    Assert.Matches("^[0-9]{6}$", first.Code);
    Assert.Equal(clock.GetUtcNow().AddSeconds(60), first.ExpiresAt);
    Assert.DoesNotContain(first.Code, first.ToString());
    Assert.True(pairing.Consume(first.Code)); Assert.False(pairing.Consume(first.Code));
    var second = pairing.Create(); clock.Now = second.ExpiresAt;
    Assert.False(pairing.IsOpen); Assert.False(pairing.Consume(second.Code));
  }

  [Fact]
  public void FiveMissesBurnTheOfferAndCancelWithdrawsIt()
  {
    var pairing = new PairingWindow(new TestClock()); var offer = pairing.Create();
    var wrong = offer.Code == "000000" ? "111111" : "000000";
    for (var i = 0; i < 4; i++) Assert.False(pairing.Consume(wrong));
    Assert.True(pairing.IsOpen); Assert.False(pairing.Consume(wrong));
    Assert.False(pairing.IsOpen); Assert.False(pairing.Consume(offer.Code));
    offer = pairing.Create(); pairing.Cancel(); Assert.False(pairing.Consume(offer.Code));
  }
}

internal sealed class TestClock : TimeProvider
{
  public DateTimeOffset Now { get; set; } = new(2026, 10, 29, 0, 0, 0, TimeSpan.Zero);
  public override DateTimeOffset GetUtcNow() => Now;
}
