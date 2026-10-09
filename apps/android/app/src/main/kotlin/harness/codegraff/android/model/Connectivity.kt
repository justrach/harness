package harness.codegraff.android.model

// What the phone may say about its connection and about each computer (Connectivity.swift, PresenceRule.swift and
// AppModel.hostNotice on iOS). The grace and presence rules themselves run in the native core; these are the
// screen-side rules and copy built on them.

/** The graced connectivity state: a source must stay degraded for 4 s before it shows; recovery shows at once. */
enum class Connection { Offline, Reconnecting, Connected }

data class ConnectivityUi(
    val state: Connection = Connection.Connected,
    /** Chats whose room is degraded past the grace. */
    val degradedChats: Set<String> = emptySet(),
    /** The soonest redial, epoch ms. */
    val retryAtMs: Long? = null,
)

/** Online on a beat in the last 45 s; offline only on positive evidence of absence; otherwise unknown. */
enum class HostStatus { Online, Unknown, Offline }

/** The one line the new-session screen may show above the composer, in order of what is actually wrong. */
enum class HostNotice { SignedOut, Reconnecting, Offline }

object ConnectivityRules {
    /**
     * AppModel.hostNotice: a dead sign-in first, then a phone that is not connected, then a host that is positively
     * gone. A host that is merely unconfirmed (just launched, a beat not yet in) gets no warning.
     */
    fun hostNotice(sessionExpired: Boolean, status: HostStatus, registryConnected: Boolean): HostNotice? = when {
        sessionExpired -> HostNotice.SignedOut
        status == HostStatus.Online -> null
        !registryConnected -> HostNotice.Reconnecting
        status == HostStatus.Offline -> HostNotice.Offline
        else -> null
    }

    /**
     * AppModel.chatDeliveryDegraded: a send would queue rather than deliver promptly when the phone is offline, the
     * chat's room is degraded (or, with no room dialed yet, the app is not connected), or the host is gone.
     */
    fun deliveryDegraded(connectivity: ConnectivityUi, chatId: String, roomActive: Boolean, host: HostStatus): Boolean {
        if (connectivity.state == Connection.Offline) return true
        if (roomActive) {
            if (chatId in connectivity.degradedChats) return true
        } else if (connectivity.state != Connection.Connected) {
            return true
        }
        return host == HostStatus.Offline
    }

    /** "Reconnecting in 5s…" while a redial is more than a second away, else "Reconnecting…". */
    fun reconnectingLabel(retryAtMs: Long?, now: Long): String {
        retryAtMs ?: return "Reconnecting…"
        val secs = Math.ceil((retryAtMs - now) / 1000.0).toLong()
        return if (secs > 1) "Reconnecting in ${secs}s…" else "Reconnecting…"
    }

    /** A computer's line in the host picker: not confirmed is not offline, and a send to it is still saved. */
    fun hostStatusLine(status: HostStatus): String = when (status) {
        HostStatus.Online -> "Online"
        HostStatus.Unknown -> "Not confirmed — sends are saved"
        HostStatus.Offline -> "Offline — sends are saved"
    }

    /** The composer's one quiet caption while sends would queue. */
    fun degradedCaption(state: Connection): String =
        if (state == Connection.Offline) "Offline — messages will send when you're back online."
        else "Messages will send once the connection recovers."
}
