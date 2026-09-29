package harness.codegraff.android

import android.content.Intent
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
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

    private fun launch(result: String) {
        val intent = Intent(ApplicationProvider.getApplicationContext(), MainActivity::class.java)
            .putExtra("scenario", "onboarding-noagent").putExtra("chatgptResult", result)
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

    private fun assertPhase(phase: String) {
        rule.onNodeWithTag("chatgpt-status").assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, phase))
    }

    @Test
    fun anApprovedSignInWithPlanUsageEndsWithTheOneTimeConfirmation() {
        launch("connected")
        openSheetAndContinue()
        rule.onNodeWithText("Keep this open until it finishes.").assertExists()
        rule.onNodeWithTag("chatgpt-cancel").assertExists()
        rule.waitUntil(20_000) { rule.onAllNodesWithTextCount("You're using your ChatGPT plan") > 0 }
        assertPhase("connected")
        rule.onNodeWithTag("chatgpt-manage-usage").assertExists()
        rule.onNodeWithTag("chatgpt-done").performClick()
        rule.onNodeWithText("Bring in your agent").assertExists()
    }

    @Test
    fun aSignInWithoutPlanUsageIsNotReadyAndOffersAnotherTry() {
        launch("planUsageOff")
        openSheetAndContinue()
        rule.waitUntil(20_000) { rule.onAllNodesWithTextCount("Signed in, but plan usage is off") > 0 }
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
}

private fun androidx.compose.ui.test.junit4.ComposeTestRule.onAllNodesWithTextCount(text: String): Int =
    onAllNodesWithText(text).fetchSemanticsNodes().size
