package com.ysh0566.getfor

import android.app.Activity
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Bundle
import android.os.CancellationSignal
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPublicKeyCredentialOption
import androidx.credentials.GetPasswordOption
import androidx.credentials.PasswordCredential
import androidx.credentials.PublicKeyCredential
import androidx.credentials.provider.PendingIntentHandler

class CredentialResultActivity : Activity() {
    private var cancellationSignal: CancellationSignal? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val request = PendingIntentHandler.retrieveProviderGetCredentialRequest(intent)
        val passwordCredentialId = intent.getStringExtra(EXTRA_CREDENTIAL_ID)
        val passkeyCredentialId = intent.getByteArrayExtra(EXTRA_PASSKEY_CREDENTIAL_ID)
        if (request == null || (passwordCredentialId == null && passkeyCredentialId == null)) {
            finish()
            return
        }

        cancellationSignal = CancellationSignal()
        BiometricPrompt.Builder(this)
            .setTitle("解锁 Getfor 凭据")
            .setSubtitle("使用屏幕锁验证身份")
            .setAllowedAuthenticators(
                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
            )
            .build()
            .authenticate(
                cancellationSignal!!,
                mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        runCatching {
                            val store = CredentialStore(this@CredentialResultActivity)
                            val credential = if (passkeyCredentialId != null) {
                                val passkey = requireNotNull(store.findPasskey(passkeyCredentialId))
                                val option = request.credentialOptions
                                    .filterIsInstance<GetPublicKeyCredentialOption>()
                                    .first()
                                val options = PasskeyWebAuthn.parseRequestOptions(option.requestJson)
                                PublicKeyCredential(
                                    PasskeyWebAuthn.assertionResponse(
                                        passkey,
                                        options,
                                        request.callingAppInfo,
                                        option.clientDataHash,
                                    ),
                                )
                            } else {
                                val record = requireNotNull(store.get(passwordCredentialId!!))
                                require(CredentialTarget.from(request.callingAppInfo).matches(record.website))
                                require(request.credentialOptions.filterIsInstance<GetPasswordOption>().any {
                                    it.allowedUserIds.isEmpty() || record.username in it.allowedUserIds
                                })
                                PasswordCredential(record.username, record.password)
                            }
                            val response = Intent()
                            PendingIntentHandler.setGetCredentialResponse(
                                response,
                                GetCredentialResponse(credential),
                            )
                            setResult(RESULT_OK, response)
                            finish()
                        }.onFailure { finish() }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        finish()
                    }
                },
            )
    }

    override fun onDestroy() {
        cancellationSignal?.cancel()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_CREDENTIAL_ID = "credential_id"
        const val EXTRA_PASSKEY_CREDENTIAL_ID = "passkey_credential_id"
    }
}
