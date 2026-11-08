package com.ysh0566.getfor

import android.app.PendingIntent
import android.content.Intent
import android.os.CancellationSignal
import android.os.OutcomeReceiver
import androidx.credentials.exceptions.ClearCredentialException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.CreateCredentialUnsupportedException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.GetCredentialUnknownException
import androidx.credentials.provider.BeginCreateCredentialRequest
import androidx.credentials.provider.BeginCreateCredentialResponse
import androidx.credentials.provider.BeginCreatePasswordCredentialRequest
import androidx.credentials.provider.BeginCreatePublicKeyCredentialRequest
import androidx.credentials.provider.BeginGetCredentialRequest
import androidx.credentials.provider.BeginGetCredentialResponse
import androidx.credentials.provider.BeginGetPasswordOption
import androidx.credentials.provider.BeginGetPublicKeyCredentialOption
import androidx.credentials.provider.CreateEntry
import androidx.credentials.provider.CredentialProviderService
import androidx.credentials.provider.PasswordCredentialEntry
import androidx.credentials.provider.PublicKeyCredentialEntry
import androidx.credentials.provider.ProviderClearCredentialStateRequest

class GetforCredentialProviderService : CredentialProviderService() {
    override fun onBeginGetCredentialRequest(
        request: BeginGetCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginGetCredentialResponse, GetCredentialException>,
    ) {
        runCatching {
            val records = CredentialStore(this).list()
            val response = BeginGetCredentialResponse.Builder()
            request.beginGetCredentialOptions.filterIsInstance<BeginGetPasswordOption>().forEach { option ->
                val caller = request.callingAppInfo ?: return@forEach
                CredentialTarget.from(caller).filter(records)
                    .filter { option.allowedUserIds.isEmpty() || it.username in option.allowedUserIds }
                    .forEach { record -> response.addCredentialEntry(record.entry(option)) }
            }
            request.beginGetCredentialOptions.filterIsInstance<BeginGetPublicKeyCredentialOption>().forEach { option ->
                val parsed = PasskeyWebAuthn.parseRequestOptions(option.requestJson)
                records
                    .flatMap(StoredCredential::passkeys)
                    .filter { passkey ->
                        passkey.relyingPartyId == parsed.relyingPartyId &&
                            (parsed.allowedCredentialIds.isEmpty() ||
                                parsed.allowedCredentialIds.any(passkey.credentialId::contentEquals))
                    }
                    .forEach { passkey -> response.addCredentialEntry(passkey.entry(option)) }
            }
            response.build()
        }.onSuccess(callback::onResult).onFailure {
            callback.onError(GetCredentialUnknownException(it.message))
        }
    }

    override fun onBeginCreateCredentialRequest(
        request: BeginCreateCredentialRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<BeginCreateCredentialResponse, CreateCredentialException>,
    ) {
        val intent = runCatching {
            when (request) {
                is BeginCreatePasswordCredentialRequest ->
                    Intent(this, MainActivity::class.java).setAction(MainActivity.ACTION_CREATE_PASSWORD)
                is BeginCreatePublicKeyCredentialRequest -> {
                    PasskeyWebAuthn.parseCreationOptions(request.requestJson)
                    Intent(this, PasskeyCreateActivity::class.java)
                }
                else -> throw CreateCredentialUnsupportedException()
            }
        }.getOrElse {
            callback.onError(
                it as? CreateCredentialException ?: CreateCredentialUnsupportedException(),
            )
            return
        }
        // Credential Manager must add the final request, so this explicit PendingIntent has to stay mutable.
        val pendingIntent = PendingIntent.getActivity(
            this,
            CREATE_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        callback.onResult(
            BeginCreateCredentialResponse.Builder()
                .addCreateEntry(CreateEntry.Builder("Getfor", pendingIntent).build())
                .build(),
        )
    }

    override fun onClearCredentialStateRequest(
        request: ProviderClearCredentialStateRequest,
        cancellationSignal: CancellationSignal,
        callback: OutcomeReceiver<Void?, ClearCredentialException>,
    ) {
        // Getfor does not keep sticky account selection state.
        callback.onResult(null)
    }

    private fun StoredCredential.entry(option: BeginGetPasswordOption): PasswordCredentialEntry {
        val intent = Intent(this@GetforCredentialProviderService, CredentialResultActivity::class.java)
            .putExtra(CredentialResultActivity.EXTRA_CREDENTIAL_ID, id)
        val pendingIntent = PendingIntent.getActivity(
            this@GetforCredentialProviderService,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        return PasswordCredentialEntry.Builder(
            this@GetforCredentialProviderService,
            username,
            pendingIntent,
            option,
        ).setDisplayName(title.ifEmpty { website }).build()
    }

    private fun StoredPasskey.entry(option: BeginGetPublicKeyCredentialOption): PublicKeyCredentialEntry {
        val intent = Intent(this@GetforCredentialProviderService, CredentialResultActivity::class.java)
            .putExtra(CredentialResultActivity.EXTRA_PASSKEY_CREDENTIAL_ID, credentialId)
        val pendingIntent = PendingIntent.getActivity(
            this@GetforCredentialProviderService,
            credentialId.contentHashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        return PublicKeyCredentialEntry.Builder(
            this@GetforCredentialProviderService,
            userName,
            pendingIntent,
            option,
        ).setDisplayName(userDisplayName.ifEmpty { userName }).build()
    }

    private companion object {
        const val CREATE_REQUEST_CODE = 0x474554
    }
}
