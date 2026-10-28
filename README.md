# Sirena

Sirena is a macOS menu bar app that lets you use your Mac **hands-free**. You talk to her to control the
computer ("Sirena, switch to Chrome", "go to the first tab", "click Send") or to dictate clean text into any
app. She understands commands in the context of what is on screen and carries them out instantly, through
the Accessibility API, keyboard events and AppleScript rather than slow screenshot loops.

Built for the Meta Model API hackathon on top of Meta's models:

| Job | Model |
|---|---|
| Speech to text, streaming with endpointing | `muse-voice-transcribe-1.0` (realtime WebSocket, one-shot fallback) |
| Command understanding + dictation cleanup | `muse-spark-1.3` (tool calling, `reasoning_effort: minimal`) |
| Screenshot fallback ("Looking at the screen…") | `muse-spark-1.3` computer use via the Responses API |
| Optional private mode, fully on-device | `Muse Glimmer` through Ollama / LM Studio / llama.cpp |

## How it works

```
mic ──► Muse Voice Transcribe (ENDPOINTING) ──► utterance router ──► command pipeline ──► actions
           partials shown live in the overlay       "Sirena" rule        1. fast path (regex, <1 ms)
           keywords = apps + tabs + custom words     follow-up window     2. Muse Spark tool calls + screen snapshot
                                                     dictation mode       3. computer use (screenshots)
                                                     confirmations
```

* **Three listening states.** Off (mic closed) → one click. Waiting (only "Hey Sirena" wakes her) → say
  "Sirena, wait" or 2 minutes of silence. Awake (continuous listening, each pause ends an utterance).
* **Private waiting.** While waiting, "Hey Sirena" is detected with Apple's on-device speech recognition and
  the stream to Meta is paused: no audio leaves the Mac until she is awake (lock icon in the pill). Falls back
  to streaming if on-device recognition is unavailable; can be turned off in the menu.
* **The "Sirena" rule.** A command only runs when the utterance starts with "Sirena" (or a close
  misrecognition such as "Serena"). For 6 seconds after a command the next one works without the name;
  the overlay shows a countdown ring. Background speech like "switch to Slack" does nothing.
* **Dictation.** "Sirena, type …" inserts just that text. "Sirena, start dictating" types everything you say
  (cleaned up by Muse Spark: filler words, false starts, punctuation, lists, tone adapted to the app) until
  "Sirena, stop". "Sirena, delete that", "Sirena, new line", "Sirena, undo" work while dictating.
* **Confirmations.** Anything irreversible (sending a message, deleting, closing unsaved work) shows
  "Send this message? Yes / Cancel" and waits for "yes" or "cancel" (Enter and Esc also work).
* **Numbers mode.** "Sirena, show numbers" puts a badge on every clickable element of the front window
  (from the Accessibility tree), then "click 7".
* **Live vocabulary.** The recognizer gets the names of running apps, window titles, browser tab titles
  and your custom words as `keywords`, so "switch to the Meta docs tab" is heard correctly.
* **Overlay on every screen.** A non-activating floating panel that never takes focus, on every connected screen
  and Space, over full-screen apps. All copies show the same state; the one on the screen with the front window
  is marked, the others are dimmed. Each screen remembers its own position. The expanded pill shows the front
  app's icon and name; the sound wave appears only while expanded or dictating; dictation is amber, reading
  violet. Optional per-stage latency (speech recognition · understanding · action).
* **Several screens.** "Sirena, move this window to the other screen / the left monitor / screen 2" and
  "Sirena, switch to the other screen" (focuses the topmost window there and moves the pointer).
* **Copy text without selecting it.** "Copy the first paragraph / the paragraph about … / the paragraph that starts with …
  / the title / the second sentence / the last message" finds the text through Accessibility (the article only, skipping
  menus, sidebars, ads and reference lists), puts it on the clipboard, selects it on screen and shows the first words.
* **Lists and text edits in dictation.** "first point…", "point two…", "next item…", "ponto três…" said in
  separate pauses land on their own line, correctly numbered (continuing a list already in the field).
  "Sirena, make that a list", "separate the points with two line breaks", "fix the grammar" rewrite the text
  dictated in this session in place; text edits never go to the screenshot fallback, run only on dictated text, a
  selection in an editable field or an editable field's contents, and are never used to copy, select or read.
* **Read aloud.** "Sirena, read this" (selection), "read the article" (main content only, skipping menus,
  sidebars and ads), "read the page" (all visible text). While reading, "stop", "pause", "resume", "faster",
  "slower" work without the name. Sirena's own voice is echo-cancelled and filtered by matching the text being read.
* **Background noise.** The microphone goes through Apple's voice processing (noise suppression, gain control,
  echo cancellation) before recognition; menu toggle, on by default, automatic fallback on devices that refuse it.
* **Websites and browsers.** "Open Google / YouTube / Gmail…" opens the site (or its open tab) in the browser in
  front, else the browser used last; "open Google Chrome" or "open Google app" still opens the app. Web
  searches also go to that browser.
* **Shortcut book.** Save named commands: "call mom" = "open WhatsApp, select Mother and call her". Sirena
  writes the steps by following a written rulebook (`docs/shortcut-rulebook.md`); you review them before saving.
  Placeholders ("message {person} saying {text}"), confirmations before calling / sending / deleting, triggered
  by "Sirena, run <name>" or the name itself. Also runs your Apple Shortcuts by name.
* **Notes and snippets.** "Sirena, note <text>" saves a note without leaving your app; "Sirena, insert my email"
  types a saved snippet. Both are editable in a menu window.
* **Learning.** After Sirena is turned off, she looks for commands you corrected or undid, commands that kept
  needing the model or the screenshot fallback, and failures you finished another way, and proposes shortcuts
  ("Suggestions (N)" in the menu: Accept, Edit, Later, Never). Local only, no tokens, at most three pending and
  new ones at most once a day. "Sirena, forget that" removes a learned shortcut that just ran.
* **Dev mode.** A usage panel since Sirena was turned on (audio seconds, tokens in/out per category, screen
  reads and what triggered them, estimated cost, commands per layer, failures, latency, reconnects, wake method)
  and a log of every session in `~/Library/Application Support/Sirena/sessions.jsonl`.
* **History.** Every utterance, how it was routed, the layer used, the action and its latency go to
  `~/Library/Application Support/Sirena/history.jsonl`. No audio is stored. The history window groups it by
  session, with search, filters by type and layer, latency, and "Run again".

While the screenshot fallback works, other speech does not interrupt it: only "cancel", "stop" or the answer to its
confirmation. Its confirmations name the item it will act on ("Click “Mark” (the first item in the “Chats” list) in
WhatsApp?"), never a window or page title.

## Requirements

* macOS 14 or later, Apple silicon or Intel.
* Xcode 15+ command line tools (Swift 5.9+).
* A Meta Model API key, in `MODEL_API_KEY` (or `SIRENA_API_KEY`) or the macOS Keychain. The app copies a key
  found in the environment into the Keychain on first launch; the setup window also accepts a pasted key.

## Build and run

```bash
export MODEL_API_KEY="LLM|…"        # or SIRENA_API_KEY
scripts/run.sh                      # builds, signs, launches build/Sirena.app
```

`scripts/build-app.sh` compiles with SwiftPM (release builds use per-file optimization: Swift 6.2's whole-module
optimizer hangs on this code base), assembles `build/Sirena.app`, and signs it with your
Apple Development identity (set `SIRENA_SIGN_IDENTITY` to pick one). Signing with the same identity every
time keeps the permission grants across rebuilds. Without an identity it falls back to an ad-hoc signature,
which makes macOS forget the permissions after each rebuild.

Run the tests with `swift test`.

### Developer CLI

`swift run sirena-cli …` exercises the pieces without the app (nothing is executed on your Mac):

```bash
swift run sirena-cli transcribe sample.wav          # 24 kHz mono WAV through the realtime recognizer, with events and latency
swift run sirena-cli parse "Sirena, go to the first tab" --follow-up   # router + fast-path parser
swift run sirena-cli plan "open the API reference" --no-browser        # Muse Spark plan for the current screen
swift run sirena-cli plan-demo                                         # the demo commands against a canned snapshot
swift run sirena-cli snapshot                                          # what the model would see
swift run sirena-cli simulate                                          # the whole demo script through router → pipeline → overlay, dry run
swift run sirena-cli dictate "point one, finish the overlay" "second point," "test it"   # list dictation with model cleanup
swift run sirena-cli edit "make that a list" "eggs milk bread"          # the text-edit rewrite
swift run sirena-cli compile "call mom" "open WhatsApp, select Mother and call her"     # the shortcut rulebook
swift run sirena-cli render-overlay /tmp/overlay                       # every pill state as PNG
```

Diagnostics that run inside the signed app, with its permissions:

```bash
open -n build/Sirena.app --args --selftest-wake hey_sirena.wav /tmp/wake.txt   # on-device wake word
open -n build/Sirena.app --args --selftest audio /tmp/audio.txt                 # voice-processing microphone
open -n build/Sirena.app --args --selftest context /tmp/context.txt             # snapshot, screens, article text
```

Set `SIRENA_DEBUG_DUMP=/some/dir` to write every model request and response body there.

### Permissions

The first launch opens a setup window with the status of each permission and a button to the right
System Settings pane:

* **Microphone**, required.
* **Accessibility**, required (clicks, typing, shortcuts, the element list).
* **Screen Recording**, only for the screenshot fallback.
* **Automation**, to switch tabs in Chrome and Safari (macOS asks the first time a browser is controlled).

## Using Sirena

Click the gray dot (or the menu bar icon, or press ⌃⌥⌘S). Then:

| Say | What happens |
|---|---|
| "Sirena, switch to Chrome" / "switch to the Google page" | app, browser tab or window brought to the front |
| "Sirena, go to the first tab" · "next tab" · "tab 3" · "close tab" · "close the tabs to the right" | tabs of the app in front: browsers, VS Code (by position), Finder, Terminal, Xcode…; a browser only when the front app has no tabs |
| "Sirena, Chrome tab 2" · "switch to the second tab in VS Code" | tabs of a named app |
| "Sirena, copy the first paragraph" · "copy the paragraph about …" · "copy the paragraph that starts with …" · "copy the title" · "copy the second sentence" · "copy the last message" | copies it (and selects it on screen); "select …" / "read …" work the same way |
| "Sirena, command tab" · "alt tab" · "control c" · "alt F4" | shortcuts, Windows wording mapped to the Mac |
| "Sirena, scroll down" · "scroll up a bit" · "page down" · "scroll to the top" | scrolling |
| "Sirena, click Send" · "click the Reply button" · "focus the search field" | by accessibility label |
| "Sirena, send a message to Claude saying …" | switches, focuses the composer, types, asks before Enter |
| "Sirena, type hello world" | inserts the text |
| "Sirena, start dictating" … "Sirena, stop" | dictation mode |
| "Sirena, show numbers" … "click 4" · "hide numbers" | numbers mode |
| "Sirena, undo" · "Sirena, cancel" | undo or stop the last action |
| "Sirena, wait" … "Hey Sirena" (or "Hey Sirena, next tab") | pause and wake (and run the command) |
| "Sirena, move this window to the other screen" · "switch to the left monitor" | several screens |
| "Sirena, make that a list" · "separate the points with two line breaks" | edit the text just dictated |
| "Sirena, read this" · "read the article" · "read the page" … "stop / pause / faster" | read aloud |
| "Sirena, note call the bank" · "Sirena, insert my email" | notes and snippets |
| "Sirena, call mom" · "Sirena, run Morning Routine" | shortcut book, Apple Shortcuts |
| "Sirena, forget that" | remove the learned shortcut that just ran |
| "Sirena, stop listening" | off |
| anything else, e.g. "Sirena, open the settings of this app and turn on dark mode" | Muse Spark plans it from the screen snapshot; the screenshot fallback takes over if needed |

Menu bar: on / wait / off, private mode (Glimmer), push-to-talk (hold right ⌥ to dictate, right ⌘ to
command), noise reduction, on-device wake word, raw dictation, latency display, larger overlay, Suggestions (N),
shortcut book, notes & snippets, custom vocabulary, command history (window and plain text), developer mode,
session log, permissions.

### Microphone

"Microphone" in the menu picks the input: Automatic (the system default) or a specific device. Some Bluetooth
earbuds appear as the default input but send only digital silence to the Mac (for example when their microphone
is connected to a phone). Sirena notices after three seconds, says "No sound from <device> — listening with
<other microphone>" and switches. Noise reduction (Apple voice processing) works only on the system default
input, so a microphone chosen this way is captured without it; set it as the input in System Settings → Sound to
get noise reduction too.

### On-device wake word

While waiting, "Hey Sirena" can be detected with Apple's on-device speech recognition so no real audio leaves
the Mac (the Meta session stays open with silence, so waking is instant, and the last three seconds are replayed
so "Hey Sirena, next tab" runs in one go). This needs the Speech Recognition permission **and Dictation turned
on** in System Settings → Keyboard → Dictation; with Dictation off, macOS refuses every on-device request
("Siri and Dictation are disabled"). Sirena detects that, says so in the menu, and wakes through the normal
stream instead.

## Repository layout

```
Sources/Sirena            entry point
Sources/SirenaCore/App    menu bar, overlay panel wiring, onboarding, settings, hotkeys
Sources/SirenaCore/Speech mic capture + Muse Voice Transcribe realtime client (reconnect, keyword hot-swap) + one-shot fallback
Sources/SirenaCore/Listening  state machine, "Sirena" rule, utterance router
Sources/SirenaCore/Commands   fast-path parser, Muse Spark planner, executor, numbers mode, computer-use fallback, pipeline
Sources/SirenaCore/Context    running apps, windows, browser tabs, Accessibility tree snapshot, permissions
Sources/SirenaCore/Dictation  cleanup, list numbering, text edits, insertion
Sources/SirenaCore/Shortcuts  shortcut book, script format, rulebook compiler, Apple Shortcuts
Sources/SirenaCore/Notes      notes and snippets
Sources/SirenaCore/Learning   suggestions mined from the history
Sources/SirenaObjC        catches Objective-C exceptions from AVAudioEngine
Sources/SirenaCore/Overlay    the pill
Tests/                    parser and router tests
docs/                     demo script and architecture notes
scripts/                  build and run
```

## Privacy

Audio is streamed to Muse Voice Transcribe only while Sirena is on, and never stored. The model layer
receives a compact text snapshot of the screen (app names, window and tab titles, element labels), not
screenshots, except in the explicit screenshot fallback. Private mode keeps command understanding and
dictation cleanup on the Mac with Muse Glimmer.

## License

MIT, see `LICENSE`.
