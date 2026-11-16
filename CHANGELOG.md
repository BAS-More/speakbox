# Changelog

## Unreleased

### Fixed
- Neural voices failed when SpeakBox started at sign-in if `.venv` was built inside an MSIX-packaged app,
  whose `AppData` is private to that app. `setup.ps1` now prefers a python.org Python and warns about such a `.venv`.
- A broken neural engine no longer restarts for every sentence: SpeakBox checks the `.venv`'s Python first, pauses
  restarts for 30 s after 3 failures in a row, and says why in the window instead of "Done".
- `speakbox.log` records the engine's exit code and last error lines when it exits, once per distinct failure.

### Added
- `tests/failure-paths-speakbox.ps1`: live test that breaks the engine on purpose and checks the handling.

## 1.0.0 - 2026-11-16

First public release.

### Added
- Offline neural voices: 27 Kokoro (US + British English) and Piper voices, alongside the Windows voices.
- Sentence-by-sentence playback with a seek bar (drag, click, wheel, arrow keys), read-ahead shading,
  Back / Next (`Alt+Left` / `Alt+Right`), one Play / Pause / Resume button, Clear, and a highlight on the
  sentence being read.
- Redesigned window: follows the Windows dark / light theme (`-Theme` to force one), sharp at any DPI,
  works with screen readers (custom painting on native controls).
- Tray icon that changes while speaking.
- `setup.ps1`: one-command install of the Python environment and voice models, with SHA-256 checks.
- `tools/install-autostart.ps1`: start at sign-in through a per-user scheduled task.
- Tests: CI checks, 21 component checks, 31-check live UI Automation suite.

### Fixed
- Start-up after a crash (abandoned single-instance mutex).
- Autostart blocked by other hung startup apps (Run-key queue), and below-normal priority when started by
  Task Scheduler.
- Blurry, mis-sized window when launched DPI-unaware.
- Neural engine hang on Windows when a thread waits on stdin while models load.
