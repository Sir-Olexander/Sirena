# Architecture notes

## Audio and speech

`AudioCapture` taps the default input through `AVAudioEngine`, converts to mono 16-bit PCM at 24 kHz and
emits 80 ms chunks (3840 bytes). `RealtimeTranscriber` keeps one WebSocket session open to
`wss://api.meta.ai/v1/asr/realtime`:

* handshake frame with `mode: ENDPOINTING`, `partialMode: CUMULATIVE`, `keywords`, `languageBias`;
* binary PCM frames paced by the microphone itself (real time by construction);
* events: `speechStart` → cumulative `transcript` partials → `speechEnd` → `speechComplete` (the final text);
* reconnect with backoff on close/error; proactive rotation before the 60-minute cap;
* **keyword hot-swap**: when the front app changes, a second session is opened with the new keywords and
  takes over once its handshake succeeds, so no audio is lost. Swaps only happen while nobody is speaking.
* if the realtime endpoint keeps refusing the handshake, `OneShotTranscriber` takes over: a local
  energy-based VAD cuts utterances and posts them as WAV to `/v1/asr/transcribe`.

The `asr` latency shown in the overlay is the time between the audio frame where speech ended (as reported
by `speechEnd.audioProcessedMs`) was sent and the `speechComplete` event.

### On-device wake word

In the waiting state `LocalWakeWordDetector` runs `SFSpeechRecognizer` with `requiresOnDeviceRecognition`
on the raw microphone buffers and the Meta session is closed. When "Hey Sirena" (or a close misrecognition)
shows up in the on-device partials, the realtime session is reopened and the state becomes awake. The
recognizer request is rotated every 45 s because on-device requests are limited to about a minute.

## Listening state machine (`ListeningController`)

* `off` → `awake` on click / menu / ⌃⌥⌘S. `awake` → `waiting` on "Sirena, wait" or 2 minutes of silence.
  `waiting` → `awake` on "Hey Sirena".
* `UtteranceRouter` classifies each final transcript using the state, dictation mode, pending confirmation,
  follow-up window, numbers mode and push-to-talk key. The name is only recognized at the start of an
  utterance, with a list of misrecognitions ("Serena", "siren a", …).
* The follow-up window (6 s, 15 s while numbers are visible) is restarted by every command.

## Command pipeline

1. `FastPathParser`: regex-based parser for shortcuts (with Windows → Mac mapping), app switching, tabs,
   scrolling, clicks, typing, messaging ("send a message to X saying …" expands to switch → focus composer →
   type → confirm → Enter) and Sirena's own controls. Target: action under 300 ms after the final transcript.
2. `ModelCommandPlanner`: Muse Spark with tools `press_keys`, `activate_app`, `switch_tab`, `focus_element`,
   `focus_composer`, `click_element`, `type_text`, `scroll`, `open_url`, `web_search`, `confirm`,
   `need_screen`. The prompt is a compact snapshot (`ScreenSnapshot.promptText`): front app, windows, tabs,
   up to 120 interactive elements with labels. `reasoning_effort: minimal`, `prompt_cache_key` for the
   stable system prompt. A `confirm` call splits the plan: everything after it waits for "yes".
   The planner runs a bounded loop (3 rounds): the tool calls of a round are executed, their results and a
   fresh snapshot are fed back as tool messages, and the model either continues or answers with no tool
   calls. Rounds made only of scrolls / key presses / typing end the loop immediately, because a snapshot
   cannot show their effect and the model would be tempted to repeat them. A failed element lookup is
   reported back so the model can try another label or hand over to the screenshot fallback.
3. `ComputerUseAgent`: Responses API with `tools: [{"type": "computer"}]`, screenshots through
   ScreenCaptureKit with Sirena's own windows excluded, coordinates mapped from screenshot pixels to display
   points, 8 steps max, confirmation for safety checks and for Enter after typing.

`ActionExecutor` runs actions on a private queue: `CGEvent` keyboard and mouse events, `NSRunningApplication`
/ Launch Services / AX for activation, AppleScript for browser tabs, AX `AXPress` for clicks, the clipboard
for text insertion (previous contents restored). It keeps a small undo stack (text inserted, app switched,
tab switched).

## Overlay

`OverlayPanel` is an `NSPanel` with `.nonactivatingPanel`, `canBecomeKey == false`, level `.screenSaver`,
`canJoinAllSpaces` + `fullScreenAuxiliary`. The SwiftUI `OverlayView` renders the states; the panel resizes
to the content, anchored at the bottom-center point the user dragged it to. It is excluded from the
computer-use screenshots by window ID instead of hiding it from all screen capture, so demo recordings still
show it.
