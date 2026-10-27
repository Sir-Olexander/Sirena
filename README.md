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
* **Overlay.** A non-activating floating panel that never takes focus, floats over full-screen apps on every
  Space, grows and shrinks with the state, changes color in dictation mode, and can show per-stage latency
  (speech recognition · understanding · action).
* **History.** Every utterance, how it was routed, the layer used, the action and its latency go to
  `~/Library/Application Support/Sirena/history.jsonl`. No audio is stored.

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

`scripts/build-app.sh` compiles with SwiftPM, assembles `build/Sirena.app`, and signs it with your
Apple Development identity (set `SIRENA_SIGN_IDENTITY` to pick one). Signing with the same identity every
time keeps the permission grants across rebuilds. Without an identity it falls back to an ad-hoc signature,
which makes macOS forget the permissions after each rebuild.

Run the tests with `swift test`.

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
| "Sirena, go to the first tab" · "next tab" · "tab 3" · "close tab" | tabs in Chrome, Safari, Arc, Brave, Edge |
| "Sirena, command tab" · "alt tab" · "control c" · "alt F4" | shortcuts, Windows wording mapped to the Mac |
| "Sirena, scroll down" · "scroll up a bit" · "page down" · "scroll to the top" | scrolling |
| "Sirena, click Send" · "click the Reply button" · "focus the search field" | by accessibility label |
| "Sirena, send a message to Claude saying …" | switches, focuses the composer, types, asks before Enter |
| "Sirena, type hello world" | inserts the text |
| "Sirena, start dictating" … "Sirena, stop" | dictation mode |
| "Sirena, show numbers" … "click 4" · "hide numbers" | numbers mode |
| "Sirena, undo" · "Sirena, cancel" | undo or stop the last action |
| "Sirena, wait" … "Hey Sirena" | pause and wake |
| "Sirena, stop listening" | off |
| anything else, e.g. "Sirena, open the settings of this app and turn on dark mode" | Muse Spark plans it from the screen snapshot; the screenshot fallback takes over if needed |

Menu bar: on / wait / off, private mode (Glimmer), push-to-talk (hold right ⌥ to dictate, right ⌘ to
command), raw dictation, latency display, larger overlay, custom vocabulary, command history, permissions.

## Repository layout

```
Sources/Sirena            entry point
Sources/SirenaCore/App    menu bar, overlay panel wiring, onboarding, settings, hotkeys
Sources/SirenaCore/Speech mic capture + Muse Voice Transcribe realtime client (reconnect, keyword hot-swap) + one-shot fallback
Sources/SirenaCore/Listening  state machine, "Sirena" rule, utterance router
Sources/SirenaCore/Commands   fast-path parser, Muse Spark planner, executor, numbers mode, computer-use fallback, pipeline
Sources/SirenaCore/Context    running apps, windows, browser tabs, Accessibility tree snapshot, permissions
Sources/SirenaCore/Dictation  cleanup + insertion
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
