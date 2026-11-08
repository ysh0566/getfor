package com.ysh0566.getfor

import android.app.Activity
import android.app.assist.AssistStructure
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Bundle
import android.os.CancellationSignal
import android.view.WindowManager
import android.view.autofill.AutofillId
import android.view.autofill.AutofillManager

class AutofillAuthenticationActivity : Activity() {
    private var cancellationSignal: CancellationSignal? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        val structure = intent.getParcelableExtra(
            AutofillManager.EXTRA_ASSIST_STRUCTURE,
            AssistStructure::class.java,
        )
        val focusedId = intent.getParcelableExtra(EXTRA_FOCUSED_ID, AutofillId::class.java)
        val fields = structure?.let { AutofillFields.from(it, focusedId) }
        if (fields == null) {
            cancel()
            return
        }

        cancellationSignal = CancellationSignal()
        BiometricPrompt.Builder(this)
            .setTitle("解锁 Getfor 自动填充")
            .setSubtitle("使用生物识别或屏幕锁验证身份")
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
                        val response = runCatching {
                            fields.response(
                                CredentialStore(this@AutofillAuthenticationActivity).list(),
                                packageName,
                            )
                        }.getOrNull()
                        if (response == null) {
                            cancel()
                            return
                        }
                        setResult(
                            RESULT_OK,
                            Intent().putExtra(
                                AutofillManager.EXTRA_AUTHENTICATION_RESULT,
                                response,
                            ),
                        )
                        finish()
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        cancel()
                    }
                },
            )
    }

    private fun cancel() {
        setResult(RESULT_CANCELED, Intent().putExtras(Bundle.EMPTY))
        finish()
    }

    override fun onDestroy() {
        cancellationSignal?.cancel()
        super.onDestroy()
    }

    companion object {
        const val EXTRA_FOCUSED_ID = "com.ysh0566.getfor.FOCUSED_ID"
    }
}
