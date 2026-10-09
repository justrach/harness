package harness.codegraff.android.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import harness.codegraff.android.core.MobileCoreInterface

/**
 * The OS network path, for the core (NWPathMonitor in the iOS AppModel). Only a definitive "no network" parks the
 * rooms; every usable network broadcasts "online", and a switch between networks (wifi to cellular, which silently
 * kills open sockets) kicks every room instead of letting it sit out its backoff.
 */
object NetworkMonitor {
    fun start(context: Context, core: MobileCoreInterface) {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return
        manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                val usable = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                core.setNetwork(usable, key(network, capabilities))
            }

            override fun onLost(network: Network) {
                core.setNetwork(false, "down")
            }
        })
    }

    /** The network and its transports: the same network gaining or losing a transport is a different path. */
    private fun key(network: Network, capabilities: NetworkCapabilities): String {
        val transports = listOf(
            NetworkCapabilities.TRANSPORT_WIFI to "wifi",
            NetworkCapabilities.TRANSPORT_CELLULAR to "cellular",
            NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet",
            NetworkCapabilities.TRANSPORT_VPN to "vpn",
        ).filter { capabilities.hasTransport(it.first) }.joinToString(",") { it.second }
        return "up:$network:$transports"
    }
}
