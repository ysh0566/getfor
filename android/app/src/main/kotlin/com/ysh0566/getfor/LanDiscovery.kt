package com.ysh0566.getfor

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

internal class LanDiscovery(context: Context, private val channel: MethodChannel) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var registration: NsdManager.RegistrationListener? = null
    private var discovery: NsdManager.DiscoveryListener? = null

    fun start(port: Int, deviceId: String, advertise: Boolean) {
        stop()
        if (advertise) {
            val registrationListener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(serviceInfo: NsdServiceInfo) = Unit
                override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) = Unit
                override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
            }
            registration = registrationListener
            manager.registerService(
                NsdServiceInfo().apply {
                    serviceName = "Getfor-${deviceId.take(8)}"
                    serviceType = SERVICE_TYPE
                    setPort(port)
                    setAttribute("v", "1")
                    setAttribute("id", deviceId)
                },
                NsdManager.PROTOCOL_DNS_SD,
                registrationListener,
            )
        }

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = stop()
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                manager.resolveService(
                    serviceInfo,
                    object : NsdManager.ResolveListener {
                        override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = Unit
                        override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                            val id = serviceInfo.attributes["id"]?.toString(Charsets.UTF_8) ?: return
                            if (id == deviceId) return
                            // Android delivers NSD callbacks on ConnectivityThread, while Flutter
                            // platform messages must always be dispatched from the main thread.
                            mainHandler.post {
                                channel.invokeMethod(
                                    "lanPeerFound",
                                    mapOf(
                                        "id" to id,
                                        "host" to serviceInfo.host.hostAddress,
                                        "port" to serviceInfo.port,
                                    ),
                                )
                            }
                        }
                    },
                )
            }
        }
        discovery = discoveryListener
        manager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    fun stop() {
        discovery?.let { runCatching { manager.stopServiceDiscovery(it) } }
        registration?.let { runCatching { manager.unregisterService(it) } }
        discovery = null
        registration = null
    }

    private companion object {
        const val SERVICE_TYPE = "_getfor._tcp."
    }
}
