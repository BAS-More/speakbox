# Contributing

Thanks for helping. Issues and pull requests are welcome.

## Before you change code

Read [Windows gotchas](README.md#windows-gotchas-do-not-undo-these) in the README. Several
"simplifications" (a raw `ShowWindow`, reading `.Value` while painting a slider, plain `Control`
subclasses, the Run key for autostart) bring back bugs that were hard to find.

## Set up

```powershell
pwsh -File .\setup.ps1 -AllVoices
```

## Test

| Command | Needs | Runs in CI |
|---|---|---|
| `pwsh -NoProfile -File tests\ci-checks.ps1` | nothing | yes |
| `pwsh -NoProfile -File tests\components-speakbox.ps1` | `setup.ps1` done, an audio device | no |
| `pwsh -NoProfile -STA -File tests\e2e-speakbox.ps1` | the above + SpeakBox running | no |

The e2e suite speaks aloud, replaces the text in the window and briefly uses the clipboard.
If you change the UI, run it and say so in the pull request.

To refresh the screenshots in `docs/`: `pwsh -NoProfile -STA -File tools\make-docs-images.ps1`.

## Ground rules

- **SpeakBox stays offline.** Anything that needs the network belongs with the extras
  (`Read-Aloud.ps1`), not in the app.
- Keep changes small and focused, matching the existing style.
- No secrets, tokens or personal paths in commits.
