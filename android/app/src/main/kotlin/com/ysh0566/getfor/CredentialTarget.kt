package com.ysh0566.getfor

import androidx.credentials.provider.CallingAppInfo
import java.net.URI
import java.util.Locale

internal data class CredentialTarget(
    val packageName: String,
    val webDomain: String? = null,
) {
    fun matches(website: String): Boolean {
        if (webDomain != null) {
            val domain = credentialDomain(webDomain) ?: return false
            // Match hosts, not substrings or guessed parent domains (which may be public suffixes).
            return credentialDomain(website) == domain
        }
        return packageName.isNotBlank() &&
            website.trim().removePrefix("androidapp://").removeSuffix("/") == packageName
    }

    fun filter(records: List<StoredCredential>, usernamePrefix: String = ""): List<StoredCredential> =
        records.filter { record ->
            record.password.isNotEmpty() && matches(record.website) &&
                record.username.startsWith(usernamePrefix, ignoreCase = true)
        }

    companion object {
        fun from(caller: CallingAppInfo): CredentialTarget = CredentialTarget(
            caller.packageName,
            PasskeyWebAuthn.verifiedOrigin(caller),
        )
    }
}

internal fun credentialDomain(value: String): String? = runCatching {
    val trimmed = value.trim()
    if (trimmed.isEmpty()) return null
    val uri = URI(if (trimmed.contains("://")) trimmed else "https://$trimmed")
    if (uri.scheme.lowercase(Locale.ROOT) !in setOf("http", "https")) return null
    uri.host?.lowercase(Locale.ROOT)?.removeSuffix(".")?.removePrefix("www.")
        ?.takeIf(String::isNotEmpty)
}.getOrNull()
