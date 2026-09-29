package harness.codegraff.android

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The "Use your ChatGPT plan" sheet against the demo computer, which answers "pending" twice and then the outcome named. */
@RunWith(AndroidJUnit4::class)
class ChatGPTSignInTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    private fun launch(result: String, scenarioName: String = "onboarding-noagent", welcomeSeen: Boolean = false) {
        val intent = Intent(ApplicationProvider.getApplicationContext(), MainActivity::class.java)
            .putExtra("scenario", scenarioName).putExtra("chatgptResult", result).putExtra("chatgptWelcomeSeen", welcomeSeen)
        scenario = ActivityScenario.launch(intent)
    }

    @After
    fun tearDown() {
        scenario?.close()
        AppModel.scenario = null
        AppModel.chatGptResult = null
    }

    private fun openSheetAndContinue() {
        rule.onNodeWithTag("onboarding-chatgpt").performClick()
        rule.onNodeWithText("Choose the computer").assertExists()
        rule.onNodeWithTag("chatgpt-continue").performClick()
    }

    /**
     * The demo computer answers after a few polls half a second apart. Compose's test clock drives those delays, so a
     * slow emulator would need hundreds of idle checks to get there; jump it forward instead, then wait on the screen.
     */
    private fun awaitOutcome(condition: () -> Boolean) {
        rule.mainClock.autoAdvance = false
        rule.mainClock.advanceTimeBy(6_000)
        rule.mainClock.autoAdvance = true
        rule.waitUntil(20_000, condition)
    }

    private fun assertPhase(phase: String) {
        rule.onNodeWithTag("chatgpt-status").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, phase))
    }

    @Test
    fun anApprovedSignInWithPlanUsageEndsWithTheOneTimeConfirmation() {
        launch("connected")
        openSheetAndContinue()
        rule.onNodeWithText("Keep this open until it finishes.").assertExists()
        rule.onNodeWithTag("chatgpt-cancel").assertExists()
        awaitOutcome { rule.onAllNodesWithTextCount("You're using your ChatGPT plan") > 0 }
        assertPhase("connected")
        rule.onNodeWithTag("chatgpt-manage-usage").assertExists()
        rule.onNodeWithTag("chatgpt-done").performClick()
        rule.onNodeWithText("Bring in your agent").assertExists()
    }

    @Test
    fun aSignInWithoutPlanUsageIsNotReadyAndOffersAnotherTry() {
        launch("planUsageOff")
        openSheetAndContinue()
        awaitOutcome { rule.onAllNodesWithTextCount("Signed in, but plan usage is off") > 0 }
        assertPhase("planUsageOff")
        rule.onNodeWithTag("chatgpt-retry").assertExists()
        rule.onNodeWithTag("chatgpt-manage-usage").assertDoesNotExist()
    }

    @Test
    fun cancelWhileWaitingReturnsToTheStart() {
        launch("connected")
        openSheetAndContinue()
        rule.onNodeWithTag("chatgpt-cancel").performClick()
        rule.onNodeWithTag("chatgpt-continue").assertExists()
        rule.onNodeWithTag("chatgpt-status").assertDoesNotExist()
    }

    @Test
    fun theConfirmationIsOnlyForTheFirstSignIn() {
        launch("connected", welcomeSeen = true)
        openSheetAndContinue()
        // Already confirmed once: the sheet closes on its own and shows nothing more.
        awaitOutcome { rule.onAllNodesWithTag("chatgpt-continue").fetchSemanticsNodes().isEmpty() }
        rule.onNodeWithText("You're using your ChatGPT plan").assertDoesNotExist()
    }

    @Test
    fun theFirstSignInConfirmsThatThePlanIsInUse() {
        launch("connected")
        openSheetAndContinue()
        awaitOutcome { rule.onAllNodesWithTextCount("You're using your ChatGPT plan") > 0 }
        rule.onNodeWithText("Eligible AI requests in this app use your ChatGPT plan. You can manage usage in ChatGPT settings.").assertExists()
        rule.onNodeWithTag("chatgpt-done").assertExists()
    }

    @Test
    fun settingsOffersTheOptionAndThenShowsThePlanIsInUse() {
        launch("connected")
        rule.onNodeWithContentDescription("Settings").performClick()
        rule.onNodeWithTag("chatgpt-plan-card").assertExists()
        rule.onNodeWithText("Complete eligible AI requests in this app with usage included in your ChatGPT plan or credits balance.").assertExists()
        rule.onNodeWithTag("continue-with-chatgpt").performClick()
        rule.onNodeWithTag("chatgpt-continue").performClick()
        awaitOutcome { rule.onAllNodesWithTag("chatgpt-done").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("chatgpt-done").performClick()
        rule.onNodeWithTag("plan-usage-line").assertExists()
        rule.onNodeWithTag("continue-with-chatgpt").assertDoesNotExist()
    }

    @Test
    fun someoneWithSessionsIsInvitedByABannerUntilTheyConnect() {
        launch("connected", scenarioName = "chatgpt-plan")
        rule.onNodeWithTag("chatgpt-plan-banner").assertExists()
        rule.onNodeWithText("New").assertExists()
        rule.onNodeWithText("Use your ChatGPT plan in this app").assertExists()
        rule.onNodeWithTag("continue-with-chatgpt").performClick()
        rule.onNodeWithTag("chatgpt-continue").performClick()
        awaitOutcome { rule.onAllNodesWithTag("chatgpt-done").fetchSemanticsNodes().isNotEmpty() }
        rule.onNodeWithTag("chatgpt-done").performClick()
        rule.waitUntil(5_000) { rule.onAllNodesWithTag("chatgpt-plan-banner").fetchSemanticsNodes().isEmpty() }
    }

    @Test
    fun aSessionOnThePlanShowsWhereToManageUsageAndItsLimitCard() {
        launch("connected", scenarioName = "chatgpt-plan")
        rule.onNodeWithContentDescription("Plan session", substring = true).performClick()
        rule.onNodeWithTag("plan-usage-line").assertExists()
        rule.onNodeWithText("Using ChatGPT plan").assertExists()
        rule.onNodeWithTag("usage-limit-card").assertExists()
        rule.onNodeWithText("Usage limit reached").assertExists()
        rule.onNodeWithText("Review your plan or app limit in ChatGPT settings.").assertExists()
    }
}

private fun androidx.compose.ui.test.junit4.ComposeTestRule.onAllNodesWithTextCount(text: String): Int =
    onAllNodesWithText(text).fetchSemanticsNodes().size
