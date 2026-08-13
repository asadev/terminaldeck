package dev.terminaldeck.android.store

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.StaticKeyPair
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Everything this phone must not lose and must not leak: its static key and its credential.
 *
 * ## Why the private key is not *itself* a Keystore key
 *
 * The obvious design is to have the hardware hold the X25519 private key and never hand it over.
 * The Android Keystore cannot do that here, for a reason that is a fact about the platform rather
 * than a preference:
 *
 *  - The Keystore's key algorithms are RSA, EC (NIST curves), AES and HMAC. X25519 is not among
 *    them at any API level this app supports — `KeyProperties.KEY_ALGORITHM_XDH` arrived in API 33,
 *    and `minSdk` here is 26, so on most of the range there is no way to even ask.
 *  - Noise needs the raw DH output to feed HKDF. A key agreement that returns a hardware-held
 *    secret would still have to surface those 32 bytes.
 *
 * So the key is generated in the app and **wrapped**: an AES-256-GCM key is created inside the
 * Keystore, marked non-exportable, and used to encrypt this blob. The wrapping key never leaves the
 * TEE, which means the file on disk is worthless off this device and worthless to another app on
 * it — including after a `adb backup`, which `allowBackup="false"` already refuses.
 *
 * That is strictly better than `SharedPreferences`, which is where this sort of thing usually ends
 * up: a preferences XML is plaintext, readable by anything that can read the app's data directory,
 * and it survives being copied off a rooted phone intact.
 *
 * ## What a lost wrapping key means
 *
 * If the Keystore entry is gone — a restore onto another device, a lock-screen change on some
 * OEM builds, a factory reset of the secure hardware — the blob cannot be decrypted and there is
 * nothing to recover. The vault then reports "unpaired" and the file is deleted, because the
 * honest reading of "the credential cannot be read" is that this device has to pair again. It
 * never silently regenerates a key and pretends the pairing survived: that would produce a phone
 * that fails authentication forever with no explanation.
 */
interface DeviceVault {

    /** This device's static X25519 identity, created on first use and never regenerated silently. */
    fun identity(): StaticKeyPair

    /** What this device knows about a Mac, or null when it has never been paired. */
    fun pairing(): PairingRecord?

    /** A pairing code was accepted. Stores the host and the one-shot token; clears any credential. */
    fun beginPairing(hostId: String, hostStaticPublicKey: ByteArray, relayUrl: String, pairingToken: String)

    /** The desktop minted a durable credential in `welcome`. Replaces the pairing token. */
    fun storeCredential(token: String, deviceId: String, deviceName: String)

    /** The desktop admitted this device, so the approval wait is over. */
    fun markApproved()

    /** The desktop refused the credential. The host is kept so the pair screen can explain itself. */
    fun clearCredential()

    /** Forget the Mac entirely and rotate this device's key. */
    fun unpair()
}

/**
 * The pairing as this phone understands it.
 *
 * `token` is what goes in `hello` — the durable credential once there is one, the single-use
 * pairing token before that. The transport is not told which it is holding, for the same reason
 * `device-auth.ts` decides by shape rather than by being told: a transport that could tell the
 * difference would eventually branch on it.
 */
data class PairingRecord(
    val hostId: String,
    val hostStaticPublicKey: ByteArray,
    val relayUrl: String,
    val token: String?,
    val deviceId: String?,
    val deviceName: String?,
    val approved: Boolean,
    val pairedAt: Long,
) {
    /** True while the only thing this device holds is a pairing token it has not spent yet. */
    val isFresh: Boolean get() = token != null && !token.contains('.')

    override fun equals(other: Any?): Boolean = this === other || (other is PairingRecord &&
        hostId == other.hostId && token == other.token && approved == other.approved &&
        hostStaticPublicKey.contentEquals(other.hostStaticPublicKey))

    override fun hashCode(): Int = hostId.hashCode() * 31 + (token?.hashCode() ?: 0)
}

@Serializable
private data class VaultData(
    val version: Int = 1,
    val devicePrivateKey: String,
    val hostId: String? = null,
    val hostStaticPublicKey: String? = null,
    val relayUrl: String? = null,
    val token: String? = null,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val approved: Boolean = false,
    val pairedAt: Long = 0,
)

/* -------------------------------------------------------------------------- */

class KeystoreDeviceVault(context: Context) : DeviceVault {

    private val file = File(context.filesDir, FILE_NAME)
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val lock = Any()

    @Volatile
    private var cached: VaultData? = null

    override fun identity(): StaticKeyPair = synchronized(lock) {
        StaticKeyPair.fromPrivate(decodeBase64(state().devicePrivateKey))
    }

    override fun pairing(): PairingRecord? = synchronized(lock) {
        val data = state()
        val hostId = data.hostId ?: return null
        val hostKey = data.hostStaticPublicKey ?: return null
        val relay = data.relayUrl ?: return null
        PairingRecord(
            hostId = hostId,
            hostStaticPublicKey = decodeBase64(hostKey),
            relayUrl = relay,
            token = data.token,
            deviceId = data.deviceId,
            deviceName = data.deviceName,
            approved = data.approved,
            pairedAt = data.pairedAt,
        )
    }

    override fun beginPairing(
        hostId: String,
        hostStaticPublicKey: ByteArray,
        relayUrl: String,
        pairingToken: String,
    ) = synchronized(lock) {
        write(
            state().copy(
                hostId = hostId,
                hostStaticPublicKey = encodeBase64(hostStaticPublicKey),
                relayUrl = relayUrl,
                token = pairingToken,
                deviceId = null,
                deviceName = null,
                approved = false,
                pairedAt = System.currentTimeMillis(),
            )
        )
    }

    override fun storeCredential(token: String, deviceId: String, deviceName: String) = synchronized(lock) {
        write(state().copy(token = token, deviceId = deviceId, deviceName = deviceName))
    }

    override fun markApproved() = synchronized(lock) {
        val data = state()
        if (!data.approved) write(data.copy(approved = true))
    }

    override fun clearCredential() = synchronized(lock) {
        write(state().copy(token = null, approved = false))
    }

    override fun unpair() = synchronized(lock) {
        // The key is rotated rather than kept. A device public key the Mac still lists is a device
        // the Mac would let back in without a pairing code; unpairing should mean unpaired.
        write(VaultData(devicePrivateKey = encodeBase64(Sealed.generateStatic().privateKey)))
    }

    /* ------------------------------------------------------------------ disk -- */

    private fun state(): VaultData {
        cached?.let { return it }
        val loaded = read() ?: VaultData(devicePrivateKey = encodeBase64(Sealed.generateStatic().privateKey))
        cached = loaded
        if (!file.exists()) write(loaded)
        return loaded
    }

    private fun read(): VaultData? {
        if (!file.exists()) return null
        return try {
            val blob = file.readBytes()
            // [version][12-byte IV][ciphertext ‖ tag]
            if (blob.size < 1 + IV_BYTES + 16 || blob[0].toInt() != BLOB_VERSION) return discard()
            val iv = blob.copyOfRange(1, 1 + IV_BYTES)
            val body = blob.copyOfRange(1 + IV_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, iv))
            json.decodeFromString(VaultData.serializer(), cipher.doFinal(body).decodeToString())
        } catch (e: Exception) {
            // Every way this can fail — a rotated Keystore entry, a truncated file, a blob from a
            // future version — means the same thing to a caller.
            discard()
        }
    }

    private fun discard(): VaultData? {
        file.delete()
        return null
    }

    private fun write(data: VaultData) {
        cached = data
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val body = cipher.doFinal(json.encodeToString(VaultData.serializer(), data).toByteArray())
        val blob = ByteArray(1 + cipher.iv.size + body.size)
        blob[0] = BLOB_VERSION.toByte()
        cipher.iv.copyInto(blob, 1)
        body.copyInto(blob, 1 + cipher.iv.size)

        // Written beside and renamed: a process killed mid-write must not leave a half file that
        // reads as "this device was never paired".
        val temp = File(file.parentFile, "$FILE_NAME.tmp")
        temp.writeBytes(blob)
        if (!temp.renameTo(file)) {
            file.writeBytes(blob)
            temp.delete()
        }
    }

    /**
     * The AES-256-GCM key that wraps the blob, held by the Keystore and never exported.
     *
     * `setRandomizedEncryptionRequired` is the default and is stated anyway: it is what stops a
     * caller supplying an IV, and a repeated IV under GCM is catastrophic in the same way a
     * repeated nonce is for the sealed channel.
     */
    private fun wrappingKey(): SecretKey {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                // Deliberately not `setUserAuthenticationRequired(true)`: the transport reconnects
                // from the background when the network returns, and a key that needs the lock
                // screen would turn every reconnect into a notification asking for a fingerprint.
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val FILE_NAME = "device-vault.v1.bin"
        const val KEY_ALIAS = "terminaldeck.vault.v1"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val BLOB_VERSION = 1
    }
}

/* -------------------------------------------------------------------------- */

/**
 * A vault that forgets on relaunch.
 *
 * For unit tests and Compose previews only — the Keystore does not exist on a JVM. Named so that
 * nothing mistakes it for storage.
 */
class InMemoryDeviceVault(private val key: StaticKeyPair = Sealed.generateStatic()) : DeviceVault {
    private var record: PairingRecord? = null

    override fun identity(): StaticKeyPair = key

    override fun pairing(): PairingRecord? = record

    override fun beginPairing(hostId: String, hostStaticPublicKey: ByteArray, relayUrl: String, pairingToken: String) {
        record = PairingRecord(hostId, hostStaticPublicKey, relayUrl, pairingToken, null, null, false, System.currentTimeMillis())
    }

    override fun storeCredential(token: String, deviceId: String, deviceName: String) {
        record = record?.copy(token = token, deviceId = deviceId, deviceName = deviceName)
    }

    override fun markApproved() {
        record = record?.copy(approved = true)
    }

    override fun clearCredential() {
        record = record?.copy(token = null, approved = false)
    }

    override fun unpair() {
        record = null
    }
}

/**
 * `java.util.Base64`, not `android.util.Base64`.
 *
 * Available from API 26, which is this module's floor, and unlike the Android one it exists on a
 * plain JVM — so the types that use it stay unit-testable instead of returning zero under the
 * "not mocked" stub.
 */
private fun encodeBase64(bytes: ByteArray): String =
    java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

private fun decodeBase64(value: String): ByteArray = java.util.Base64.getUrlDecoder().decode(value)
