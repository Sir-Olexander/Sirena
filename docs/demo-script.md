# Demo script (90 seconds, hands off the keyboard after the first click)

Setup before recording: Chrome with three tabs (first one is a docs page), the Claude desktop app, Notes open
on an empty note, Slack somewhere in the background. Sirena off (gray dot at the bottom of the screen).
Latency display on (menu bar → "Show latency in the overlay").

1. **Click the dot.** The pill expands: "Listening".
   "Sirena, switch to Chrome" → Chrome comes to the front, pill: "Switched to Google Chrome".
   "go to the first tab" → tab 1 (no name needed: the countdown ring was still running).
   "scroll down" → the page scrolls.
2. **Someone else talks.** A second person says "switch to Slack". Nothing happens, the pill shows
   "Start with “Sirena” to give a command". Point at it.
3. "Sirena, switch to Claude" → Claude in front.
   "Sirena, send a message to Claude saying summarize the page I just read" → the message is typed and the
   big confirm card appears: "Send this message to Claude? Yes / Cancel".
   "Yes" → Enter is pressed, the message is sent.
4. "Sirena, switch to Notes" → "Sirena, start dictating" (pill turns amber).
   "um so basically the meeting is, no wait, moved to Friday" → "The meeting is moved to Friday." appears.
   "Sirena, stop" → pill back to blue.
5. "Sirena, show numbers" → yellow badges on every button of Notes. "Sirena, click 4" → that button is clicked.
6. "Sirena, wait" → the pill dims to "Say “Hey Sirena”". Say "scroll down": nothing happens.
   "Hey Sirena" → she wakes up.
7. Point at the latency line under the pill (asr · fast/spark · act). Close on: a whole workflow, no hands.

Fallbacks during the demo:
* If the confirm card does not appear because Claude's composer was not focused, say "Sirena, click the
  message box" first, then repeat the send command.
* If realtime transcription drops, the pill shows "Reconnecting…" and comes back on its own.
