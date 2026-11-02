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

### The Mac's own sound (`EchoCanceller`, `EchoGate`, `SystemAudioTap`)

Voice processing cancels only Sirena's own playback and only on the default input, so other apps' sound reached
the recognizer (a song's "Hey, welcome…" was heard as "Hey Sirena", lyrics ran as commands). While Sirena is not
off and Core Audio reports another process with output running, `SystemAudioTap` captures the system mix with
ScreenCaptureKit (24 kHz mono, own process excluded, 2×2-pixel video ignored) as a reference stamped with host
time; `AudioCapture` stamps every microphone chunk the same way. The reference is kept as a continuous stream by
absolute sample index (jitter under 4 ms ignored). A microphone chunk waits until its stretch of reference has
arrived (it lags the microphone by up to ~100 ms), then `EchoCanceller` subtracts the predicted echo: a
partitioned-block frequency-domain NLMS filter (10 ms blocks, 480-point transforms, 24 partitions = 240 ms path),
normalized by the reference power over the filter span (peak-held on every block, so a loud passage after a pause
cannot overshoot), gradient-constrained on every partition, frozen while a voice is heard, slowed once converged
when the residual is not echo-like, reset if the residual stays louder than the microphone. About 19 dB of
cancellation on simulated music through a distorting laptop speaker; ~1.3% of one core in release.

`EchoGate` then judges the canceller's output, per 10 ms frame in five bands (150 Hz–6 kHz): the delay and the
speaker-to-microphone coupling are learned on the raw microphone (median of microphone-minus-reference on loud,
voice-free frames; stable per device pair and what is stored); the canceller's current reduction per band is
measured on the same frames; the leftover echo is predicted as reference + coupling − reduction, with a
reverberation tail and a few frames of slack, power-summed with the room-noise floor (learned only while nothing
plays). A frame is a voice when the speech bands (400–3200 Hz) exceed it by 10 dB (the leftover is spikier than raw
echo); a chunk opens with 50 ms of voice, keeps 400 ms of hangover and releases the chunk before it (one chunk of
lookahead). The recognizer gets the cleaned audio when open, silence otherwise. Excess that rises and falls with the reference (r > 0.8
over 200 ms, no voice just before) is louder echo, not a voice: the coupling is raised at once (at most 12 dB) and
fades back by 2 dB/s. A hiss rise
above 3.2 kHz keeps the gate open within a phrase. Learned coupling is stored per microphone/speaker pair;
built-in speakers into the built-in microphone start from values measured on a MacBook Air. Tuned on real
recordings (`--selftest echo` records to /tmp/sirena-echo and transcribes with and without the gate) and on
`EchoSimulation` (a ringtone with sung lyrics through a laptop speaker and room, the user's command at chosen levels;
`--selftest echo-sim`, `sirena-cli echo-bench`).

### On-device wake word

In the waiting state `LocalWakeWordDetector` runs `SFSpeechRecognizer` with `requiresOnDeviceRecognition`
on the raw microphone buffers. `StreamGate` keeps the Meta session open but sends zeros instead of audio,
holding the last ~3 s of real audio locally. When "Hey Sirena" shows up in the on-device partials, the gate
goes live and replays that pre-roll, so "Hey Sirena, switch to Chrome" said in one breath reaches the
recognizer whole; the router turns it into wake + command.

The detector must prove it works before audio goes private (1.2 s without errors), and it reports failure
instead of retrying silently: fatal recognizer errors (kLSRErrorDomain 201 "Siri and Dictation are disabled"
is what a Mac with Dictation off returns), three errors in 20 s, or four seconds of speech-like audio with no
recognition result. The controller then switches back to streaming real audio. A probe at launch marks it
unavailable up front and the menu shows why.

### Microphone

`AudioCapture` enables voice processing on the input node (noise suppression, AGC, echo cancellation, other
audio not ducked). It tries, in order: voice processing with an echo-cancelled player node (used for reading
aloud), voice processing without it (Bluetooth headsets in call mode report a 0 Hz output format and fail to
initialize with the player attached, -10875), then the plain microphone. AVAudioEngine graph calls run inside
an Objective-C `@try` (`SirenaObjC`) because invalid formats raise exceptions Swift cannot catch.

### Reading aloud

`ReadAloud` synthesizes sentence by sentence with `AVSpeechSynthesizer.write` (on-device voice chosen by the
text's language), converts and schedules buffers on the player node, and reports progress per sentence. Speed
changes restart the current sentence. Transcripts that match the sentences around the current one are dropped
as echo (`isLikelyEcho`), so Sirena never acts on her own voice even without echo cancellation.
`TextExtractor` gets the selection (Accessibility, else ⌘C with the clipboard restored), the article (`<article>`
/ `<main>` landmarks, prose blocks, skipping navigation, sidebars and anything whose DOM class looks like an ad,
footer, share bar or recommendation), or all visible text.

## Listening state machine (`ListeningController`)

* `off` → `awake` on click / menu / ⌃⌥⌘S. `awake` → `waiting` on "Sirena, wait" or 2 minutes of silence.
  `waiting` → `awake` on "Hey Sirena".
* `UtteranceRouter` classifies each final transcript using the state, dictation mode, pending confirmation,
  follow-up window, numbers mode and push-to-talk key. The name is only recognized at the start of an
  utterance, with a list of misrecognitions ("Serena", "siren a", …).
* The follow-up window (8 s, 12 s after a wake, 15 s while numbers are visible) is restarted by every command and
  stays open while one runs. It is checked against the recognizer's speech start of the utterance, not the
  arrival of its transcript. Until 20 s after the last command a quiet stretch lets safe fast-path commands
  (`FastPathParser.isSafeWithoutName`) run without the name, through the fast path only.
* `CommandShape` classifies name-less speech as command, filler, incomplete, question or chatter; only commands
  reach the pipeline. A control next to the name anywhere in the utterance ("wait Sirena") counts as named.
* When the recognizer reports the end of speech, `ListeningController.prepareEarly` takes the element snapshot and,
  for words only the model can handle, sends the first model call (or the dictation cleanup) with the last partial
  transcript; the result is used only if the final transcript matches. Nothing acts before the final transcript.

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

## Shortcuts, notes, learning

* `ShortcutBook` stores named commands as a readable script (one step per line, `docs/shortcut-rulebook.md`).
  Triggers support `{placeholders}`; matching is exact for placeholders and fuzzy (0.86) for plain names.
  `ShortcutScript.enforceConfirmations` inserts a `confirm` before sending, calling, deleting, buying or
  submitting, both when saving and when running. `ShortcutCompiler` writes steps with Muse Spark following the
  rulebook, with the real labels and menus of running apps and the user's Apple Shortcuts as context.
* The pipeline order is: Sirena's controls → saved shortcuts (and Apple Shortcuts after "run") → snippets →
  fast path → model loop → screenshot fallback. Every history entry carries the session id, the command, the
  structured actions and a failure flag.
* `UsageLearner` mines that history after turn-off (no model calls): commands undone or rephrased right after
  running, commands that needed the model twice with the same plan (or the screen twice), and failures followed
  by successful commands. It drops "this/that" commands, labels with counters or dates, numbered clicks and
  dismissed triggers, adds confirmations to irreversible steps, ranks by usefulness, keeps at most three pending
  and adds new ones at most once a day.
* `SessionStats` meters audio seconds, tokens per category, screen reads and their triggering command,
  commands per layer, failures, latencies, reconnects and wake methods, priced with the published rates.

## Overlay

`OverlayController` keeps one `OverlayPanel` per screen (rebuilt when screens change), all bound to the same
`OverlayModel`; each panel remembers its position as an offset from its screen's origin (keyed by display UUID).
The active screen (front window's screen, polled once a second) gets a marker and the other copies are dimmed.
`OverlayPanel` is an `NSPanel` with `.nonactivatingPanel`, `canBecomeKey == false`, level `.screenSaver`,
`canJoinAllSpaces` + `fullScreenAuxiliary`. The SwiftUI `OverlayView` renders the states; the panel resizes
to the content, anchored at the bottom-center point the user dragged it to. It is excluded from the
computer-use screenshots by window ID instead of hiding it from all screen capture, so demo recordings still
show it.
