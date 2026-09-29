package harness.codegraff.android

// Runs the rules the SwiftUI and Compose apps must share against the JSON in apps/parity. The iOS app runs the same
// files in ParityTests.swift: the expected values are what the SwiftUI app does, so a change on either side that moves
// them fails a test on the other.

import harness.codegraff.android.model.ATTACHMENT_ONLY_TEXT
import harness.codegraff.android.model.AgentDescriptor
import harness.codegraff.android.model.AgentReadiness
import harness.codegraff.android.model.ChatGPTPhase
import harness.codegraff.android.model.ChatGPTPoll
import harness.codegraff.android.model.ChatGPTSignIn
import harness.codegraff.android.model.DeviceAgents
import harness.codegraff.android.model.OnboardingAgent
import harness.codegraff.android.model.AccountDeletion
import harness.codegraff.android.model.Chat
import harness.codegraff.android.model.HomeGroup
import harness.codegraff.android.model.HomeGroupBy
import harness.codegraff.android.model.HomeGrouping
import harness.codegraff.android.model.MessageQueue
import harness.codegraff.android.model.QueueAction
import harness.codegraff.android.model.QueueActionReply
import harness.codegraff.android.model.QueueComposerEdit
import harness.codegraff.android.model.QueueDeliveryGate
import harness.codegraff.android.model.QueueEditFinishResult
import harness.codegraff.android.model.QueueEditLease
import harness.codegraff.android.model.QueuedMessage
import harness.codegraff.android.perf.Perf
import harness.codegraff.android.perf.PerfPolicy
import harness.codegraff.android.perf.PerfBatchMeta
import harness.codegraff.android.perf.PerfHistograms
import harness.codegraff.android.perf.PerfMetric
import harness.codegraff.android.perf.PerfStatsBatch
import harness.codegraff.android.perf.PerfWindow
import harness.codegraff.android.perf.PerfSharing
import harness.codegraff.android.perf.PerfSpan
import harness.codegraff.android.perf.PerfTransport
import harness.codegraff.android.perf.PerfUploader
import harness.codegraff.android.ui.session.QueueUX
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

@OptIn(ExperimentalCoroutinesApi::class)
class ParityTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setUp() = Dispatchers.setMain(dispatcher)

    @After fun tearDown() = Dispatchers.resetMain()

    // Unit tests run with the app module as the working directory: apps/android/app.
    private val parity = File("../../parity")

    private fun load(path: String) = JSONObject(File(parity, path).readText())

    private fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }

    private fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }

    private fun JSONObject.rows(key: String) = getJSONArray(key).objects()

    private fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else getString(key)

    private fun JSONObject.intOrNull(key: String): Int? = if (isNull(key)) null else getInt(key)

    private fun JSONObject.list(key: String): List<String> = optJSONArray(key)?.strings().orEmpty()

    // MARK: Message queue (pure rules)

    @Test
    fun theImageOnlyTextMatches() {
        assertEquals(load("vectors/message-queue.json").getString("attachmentOnlyText"), ATTACHMENT_ONLY_TEXT)
    }

    @Test
    fun actionsCarryTheSameHostMethodsAndLabels() {
        val actions = load("vectors/message-queue.json").getJSONObject("actions")
        for ((key, action) in listOf("sendNow" to QueueAction.SendNow, "remove" to QueueAction.Remove)) {
            assertEquals(actions.getJSONObject(key).getString("method"), action.method)
            assertEquals(actions.getJSONObject(key).getString("label"), action.label)
        }
    }

    @Test
    fun labelOneLineAndNeighbour() {
        val queue = load("vectors/message-queue.json")
        for (c in queue.rows("label")) assertEquals("$c", c.stringOrNull("expect"), MessageQueue.label(c.getInt("count")))
        for (c in queue.rows("oneLine")) assertEquals("$c", c.getString("expect"), MessageQueue.oneLine(c.getString("text")))
        for (c in queue.rows("neighbour")) {
            assertEquals("$c", c.intOrNull("expect"), MessageQueue.neighbour(c.getInt("from"), c.getInt("direction"), c.getInt("count")))
        }
    }

    @Test
    fun editedAndVisibleText() {
        val queue = load("vectors/message-queue.json")
        for (c in queue.rows("editedText")) {
            assertEquals("$c", c.stringOrNull("expect"), MessageQueue.editedText(c.getString("text"), c.getBoolean("hasAttachments")))
        }
        for (c in queue.rows("visibleText")) {
            assertEquals("$c", c.getString("expect"), MessageQueue.visibleText(c.getString("text"), c.getJSONArray("attachments").strings()))
        }
    }

    private fun gate(kind: String?): QueueDeliveryGate? = when (kind) {
        "reviewRequired" -> QueueDeliveryGate.ReviewRequired("mac")
        "editing" -> QueueDeliveryGate.Editing("mac", 60_000)
        else -> null
    }

    private fun action(name: String?) = if (name == "remove") QueueAction.Remove else QueueAction.SendNow

    private fun reply(value: JSONObject) = QueueActionReply(
        sent = if (value.has("sent")) value.getBoolean("sent") else null,
        removed = if (value.has("removed")) value.getBoolean("removed") else null,
    )

    @Test
    fun primaryActionAndAcknowledgement() {
        val queue = load("vectors/message-queue.json")
        for (c in queue.rows("primaryAction")) {
            val item = QueuedMessage("q", "hello", attachments = c.getJSONArray("attachments").strings(), deliveryGate = gate(c.stringOrNull("gate")))
            val expected = c.stringOrNull("expect")?.let { QueueAction.SendNow }
            assertEquals("$c", expected, MessageQueue.primaryAction(item, c.getBoolean("supportsActions"), c.getBoolean("pending")))
        }
        for (c in queue.rows("acknowledged")) {
            assertEquals("$c", c.getBoolean("expect"), reply(c.getJSONObject("reply")).acknowledged(action(c.getString("action"))))
        }
    }

    @Test
    fun composerEditRules() {
        val queue = load("vectors/message-queue.json")
        for (c in queue.rows("composerEdit")) {
            val lease = QueueEditLease("row", "lease", c.getString("leaseText"), "hash", 60_000)
            val edit = QueueComposerEdit(lease, "draft", c.getBoolean("hasAttachments"))
            assertEquals(c.getString("name"), c.stringOrNull("expect"), edit.textToCommit(c.getString("commit")))
        }
        val results = mapOf(
            "missing" to QueueEditFinishResult.Missing, "lost" to QueueEditFinishResult.Lost, "finished" to QueueEditFinishResult.Finished,
            "conflict" to QueueEditFinishResult.Conflict, "unavailable" to QueueEditFinishResult.Unavailable,
        )
        for (c in queue.rows("editResults")) {
            var edit = QueueComposerEdit(QueueEditLease("row", "lease", "queued", "hash", 1), "draft", false)
            for (name in c.getJSONArray("results").strings()) edit = edit.receive(results.getValue(name))
            assertEquals("$c", c.getBoolean("terminal"), edit.terminal)
        }
    }

    // MARK: Message queue (the model)

    private val chat = "chat-parity"

    private fun AppModel.texts() = queue(chat).rows.map { it.text }

    private fun AppModel.idOf(text: String) = queue(chat).rows.first { it.text == text }.id

    @Test
    fun enqueueRules() {
        val spec = load("vectors/message-queue.json").getJSONObject("enqueue")
        val model = AppModel()
        for (row in spec.rows("rows")) {
            val accepted = model.enqueueMessage(chat, row.getString("text"), row.getJSONArray("attachments").strings()) != null
            assertEquals("$row", row.getBoolean("expectAccepted"), accepted)
        }
        assertEquals(spec.list("expectTexts"), model.texts())
        assertTrue(model.queue(chat).rows.all { it.holdForTurnEnd == spec.getBoolean("expectHoldForTurnEnd") })
    }

    @Test
    fun moveRules() {
        val spec = load("vectors/message-queue.json").getJSONObject("moves")
        val model = AppModel()
        for (text in spec.list("texts")) model.enqueueMessage(chat, text)
        for (step in spec.rows("steps")) {
            val id = model.idOf(step.getString("row"))
            if (step.getString("op") == "by") model.moveQueuedBy(chat, id, step.getInt("by")) else model.moveQueued(chat, id, step.getInt("to"))
            assertEquals("$step", step.list("expect"), model.texts())
        }
    }

    @Test
    fun hostActionRules() = runTest {
        for (scenario in load("vectors/message-queue.json").rows("actionScenarios")) {
            val name = scenario.getString("name")
            val model = AppModel()
            for (text in scenario.list("texts")) model.enqueueMessage(chat, text)
            val target = model.idOf(scenario.getString("target"))
            scenario.stringOrNull("gate")?.let { model.setDeliveryGateForTesting(chat, target, gate(it)) }
            var invoked = false
            val throwing = scenario.opt("reply") == "throw"
            val canned = (scenario.opt("reply") as? JSONObject)?.let(::reply) ?: QueueActionReply()
            val ok = model.performQueueAction(chat, target, action(scenario.getString("action"))) { _, _ ->
                invoked = true
                if (throwing) error("host offline")
                canned
            }
            assertEquals(name, scenario.getBoolean("expectOk"), ok)
            assertEquals(name, scenario.list("expectTexts"), model.texts())
            assertEquals(name, scenario.stringOrNull("expectError"), model.queue(chat).error)
            if (scenario.has("expectCalled")) assertEquals(name, scenario.getBoolean("expectCalled"), invoked)
            assertTrue(name, model.queue(chat).pending.isEmpty())
        }
    }

    @Test
    fun anInFlightActionBlocksCompetingOnes() = runTest {
        val spec = load("vectors/message-queue.json").getJSONObject("inFlight")
        val model = AppModel()
        for (text in spec.list("texts")) model.enqueueMessage(chat, text)
        val target = model.idOf(spec.getString("target"))
        val before = model.texts()
        val ok = model.performQueueAction(chat, target, QueueAction.Remove) { method, _ ->
            assertEquals(spec.getString("expectMethod"), method)
            assertEquals(spec.list("expectTextsDuringCall"), model.texts())
            assertEquals(spec.getBoolean("expectPendingDuringCall"), target in model.queue(chat).pending)
            model.moveQueued(chat, target, 1)
            assertEquals("a row with an action in flight must not move", before, model.texts())
            val competing = model.performQueueAction(chat, target, QueueAction.SendNow) { _, _ ->
                error("an in-flight action must prevent a competing one")
            }
            assertFalse(competing)
            QueueActionReply(removed = true)
        }
        assertTrue(ok)
        assertEquals(spec.list("expectTextsAfter"), model.texts())
    }

    // MARK: Account deletion

    @Test
    fun accountDeletionAnswers() {
        for (c in load("vectors/account-deletion.json").rows("cases")) {
            val name = c.getString("name")
            val expect = c.getJSONObject("expect")
            when (val outcome = AccountDeletion.from(c.getInt("status"), c.getString("body"))) {
                AccountDeletion.Deleted -> assertEquals(name, "deleted", expect.getString("kind"))
                is AccountDeletion.Refused -> {
                    assertEquals(name, "refused", expect.getString("kind"))
                    assertEquals(name, expect.getString("message"), outcome.message)
                    val tokens = expect.optJSONObject("tokens")
                    assertEquals(name, tokens?.getString("accessToken"), outcome.tokens?.accessToken)
                    assertEquals(name, tokens?.getString("refreshToken"), outcome.tokens?.refreshToken)
                }
            }
        }
    }

    // MARK: Home grouping

    @Test
    fun homeGroupingMatches() {
        val vectors = load("vectors/home-grouping.json")
        val chats = vectors.rows("chats").map {
            Chat(id = it.getString("id"), deviceId = it.getString("deviceId"), createdAt = 0, spaceId = it.stringOrNull("spaceId"))
        }
        for (c in vectors.rows("cases")) {
            val name = c.getString("name")
            val groups = HomeGrouping.groups(chats, HomeGroupBy.fromKey(c.getString("by")), c.list("pinned").toSet())
            val expected = c.rows("expect")
            assertEquals(name, expected.map { it.getString("id") }, groups.map { it.id })
            assertEquals(name, expected.map { it.getString("kind") }, groups.map { kindName(it.kind) })
            assertEquals(name, expected.map { it.list("chats") }, groups.map { g -> g.chats.map { it.id } })
        }
    }

    private fun kindName(kind: HomeGroup.Kind) = when (kind) {
        HomeGroup.Kind.All -> "all"
        HomeGroup.Kind.Pinned -> "pinned"
        is HomeGroup.Kind.Project -> "project"
        is HomeGroup.Kind.Device -> "device"
    }

    // MARK: UX contract

    private fun kotlinSources(): String =
        File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.joinToString("\n") { it.readText() }

    @Test
    fun everyContractStringIsInTheComposeSource() {
        val strings = load("ux-contract.json").getJSONObject("strings")
        val source = kotlinSources()
        for (group in strings.keys()) {
            for (value in strings.getJSONArray(group).strings()) {
                assertTrue("$group: \"$value\" is missing from the Compose app", source.contains("\"$value\""))
            }
        }
    }

    @Test
    fun theQueuePanelIsLaidOutWithTheContractNumbers() {
        val layout = load("ux-contract.json").getJSONObject("queuePanelLayout")
        assertEquals(layout.getInt("rowHeightDp"), QueueUX.ROW_HEIGHT_DP)
        assertEquals(layout.getInt("rowGapDp"), QueueUX.ROW_GAP_DP)
        assertEquals(layout.getInt("maxVisibleRows"), QueueUX.MAX_VISIBLE_ROWS)
        assertEquals(layout.getInt("controlSizeDp"), QueueUX.CONTROL_SIZE_DP)
        // The same height QueuePanelView.swift computes for any queue length.
        val row = layout.getInt("rowHeightDp")
        val gap = layout.getInt("rowGapDp")
        val most = layout.getInt("maxVisibleRows")
        for (count in 0..8) {
            val visible = minOf(count, most)
            assertEquals("count $count", visible * row + maxOf(0, visible - 1) * gap, QueueUX.listHeightDp(count))
        }
    }

    // MARK: Bring in your agent

    @Test
    fun theAgentReadinessRulesMatch() {
        val v = load("vectors/agent-readiness.json")
        assertEquals(v.getJSONArray("agents").strings(), OnboardingAgent.ALL.map { it.id })
        assertEquals(v.getString("downloadUrl"), AgentReadiness.DOWNLOAD_URL)
        for (c in v.rows("cases")) {
            val devices = c.rows("devices").map { d ->
                DeviceAgents(
                    d.getString("id"), d.getString("name"), d.getBoolean("online"),
                    d.rows("agents").map { a ->
                        AgentDescriptor(
                            a.getString("id"),
                            installed = if (a.has("installed")) a.getBoolean("installed") else true,
                            canInstall = if (a.has("canInstall")) a.getBoolean("canInstall") else false,
                            enabled = if (a.has("enabled")) a.getBoolean("enabled") else null,
                        )
                    },
                )
            }
            val report = AgentReadiness.evaluate(devices)
            val expected = c.getJSONObject("expect")
            val name = c.getString("name")
            assertEquals(name, expected.getString("state"), report.state.name.replaceFirstChar { it.lowercase() })
            val rows = expected.rows("agents")
            assertEquals(name, rows.map { it.getString("id") }, report.rows.map { it.agent.id })
            assertEquals(name, rows.map { it.getString("status") }, report.rows.map { it.status.wireName })
            assertEquals(name, rows.map { it.getJSONArray("devices").strings() }, report.rows.map { it.deviceIds })
        }
    }

    @Test
    fun theChatGPTSignInRulesMatch() {
        val v = load("vectors/chatgpt-sign-in.json")
        assertEquals(v.getString("manageUsageUrl"), ChatGPTSignIn.MANAGE_USAGE_URL)
        assertEquals(v.getJSONArray("phases").strings(), ChatGPTPhase.entries.map { it.wireName })
        val actions = v.getJSONObject("actions")
        for (phase in ChatGPTPhase.entries) {
            assertEquals(phase.wireName, actions.getString(phase.wireName), ChatGPTSignIn.action(phase).wireName)
        }
        for (c in v.rows("polls")) {
            val poll = ChatGPTPoll(c.getString("status"), if (c.has("planUsage")) c.getBoolean("planUsage") else null)
            assertEquals(c.getString("name"), c.getString("phase"), ChatGPTSignIn.phase(poll).wireName)
        }
        val plan = v.getJSONObject("plan")
        for (c in plan.rows("models")) {
            assertEquals(c.optString("model"), c.getBoolean("usesPlan"), ChatGPTSignIn.usesPlan(if (c.isNull("model")) null else c.getString("model")))
        }
        for (c in plan.rows("limits")) {
            assertEquals(c.getString("message"), c.getBoolean("limit"), ChatGPTSignIn.isUsageLimit(c.getString("message")))
        }
    }

    // MARK: Performance monitor

    @Test
    fun theMonitorTimesTheSameOperationsAgainstTheSameBudgets() {
        val contract = load("perf-contract.json").getJSONObject("spans")
        val expected = contract.keys().asSequence().associateWith { contract.getDouble(it) }
        assertEquals(expected, PerfSpan.budgetsMs)
    }

    /** Numbers compared as doubles, so 5 and 5.0 from two JSON libraries are the same value. */
    private fun canon(value: Any?): Any? = when (value) {
        is JSONObject -> value.keys().asSequence().associateWith { canon(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { canon(value.get(it)) }
        is Number -> value.toDouble()
        JSONObject.NULL -> null
        else -> value
    }

    private fun stats() = load("vectors/perf-stats.json")

    @Test
    fun theBucketBoundsAndMetricNamesAreTheSharedOnes() {
        val v = stats()
        assertEquals(v.getJSONArray("bucketsMs").let { a -> (0 until a.length()).map { a.getDouble(it) } }, PerfHistograms.BUCKETS_MS.toList())
        assertEquals(v.getJSONArray("metricOrder").strings(), PerfMetric.ORDER)
        assertEquals(v.getString("schema"), PerfStatsBatch.SCHEMA)
        assertEquals(v.getDouble("maxSampleMs"), PerfHistograms.MAX_SAMPLE_MS, 0.0)
        assertEquals(v.getInt("maxDeviceLength"), PerfStatsBatch.MAX_DEVICE_LENGTH)
        assertEquals(v.getInt("maxVersionLength"), PerfStatsBatch.MAX_VERSION_LENGTH)
        assertEquals(v.getLong("maxWindowMs"), PerfHistograms.MAX_WINDOW_MS)
        assertEquals(v.getJSONObject("refreshHz").getInt("min"), PerfStatsBatch.MIN_REFRESH_HZ)
        assertEquals(v.getJSONObject("refreshHz").getInt("max"), PerfStatsBatch.MAX_REFRESH_HZ)
        assertEquals(v.getLong("minIntervalMs"), PerfUploader.MIN_INTERVAL_MS)
        assertEquals(v.getBoolean("sharingDefault"), PerfSharing.DEFAULT_ENABLED)
        assertEquals(v.getString("endpoint"), PerfSharing.endpoint)
        assertTrue(PerfTransport.isAllowed(v.getString("endpoint")))
        val wire = load("perf-contract.json").getJSONObject("wire")
        assertEquals(wire.keys().asSequence().associateWith { wire.getString(it) }, PerfMetric.forSpan)
    }

    private fun meta(i: JSONObject) = PerfBatchMeta(
        i.getString("installId"), i.getString("os"), i.getString("arch"), i.getString("appVersion"), i.getString("osVersion"),
        i.getString("device"), i.getInt("refreshHz"),
    )

    @Test
    fun aBatchIsBuiltTheSameWayOnBothApps() {
        for (c in stats().rows("batches")) {
            val i = c.getJSONObject("input")
            var clock = i.getLong("windowStartMs")
            val histograms = PerfHistograms(now = { clock })
            val samples = i.getJSONObject("samples")
            for (name in samples.keys()) {
                val xs = samples.getJSONArray(name)
                for (k in 0 until xs.length()) histograms.add(name, xs.getDouble(k))
            }
            clock = i.getLong("windowEndMs")
            val window = histograms.take()
            val json = (window?.let { PerfStatsBatch(meta(i), it).toJson() }
                ?: PerfStatsBatch(meta(i), PerfWindow(i.getLong("windowStartMs"), clock, emptyList())).toJson())
            assertEquals(c.getString("name"), canon(c.getJSONObject("expect")), canon(json))
        }
    }

    @Test
    fun theUploaderSendsWhenTheSharedRulesSay() {
        for (case in stats().rows("uploader")) {
            val config = case.getJSONObject("config")
            var clock = 0L
            var status = 204
            var posts = 0
            val histograms = PerfHistograms(now = { clock })
            val uploader = PerfUploader(
                endpoint = if (config.isNull("endpoint")) null else config.getString("endpoint"),
                enabled = { config.getBoolean("enabled") },
                source = histograms,
                meta = { PerfBatchMeta("id", "android", "aarch64", "0.1.0", "36", "Pixel", 60) },
                now = { clock },
                post = { _, _ -> posts++; status },
            )
            for (step in case.rows("steps")) {
                clock = step.getLong("atMs")
                status = step.getInt("status")
                repeat(step.getInt("addSamples")) { histograms.add(PerfMetric.AppLaunch, 5.0) }
                val before = posts
                val label = "${case.getString("name")} at ${clock}ms"
                assertEquals(label, step.getBoolean("expectSent"), uploader.flush())
                assertEquals("$label: posted", step.getBoolean("expectPosted"), posts > before)
                assertEquals("$label: samples held", step.getLong("expectPending"), histograms.pendingSamples())
            }
        }
    }

    @Test
    fun backgroundWorkHoldsBackWhenTheDeviceIsHotOrSavingPower() {
        for (c in stats().rows("deviceCalm")) {
            assertEquals("$c", c.getBoolean("expect"), PerfPolicy.deviceIsCalm(c.getBoolean("lowPower"), c.getString("thermal")))
        }
    }

    /** The monitor sits on hot paths (every frame, every parse), so its per-call cost has a ceiling. */
    @Test
    fun recordingAnOperationCostsMicroseconds() {
        val n = 200_000
        // Warm up so the JIT has compiled the path being timed.
        repeat(20_000) { Perf.measure(PerfSpan.HomeGroup) { it } }
        val start = System.nanoTime()
        repeat(n) { Perf.measure(PerfSpan.HomeGroup) { it } }
        val perCallUs = (System.nanoTime() - start) / 1e3 / n
        println("monitor cost: measure() %.3f µs a call".format(perCallUs))
        assertTrue("measure() took $perCallUs µs a call", perCallUs < 5.0)

        val tally = harness.codegraff.android.perf.FrameTally()
        val histograms = PerfHistograms()
        val stages = DoubleArray(harness.codegraff.android.perf.FrameStage.entries.size)
        repeat(20_000) { tally.add(8.0, stages, 16.7); histograms.add(PerfMetric.FrameCost, 8.0) }
        val frameStart = System.nanoTime()
        repeat(n) { tally.add(8.0, stages, 16.7); histograms.add(PerfMetric.FrameCost, 8.0) }
        val perFrameUs = (System.nanoTime() - frameStart) / 1e3 / n
        println("monitor cost: tallying a frame %.3f µs".format(perFrameUs))
        assertTrue("a frame took $perFrameUs µs to tally", perFrameUs < 5.0)
    }

    @Test
    fun onlyHttpsOrLoopbackIsAnAllowedEndpoint() {
        assertTrue(PerfTransport.isAllowed("https://example.invalid/perf"))
        assertTrue(PerfTransport.isAllowed("http://127.0.0.1:8080/perf"))
        assertFalse(PerfTransport.isAllowed("http://example.invalid/perf"))
        assertFalse(PerfTransport.isAllowed("ftp://example.invalid/perf"))
        assertFalse(PerfTransport.isAllowed("not a url"))
    }

    @Test
    fun aReportIsPostedAsPlainJsonWithNoCredentials() {
        // A one-shot HTTP server on a raw socket (the trimmed JDK here has no com.sun.net.httpserver).
        val server = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1"))
        val port = server.localPort
        var requestLine = ""
        val headers = mutableMapOf<String, String>()
        var seenBody = ""
        val serving = Thread {
            server.accept().use { socket ->
                val input = socket.getInputStream().buffered()
                fun line(): String {
                    val sb = StringBuilder()
                    while (true) {
                        val b = input.read()
                        if (b < 0 || b == '\n'.code) break
                        if (b != '\r'.code) sb.append(b.toChar())
                    }
                    return sb.toString()
                }
                requestLine = line()
                while (true) {
                    val l = line()
                    if (l.isEmpty()) break
                    headers[l.substringBefore(':').lowercase()] = l.substringAfter(':').trim()
                }
                val n = headers["content-length"]?.toInt() ?: 0
                seenBody = String(input.readNBytes(n))
                socket.getOutputStream().apply { write("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".toByteArray()); flush() }
            }
        }.also { it.start() }
        val body = PerfStatsBatch(PerfBatchMeta("id", "android", "aarch64", "0.1.0", "36", "Pixel", 60), PerfWindow(0, 1, emptyList())).toJson().toString()
        assertEquals(204, PerfTransport.post("http://127.0.0.1:$port/perf", body))
        serving.join(5_000)
        server.close()
        assertEquals("POST /perf HTTP/1.1", requestLine)
        assertEquals(body, seenBody)
        assertEquals("application/json", headers["content-type"])
        for (name in listOf("authorization", "cookie")) assertFalse("$name was sent", name in headers)
        // Nothing listening any more: a failed post is reported, not thrown.
        assertEquals(0, PerfTransport.post("http://127.0.0.1:$port/perf", "{}"))
    }

    @Test
    fun thePerformancePageUsesTheContractStrings() {
        val strings = load("perf-contract.json").getJSONObject("strings")
        val source = kotlinSources()
        for (key in strings.keys()) {
            assertTrue("${strings.getString(key)} is missing from the Compose app", source.contains("\"${strings.getString(key)}\""))
        }
    }
}
