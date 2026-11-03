# Synthetic protocol fixtures

`sealed-vectors.json` is imported unchanged from the product's shared sealed-channel test vectors.

SHA-256: `2fc461023f31f1635c71caedf304df006125977f8d35cd2ec757d19161a606b8`.

The source generator is the product's sealed-vectors harness. It records bytes produced by the product's TypeScript sealed channel and relay-wire modules, and is also consumed by the Mac/phone tests. Its keys are named synthetic test identities, never real devices or credentials. Do not regenerate to make a failing port agree with itself. No Mac build or live session is needed.

The three rendezvous vectors in PairingTests were transcribed from the Mac/phone rendezvous tests; the expected host ids and public keys are independent of this implementation.
