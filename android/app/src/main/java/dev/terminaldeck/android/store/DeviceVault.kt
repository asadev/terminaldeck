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
 * Everything this phone must not lose and must not leak: its static key, and one record per machine
 * it is paired with.
 *
 * ## One key, many machines
 *
 * The collection is keyed by host id. The static key is not: there is exactly one of them for every
 * machine, deliberately, because it is this phone's name in the sealed channel. A per-host key would
 * mean the same physical phone appearing as a stranger on a Mac that has already approved it, and
 * being approved again — twice in that Mac's device list, for one phone.
 *
 * What *is* per host is the credential, the host's static public key and the relay address. Those
 * are the three things that differ between a Mac and a Windows PC the same phone is talking to, and
 * nothing else does: the protocol is the same, the handshake is the same, and a phone genuinely
 * cannot tell one operating system from the other from anything on the wire.
 *
 * ## Adding a machine must never remove one
 *
 * This is the failure this whole shape exists to prevent. A phone that pairs with a second machine
 * and silently drops the first does not look like a missing feature — it looks like *the phone
 * forgot my Mac*, which is the complaint that gets an app deleted. So [beginPairing] writes one
 * record into a map and touches nothing else, and the only two things that remove a record are the
 * user asking ([forget], [unpairAll]) and a machine refusing the credential outright.
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
 * ## One blob, and what that costs
 *
 * Every machine lives in the same encrypted file rather than one file each. The iOS client makes the
 * opposite choice, and for a good reason there — a Keychain item per host means one unreadable
 * record cannot take the others with it. Here the trade is different: there is one wrapping key for
 * the whole app, so a Keystore entry that has gone takes every file with it whatever the layout, and
 * splitting the blob would buy nothing except a second structure that can disagree with the first
 * about which machines exist. What the layout must do instead is survive a *shape* change, which is
 * what the version field and [VaultData.folded] are for.
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

    /**
     * Every machine this phone is paired with, oldest pairing first.
     *
     * The order is the order they were added and never changes — not "most recently used", which
     * would reshuffle the switcher between one look and the next and have people tapping the row
     * that used to be there. Re-pairing an existing machine keeps its place for the same reason.
     */
    fun pairings(): List<PairingRecord>

    /** What this device knows about one machine, or null when it has never been paired with it. */
    fun pairing(hostId: String): PairingRecord?

    /**
     * A pairing code was accepted. Stores the host and the one-shot token; clears any credential.
     *
     * **Adds or updates that one record and leaves every other machine exactly as it was.** A
     * re-pair keeps the machine's place in the list and the name the user gave it, because pairing
     * again after a revoke is a normal thing to do and it must not cost either.
     */
    fun beginPairing(hostId: String, hostStaticPublicKey: ByteArray, relayUrl: String, pairingToken: String)

    /** That machine minted a durable credential in `welcome`. Replaces its pairing token. */
    fun storeCredential(hostId: String, token: String, deviceId: String, deviceName: String)

    /** That machine admitted this device, so its approval wait is over. */
    fun markApproved(hostId: String)

    /** That machine refused the credential. The record is kept so the pair screen can explain itself. */
    fun clearCredential(hostId: String)

    /** What the user calls this machine. Null clears it and the switcher falls back to the host id. */
    fun rename(hostId: String, nickname: String?)

    /** Forget one machine. The others, and this device's key, survive. */
    fun forget(hostId: String)

    /**
     * Forget every machine and rotate this device's key.
     *
     * The rotation is why this is not a loop over [forget]. A device public key a machine still
     * lists is a device that machine would let back in without a pairing code, so a phone that has
     * unpaired from *everything* should stop being that device. It follows that the key must not
     * rotate while any pairing remains: doing that would turn this phone into a stranger on every
     * machine that still trusts it, to remove it from one.
     */
    fun unpairAll()

    /** Which machine the screens were showing when the app was last used. Null before any choice. */
    fun selectedHost(): String?

    /** Remember the machine on screen, so a relaunch comes back to it rather than to the oldest. */
    fun selectHost(hostId: String?)
}

/**
 * One machine, as this phone understands it.
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
    /**
     * What the user calls this machine, if they have named it.
     *
     * Null is the normal state. It exists because a host id is 26 characters of base32 and the relay
     * address is the same for every machine behind that relay — neither is something a person can
     * pick their laptop out of a list by, and picking the right machine out of a list is the whole
     * of multi-host.
     */
    val nickname: String? = null,
) {
    /** True while the only thing this device holds is a pairing token it has not spent yet. */
    val isFresh: Boolean get() = token != null && !token.contains('.')

    /** What the switcher shows: the user's name for the machine, or enough of the id to tell it apart. */
    val label: String get() = nickname?.trim()?.takeIf { it.isNotEmpty() } ?: hostId.take(SHORT_ID_CHARS)

    override fun equals(other: Any?): Boolean = this === other || (other is PairingRecord &&
        hostId == other.hostId && token == other.token && approved == other.approved &&
        nickname == other.nickname && deviceName == other.deviceName &&
        hostStaticPublicKey.contentEquals(other.hostStaticPublicKey))

    override fun hashCode(): Int = hostId.hashCode() * 31 + (token?.hashCode() ?: 0)

    companion object {
        /**
         * Six characters of the host id when there is no nickname.
         *
         * Enough to tell two machines apart at a glance — the alphabet excludes the confusable
         * glyphs, so six of them is thirty bits — and short enough to sit in a title bar. The whole
         * 26 would be a row of noise that every machine's row looks identical to.
         */
        const val SHORT_ID_CHARS = 6
    }
}

/* -------------------------------------------------------------------------- */

@Serializable
private data class StoredHost(
    val hostId: String,
    val hostStaticPublicKey: String,
    val relayUrl: String,
    val token: String? = null,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val approved: Boolean = false,
    val pairedAt: Long = 0,
    val nickname: String? = null,
)

/**
 * The blob, and both shapes it has ever had.
 *
 * Version 1 held a single machine in top-level fields. Version 2 holds a list. The old fields are
 * still declared here rather than deleted, because deleting them is what would make a phone that has
 * been paired for weeks come back from an update with no Mac — the decode would simply not see them.
 * They are read by [folded] and written as null from then on.
 *
 * `version` is the *payload* version. The first byte of the file on disk is the envelope version and
 * is a different number about a different thing: how the bytes are wrapped, not what they say.
 */
@Serializable
private data class VaultData(
    val version: Int = CURRENT_VERSION,
    val devicePrivateKey: String,
    val hosts: List<StoredHost> = emptyList(),
    val currentHostId: String? = null,
    // Version 1. Only ever read; see above.
    val hostId: String? = null,
    val hostStaticPublicKey: String? = null,
    val relayUrl: String? = null,
    val token: String? = null,
    val deviceId: String? = null,
    val deviceName: String? = null,
    val approved: Boolean = false,
    val pairedAt: Long = 0,
) {
    /** True when this was written by a build that could only hold one machine. */
    val isLegacy: Boolean get() = hostId != null && hostStaticPublicKey != null && relayUrl != null

    /**
     * The same vault with the version-1 machine folded into the collection.
     *
     * Prepended rather than appended: it was paired before anything else in the list, and the list
     * is ordered oldest first. Skipped when the collection already knows that host, which is what
     * makes this safe to run on every read — the fold is not a migration step that can happen twice.
     */
    fun folded(): VaultData {
        if (!isLegacy) return this
        val existing = hosts.any { it.hostId == hostId }
        val merged = if (existing) {
            hosts
        } else {
            listOf(
                StoredHost(
                    hostId = hostId!!,
                    hostStaticPublicKey = hostStaticPublicKey!!,
                    relayUrl = relayUrl!!,
                    token = token,
                    deviceId = deviceId,
                    deviceName = deviceName,
                    approved = approved,
                    pairedAt = pairedAt,
                )
            ) + hosts
        }
        return VaultData(
            version = CURRENT_VERSION,
            devicePrivateKey = devicePrivateKey,
            hosts = merged,
            currentHostId = currentHostId ?: hostId,
        )
    }
}

private const val CURRENT_VERSION = 2

/* -------------------------------------------------------------------------- */

/**
 * How the blob is protected on the way to disk.
 *
 * Split out so the collection logic above it can be exercised on a plain JVM. That is not test
 * scaffolding for its own sake: the two things this file must never get wrong — a second pairing
 * that drops the first, and a version-1 blob that stops decoding — are both about what happens
 * across a write and a relaunch, and neither can be tested at all while reading the file requires
 * the Android Keystore.
 */
interface VaultCipher {

    fun seal(plaintext: ByteArray): ByteArray

    /** Null when the bytes cannot be opened, whatever the reason. See [DeviceVault]. */
    fun open(blob: ByteArray): ByteArray?
}

/**
 * AES-256-GCM under a key the Keystore holds and never exports.
 *
 * `setRandomizedEncryptionRequired` is the default and is stated anyway: it is what stops a
 * caller supplying an IV, and a repeated IV under GCM is catastrophic in the same way a
 * repeated nonce is for the sealed channel.
 */
class KeystoreVaultCipher : VaultCipher {

    override fun seal(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey())
        val body = cipher.doFinal(plaintext)
        // [version][12-byte IV][ciphertext ‖ tag]
        val blob = ByteArray(1 + cipher.iv.size + body.size)
        blob[0] = ENVELOPE_VERSION.toByte()
        cipher.iv.copyInto(blob, 1)
        body.copyInto(blob, 1 + cipher.iv.size)
        return blob
    }

    override fun open(blob: ByteArray): ByteArray? {
        if (blob.size < 1 + IV_BYTES + 16 || blob[0].toInt() != ENVELOPE_VERSION) return null
        return try {
            val iv = blob.copyOfRange(1, 1 + IV_BYTES)
            val body = blob.copyOfRange(1 + IV_BYTES, blob.size)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey(), GCMParameterSpec(128, iv))
            cipher.doFinal(body)
        } catch (e: Exception) {
            // Every way this can fail — a rotated Keystore entry, a truncated file, a tag that does
            // not verify — means the same thing to a caller.
            null
        }
    }

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
        const val KEY_ALIAS = "terminaldeck.vault.v1"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12

        /** How the bytes are wrapped. Unrelated to [CURRENT_VERSION], which is what they say. */
        const val ENVELOPE_VERSION = 1
    }
}

/* -------------------------------------------------------------------------- */

/**
 * The collection, in one sealed file.
 *
 * Every mutation reads the whole blob, changes one record and writes the whole blob back — which is
 * the only way to be sure that adding a machine cannot corrupt another one, because there is never
 * a moment when half of the change is on disk.
 */
open class FileDeviceVault(
    private val file: File,
    private val cipher: VaultCipher,
) : DeviceVault {

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val lock = Any()

    @Volatile
    private var cached: VaultData? = null

    override fun identity(): StaticKeyPair = synchronized(lock) {
        StaticKeyPair.fromPrivate(decodeBase64(state().devicePrivateKey))
    }

    override fun pairings(): List<PairingRecord> = synchronized(lock) {
        state().hosts.map { it.toRecord() }
    }

    override fun pairing(hostId: String): PairingRecord? = synchronized(lock) {
        state().hosts.firstOrNull { it.hostId == hostId }?.toRecord()
    }

    override fun beginPairing(
        hostId: String,
        hostStaticPublicKey: ByteArray,
        relayUrl: String,
        pairingToken: String,
    ): Unit = synchronized(lock) {
        val data = state()
        val existing = data.hosts.firstOrNull { it.hostId == hostId }
        val record = StoredHost(
            hostId = hostId,
            hostStaticPublicKey = encodeBase64(hostStaticPublicKey),
            relayUrl = relayUrl,
            token = pairingToken,
            deviceId = null,
            deviceName = null,
            approved = false,
            // A machine that is being paired again keeps the moment it was first paired and the
            // name it was given. Both are what stop a re-pair from moving a row in the switcher.
            pairedAt = existing?.pairedAt ?: System.currentTimeMillis(),
            nickname = existing?.nickname,
        )
        write(data.copy(hosts = data.hosts.replacingOrAdding(record)))
    }

    override fun storeCredential(hostId: String, token: String, deviceId: String, deviceName: String) {
        update(hostId) { it.copy(token = token, deviceId = deviceId, deviceName = deviceName) }
    }

    override fun markApproved(hostId: String) {
        update(hostId) { it.copy(approved = true) }
    }

    override fun clearCredential(hostId: String) {
        update(hostId) { it.copy(token = null, approved = false) }
    }

    override fun rename(hostId: String, nickname: String?) {
        update(hostId) { it.copy(nickname = nickname?.trim()?.takeIf { name -> name.isNotEmpty() }) }
    }

    override fun forget(hostId: String) {
        synchronized(lock) {
            val data = state()
            if (data.hosts.none { it.hostId == hostId }) return
            write(
                data.copy(
                    hosts = data.hosts.filterNot { it.hostId == hostId },
                    currentHostId = data.currentHostId?.takeIf { it != hostId },
                )
            )
        }
    }

    override fun unpairAll() {
        synchronized(lock) {
            write(VaultData(devicePrivateKey = encodeBase64(Sealed.generateStatic().privateKey)))
        }
    }

    override fun selectedHost(): String? = synchronized(lock) { state().currentHostId }

    override fun selectHost(hostId: String?) {
        synchronized(lock) {
            val data = state()
            if (data.currentHostId == hostId) return
            write(data.copy(currentHostId = hostId))
        }
    }

    /**
     * Change one machine's record and no other.
     *
     * Every per-host mutation goes through here, which is what makes "adding a machine cannot touch
     * another one" a property of one method rather than of five that have to keep agreeing.
     */
    private fun update(hostId: String, change: (StoredHost) -> StoredHost) {
        synchronized(lock) {
            val data = state()
            val existing = data.hosts.firstOrNull { it.hostId == hostId } ?: return
            val next = change(existing)
            if (next == existing) return
            write(data.copy(hosts = data.hosts.replacingOrAdding(next)))
        }
    }

    /* ------------------------------------------------------------------ disk -- */

    private fun state(): VaultData {
        cached?.let { return it }
        val loaded = read()
        if (loaded == null) {
            val fresh = VaultData(devicePrivateKey = encodeBase64(Sealed.generateStatic().privateKey))
            write(fresh)
            return fresh
        }
        val folded = loaded.folded()
        cached = folded
        // A version-1 blob is rewritten in its new shape now rather than whenever the next pairing
        // happens, so a phone that migrates and is then never paired again is not one restore away
        // from depending on code that has been deleted.
        if (loaded.isLegacy) write(folded)
        return folded
    }

    private fun read(): VaultData? {
        if (!file.exists()) return null
        val plain = cipher.open(file.readBytes()) ?: return discard()
        return try {
            json.decodeFromString(VaultData.serializer(), plain.decodeToString())
        } catch (e: Exception) {
            // A blob from a future version, or one this build cannot make sense of. Same answer as
            // a key that has gone: this device has to pair again.
            discard()
        }
    }

    private fun discard(): VaultData? {
        file.delete()
        return null
    }

    private fun write(data: VaultData) {
        cached = data
        val blob = cipher.seal(json.encodeToString(VaultData.serializer(), data).toByteArray())

        // Written beside and renamed: a process killed mid-write must not leave a half file that
        // reads as "this device was never paired" — which with several machines in one blob would
        // now lose all of them at once.
        val temp = File(file.parentFile, file.name + ".tmp")
        temp.writeBytes(blob)
        if (!temp.renameTo(file)) {
            file.writeBytes(blob)
            temp.delete()
        }
    }
}

/** Keyed replacement that keeps the list's order, so the switcher never reshuffles itself. */
private fun List<StoredHost>.replacingOrAdding(record: StoredHost): List<StoredHost> {
    val at = indexOfFirst { it.hostId == record.hostId }
    if (at < 0) return this + record
    return toMutableList().also { it[at] = record }
}

private fun StoredHost.toRecord(): PairingRecord = PairingRecord(
    hostId = hostId,
    hostStaticPublicKey = decodeBase64(hostStaticPublicKey),
    relayUrl = relayUrl,
    token = token,
    deviceId = deviceId,
    deviceName = deviceName,
    approved = approved,
    pairedAt = pairedAt,
    nickname = nickname,
)

/* -------------------------------------------------------------------------- */

/**
 * The vault the app runs on: the collection in a file, wrapped by a key the hardware holds.
 *
 * The file name still says `v1`. That is not an oversight — it is the name a phone that has been
 * paired for weeks already has on disk, and renaming it would be this build declaring every one of
 * those pairings lost. What the payload inside it says is version 2; see [VaultData].
 */
class KeystoreDeviceVault(context: Context) : FileDeviceVault(
    File(context.filesDir, FILE_NAME),
    KeystoreVaultCipher(),
)

private const val FILE_NAME = "device-vault.v1.bin"

/* -------------------------------------------------------------------------- */

/**
 * A vault that forgets on relaunch.
 *
 * For unit tests and Compose previews only — the Keystore does not exist on a JVM. Named so that
 * nothing mistakes it for storage. Tests that are about what survives a relaunch want
 * [FileDeviceVault] over a temporary file instead; this one cannot answer that question.
 */
class InMemoryDeviceVault(private val key: StaticKeyPair = Sealed.generateStatic()) : DeviceVault {

    private var rotated: StaticKeyPair? = null
    private val records = LinkedHashMap<String, PairingRecord>()
    private var current: String? = null

    override fun identity(): StaticKeyPair = rotated ?: key

    override fun pairings(): List<PairingRecord> = records.values.toList()

    override fun pairing(hostId: String): PairingRecord? = records[hostId]

    override fun beginPairing(hostId: String, hostStaticPublicKey: ByteArray, relayUrl: String, pairingToken: String) {
        val existing = records[hostId]
        records[hostId] = PairingRecord(
            hostId = hostId,
            hostStaticPublicKey = hostStaticPublicKey,
            relayUrl = relayUrl,
            token = pairingToken,
            deviceId = null,
            deviceName = null,
            approved = false,
            pairedAt = existing?.pairedAt ?: System.currentTimeMillis(),
            nickname = existing?.nickname,
        )
    }

    override fun storeCredential(hostId: String, token: String, deviceId: String, deviceName: String) {
        records[hostId] = records[hostId]?.copy(token = token, deviceId = deviceId, deviceName = deviceName) ?: return
    }

    override fun markApproved(hostId: String) {
        records[hostId] = records[hostId]?.copy(approved = true) ?: return
    }

    override fun clearCredential(hostId: String) {
        records[hostId] = records[hostId]?.copy(token = null, approved = false) ?: return
    }

    override fun rename(hostId: String, nickname: String?) {
        val trimmed = nickname?.trim()?.takeIf { it.isNotEmpty() }
        records[hostId] = records[hostId]?.copy(nickname = trimmed) ?: return
    }

    override fun forget(hostId: String) {
        records.remove(hostId)
        if (current == hostId) current = null
    }

    override fun unpairAll() {
        records.clear()
        current = null
        rotated = Sealed.generateStatic()
    }

    override fun selectedHost(): String? = current

    override fun selectHost(hostId: String?) {
        current = hostId
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
