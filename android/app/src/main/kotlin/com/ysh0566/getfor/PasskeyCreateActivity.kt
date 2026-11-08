package com.ysh0566.getfor

import android.app.Activity
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Bundle
import android.os.CancellationSignal
import androidx.credentials.CreatePublicKeyCredentialRequest
import androidx.credentials.CreatePublicKeyCredentialResponse
import androidx.credentials.provider.PendingIntentHandler

class PasskeyCreateActivity : Activity() {
    private var cancellationSignal: CancellationSignal? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val providerRequest = PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)
        val request = providerRequest?.callingRequest as? CreatePublicKeyCredentialRequest
        if (providerRequest == null || request == null) {
            finishCanceled()
            return
        }
        val options = runCatching { PasskeyWebAuthn.parseCreationOptions(request.requestJson) }
            .getOrElse {
                finishCanceled()
                return
            }
        val store = CredentialStore(this)
        if (options.excludedCredentialIds.any { excluded -> store.findPasskey(excluded) != null }) {
            finishCanceled()
            return
        }

        // Asset Links verification performs network I/O and must finish before any private key is generated.
        Thread {
            val trusted = runCatching {
                PasskeyWebAuthn.verifyAssetLinks(options.relyingPartyId, providerRequest.callingAppInfo)
            }.getOrDefault(false)
            runOnUiThread {
                if (!trusted) finishCanceled() else authenticateAndCreate(
                    request,
                    providerRequest.callingAppInfo,
                    options,
                    store,
                )
            }
        }.start()
    }

    private fun authenticateAndCreate(
        request: CreatePublicKeyCredentialRequest,
        callingAppInfo: androidx.credentials.provider.CallingAppInfo,
        options: PasskeyWebAuthn.CreationOptions,
        store: CredentialStore,
    ) {
        cancellationSignal = CancellationSignal()
        BiometricPrompt.Builder(this)
            .setTitle("创建 ${options.relyingPartyName} 通行密钥")
            .setSubtitle("使用屏幕锁确认保存到 Getfor")
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
                            val created = PasskeyWebAuthn.create(
                                options,
                                callingAppInfo,
                                request.clientDataHash,
                            )
                            store.addCreatedPasskey(created.stored)
                            val response = Intent()
                            PendingIntentHandler.setCreateCredentialResponse(
                                response,
                                CreatePublicKeyCredentialResponse(created.registrationResponseJson),
                            )
                            setResult(RESULT_OK, response)
                            finish()
                        }.onFailure { finishCanceled() }
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        finishCanceled()
                    }
                },
            )
    }

    private fun finishCanceled() {
        setResult(RESULT_CANCELED)
        finish()
    }

    override fun onDestroy() {
        cancellationSignal?.cancel()
        super.onDestroy()
    }
}
