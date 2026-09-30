package harness.codegraff.android.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Sign in with ChatGPT (plan usage) for OpenAI Codex, driven from the phone (ChatGPTSignIn.swift on iOS). Harness on the
 * computer does the sign-in itself. The browser step runs there: OpenAI's redirect is a loopback on that machine and
 * there is no device code, so the phone starts the sign-in, shows the wait and shows the outcome. It never opens the browser and
 * never sees a token. The rules are pinned in `apps/parity/vectors/chatgpt-sign-in.json`.
 */

/** What the sign-in sheet is showing. */
enum class ChatGPTPhase(val wireName: String) {
    Idle("idle"),

    /** Started on the computer; waiting for the person to approve in its browser. */
    Waiting("waiting"),

    /** Signed in and plan usage granted. */
    Connected("connected"),

    /** Signed in, but the token does not grant plan usage, so it cannot run requests on the plan. */
    PlanUsageOff("planUsageOff"),
    Declined("declined"),
    Failed("failed"),
}

/** What the one main button does on a screen. */
enum class ChatGPTAction(val wireName: String) { Start("start"), Cancel("cancel"), Done("done"), Retry("retry") }

/**
 * The computer's answer to a poll: the engine's agent-login status (pending, done or error), whether plan usage was
 * granted once done, and the message of an error.
 */
data class ChatGPTPoll(val status: String, val planUsage: Boolean? = null, val message: String? = null)

/** A computer that can run the sign-in: online, with OpenAI Codex on it. */
data class ChatGPTComputer(val id: String, val name: String)

object ChatGPTSignIn {
    /** OpenAI's page for the plan's usage, linked as "Manage usage". */
    const val MANAGE_USAGE_URL = "https://chatgpt.com/settings/usage"

    /** What the computer says when the person declined in its browser; any other error is a failed sign-in. */
    const val DECLINED_MESSAGE = "ChatGPT sign-in was declined."

    /** Plan usage counts only when the computer says it was granted; a sign-in that does not say is not treated as ready. */
    fun phase(poll: ChatGPTPoll): ChatGPTPhase = when (poll.status) {
        "pending" -> ChatGPTPhase.Waiting
        "done" -> if (poll.planUsage == true) ChatGPTPhase.Connected else ChatGPTPhase.PlanUsageOff
        "error" -> if (poll.message == DECLINED_MESSAGE) ChatGPTPhase.Declined else ChatGPTPhase.Failed
        else -> ChatGPTPhase.Failed
    }

    /** A session runs on the person's ChatGPT plan when its model's provider is `chatgpt` (`chatgpt/<slug>`). */
    fun usesPlan(modelId: String?): Boolean = modelId?.startsWith("chatgpt/") == true

    /**
     * The plan's usage limit (HTTP 429, `subscription_sharing_usage_limit_exceeded`), as it reaches the transcript. It gets
     * its own card that leads with Manage usage instead of a one-line error.
     */
    fun isUsageLimit(message: String): Boolean =
        "subscription_sharing_usage_limit_exceeded" in message || "chatgpt.com/settings/usage" in message

    fun action(phase: ChatGPTPhase): ChatGPTAction = when (phase) {
        ChatGPTPhase.Idle -> ChatGPTAction.Start
        ChatGPTPhase.Waiting -> ChatGPTAction.Cancel
        ChatGPTPhase.Connected -> ChatGPTAction.Done
        ChatGPTPhase.PlanUsageOff, ChatGPTPhase.Declined, ChatGPTPhase.Failed -> ChatGPTAction.Retry
    }
}

/** The calls the sign-in makes on a computer. Demo only until the phone talks to the engine's login calls; with no client the phone offers nothing. */
interface ChatGPTSignInClient {
    val pollIntervalMs: Long

    /** Starts the sign-in on the computer, which opens its browser. */
    suspend fun start(deviceId: String)
    suspend fun poll(deviceId: String): ChatGPTPoll
    suspend fun cancel(deviceId: String)
}

/** One sign-in from tap to outcome. */
class ChatGPTSignInFlow(private val client: ChatGPTSignInClient, private val scope: CoroutineScope) {
    var phase by mutableStateOf(ChatGPTPhase.Idle)
        private set
    private var job: Job? = null

    fun start(deviceId: String) {
        job?.cancel()
        phase = ChatGPTPhase.Waiting
        job = scope.launch {
            try {
                client.start(deviceId)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                phase = ChatGPTPhase.Failed
                return@launch
            }
            while (true) {
                delay(client.pollIntervalMs)
                val next = ChatGPTSignIn.phase(client.poll(deviceId))
                phase = next
                if (next != ChatGPTPhase.Waiting) return@launch
            }
        }
    }

    /** Stops waiting and tells the computer to close its callback listener. */
    fun cancel(deviceId: String) {
        job?.cancel()
        val wasWaiting = phase == ChatGPTPhase.Waiting
        phase = ChatGPTPhase.Idle
        if (wasWaiting) scope.launch { client.cancel(deviceId) }
    }

    fun stop() { job?.cancel() }

    /** The sheet went away mid-wait: close the computer's listener from a scope that outlives it. */
    fun abandon(deviceId: String) {
        job?.cancel()
        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main.immediate).launch { client.cancel(deviceId) }
    }
}

/** Stands in for the engine in the demo: answers "pending" for a few seconds, then the outcome named (a phase's wire name). */
class DemoChatGPTSignIn(outcome: String) : ChatGPTSignInClient {
    override val pollIntervalMs = 500L
    private val outcome = when (outcome) {
        "planUsageOff" -> ChatGPTPoll("done", planUsage = false)
        "declined" -> ChatGPTPoll("error", message = ChatGPTSignIn.DECLINED_MESSAGE)
        "failed" -> ChatGPTPoll("error", message = "ChatGPT sign-in failed.")
        else -> ChatGPTPoll("done", planUsage = true)
    }
    private var polls = 0

    override suspend fun start(deviceId: String) { polls = 0 }

    override suspend fun poll(deviceId: String): ChatGPTPoll {
        polls += 1
        return if (polls <= 6) ChatGPTPoll("pending") else outcome
    }

    override suspend fun cancel(deviceId: String) {}
}
