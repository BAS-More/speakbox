<#
.SYNOPSIS
    Component tests for SpeakBox (21 checks): script parses, sentence splitter,
    neural engine round trip (Piper + Kokoro, flush/drop), WAV player (MCI open,
    seek, pause, end), Windows voice to WAV. Does not need the app running.
.EXAMPLE
    pwsh -NoProfile -File C:\Dev\tools\tts\tests\components-speakbox.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot   # C:\Dev\tools\tts
$src = Join-Path $Root 'SpeakBox.ps1'
$errs = $null
[System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$errs) | Out-Null
"PARSE errors: $($errs.Count)"; $errs | ForEach-Object { "  $($_.Message) @ $($_.Extent.StartLineNumber)" }

$text = Get-Content $src -Raw
$m = [regex]::Match($text, "(?s)# --- native helpers.*?Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Add-Type -TypeDefinition $m.Groups[1].Value
$fail = 0
function Check($name, $cond) { if ($cond) { "PASS $name" } else { "FAIL $name"; $script:fail++ } }

# Splitter
$t = "Hello there. How are you?`nFine!  Thanks.`r`n`r`n...`n""Quoted.""  End"
$r = [SbText]::Split($t, 220)
$parts = for ($i = 0; $i -lt $r.Length; $i += 2) { $t.Substring($r[$i], $r[$i + 1]) }
Check 'split count' ($parts.Count -eq 6)
Check 'split content' (($parts -join '|') -eq 'Hello there.|How are you?|Fine!|Thanks.|"Quoted."|End')
$long = ('word ' * 200)
$r2 = [SbText]::Split($long, 220)
$lens = for ($i = 1; $i -lt $r2.Length; $i += 2) { $r2[$i] }; Check "long split capped (max $(($lens | Measure-Object -Maximum).Maximum), n $($lens.Count))" (($lens | Measure-Object -Maximum).Maximum -le 230 -and $lens.Count -ge 4)
Check 'empty split' ([SbText]::Split('  ...  ', 220).Length -eq 0)

# Engine round trip + timing
$e = New-Object SbEngine
Check 'engine start' ($e.Start((Join-Path $Root 'bench\.venv\Scripts\python.exe'), (Join-Path $Root 'speakbox_engine.py')))
$tmp = Join-Path $env:TEMP 'SpeakBoxTest'; New-Item -ItemType Directory -Force $tmp | Out-Null
$e.Send((@{cmd='flush';gen=2} | ConvertTo-Json -Compress)) | Out-Null; Start-Sleep -Milliseconds 200; $sw = [Diagnostics.Stopwatch]::StartNew()
$e.Send((@{cmd='synth';id=1;gen=2;engine='piper';voice='en_GB-alan-medium';text='This is the first sentence from Alan.';speed=1.0;out="$tmp\1.wav"} | ConvertTo-Json -Compress)) | Out-Null
$e.Send((@{cmd='flush';gen=2} | ConvertTo-Json -Compress)) | Out-Null
$e.Send((@{cmd='synth';id=2;gen=1;engine='piper';voice='en_GB-alan-medium';text='Stale, should drop.';speed=1.0;out="$tmp\2.wav"} | ConvertTo-Json -Compress)) | Out-Null
$e.Send((@{cmd='synth';id=3;gen=2;engine='kokoro';voice='bf_emma';text='Hello, I am Emma, a Kokoro voice.';speed=1.3;out="$tmp\3.wav"} | ConvertTo-Json -Compress)) | Out-Null
$got = @{}
while ($got.Count -lt 3 -and $sw.Elapsed.TotalSeconds -lt 60) {
    $l = $null
    if ($e.TryRead([ref]$l)) { $o = $l | ConvertFrom-Json; if ($o.PSObject.Properties['id']) { $got[[int]$o.id] = $o; "  reply @{0:n1}s: {1}" -f $sw.Elapsed.TotalSeconds, $l } }
    else { Start-Sleep -Milliseconds 50 }
}
Check 'piper ok' ($got[1].ok -and (Test-Path "$tmp\1.wav"))
Check 'stale dropped' ((-not $got[2].ok) -and $got[2].error -eq 'dropped')
Check 'kokoro ok' ($got[3].ok -and (Test-Path "$tmp\3.wav"))
$e.Stop()
Check 'engine stopped' (-not $e.Alive)

# Player: open, play from offset, position advances, pause holds, ends
$p = New-Object SbWavPlayer
Check 'mci open' ($p.Open("$tmp\1.wav"))
$len = $p.Length; "  length ms: $len"
Check 'mci length' ($len -gt 1000)
Check 'mci play from' ($p.Play([int]($len / 2)))
Start-Sleep -Milliseconds 300
$pos1 = $p.Position; Check "mci position after seek ($pos1)" ($pos1 -ge $len / 2)
Check "mci mode playing" ($p.Mode -eq 'playing')
$p.Pause(); $a = $p.Position; Start-Sleep -Milliseconds 400; $b = $p.Position
Check "mci pause holds ($a -> $b)" ([Math]::Abs($b - $a) -lt 50 -and $p.Mode -eq 'paused')
$p.Resume(); Start-Sleep -Milliseconds ($len / 2 + 400)
Check "mci ends -> stopped ($($p.Mode))" ($p.Mode -eq 'stopped')
$p.Close()
Check 'mci closed' ($p.Mode -eq 'closed')

# SAPI to wav, played by MCI
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SetOutputToWaveFile("$tmp\w.wav"); $s.Speak('Windows voice test.'); $s.SetOutputToNull()
Check 'sapi wav plays' ($p.Open("$tmp\w.wav") -and $p.Length -gt 300)
$p.Close()
Remove-Item $tmp -Recurse -Force
"FAILURES: $fail"
exit [int]($fail -gt 0)

