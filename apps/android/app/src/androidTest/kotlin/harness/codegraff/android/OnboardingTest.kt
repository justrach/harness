package harness.codegraff.android

import android.content.Intent
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** The "Bring in your agent" screen against the three demo accounts that have nothing started yet. */
@RunWith(AndroidJUnit4::class)
class OnboardingTest {
    @get:Rule
    val rule = createEmptyComposeRule()

    private var scenario: ActivityScenario<MainActivity>? = null

    private fun launch(name: String) {
        val intent = Intent(ApplicationProvider.getApplicationContext(), MainActivity::class.java).putExtra("scenario", name)
        scenario = ActivityScenario.launch(intent)
    }

    @After
    fun tearDown() {
        scenario?.close()
        AppModel.scenario = null
    }

    @Test
    fun noComputerExplainsWhatToDoAndOffersTheLink() {
        launch("onboarding-nocomputer")
        rule.onNodeWithText("Bring in your agent").assertExists()
        rule.onNodeWithText("Get Harness on your computer").assertExists()
        rule.onNodeWithTag("onboarding-share-link").assertExists()
        rule.onNodeWithTag("onboarding-copy-link").assertExists()
        for (id in listOf("graff", "claude-code", "codex")) {
            rule.onNodeWithTag("onboarding-agent-$id").assertTextContains("Needs a computer", substring = true)
        }
    }

    @Test
    fun aComputerWithNoAgentReadySaysWhatIsMissingOnIt() {
        launch("onboarding-noagent")
        rule.onNodeWithText("Bring in your agent").assertExists()
        rule.onNodeWithText("Get Harness on your computer").assertDoesNotExist()
        rule.onNodeWithTag("onboarding-agent-graff").assertTextContains("Switched off on MacBook Pro", substring = true)
        rule.onNodeWithTag("onboarding-agent-claude-code").assertTextContains("Not installed on MacBook Pro", substring = true)
        rule.onNodeWithTag("onboarding-agent-codex").assertTextContains("Not found on MacBook Pro", substring = true)
    }

    @Test
    fun onceAnAgentIsReadyHomeShowsItsPlainEmptyLine() {
        launch("onboarding-ready")
        rule.onNodeWithTag("home-empty").assertExists()
        rule.onNodeWithText("Bring in your agent").assertDoesNotExist()
    }
}
