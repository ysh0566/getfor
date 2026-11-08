package com.ysh0566.getfor

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal data class StoredCredential(
    val id: String,
    val title: String,
    val website: String,
    val username: String,
    val password: String,
    val passkeys: List<StoredPasskey>,
)

internal data class StoredPasskey(
    val credentialId: ByteArray,
    val relyingPartyId: String,
    val userHandle: ByteArray,
    val userName: String,
    val userDisplayName: String,
    val privateKeyPkcs8: ByteArray,
    val backupEligible: Boolean = true,
    val backupState: Boolean = true,
) {
    fun privateKey(): PrivateKey = KeyFactory.getInstance("EC")
        .generatePrivate(PKCS8EncodedKeySpec(privateKeyPkcs8))
}

internal class CredentialStore(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    fun replace(values: List<*>) {
        val records = JSONArray()
        values.forEach { value ->
            val map = value as? Map<*, *> ?: error("Credential must be a map")
            val password = map.requiredString("password")
            val passkeys = (map["passkeys"] as? List<*>)?.map(::passkeyFromMap).orEmpty()
            if (password.isEmpty() && passkeys.isEmpty()) return@forEach
            records.put(
                JSONObject()
                    .put("id", map.requiredString("id"))
                    .put("title", map.requiredString("title"))
                    .put("website", map.requiredString("website"))
                    .put("username", map.requiredString("username"))
                    .put("password", password)
                    .put("passkeys", JSONArray(passkeys.map { it.toJson() })),
            )
        }
        writeEncrypted(PAYLOAD, records)
    }

    fun list(): List<StoredCredential> {
        val records = readEncrypted(PAYLOAD) ?: return emptyList()
        return buildList {
            for (index in 0 until records.length()) {
                val record = records.getJSONObject(index)
                add(
                    StoredCredential(
                        id = record.getString("id"),
                        title = record.getString("title"),
                        website = record.getString("website"),
                        username = record.getString("username"),
                        password = record.getString("password"),
                        passkeys = record.optJSONArray("passkeys")?.toPasskeys().orEmpty(),
                    ),
                )
            }
        }
    }

    fun get(id: String): StoredCredential? = list().firstOrNull { it.id == id }

    fun findPasskeys(relyingPartyId: String): List<StoredPasskey> = list()
        .flatMap(StoredCredential::passkeys)
        .filter { it.relyingPartyId == relyingPartyId }

    fun findPasskey(credentialId: ByteArray): StoredPasskey? = list()
        .asSequence()
        .flatMap { it.passkeys.asSequence() }
        .firstOrNull { it.credentialId.contentEquals(credentialId) }

    fun addCreatedPasskey(passkey: StoredPasskey) {
        // Validate imported/generated key material before it can reach the provider cache.
        passkey.privateKey()
        val pending = readEncrypted(PENDING_PASSKEYS) ?: JSONArray()
        if ((0 until pending.length()).none {
                pending.getJSONObject(it).getBytes("credentialId").contentEquals(passkey.credentialId)
            }
        ) {
            pending.put(passkey.toJson())
            writeEncrypted(PENDING_PASSKEYS, pending)
        }

        val records = list().toMutableList()
        val index = records.indexOfFirst {
            it.website == passkey.relyingPartyId && it.username == passkey.userName
        }
        if (index >= 0) {
            val record = records[index]
            records[index] = record.copy(passkeys = record.passkeys + passkey)
        } else {
            records += StoredCredential(
                id = "pending:${Base64.encodeToString(passkey.credentialId, Base64.NO_WRAP)}",
                title = passkey.relyingPartyId,
                website = passkey.relyingPartyId,
                username = passkey.userName,
                password = "",
                passkeys = listOf(passkey),
            )
        }
        writeStoredCredentials(records)
    }

    fun takePendingPasskeys(): List<StoredPasskey> {
        return readEncrypted(PENDING_PASSKEYS)?.toPasskeys().orEmpty()
    }

    fun clearPendingPasskeys() {
        check(preferences.edit().remove(PENDING_PASSKEYS).commit())
    }

    fun storeQuickKey(value: ByteArray) {
        require(value.size == 32)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val payload = cipher.iv + cipher.doFinal(value)
        check(preferences.edit().putString(QUICK_KEY, Base64.encodeToString(payload, Base64.NO_WRAP)).commit())
    }

    fun hasQuickKey(): Boolean = preferences.contains(QUICK_KEY)

    fun loadQuickKey(): ByteArray {
        val payload = Base64.decode(preferences.getString(QUICK_KEY, null), Base64.NO_WRAP)
        require(payload.size > IV_LENGTH)
        return Cipher.getInstance(TRANSFORMATION).run {
            init(
                Cipher.DECRYPT_MODE,
                secretKey(),
                GCMParameterSpec(128, payload.copyOfRange(0, IV_LENGTH)),
            )
            doFinal(payload.copyOfRange(IV_LENGTH, payload.size))
        }
    }

    private fun secretKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        // The key never leaves Android Keystore; the provider additionally requires user presence before use.
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            generateKey()
        }
    }

    private fun writeStoredCredentials(values: List<StoredCredential>) {
        val records = JSONArray(values.map { record ->
            JSONObject()
                .put("id", record.id)
                .put("title", record.title)
                .put("website", record.website)
                .put("username", record.username)
                .put("password", record.password)
                .put("passkeys", JSONArray(record.passkeys.map { it.toJson() }))
        })
        writeEncrypted(PAYLOAD, records)
    }

    private fun writeEncrypted(key: String, value: JSONArray) {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        val payload = cipher.iv + cipher.doFinal(value.toString().toByteArray(Charsets.UTF_8))
        check(preferences.edit().putString(key, Base64.encodeToString(payload, Base64.NO_WRAP)).commit()) {
            "Could not persist credentials"
        }
    }

    private fun readEncrypted(key: String): JSONArray? {
        val encoded = preferences.getString(key, null) ?: return null
        val payload = Base64.decode(encoded, Base64.NO_WRAP)
        require(payload.size > IV_LENGTH) { "Invalid credential payload" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            secretKey(),
            GCMParameterSpec(128, payload.copyOfRange(0, IV_LENGTH)),
        )
        return JSONArray(
            cipher.doFinal(payload.copyOfRange(IV_LENGTH, payload.size)).toString(Charsets.UTF_8),
        )
    }

    private fun passkeyFromMap(value: Any?): StoredPasskey {
        val map = value as? Map<*, *> ?: error("Passkey must be a map")
        return StoredPasskey(
            credentialId = map.requiredBytes("credentialId", 16..1024),
            relyingPartyId = map.requiredString("relyingPartyId").also(::validateRpId),
            userHandle = map.requiredBytes("userHandle", 1..64),
            userName = map.requiredString("userName").also { require(it.isNotEmpty()) },
            userDisplayName = map.requiredString("userDisplayName"),
            privateKeyPkcs8 = map.requiredBytes("privateKeyPkcs8", 64..2048),
            backupEligible = map["backupEligible"] as? Boolean ?: true,
            backupState = map["backupState"] as? Boolean ?: true,
        ).also { it.privateKey() }
    }

    private fun JSONArray.toPasskeys(): List<StoredPasskey> = buildList {
        for (index in 0 until length()) add(getJSONObject(index).toPasskey())
    }

    private fun JSONObject.toPasskey(): StoredPasskey = StoredPasskey(
        credentialId = getBytes("credentialId"),
        relyingPartyId = getString("relyingPartyId").also(::validateRpId),
        userHandle = getBytes("userHandle"),
        userName = getString("userName"),
        userDisplayName = optString("userDisplayName"),
        privateKeyPkcs8 = getBytes("privateKeyPkcs8"),
        backupEligible = optBoolean("backupEligible", true),
        backupState = optBoolean("backupState", true),
    ).also { it.privateKey() }

    private fun StoredPasskey.toJson(): JSONObject = JSONObject()
        .put("credentialId", Base64.encodeToString(credentialId, Base64.NO_WRAP))
        .put("relyingPartyId", relyingPartyId)
        .put("userHandle", Base64.encodeToString(userHandle, Base64.NO_WRAP))
        .put("userName", userName)
        .put("userDisplayName", userDisplayName)
        .put("privateKeyPkcs8", Base64.encodeToString(privateKeyPkcs8, Base64.NO_WRAP))
        .put("backupEligible", backupEligible)
        .put("backupState", backupState)

    private fun JSONObject.getBytes(key: String): ByteArray =
        Base64.decode(getString(key), Base64.NO_WRAP)

    private fun Map<*, *>.requiredBytes(key: String, allowed: IntRange): ByteArray {
        val value = this[key] as? ByteArray ?: error("Missing passkey field: $key")
        require(value.size in allowed)
        return value
    }

    private fun validateRpId(value: String) {
        require(value.length in 1..253 && RP_ID.matches(value)) { "Invalid relying party ID" }
    }

    private fun Map<*, *>.requiredString(key: String): String =
        this[key] as? String ?: error("Missing credential field: $key")

    private companion object {
        const val PREFERENCES = "credential_provider"
        const val PAYLOAD = "encrypted_credentials"
        const val PENDING_PASSKEYS = "pending_passkeys"
        const val QUICK_KEY = "quick_unlock_key"
        const val KEY_ALIAS = "getfor.credentials.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
        val RP_ID = Regex("^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")
    }
}
