> **Owner's development notes.** History, measurements and decisions from building SpeakBox on one PC.
> Paths and dates refer to that machine. For installing and using SpeakBox, see the [README](../README.md).

# Local read-aloud

Replaces the read-aloud (speaker) button that disappeared from the Claude
desktop app. That toolbar is served from `https://claude.ai` and rendered inside
an Electron shell, so it cannot be restored by reinstalling or rolling back the
app. These tools provide the capability locally instead.

---

## Read this first: the two engines are not interchangeable

Measured on this machine, 2026-08-16:

| Engine | 199 characters | Length limit | Offline |
|---|---|---|---|
| **Local** (Windows SAPI) | **0.24s** | none | yes |
| Router `gemini/3.1-flash` | 17s | ~600 chars | no |
| Router `gemini/2.5-flash` | ~24s (intermittent 502s) | ~600 chars | no |
| Router `gemini/2.5-pro` | **>180s - unusable** | - | no |

The router synthesises **slower than real time**: 199 characters is roughly 13
seconds of speech and takes 17 seconds to generate. That is why long text
through the router times out, and why chunking does not rescue it - playback
would stall waiting on the next chunk.

**Local is the default and the right choice for reading.** Use the router only
when you want better voice quality on a sentence or two.

---

## 0. Speak Box - the fast path (runs at sign-in)

Paste or drop text, hear it immediately. No Generate button, no wait.

| Action | Result |
|---|---|
| Paste (`Ctrl+V`) | speaks immediately |
| Drag text, or a `.txt`/`.md` file, onto it | speaks immediately |
| Type + `Enter` | speaks |
| **"Speak anything I copy" on** | anything copied *anywhere* speaks - never touch the window |
| `Esc` or Stop | stops instantly |
| Seek bar (drag, click, wheel, arrow keys) | jump forward / back in the text |
| Back / Next, or `Alt+Left` / `Alt+Right` | previous / next sentence |
| Play button | speak / pause / resume |
| Clear | stop and empty the box |

The sentence being read is highlighted; the lighter part of the seek bar is
audio already prepared ahead. The window follows the Windows dark/light setting.

**Starts at sign-in** via the `HKCU\...\CurrentVersion\Run` value `SpeakBox`.
(The old `shell:startup` shortcut is renamed `Speak Box.lnk.disabled`: on
2026-11-15 no Startup-folder item ran at boot, while Run-key entries did.)
Startup errors are written to `speakbox.log`. To run it by hand:

```
wscript.exe C:\Dev\tools\tts\Start-SpeakBox.vbs
```

### Voices

| Engine | Voices | Quality / speed (this PC, measured) |
|---|---|---|
| **Kokoro** (neural) | 27 English, US + British | best quality; ~real time on CPU (fp32 model) |
| **Piper** (neural) | 9 English (`voices/piper/`) | good; ~6-10x faster than real time |
| Windows | the installed SAPI voices | robotic; instant |

Kokoro and Piper run offline in `speakbox_engine.py` (a JSON-lines helper over
stdin/stdout, run by `bench\.venv`), started on first use and kept warm. The
model files are **not in git** (about 5 GB). To set up on a new machine:

- Kokoro: `bench/models/kokoro-v1.0.fp32.onnx` + `bench/models/voices-v1.0.bin`
  (from the kokoro-onnx v1.0 release).
- Piper: `voices/piper/<voice>.onnx` + `.onnx.json` from
  [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices).
- Python venv in `bench/.venv` with `piper-tts`, `kokoro-onnx`, `numpy`.

Missing models just mean those voices are not listed.

### Tests

```
pwsh -NoProfile -File C:\Dev\tools\tts\tests\components-speakbox.ps1
pwsh -NoProfile -STA -File C:\Dev\tools\tts\tests\e2e-speakbox.ps1
```

`components` (21 checks) needs no running app. `e2e` (31 checks) drives the live
window through UI Automation - no mouse or keyboard - so it speaks aloud,
replaces the box text, and briefly uses the clipboard (restored afterwards).

### It lives in the system tray

Closing the window (or minimising it) **hides it to the tray** - the app keeps
running and the clipboard watcher keeps working. Only **Exit** on the tray menu
actually quits.

| Tray action | Result |
|---|---|
| Double-click the icon | reopen the window |
| Right-click | Show / Speak clipboard / Stop / Speak on copy / Exit |
| Running the launcher again | restores the hidden window (no second copy) |

The tray "Speak on copy" item and the in-window checkbox stay in sync.

Single-instance is enforced by a named mutex. A second launch does not open a
rival window; it signals the running one to show itself. That signal is a named
`EventWaitHandle` polled on a UI-thread timer, deliberately **not** a
cross-process `ShowWindow` - see the trap below for why that would be fatal, and
note `SetForegroundWindow` alone cannot un-hide a tray-hidden window.

Voice, speed and the "speak on copy" setting persist in `speakbox.state.json`.
Activity goes to `speakbox.log`.

### Behaviour notes

**Copying elsewhere never writes into the box.** The clipboard watcher speaks
what you copied but leaves your typed text alone. An earlier version pasted the
clipboard into the box on every `Ctrl+C`, which made ordinary copying look like
the app was hijacking the window.

**Speed applies from the next utterance.** `SpeechSynthesizer` fixes the rate at
the start of a passage, so moving the slider mid-sentence changes nothing you
can hear - which reads as a dead control. Releasing the slider now restarts the
current passage at the new rate. Measured effect on the same sentence: rate -4
gives 14s of audio, rate 0 gives 9.1s, rate +5 gives 5.2s.

The slider is wired to `ValueChanged`, not `Scroll`: `Scroll` misses keyboard and
several click paths, so the thumb could move without the rate ever being applied.

### Two Windows traps this had to work around

Both cost real debugging time; do not undo either.

**The window launched invisible.** `WScript.Shell.Run(cmd, 0, False)` hides the
console by putting `SW_HIDE` in the process `STARTUPINFO`, and .NET applies that
show-state to the process's *first* top-level window - the form. The app ran
perfectly and stayed invisible forever. Fixed by forcing visibility in
`Form.Shown` through the managed properties (`WindowState`, `Visible`,
`BringToFront`, `Activate`).

**`ShowWindow(hwnd, SW_SHOW)` from another process kills this app outright.**
Verified in isolation: the process dies between that call and the next
statement, with no exception and no `FormClosed`. The first single-instance
implementation used exactly that call to surface the running window, so an
innocent second launch silently killed the instance the user was working in.
`Surface()` now uses `SetForegroundWindow` only, and there is no raw
`ShowWindow` anywhere in this codebase. Do not add one.

**A reader thread blocking on stdin hangs Python model loading.** On Windows,
I/O on one pipe handle is serialized, so while the engine's reader thread waits
on stdin, libraries probing stdin during model load block forever.
`speakbox_engine.py` keeps the request pipe on a duplicated descriptor and
points fd 0 at NUL.

**Painting a `TrackBar` subclass must not read `.Value`.** The native control
repaints *before* it notifies WinForms; reading `.Value` during that paint syncs
the cached value early, so `ValueChanged` never fires. `SbSlider` reads
`TBM_GETPOS` instead. Custom controls are built on native `TrackBar` / `Button`
(painted by us) because plain `Control` subclasses show up to UI Automation and
screen readers as an anonymous "Pane".

---

## 1. Tray reader - hotkey on any selection

Select text in any application, press the hotkey, hear it.

| Key | Action |
|---|---|
| `Ctrl+Alt+R` | speak the current selection (falls back to clipboard) |
| `Ctrl+Alt+S` | stop playback |

Start it:

```
wscript.exe C:\Dev\tools\tts\Start-SpeakSelection.vbs
```

The `.vbs` launcher starts it with no console window. For it to load at sign-in,
put a shortcut to that file in `shell:startup`.

Tray menu: **Speak selection**, **Speak clipboard**, **Stop**, **Engine**
(Local / Router), **Voice (local)**, **Model (router)**, **Speed (local)**, and
**Open log**. Double-clicking the tray icon is the same as the hotkey. Every
choice persists in `speak-selection.state.json`.

Installed local voices include `Microsoft Catherine` and `Microsoft James`
(en-AU), plus en-US and en-GB options.

Activity is logged to `speak-selection.log`.

### Known trade-offs

- **Only clipboard *text* is preserved** across a selection capture. The tool
  copies the selection with `Ctrl+C` and restores the previous clipboard text
  afterwards; images and file lists are not restored.
- **Router engine is capped at 600 characters** (`-RouterMaxChars`) and warns
  when it truncates. The cap exists because of the throughput above.
- `gemini/2.5-pro` is deliberately absent from the menu - it exceeded 180s on a
  199-character sample.

---

## 2. Read-Aloud.ps1 - the command line

Router-engine synthesis. The tray app calls this for its Router mode.

```powershell
C:\Dev\tools\tts\Read-Aloud.ps1 -Text "Build is green."
Get-Content notes.md -Raw | C:\Dev\tools\tts\Read-Aloud.ps1
C:\Dev\tools\tts\Read-Aloud.ps1 -Path notes.md -Model gemini/gemini-3.1-flash-tts-preview -NoPlay
```

Returns an object with `Path`, `Format`, `KB`, `Model`, `Chars`. Audio lands in
`%TEMP%\claude-tts\`.

`-TimeoutSec` defaults to 120, which at measured throughput covers roughly 1300
characters. Raise it for more, or use the local engine. Transient failures retry
three times with exponential backoff; 4xx fails fast, since retrying an
unchanged bad request cannot help.

---

## 3. OpenAI_TTS_GUI - REMOVED

A third-party PyQt6 client was trialled here and deleted on 2026-08-16: 227.8 MB
for a tool only useful for long documents through the slow router, plus a
non-OSI licence with a commercial-use fee. `Start-TtsGui.ps1` and
`apply-local-patch.ps1` went with it.

Any audio it produced is still in `output\`; nothing generated was deleted.

### If you ever want it back

Upstream is <https://github.com/sm18lr88/OpenAI_TTS_GUI> by **Leo Riera /
sm18lr88**, under an Attribution and Honor-System Commercial License - **not**
an OSI licence. Non-commercial use is encouraged; **commercial use requires a
USD $5 honor-system licence** from the author.

```
git clone https://github.com/sm18lr88/OpenAI_TTS_GUI.git
uv sync
```

Needs `ffmpeg` on PATH and Python 3.14. ffmpeg was installed for this app and
uninstalled with it, so you would need it again:
`winget install Gyan.FFmpeg`. It will not work against 9Router unmodified: four values in
`src/openai_tts_gui/config/settings.py` are hardcoded for OpenAI, at OpenAI's
speed, on a machine without Controlled Folder Access. Wrap each in an env
override:

| Value | Upstream | Why it breaks here |
|---|---|---|
| `TTS_MODELS` | `["tts-1", "tts-1-hd", "gpt-4o-mini-tts"]` | none exist on 9Router - every request 502s |
| `DEFAULT_OUTPUT_DIR` | `~/Music/OpenAI-TTS` | Controlled Folder Access blocks it; startup dies with `WinError 2` |
| `OPENAI_TIMEOUT` | `60.0` | assumes OpenAI-speed synthesis |
| `MAX_CHUNK_SIZE` | `4096` | ~6 minutes per chunk at router speed |

Then set `OPENAI_BASE_URL` to `$env:NINEROUTER_URL/v1` and `OPENAI_API_KEY` to
any placeholder - 9Router needs no auth, but the OpenAI client library refuses
to start without a value. Request **wav**: the router returns `audio/wav`
whatever `response_format` asks for. Ignore its cost estimates; they come from
OpenAI's price list.

---

## Troubleshooting

**It times out.** You are on the Router engine. Switch to Local in the tray menu
(Engine -> Local). See the throughput table at the top.

**Nothing happens on the hotkey.** Another app may already own `Ctrl+Alt+R`;
registration failure is logged and shown as a balloon tip at startup. Check the
process is alive:

```powershell
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" |
  Where-Object { $_.CommandLine -like '*-File*SpeakSelection.ps1*' }
```

**Every router model returns 502.** Check the router is up:
`curl $env:NINEROUTER_URL/v1/models/tts`. If it answers but synthesis fails, the
upstream provider key is the problem, not the router. Note that `openai/*` and
`openrouter/*` always 502 here - no OpenAI key is configured.

**Nothing here needs ffmpeg.** It was installed only for the GUI and removed
with it. The local engine writes no files, and `Read-Aloud.ps1` writes WAV
directly.

---

## License

Copyright 2026 BAS-More. Licensed under the [Apache License 2.0](LICENSE).

This repository contains only SpeakBox's own code. The speech engines and
voices it uses are separate downloads under their own licenses:

| Component | License |
|---|---|
| [Piper](https://github.com/OHF-Voice/piper1-gpl) (`piper-tts`) and `phonemizer` | GPL-3.0 |
| [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx), ONNX Runtime | MIT |
| Kokoro-82M model | Apache-2.0 |
| Piper voices | per voice - see each voice's model card on Hugging Face |

If you redistribute a bundle that includes Piper, that bundle as a whole is
covered by the GPL-3.0.
