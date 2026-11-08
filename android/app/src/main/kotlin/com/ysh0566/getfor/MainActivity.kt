package com.ysh0566.getfor

import android.app.Activity
import android.content.Intent
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.credentials.CreatePasswordRequest
import androidx.credentials.CreatePasswordResponse
import androidx.credentials.provider.PendingIntentHandler
import androidx.credentials.provider.ProviderCreateCredentialRequest
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingCreate: ProviderCreateCredentialRequest? = null
    private var createRequestDelivered = false
    private var lanDiscovery: LanDiscovery? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).also { methodChannel ->
            methodChannel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "syncCredentials" -> {
                        val records = call.arguments as? List<*>
                        if (records == null) {
                            result.error("invalid_arguments", "Expected a credential list", null)
                        } else {
                            runCatching { CredentialStore(this).replace(records) }
                                .onSuccess { result.success(true) }
                                .onFailure { result.error("credential_store", it.message, null) }
                        }
                    }
                    "requestEnable" -> {
                        if (Build.VERSION.SDK_INT < 26) {
                            result.success(false)
                        } else {
                            runCatching {
                                startActivity(
                                    Intent(
                                        Settings.ACTION_REQUEST_SET_AUTOFILL_SERVICE,
                                        Uri.parse("package:$packageName"),
                                    ),
                                )
                            }
                                .onSuccess { result.success(true) }
                                .onFailure { result.error("credential_settings", it.message, null) }
                        }
                    }
                    "takePendingCreate" -> runCatching { takePendingCreate() }
                        .onSuccess(result::success)
                        .onFailure { result.error("credential_origin", it.message, null) }
                    "openBrowserAutoFillSettings" -> {
                        // Chrome has a separate opt-in before it forwards website fills to Android.
                        val settings = Intent(Intent.ACTION_APPLICATION_PREFERENCES)
                            .addCategory(Intent.CATEGORY_DEFAULT)
                            .addCategory(Intent.CATEGORY_APP_BROWSER)
                            .addCategory(Intent.CATEGORY_PREFERENCE)
                        runCatching {
                            check(settings.resolveActivity(packageManager) != null) {
                                "请在浏览器设置中选择使用其他自动填充服务，并重启浏览器"
                            }
                            startActivity(Intent.createChooser(settings, "选择浏览器"))
                        }.onSuccess { result.success(null) }
                            .onFailure { result.error("browser_settings", it.message, null) }
                    }
                    "takePendingPasskeys" -> runCatching {
                        CredentialStore(this).takePendingPasskeys().map { passkey ->
                            mapOf(
                                "credentialId" to passkey.credentialId,
                                "relyingPartyId" to passkey.relyingPartyId,
                                "userHandle" to passkey.userHandle,
                                "userName" to passkey.userName,
                                "userDisplayName" to passkey.userDisplayName,
                                "privateKeyPkcs8" to passkey.privateKeyPkcs8,
                                "backupEligible" to passkey.backupEligible,
                                "backupState" to passkey.backupState,
                            )
                        }
                    }.onSuccess(result::success)
                        .onFailure { result.error("pending_passkeys", it.message, null) }
                    "clearPendingPasskeys" -> runCatching {
                        CredentialStore(this).clearPendingPasskeys()
                    }.onSuccess { result.success(null) }
                        .onFailure { result.error("pending_passkeys", it.message, null) }
                    "completePendingCreate" -> {
                        completePendingCreate(call.argument<Boolean>("saved") == true)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        val lanChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ysh0566.getfor/lan_discovery",
        )
        lanDiscovery = LanDiscovery(this, lanChannel)
        lanChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    lanDiscovery?.start(
                        call.argument<Int>("port")!!,
                        call.argument<String>("deviceId")!!,
                        call.argument<Boolean>("advertise") == true,
                    )
                    result.success(null)
                }
                "stop" -> {
                    lanDiscovery?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val quickChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.ysh0566.getfor/quick_unlock",
        )
        quickChannel.setMethodCallHandler { call, result ->
            val store = CredentialStore(this)
            when (call.method) {
                "hasKey" -> result.success(store.hasQuickKey())
                "saveKey" -> runCatching { store.storeQuickKey(call.arguments as ByteArray) }
                    .onSuccess { result.success(null) }
                    .onFailure { result.error("quick_unlock", it.message, null) }
                "loadKey" -> {
                    if (Build.VERSION.SDK_INT < 30 || !store.hasQuickKey()) {
                        result.success(null)
                    } else {
                        BiometricPrompt.Builder(this)
                            .setTitle("解锁 Getfor")
                            .setAllowedAuthenticators(
                                BiometricManager.Authenticators.BIOMETRIC_STRONG or
                                    BiometricManager.Authenticators.DEVICE_CREDENTIAL,
                            )
                            .build()
                            .authenticate(
                                android.os.CancellationSignal(),
                                mainExecutor,
                                object : BiometricPrompt.AuthenticationCallback() {
                                    override fun onAuthenticationSucceeded(
                                        authenticationResult: BiometricPrompt.AuthenticationResult,
                                    ) {
                                        runCatching { store.loadQuickKey() }
                                            .onSuccess(result::success)
                                            .onFailure { result.error("quick_unlock", it.message, null) }
                                    }

                                    override fun onAuthenticationError(
                                        errorCode: Int,
                                        errString: CharSequence,
                                    ) {
                                        result.success(null)
                                    }
                                },
                            )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pendingCreate = null
        createRequestDelivered = false
        channel?.invokeMethod("credentialCreateReady", null)
    }

    override fun onDestroy() {
        lanDiscovery?.stop()
        super.onDestroy()
    }

    private fun takePendingCreate(): Map<String, String>? {
        if (createRequestDelivered || intent.action != ACTION_CREATE_PASSWORD) return null
        val providerRequest = pendingCreate
            ?: PendingIntentHandler.retrieveProviderCreateCredentialRequest(intent)?.also { pendingCreate = it }
            ?: return null
        val request = providerRequest.callingRequest as? CreatePasswordRequest ?: return null
        createRequestDelivered = true
        val appId = providerRequest.callingAppInfo.packageName
        val website = PasskeyWebAuthn.verifiedOrigin(providerRequest.callingAppInfo) ?: appId
        return mapOf(
            "title" to appId.substringAfterLast('.'),
            "website" to website,
            "username" to request.id,
            "password" to request.password,
        )
    }

    private fun completePendingCreate(saved: Boolean) {
        if (pendingCreate == null) return
        if (saved) {
            val response = Intent()
            PendingIntentHandler.setCreateCredentialResponse(response, CreatePasswordResponse())
            setResult(Activity.RESULT_OK, response)
        } else {
            setResult(Activity.RESULT_CANCELED)
        }
        pendingCreate = null
        createRequestDelivered = false
        finish()
    }

    companion object {
        const val ACTION_CREATE_PASSWORD = "com.ysh0566.getfor.CREATE_PASSWORD"
        private const val CHANNEL = "com.ysh0566.getfor/android_credentials"

        // Dart opens this library by name; loading it here also fails fast on packaging errors.
        init {
            System.loadLibrary("getfor_core")
        }
    }
}
