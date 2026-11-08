package com.ysh0566.getfor

import android.util.Base64
import androidx.credentials.provider.CallingAppInfo
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

internal object PasskeyWebAuthn {
    data class CreationOptions(
        val relyingPartyId: String,
        val relyingPartyName: String,
        val userHandle: ByteArray,
        val userName: String,
        val userDisplayName: String,
        val challenge: String,
        val excludedCredentialIds: List<ByteArray>,
    )

    data class RequestOptions(
        val relyingPartyId: String,
        val challenge: String,
        val allowedCredentialIds: List<ByteArray>,
    )

    data class CreatedPasskey(
        val stored: StoredPasskey,
        val registrationResponseJson: String,
    )

    fun parseCreationOptions(value: String): CreationOptions {
        require(value.length <= MAX_REQUEST_JSON)
        val json = JSONObject(value)
        val rp = json.getJSONObject("rp")
        val user = json.getJSONObject("user")
        val algorithms = json.getJSONArray("pubKeyCredParams")
        require((0 until algorithms.length()).any { algorithms.getJSONObject(it).getInt("alg") == ES256 }) {
            "Relying party does not support ES256"
        }
        val rpId = rp.getString("id").lowercase().also(::validateRpId)
        val userHandle = decodeBase64Url(user.getString("id"))
        require(userHandle.size in 1..64)
        val excluded = json.optJSONArray("excludeCredentials")?.credentialIds().orEmpty()
        return CreationOptions(
            relyingPartyId = rpId,
            relyingPartyName = rp.optString("name", rpId).take(256),
            userHandle = userHandle,
            userName = user.getString("name").also { require(it.isNotBlank() && it.length <= 1024) },
            userDisplayName = user.optString("displayName").take(1024),
            challenge = json.getString("challenge").also { require(decodeBase64Url(it).isNotEmpty()) },
            excludedCredentialIds = excluded,
        )
    }

    fun parseRequestOptions(value: String): RequestOptions {
        require(value.length <= MAX_REQUEST_JSON)
        val json = JSONObject(value)
        return RequestOptions(
            relyingPartyId = json.getString("rpId").lowercase().also(::validateRpId),
            challenge = json.getString("challenge").also { require(decodeBase64Url(it).isNotEmpty()) },
            allowedCredentialIds = json.optJSONArray("allowCredentials")?.credentialIds().orEmpty(),
        )
    }

    fun create(
        options: CreationOptions,
        callingAppInfo: CallingAppInfo,
        clientDataHash: ByteArray?,
    ): CreatedPasskey {
        val credentialId = ByteArray(32).also(SecureRandom()::nextBytes)
        val keyPair = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }
        val stored = StoredPasskey(
            credentialId = credentialId,
            relyingPartyId = options.relyingPartyId,
            userHandle = options.userHandle,
            userName = options.userName,
            userDisplayName = options.userDisplayName,
            privateKeyPkcs8 = keyPair.private.encoded,
            backupEligible = true,
            backupState = true,
        )
        val clientData = clientData(
            type = "webauthn.create",
            challenge = options.challenge,
            callingAppInfo = callingAppInfo,
            suppliedHash = clientDataHash,
        )
        val authenticatorData = registrationAuthenticatorData(
            options.relyingPartyId,
            credentialId,
            keyPair.public as ECPublicKey,
        )
        val response = JSONObject()
            .put("id", encodeBase64Url(credentialId))
            .put("rawId", encodeBase64Url(credentialId))
            .put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put(
                "response",
                JSONObject()
                    .put("clientDataJSON", encodeBase64Url(clientData.json))
                    .put("attestationObject", encodeBase64Url(attestationObject(authenticatorData)))
                    .put("transports", JSONArray(listOf("internal", "hybrid")))
                    .put("publicKeyAlgorithm", ES256)
                    .put("publicKey", encodeBase64Url(keyPair.public.encoded)),
            )
        return CreatedPasskey(stored, response.toString())
    }

    fun assertionResponse(
        passkey: StoredPasskey,
        options: RequestOptions,
        callingAppInfo: CallingAppInfo,
        clientDataHash: ByteArray?,
    ): String {
        require(passkey.relyingPartyId == options.relyingPartyId)
        require(
            options.allowedCredentialIds.isEmpty() ||
                options.allowedCredentialIds.any(passkey.credentialId::contentEquals),
        )
        val clientData = clientData(
            type = "webauthn.get",
            challenge = options.challenge,
            callingAppInfo = callingAppInfo,
            suppliedHash = clientDataHash,
        )
        val authenticatorData = assertionAuthenticatorData(
            passkey.relyingPartyId,
            passkey.backupEligible,
            passkey.backupState,
        )
        val signature = Signature.getInstance("SHA256withECDSA").run {
            initSign(passkey.privateKey())
            update(authenticatorData)
            update(clientData.hash)
            sign()
        }
        return JSONObject()
            .put("id", encodeBase64Url(passkey.credentialId))
            .put("rawId", encodeBase64Url(passkey.credentialId))
            .put("type", "public-key")
            .put("authenticatorAttachment", "platform")
            .put("clientExtensionResults", JSONObject())
            .put(
                "response",
                JSONObject()
                    .put("clientDataJSON", encodeBase64Url(clientData.json))
                    .put("authenticatorData", encodeBase64Url(authenticatorData))
                    .put("signature", encodeBase64Url(signature))
                    .put("userHandle", encodeBase64Url(passkey.userHandle)),
            )
            .toString()
    }

    /** Verifies the Android app-to-site binding before a new credential is minted. */
    fun verifyAssetLinks(relyingPartyId: String, callingAppInfo: CallingAppInfo): Boolean {
        if (callingAppInfo.isOriginPopulated()) {
            return runCatching { callingAppInfo.getOrigin(PRIVILEGED_ALLOWLIST) }.getOrNull() != null
        }
        val fingerprint = certificateFingerprint(callingAppInfo)
        val connection = URL("https://$relyingPartyId/.well-known/assetlinks.json")
            .openConnection() as HttpURLConnection
        return try {
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.instanceFollowRedirects = false
            connection.inputStream.bufferedReader().use { reader ->
                val values = JSONArray(reader.readText())
                (0 until values.length()).any { index ->
                    val statement = values.getJSONObject(index)
                    val target = statement.optJSONObject("target") ?: return@any false
                    val relations = statement.optJSONArray("relation") ?: return@any false
                    target.optString("namespace") == "android_app" &&
                        target.optString("package_name") == callingAppInfo.packageName &&
                        relations.strings().contains("delegate_permission/common.get_login_creds") &&
                        target.optJSONArray("sha256_cert_fingerprints")
                            ?.strings()
                            ?.any { it.equals(fingerprint, ignoreCase = true) } == true
                }
            }
        } finally {
            connection.disconnect()
        }
    }

    fun verifiedOrigin(callingAppInfo: CallingAppInfo): String? =
        if (callingAppInfo.isOriginPopulated()) {
            // Only certificate-verified browsers may supply a website on behalf of an app.
            requireNotNull(callingAppInfo.getOrigin(PRIVILEGED_ALLOWLIST))
        } else null

    fun encodeBase64Url(value: ByteArray): String =
        Base64.encodeToString(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    fun decodeBase64Url(value: String): ByteArray =
        Base64.decode(value, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private data class ClientData(val json: ByteArray, val hash: ByteArray)

    private fun clientData(
        type: String,
        challenge: String,
        callingAppInfo: CallingAppInfo,
        suppliedHash: ByteArray?,
    ): ClientData {
        if (suppliedHash != null) {
            require(suppliedHash.size == 32)
            val origin = callingAppInfo.getOrigin(PRIVILEGED_ALLOWLIST)
            // Credential Manager already hashed the browser's exact client data; the JSON is only a placeholder.
            val placeholder = JSONObject()
                .put("type", type)
                .put("challenge", challenge)
                .put("origin", origin)
                .toString()
                .toByteArray()
            return ClientData(placeholder, suppliedHash)
        }
        val origin = "android:apk-key-hash:${certificateHash(callingAppInfo)}"
        val json = JSONObject()
            .put("type", type)
            .put("challenge", challenge)
            .put("origin", origin)
            .put("androidPackageName", callingAppInfo.packageName)
            .toString()
            .toByteArray()
        return ClientData(json, sha256(json))
    }

    private fun registrationAuthenticatorData(
        relyingPartyId: String,
        credentialId: ByteArray,
        publicKey: ECPublicKey,
    ): ByteArray {
        val output = ByteArrayOutputStream()
        output.write(sha256(relyingPartyId.toByteArray()))
        output.write(FLAG_UP or FLAG_UV or FLAG_BE or FLAG_BS or FLAG_AT)
        output.write(byteArrayOf(0, 0, 0, 0))
        output.write(ByteArray(16)) // All-zero AAGUID: Getfor has no vendor attestation certificate.
        output.write(byteArrayOf((credentialId.size shr 8).toByte(), credentialId.size.toByte()))
        output.write(credentialId)
        output.write(cosePublicKey(publicKey))
        return output.toByteArray()
    }

    private fun assertionAuthenticatorData(
        relyingPartyId: String,
        backupEligible: Boolean,
        backupState: Boolean,
    ): ByteArray {
        var flags = FLAG_UP or FLAG_UV
        if (backupEligible) flags = flags or FLAG_BE
        if (backupState) flags = flags or FLAG_BS
        return sha256(relyingPartyId.toByteArray()) + byteArrayOf(flags.toByte(), 0, 0, 0, 0)
    }

    private fun cosePublicKey(publicKey: ECPublicKey): ByteArray {
        val x = publicKey.w.affineX.toByteArray().toFixedUnsigned(32)
        val y = publicKey.w.affineY.toByteArray().toFixedUnsigned(32)
        val output = CborWriter()
        output.map(5)
        output.integer(1).integer(2) // kty: EC2
        output.integer(3).integer(ES256)
        output.integer(-1).integer(1) // crv: P-256
        output.integer(-2).bytes(x)
        output.integer(-3).bytes(y)
        return output.value()
    }

    private fun attestationObject(authenticatorData: ByteArray): ByteArray = CborWriter().run {
        map(3)
        text("fmt").text("none")
        text("attStmt").map(0)
        text("authData").bytes(authenticatorData)
        value()
    }

    private fun ByteArray.toFixedUnsigned(size: Int): ByteArray {
        val source = if (isNotEmpty() && first() == 0.toByte()) copyOfRange(1, this.size) else this
        require(source.size <= size)
        return ByteArray(size - source.size) + source
    }

    private fun JSONArray.credentialIds(): List<ByteArray> = buildList {
        for (index in 0 until length()) {
            val descriptor = getJSONObject(index)
            if (descriptor.optString("type") == "public-key") {
                add(decodeBase64Url(descriptor.getString("id")))
            }
        }
    }

    private fun JSONArray.strings(): List<String> =
        (0 until length()).map { getString(it) }

    private fun validateRpId(value: String) {
        require(value.length in 1..253 && RP_ID.matches(value)) { "Invalid relying party ID" }
    }

    private fun certificateHash(info: CallingAppInfo): String {
        val certificate = info.signingInfo.apkContentsSigners.first().toByteArray()
        return encodeBase64Url(sha256(certificate))
    }

    private fun certificateFingerprint(info: CallingAppInfo): String {
        val certificate = info.signingInfo.apkContentsSigners.first().toByteArray()
        return sha256(certificate).joinToString(":") { "%02X".format(it.toInt() and 0xff) }
    }

    private fun sha256(value: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(value)

    private class CborWriter {
        private val output = ByteArrayOutputStream()

        fun map(size: Int) = apply { major(5, size.toLong()) }
        fun text(value: String) = apply {
            val bytes = value.toByteArray()
            major(3, bytes.size.toLong())
            output.write(bytes)
        }
        fun bytes(value: ByteArray) = apply {
            major(2, value.size.toLong())
            output.write(value)
        }
        fun integer(value: Int) = apply {
            if (value >= 0) major(0, value.toLong()) else major(1, (-1L - value))
        }
        fun value(): ByteArray = output.toByteArray()

        private fun major(type: Int, value: Long) {
            when {
                value < 24 -> output.write((type shl 5) or value.toInt())
                value <= 0xff -> {
                    output.write((type shl 5) or 24)
                    output.write(value.toInt())
                }
                value <= 0xffff -> {
                    output.write((type shl 5) or 25)
                    output.write((value shr 8).toInt())
                    output.write(value.toInt())
                }
                else -> error("CBOR value is too large")
            }
        }
    }

    private const val MAX_REQUEST_JSON = 128 * 1024
    private const val ES256 = -7
    private const val FLAG_UP = 0x01
    private const val FLAG_UV = 0x04
    private const val FLAG_BE = 0x08
    private const val FLAG_BS = 0x10
    private const val FLAG_AT = 0x40
    private val RP_ID = Regex("^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$")

    // Minimal trusted browser list for V1; expand only from Google's signed-source allowlist.
    private const val PRIVILEGED_ALLOWLIST = """{"apps":[{"type":"android","info":{"package_name":"com.android.chrome","signatures":[{"build":"release","cert_fingerprint_sha256":"F0:FD:6C:5B:41:0F:25:CB:25:C3:B5:33:46:C8:97:2F:AE:30:F8:EE:74:11:DF:91:04:80:AD:6B:2D:60:DB:83"}]}}]}"""
}
