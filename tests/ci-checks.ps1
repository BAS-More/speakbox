<#
.SYNOPSIS
    Checks that need no models, no Python packages and no audio device, so they
    run on a GitHub Actions windows-latest runner (and anywhere else).

.DESCRIPTION
    * every .ps1 in the repo parses
    * all C# embedded in SpeakBox.ps1 compiles, and the custom controls and the
      tray icon can be created
    * the sentence splitter behaves (offsets, quotes, long text, empty text)
    Python files are compile-checked separately by the workflow.

.EXAMPLE
    pwsh -NoProfile -File tests\ci-checks.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$fail = 0
function Check($name, $cond, $detail = '') {
    if ($cond) { "PASS $name $detail" } else { "FAIL $name $detail"; $script:fail++ }
}

# --- every script parses ---------------------------------------------------------
foreach ($f in Get-ChildItem -Path $Root -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '\\\.venv\\|\\bench\\\.venv\\' }) {
    $errs = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs) | Out-Null
    Check "parses: $($f.FullName.Substring($Root.Length + 1))" ($errs.Count -eq 0) (($errs | ForEach-Object { "$($_.Message) @$($_.Extent.StartLineNumber)" }) -join '; ')
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$src = Get-Content (Join-Path $Root 'SpeakBox.ps1') -Raw

# --- native helpers (player, engine client, splitter) -------------------------------
$m = [regex]::Match($src, "(?s)# --- native helpers.*?Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Check 'found native helper C#' $m.Success
Add-Type -TypeDefinition $m.Groups[1].Value
Check 'native helpers compile' ([bool]('SbText' -as [type]) -and [bool]('SbWavPlayer' -as [type]) -and [bool]('SbEngine' -as [type]))

# --- custom UI controls ---------------------------------------------------------------
$m = [regex]::Match($src, "(?s)(\`$script:UiRefs = .*?)\r?\nAdd-Type -ReferencedAssemblies \`$script:UiRefs -TypeDefinition @'\r?\n(.*?)\r?\n'@")
Check 'found UI control C#' $m.Success
Invoke-Expression $m.Groups[1].Value
Add-Type -ReferencedAssemblies $script:UiRefs -TypeDefinition $m.Groups[2].Value
foreach ($t in 'SbSlider', 'SbButton', 'SbCombo', 'SbToggle') {
    $o = New-Object $t
    Check "creates $t" ($null -ne $o)
    $o.Dispose()
}
$ico = [SbUi]::MakeIcon(32, [Drawing.Color]::SlateBlue, [Drawing.Color]::DeepSkyBlue, $true)
Check 'tray icon renders' ($ico.Width -eq 32)

# --- clipboard listener -------------------------------------------------------------------
$m = [regex]::Match($src, "(?s)# --- clipboard listener.*?Add-Type -ReferencedAssemblies (.*?) -TypeDefinition @'\r?\n(.*?)\r?\n'@")
$refs = [regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
Add-Type -ReferencedAssemblies $refs -TypeDefinition $m.Groups[2].Value
Check 'clipboard listener compiles' ([bool]('ClipboardSink' -as [type]))

# --- sentence splitter -------------------------------------------------------------------
function Parts([string] $t) {
    $r = [SbText]::Split($t, 220)
    for ($i = 0; $i -lt $r.Length; $i += 2) { $t.Substring($r[$i], $r[$i + 1]) }
}
$t = "Hello there. How are you?`nFine!  Thanks.`r`n`r`n...`n""Quoted.""  End"
Check 'splitter: sentences + quotes' ((@(Parts $t) -join '|') -eq 'Hello there.|How are you?|Fine!|Thanks.|"Quoted."|End')
Check 'splitter: decimals stay whole' ((@(Parts 'It costs 3.50 today. Yes.') -join '|') -eq 'It costs 3.50 today.|Yes.')
$long = 'word ' * 200
$r = [SbText]::Split($long, 220)
$lens = for ($i = 1; $i -lt $r.Length; $i += 2) { $r[$i] }
Check 'splitter: long text chunked' (($lens | Measure-Object -Maximum).Maximum -le 230 -and $lens.Count -ge 4)
Check 'splitter: punctuation-only is empty' ([SbText]::Split('  ...  ', 220).Length -eq 0)
Check 'splitter: offsets map back' (@(Parts 'One. Two.')[1] -eq 'Two.')

"FAILURES: $fail"
exit [int]($fail -gt 0)
