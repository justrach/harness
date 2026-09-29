package harness.codegraff.android

import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertTextContains
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Runs on any device or emulator, including foldables, where the layout is one or two panes. */
@RunWith(AndroidJUnit4::class)
class SessionFlowTest {
    @get:Rule
    val rule = createAndroidComposeRule<MainActivity>()

    private fun openToolGroupSession() {
        rule.onNodeWithContentDescription("Tool group header colors", substring = true).performClick()
        rule.waitForIdle()
    }

    @Test
    fun openingASessionShowsItsTranscript() {
        openToolGroupSession()
        rule.onNodeWithText("The test that failed before the change now passes.", substring = true).assertExists()
    }

    @Test
    fun sendIsDisabledUntilThereIsADraft() {
        openToolGroupSession()
        rule.onNodeWithContentDescription("Send").assertIsNotEnabled()
        rule.onNode(hasSetTextAction()).performTextInput("hello")
        rule.onNodeWithContentDescription("Send").assertIsEnabled()
    }

    @Test
    fun theDraftAndTheOpenSessionSurviveRecreation() {
        openToolGroupSession()
        rule.onNode(hasSetTextAction()).performTextInput("keep me")
        rule.activityRule.scenario.recreate()
        rule.waitForIdle()
        rule.onNodeWithText("The test that failed before the change now passes.", substring = true).assertExists()
        rule.onNode(hasSetTextAction()).assertTextContains("keep me")
    }

    @Test
    fun runningFilterHidesSessionsThatAreNotRunning() {
        rule.onNodeWithText("Running", substring = true).performClick()
        rule.waitForIdle()
        rule.onNodeWithContentDescription("Streaming veil on transcript rows", substring = true).assertExists()
        rule.onNodeWithContentDescription("Tool group header colors", substring = true).assertDoesNotExist()
    }
}
