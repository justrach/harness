package harness.codegraff.android.model

// Home list search, status filter and grouping (HomeFilter.swift, HomeGrouping.swift).
// Search and status narrow the same recency-ordered list the grouping splits into
// sections, so a search inside "Project" grouping still reads by project.

enum class HomeStatusFilter(val label: String) {
    All("All"), Attention("Needs you"), Running("Running");

    /** Needs you: a question, an error, or a finished run not yet looked at. */
    fun matches(indicator: ChatIndicator): Boolean = when (this) {
        All -> true
        Attention -> indicator == ChatIndicator.AwaitingInput || indicator == ChatIndicator.Errored || indicator == ChatIndicator.Completed
        Running -> indicator == ChatIndicator.Working
    }
}

/** Names a session is searchable by that live outside the chat itself. */
data class HomeFilterNames(val project: String?, val device: String)

object HomeFilter {
    /**
     * Sessions whose status matches and whose title, last message, branch, folder, project or
     * device contains every word of [query]: "harness studio" finds the harness sessions on the
     * studio, not every session on either.
     */
    fun apply(
        chats: List<Chat>,
        query: String,
        status: HomeStatusFilter,
        indicator: (Chat) -> ChatIndicator,
        names: (Chat) -> HomeFilterNames,
    ): List<Chat> {
        val terms = query.split(Regex("\\s+")).filter { it.isNotEmpty() }
        return chats.filter { chat ->
            if (!status.matches(indicator(chat))) return@filter false
            if (terms.isEmpty()) return@filter true
            val extra = names(chat)
            val fields = listOfNotNull(
                chat.displayTitle, chat.lastMessagePreview, chat.branch,
                chat.cwd?.trimEnd('/')?.substringAfterLast('/'), extra.project, extra.device,
            )
            terms.all { term -> fields.any { it.contains(term, ignoreCase = true) } }
        }
    }
}

enum class HomeGroupBy(val label: String) {
    None("None"), Project("Project"), Device("Device");

    companion object {
        fun fromKey(key: String?): HomeGroupBy = entries.firstOrNull { it.name.lowercase() == key } ?: None
    }
}

data class HomeGroup(val id: String, val kind: Kind, val chats: List<Chat>) {
    sealed interface Kind {
        data object All : Kind
        /** null: sessions without a project. */
        data class Project(val spaceId: String?) : Kind
        data class Device(val deviceId: String) : Kind
    }
}

object HomeGrouping {
    fun groups(chats: List<Chat>, by: HomeGroupBy): List<HomeGroup> = when (by) {
        HomeGroupBy.None -> listOf(HomeGroup("all", HomeGroup.Kind.All, chats))
        HomeGroupBy.Project -> {
            val buckets = ordered(chats) { it.spaceId ?: "" }
            // Projectless sessions collect at the end rather than splitting the projects up.
            (buckets.filter { it.first.isNotEmpty() } + buckets.filter { it.first.isEmpty() }).map { (key, members) ->
                HomeGroup("project:$key", HomeGroup.Kind.Project(key.ifEmpty { null }), members)
            }
        }
        HomeGroupBy.Device -> ordered(chats) { it.deviceId }.map { (key, members) ->
            HomeGroup("device:$key", HomeGroup.Kind.Device(key), members)
        }
    }

    /** Buckets in order of first appearance, members in list order. */
    private fun ordered(chats: List<Chat>, key: (Chat) -> String): List<Pair<String, List<Chat>>> {
        val order = mutableListOf<String>()
        val buckets = HashMap<String, MutableList<Chat>>()
        for (chat in chats) {
            val bucket = key(chat)
            if (bucket !in buckets) order += bucket
            buckets.getOrPut(bucket) { mutableListOf() } += chat
        }
        return order.map { it to buckets.getValue(it) }
    }
}
