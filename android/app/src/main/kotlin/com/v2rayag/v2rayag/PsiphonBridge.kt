package com.v2rayag.v2rayag

import android.content.Context
import ca.psiphon.PsiphonTunnel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File

/**
 * Real wrapper around ca.psiphon:psiphontunnel (https://github.com/Psiphon-Labs/psiphon-tunnel-core-Android-library).
 * This talks to the actual Psiphon library API (PsiphonTunnel.HostService); it does not simulate
 * anything. Whether a tunnel can actually be established depends on the SponsorId and
 * PropagationChannelId supplied from Dart (see PsiphonBridge.setup) -- values that only
 * Psiphon Inc. can issue (see developer-support@psiphon.ca). Without them tunnel-core will run
 * but will not be authorized to use the Psiphon-operated network; this bridge reports that
 * honestly via the "failed" event rather than pretending to connect.
 *
 * Mode used here: local-proxy mode, exactly as Psiphon's own TunneledWebView sample app does
 * (PsiphonTunnel.startTunneling() + the HTTP/SOCKS local proxy ports it reports). Whole-device
 * mode is layered on top in Dart (v37): once this tunnel is connected, the app starts the
 * plugin core in VPN mode with an Xray config whose only outbound is a SOCKS proxy pointing
 * at this bridge's SOCKS port, so the plugin's VpnService + tun2socks forwards the whole
 * device through Psiphon. This bridge itself still opens no VpnService / TUN interface.
 */
/**
 * v48: application-scoped holder. The bridge used to live on MainActivity,
 * so when Android destroyed and recreated the activity (app window
 * closed and reopened while the tunnel/VPN kept running), the new
 * activity got a fresh bridge that knew nothing about the running
 * tunnel: the UI showed NOT CONNECTED while the device was still
 * connected, and nothing could stop the orphaned tunnel. One bridge
 * per process fixes both: a recreated activity reuses the same tunnel,
 * ports and state.
 */
object PsiphonBridgeHolder {
    private var instance: PsiphonBridge? = null
    fun get(ctx: Context): PsiphonBridge =
        instance ?: PsiphonBridge(ctx.applicationContext).also { instance = it }
}

class PsiphonBridge(private val context: Context) : PsiphonTunnel.HostService {

    private var tunnel: PsiphonTunnel? = null
    private var sink: EventChannel.EventSink? = null
    private var connected = false
    private var sponsorId = ""
    private var propagationChannelId = ""
    private var egressRegion = ""
    private var remoteServerListUrl = ""
    private var remoteServerListSignaturePublicKey = ""
    private var upstreamProxyUrl = ""
    private var socksPort = 0
    private var httpPort = 0

    fun attach(events: EventChannel) {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(args: Any?, s: EventChannel.EventSink) {
                sink = s
                // v48: a fresh Dart isolate (app reopened) subscribing
                // to a still-running tunnel must learn the current
                // state immediately, not wait for the next tunnel event
                // (which may never come). Re-emit ports + connected so
                // the new isolate can re-verify and restore the session.
                if (socksPort > 0) emit("socksPort", mapOf("port" to socksPort))
                if (httpPort > 0) emit("httpPort", mapOf("port" to httpPort))
                if (connected) emit("connected", mapOf("socksPort" to socksPort, "httpPort" to httpPort))
            }

            override fun onCancel(args: Any?) {
                sink = null
            }
        })
    }

    private fun emit(event: String, data: Map<String, Any?> = emptyMap()) {
        val m = HashMap<String, Any?>(data)
        m["event"] = event
        android.os.Handler(android.os.Looper.getMainLooper()).post { sink?.success(m) }
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configured" -> result.success(sponsorId.isNotBlank() && propagationChannelId.isNotBlank())
            // v48: current tunnel state for session restore (Dart
            // re-probes traffic itself before trusting these ports).
            "status" -> result.success(mapOf(
                "socksPort" to socksPort,
                "httpPort" to httpPort,
                "connected" to connected,
                "configured" to (sponsorId.isNotBlank() && propagationChannelId.isNotBlank()),
            ))
            "setup" -> {
                sponsorId = call.argument<String>("sponsorId") ?: ""
                propagationChannelId = call.argument<String>("propagationChannelId") ?: ""
                egressRegion = call.argument<String>("egressRegion") ?: ""
                remoteServerListUrl = call.argument<String>("remoteServerListUrl") ?: ""
                remoteServerListSignaturePublicKey = call.argument<String>("remoteServerListSignaturePublicKey") ?: ""
                upstreamProxyUrl = call.argument<String>("upstreamProxy") ?: ""
                result.success(null)
            }
            "start" -> {
                if (sponsorId.isBlank() || propagationChannelId.isBlank()) {
                    result.error("NOT_CONFIGURED", "SponsorId / PropagationChannelId not set", null)
                    return
                }
                Thread {
                    try {
                        tunnel?.stop()
                        connected = false
                        tunnel = PsiphonTunnel.newPsiphonTunnel(this)
                        emit("connecting")
                        tunnel!!.startTunneling("")
                        android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(null) }
                    } catch (e: Exception) {
                        emit("failed", mapOf("error" to (e.message ?: e.toString())))
                        android.os.Handler(android.os.Looper.getMainLooper()).post {
                            result.error("START_FAILED", e.message, null)
                        }
                    }
                }.start()
            }
            "stop" -> {
                Thread {
                    try {
                        tunnel?.stop()
                    } catch (e: Exception) {
                        // ignore: stop() is best-effort
                    }
                    connected = false
                    socksPort = 0
                    httpPort = 0
                    emit("stopped")
                    android.os.Handler(android.os.Looper.getMainLooper()).post { result.success(null) }
                }.start()
            }
            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------------------------
    // PsiphonTunnel.HostService -- real callbacks from ca.psiphon:psiphontunnel
    // ---------------------------------------------------------------------------------------

    override fun getContext(): Context = context

    /**
     * Required fields (per Psiphon's own config.go / MobileLibrary docs):
     * PropagationChannelId and SponsorId must be supplied by Psiphon Inc. for this build.
     * Ports 0 = let tunnel-core pick a free local port; it is reported back via
     * onListeningSocksProxyPort / onListeningHttpProxyPort below.
     */
    override fun getPsiphonConfig(): String {
        val dataDir = File(context.filesDir, "psiphon").apply { mkdirs() }
        val cfg = JSONObject()
        cfg.put("PropagationChannelId", propagationChannelId)
        cfg.put("SponsorId", sponsorId)
        cfg.put("DataStoreDirectory", dataDir.absolutePath)
        if (remoteServerListUrl.isNotBlank()) {
            cfg.put("RemoteServerListUrl", remoteServerListUrl)
            cfg.put("RemoteServerListDownloadFilename", "remote_server_list")
        }
        if (remoteServerListSignaturePublicKey.isNotBlank()) {
            cfg.put("RemoteServerListSignaturePublicKey", remoteServerListSignaturePublicKey)
        }
        // v46: user-chosen upstream SOCKS proxy (Custom Proxy option);
        // empty means the tunnel dials directly, as before.
        if (upstreamProxyUrl.isNotBlank()) {
            cfg.put("UpstreamProxyUrl", upstreamProxyUrl)
        }
        // v45: user-chosen egress country ('' = all regions). Psiphon
        // config field EgressRegion (ISO code); the tunnel then only
        // tries servers in that country.
        if (egressRegion.isNotBlank()) {
            cfg.put("EgressRegion", egressRegion)
        }
        cfg.put("LocalSocksProxyPort", 0)
        cfg.put("LocalHttpProxyPort", 0)
        cfg.put("EmitDiagnosticNotices", true)
        return cfg.toString()
    }

    override fun onListeningSocksProxyPort(port: Int) {
        socksPort = port
        emit("socksPort", mapOf("port" to port))
    }

    override fun onListeningHttpProxyPort(port: Int) {
        httpPort = port
        emit("httpPort", mapOf("port" to port))
    }

    override fun onConnecting() {
        emit("connecting")
    }

    override fun onConnected() {
        connected = true
        emit("connected", mapOf("socksPort" to socksPort, "httpPort" to httpPort))
    }

    override fun onStartedWaitingForNetworkConnectivity() {
        emit("waitingForNetwork")
    }

    override fun onAvailableEgressRegions(regions: MutableList<String>) {
        emit("regions", mapOf("regions" to regions))
    }

    override fun onDiagnosticMessage(message: String) {
        emit("log", mapOf("message" to message))
    }
}
