package com.v2rayag.v2rayag

import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/// v10.1.8: Quick Settings tile. It shows the live VPN state
/// (Android's own answer, same check as MainActivity's
/// vpnActive) and, on tap, launches the app with a
/// connect/disconnect action that Dart executes on startup.
/// The tile cannot drive the tunnel itself: the tunnel lives
/// in the Flutter engine, so the tap hands the action to the
/// app, which connects or disconnects with its current mode
/// and cached configs. The user adds the tile once from the
/// quick-settings edit panel; minSdk is 24, so no version
/// gating is needed (TileService needs API 24+).
class VpnTileService : TileService() {
    private fun vpnActive(): Boolean {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        for (n in cm.allNetworks) {
            val c = cm.getNetworkCapabilities(n) ?: continue
            if (c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return true
        }
        return false
    }

    override fun onStartListening() {
        super.onStartListening()
        val t = qsTile ?: return
        t.state = if (vpnActive()) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        t.updateTile()
    }

    override fun onClick() {
        super.onClick()
        val i = Intent(this, MainActivity::class.java)
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        i.putExtra("v2rayag_action", if (vpnActive()) "disconnect" else "connect")
        startActivityAndCollapse(i)
    }
}
