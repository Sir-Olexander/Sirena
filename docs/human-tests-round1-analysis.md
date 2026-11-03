# Human tests, round 1: analysis of the results and the tester's notes

Results from `docs/human-tests.md` (2026-11-03, build d56de9e): 81 pass, 12 fail. The failures are 3.10, 4.9, 6.2,
10.1, 13.5, 18.1–18.3 and 20.1–20.4. Every verdict below was checked against the command history
(`~/Library/Application Support/Sirena/history.jsonl`) and the session log of the same afternoon, then against the code.

## The failed tests

| Test | What happened (from the history) | Cause in the code | Fix |
|---|---|---|---|
| 3.10 "what time is it" | 14:39:19 ran as a command, went to Spark, which called `need_screen` with the goal "read current time from macOS menu bar clock"; the screenshot agent then spent 30 s clicking around (that is the "manipulating a toggle" you saw) | A question is only ignored when said without the name inside the follow-up window; with the name it reaches the model, and nothing stops the model from handing a question to the screenshot fallback, which acts | Time and date are answered locally ("It's 14:39"); a question never reaches the screenshot agent in acting mode (look-only: one screenshot, a one-line answer, no clicks) |
| 4.9 "switch to Zorbulator" | heard "switch to Zorbu later"; no app, tab or window matched; Spark called `need_screen`; the agent clicked around Chrome for 30 s | After the fast path fails to resolve an app name the model may call `need_screen`, and the screen fallback is allowed for any three-word request | A switch/open of something that does not exist stops at "I couldn't find “Zorbu later”"; it never goes to the screenshot fallback |
| 6.2 "open Gmail" with Safari in front | 14:58:27 `open("gmail")` launched the Gmail app | `~/Applications/Chrome Apps.localized/Gmail.app` exists (a Chrome web-app shortcut); the "exact installed app name wins" rule fired before the website rule | With a browser in front, a known site name opens there (reusing its tab); Chrome web-app shortcuts count as sites unless you say "app" ("open the Gmail app") |
| 10.1 "type hello world" | 15:14:54 ignored: the screenshot agent was still busy with "Send an email."; 15:15:30 "start dictating" was heard as "Start dating", went to Spark, which typed it into the focused field; 15:13:42 "let's write an email" typed "an email." | (1) by design only "cancel"/"stop" get through while the agent works; (2) no tolerance for misheard control phrases, and the model treats a focused field as an invitation to type; (3) "write X" is always a typing command | Close misrecognitions of Sirena's controls are accepted ("start dating", "start the dictation"); the model is told never to type the spoken command itself; "write an email/message/note" is not typing; the pill says "Still looking at the screen" (it already did, but the agent should not have been running: see 3.10/4.9) |
| 13.5 "copy the last message" (WhatsApp Web) | copied "As suas mensagens pessoais são…": the end-to-end-encryption banner, the first row of the conversation | The text walk starts at the top of the page: the chat list (hundreds of rows) eats the 1.5 s / 15 000-node budget before the walk reaches the bottom of the conversation, so the banner is the lowest block it saw | The last message is searched from the bottom up, inside the column that holds the message box, skipping the box itself |
| 18.1–18.3 "undo" | no utterance containing "undo" exists in the whole history; at 15:44:48–57 the recognizer produced "Ando", "Ando", "Ando", "And do" (ignored as chatter / question) | Speech recognition: "undo" is not in the vocabulary hints and is heard as "Ando"; without the name it is chatter | Sirena's own control words are permanent vocabulary hints ("undo", "dictating", "numbers", "cancel"…); "ando" / "and do" are accepted as "undo"; undo itself works (it was never reached) |
| 20.1–20.4 music | 15:46–15:48: whole lyrics (Russian, then Portuguese) were transcribed and ignored as "no name"; nothing was typed, but the gate did not silence them; 20.3 your voice over the music did not come through; 20.4 a "hey" in the lyrics woke her | The history does not record the echo gate's state, so the room cause cannot be read off (candidates: music through another output than the default device, the gate still learning, the tap not started). One cause is in the code: while waiting, the on-device wake detector gets the raw microphone and bypasses the gate entirely, so lyrics can wake her | Wake detector fed only when the gate passes audio; the echo gate's state is logged with every ignored utterance and shown in the dev panel so round 2 can tell what happened; please run the two echo self-tests with your music playing (below) |

## Your notes, one by one

**Move app from one monitor to another / 15.2 "first she takes the app out of full screen, then I repeat".**
Confirmed in the history (14:43:30): Spark planned `move_window_to_screen`, the move refused with "Leave full screen
first", the model's second round pressed ⌃⌘F to leave full screen and stopped there. Your second command then moved the
window. Fix: moving a full-screen window leaves full screen, moves it, and enters full screen again on the other screen.

**"Asked her what time it is: she took a screenshot and manipulated a toggle."** See 3.10: the screenshot agent was
asked to "read the clock" and acted instead of answering. Time and date are now answered without any model.

**4.6 "alt tab works, but how do I tell her to enter the selected app?"** There is nothing to enter: ⌘⇥ pressed and
released switches straight to the previous app, like on Windows when you let go. To choose another app, say
"switch to <app>" (or "Chrome tab 2", "switch to the Wikipedia tab"). One real defect: the synthetic ⌘⇥ never released ⌘
explicitly, so the app switcher could linger on screen; the modifier is now released.

**"Numbers in VS Code with the preview open: whole screen for a fraction of a second, then only the preview."** You said
"show numbers" four times in 25 s (14:48:35–59); each one takes a new snapshot. The badges are the first 150
clickable elements found breadth-first within 0.6 s. The first call switches VS Code's (Chromium) accessibility tree to
the full mode, which changes what the second call sees: the preview's elements filled the 150 slots. Fix: numbers mode
collects up to 400 elements with a longer budget, starts in the pane that has the keyboard focus, and a repeated
"show numbers" within a few seconds keeps the badges instead of rebuilding them.

**4.9 "switched to Chrome and started executing random commands."** See above: unknown app → screenshot fallback.
Fixed at the source: it cannot reach the fallback any more.

**6.2 "opens Gmail inside Google only if I say 'open Gmail inside Google'".** See above. Note "open Gmail inside Google
Chrome" worked because it went to the model, which used `open_url`.

**"With two monitors she shows numbers on one monitor only, not even the focused one."** Numbers were only ever
drawn for the front window (test 9.1 says so), and "the front window" is what macOS reports, which after "switch to the
first monitor" was the window Sirena focused, not necessarily the one you were looking at. "show numbers on the first
monitor" (15:00:57) went to the model, which only focused the screen. Fix: "show numbers" badges the topmost window on
every screen, numbered continuously; "show numbers on screen 2 / on the other monitor" badges that screen only.

**6.6 "she clicked the first link, a cookie window popped up, 'click consent' never worked."** Two defects:
the consent dialog's button was not among the 150 elements of the snapshot (it sits deep in the page tree, after the
whole results list), and the screenshot fallback refused "click consent" as "too vague" because the rule demanded three
words (15:01:20, 15:01:27, 15:01:39: "error: too vague for the screen fallback"). Fix: a click by label searches the
whole window tree (and the app's other windows) for the label before giving up, and two-word requests with a real
object ("click consent") may use the fallback; "this one" / "click it" still may not.

**"When I repeat one word a lot of times there must be a way to add it to the vocabulary (kinogo.org)."** There is a
manual way: menu → Custom vocabulary… (one word per line; it is sent to the recognizer as a hint). Nothing automatic
existed. Now: "Sirena, learn the word kinogo" / "add kinogo to the vocabulary" / "remember the word kinogo" adds it
on the spot, and when the same unknown word comes back three times in two minutes the pill suggests it. Also, "type
kinogo dot org" now types "kinogo.org" (the recognizer wrote ".org" as "dot org"; the history shows it dropped it
altogether in "type Kinogo", which the vocabulary hint helps with).

**"Sometimes she says she typed when she didn't."** True: "Typed" was reported right after sending ⌘V, without
checking anything had the keyboard focus. Now she checks what has the focus before pasting: with no text field
focused she says "No text field is focused in <app> — click into a field first" and pastes nothing (so the clipboard
is left alone too). Reading the field back afterwards is not done: editors such as VS Code keep their text out of
the accessibility value, so a read-back would report false failures there.

**"She still listens to the sound of the PC when music is playing."** See 20.x. What I can say for sure: the lyrics
reached the recognizer, so the gate was open or not running; and the on-device wake word bypassed the gate (fixed).
What I cannot see from here is why the gate let the music through in your room. The next round records the gate's
state, and these two commands tell us within a minute, music playing on the speakers:

```
open -n build/Sirena.app --args --selftest players /tmp/players.txt   # which app plays, to which output device
open -n build/Sirena.app --args --selftest echo /tmp/echo.txt         # what the recognizer hears with and without the gate
```

**7.3 "we have to find a way for her to know whether to scroll the page or a scrollable component."** Today every
scroll is a wheel event at the centre of the front window, which is why the main page moved. Added: "scroll down in the
sidebar / in the chat / in the list / in the left panel" scrolls the scroll area whose label or content matches, and
"scroll down here" scrolls under the mouse pointer. "scroll down" alone keeps scrolling the page.

**7.7 "volume up and down work; add volume max and mute."** Added: "volume max / full volume / maximum volume",
"volume to 50 percent / set the volume to 30", "volume min", "mute / mute the sound / silence", "unmute". (The old
"mute" was a toggle; "unmute" now really unmutes.)

**10.1 "type isn't working; when she mishears a command and a field is focused she writes it."** See the table:
three separate causes, all addressed. The one worth knowing: while the screenshot fallback works, only "cancel" and
"stop" get through, by design; the real problem was that the fallback should not have been running for "Send an email."
(it said "nothing done", correctly) nor for the earlier questions.

**13.5 "copy the last message" in all its forms.** See the table. All three phrasings parsed correctly
("copy the last message in this conversation" → last message); the resolution picked the wrong block.

**14 "when she reads aloud she doesn't listen to my commands. Is there a way to make her voice better (a Meta
model?)".** Listening while reading is deliberate but narrow: "stop", "pause", "resume", "faster", "slower" work without
the name; anything else needs "Sirena, …". The failure you saw: her own voice reaches the microphone (over speakers, or
when the input has no voice processing), and a transcript that is mostly her words plus your "stop" is thrown away as
echo. Now the echoed words are stripped first and a control that is left ("stop", "Sirena, switch to Notes") runs.
Voice: she already picks the best installed Apple voice for the language (premium > enhanced > default). You get a
much better voice by downloading one: System Settings → Accessibility → Spoken Content → System voice → Manage
Voices… (English: "Zoe (Premium)", "Ava (Premium)"; Portuguese: "Joana (Enhanced)"); no restart needed. The Meta
Model API we use has no text-to-speech model as far as its docs and the endpoints we probed show (Muse Voice
Transcribe is speech-to-text only); a cloud voice (ElevenLabs, OpenAI) would mean a second provider, extra latency
per sentence and a cost per character, so I left that out.

**"Can Sirena suggest adding to the vocabulary when I repeat the same word? Is it implemented?"** It was not: the
learning only proposes shortcuts. It is now (see kinogo above): three repeats of the same unknown word within two
minutes → hint in the pill with the exact phrase to say; nothing is added without you.

**17.1 "Call Barokas: worked once, failed the second time because the search field still had the name."** Two
causes. The run after a call failed with "No element called “Procurar ou criar uma nova conversa”" (15:41:55): the
WhatsApp call had opened its own popup window, which was still the front window, so the search field was not in it.
And, as you noticed, the search field keeps the previous text, so the next run would type after it. Fixes: a step that
focuses a search field selects its old text before typing; a label not found in the front window is searched in the
app's other windows (the main WhatsApp window), and that window is raised.

## Other things the history shows (not in your notes)

* 16.4 "insert my passport number" (no such snippet) typed the words "passport numbers" (15:39:34); the plan expects
  "no snippet, nothing typed". Now "insert <name>" without a snippet says so; "type …" still types.
* "insert emoji" was typed as the word "emoji" (the typing rule ran before the shortcut table). Fixed.
* "Send an email." went to the screenshot fallback, which looked and did nothing (15:14:03); with the compose window
  open Spark should have focused the "To" field. Left as is: the fallback reported honestly.
* The learner has a pending suggestion "close all tabs → press cmd+w" from 2026-10-30 (`suggestions.json`), from
  before close-all-tabs had its own command. Say "Never" on it in the Suggestions window; it would close one tab.
