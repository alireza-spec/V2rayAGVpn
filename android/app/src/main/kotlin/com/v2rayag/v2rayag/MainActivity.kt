package com.v2rayag.v2rayag

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.ConnectivityManager
import android.net.Uri
import android.net.NetworkCapabilities
import android.net.TrafficStats
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    // v48: application-scoped bridge (see PsiphonBridgeHolder): a
    // recreated activity must reuse the running tunnel, not orphan it.
    private val psiphon get() = PsiphonBridgeHolder.get(applicationContext)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "v2rayag/psiphon").setMethodCallHandler { call, result ->
            psiphon.handle(call, result)
        }
        psiphon.attach(EventChannel(flutterEngine.dartExecutor.binaryMessenger, "v2rayag/psiphon/events"))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "v2rayag/native").setMethodCallHandler { call, result ->
            when (call.method) {
                "vpnActive" -> result.success(vpnActive())
                "bytes" -> {
                    val uid = Process.myUid()
                    result.success(listOf(TrafficStats.getUidRxBytes(uid), TrafficStats.getUidTxBytes(uid)))
                }
                "openUrl" -> {
                    try {
                        val i = Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "launchAction" -> {
                    // v10.1.8: the Quick Settings tile's action,
                    // consumed once so a later launch does not
                    // repeat it.
                    val a = intent.getStringExtra("v2rayag_action")
                    if (a != null) intent.removeExtra("v2rayag_action")
                    result.success(a)
                }
                "openVpnSettings" -> {
                    try {
                        val i = Intent(Settings.ACTION_VPN_SETTINGS)
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    } catch (e: Exception) {
                        result.success(false)
                    }
                }
                "launch" -> {
                    val pkg = call.argument<String>("pkg")
                    val i = if (pkg == null) null else packageManager.getLaunchIntentForPackage(pkg)
                    if (i != null) {
                        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(i)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "apps" -> {
                    Thread {
                        val list = installedApps()
                        Handler(Looper.getMainLooper()).post { result.success(list) }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /** True when Android itself reports an active VPN network. */
    private fun vpnActive(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        for (n in cm.allNetworks) {
            val c = cm.getNetworkCapabilities(n) ?: continue
            if (c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return true
        }
        return false
    }

    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        val out = ArrayList<Map<String, Any>>()
        for (a in pm.getInstalledApplications(0)) {
            if (a.packageName == packageName) continue
            val system = (a.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            if (system && pm.getLaunchIntentForPackage(a.packageName) == null) continue
            val m = HashMap<String, Any>()
            m["pkg"] = a.packageName
            m["name"] = pm.getApplicationLabel(a).toString()
            m["system"] = system
            m["icon"] = iconBytes(a.loadIcon(pm))
            out.add(m)
        }
        out.sortBy { (it["name"] as String).lowercase() }
        return out
    }

    private fun iconBytes(d: Drawable): ByteArray {
        val size = 64
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        d.setBounds(0, 0, size, size)
        d.draw(canvas)
        val s = ByteArrayOutputStream()
        bmp.compress(Bitmap.CompressFormat.PNG, 90, s)
        return s.toByteArray()
    }
}
