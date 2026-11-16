<#
.SYNOPSIS
    One-time setup for Speak Box: Python environment + neural voice models.

.DESCRIPTION
    1. Creates .venv (with uv if installed, otherwise Python's venv + pip) and
       installs requirements.txt.
    2. Downloads the Kokoro model (~350 MB) into models\.
    3. Downloads Piper voices (~60-120 MB each) into voices\piper\.
    Every download is checked against a pinned SHA-256. Files that are already
    present and correct are skipped, so it is safe to run again.

    Without any of this, Speak Box still works with the built-in Windows voices.

.PARAMETER Voices
    Piper voices to install. Default: a small UK + US set.
.PARAMETER AllVoices
    Install all 9 Piper voices (~700 MB).
.PARAMETER NoKokoro
    Skip the Kokoro model (Kokoro voices then do not appear).
.PARAMETER NoPython
    Skip the Python environment (only download models).
.PARAMETER Autostart
    Also start Speak Box when you sign in (runs tools\install-autostart.ps1).

.EXAMPLE
    pwsh -File .\setup.ps1
.EXAMPLE
    pwsh -File .\setup.ps1 -AllVoices -Autostart
#>
[CmdletBinding()]
param(
    [string[]] $Voices = @('en_GB-alan-medium', 'en_GB-cori-high', 'en_US-amy-medium', 'en_US-ryan-high'),
    [switch] $AllVoices,
    [switch] $NoKokoro,
    [switch] $NoPython,
    [switch] $Autostart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest is many times slower with the progress bar on

$Root = $PSScriptRoot

# --- pinned downloads ---------------------------------------------------------------
$KokoroBase = 'https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0'
$Kokoro = @(
    @{ Name = 'kokoro-v1.0.onnx'; Url = "$KokoroBase/kokoro-v1.0.onnx"; Sha = '7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5' }
    @{ Name = 'voices-v1.0.bin';  Url = "$KokoroBase/voices-v1.0.bin";  Sha = 'bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d' }
)

$PiperBase = 'https://huggingface.co/rhasspy/piper-voices/resolve/main/en'
# voice id -> (repo sub-path, sha256 of .onnx, sha256 of .onnx.json)
$Piper = [ordered]@{
    'en_GB-alan-medium'                  = @('en_GB/alan/medium', '0a309668932205e762801f1efc2736cd4b0120329622adf62be09e56339d3330', 'c0f0d124e5895c00e7c03b35dcc8287f319a6998a365b182deb5c8e752ee8c1e')
    'en_GB-alba-medium'                  = @('en_GB/alba/medium', '1f9da809b6da1ef4190bb5dd6cce4f4af803274539e9cf9e0693085150bac3d7', '6214603a0dd60e9dcd05502e23ef07fbe3d9af36d3189c8cc3eb129e1a099d6f')
    'en_GB-cori-high'                    = @('en_GB/cori/high', '470b4dd634c98f8a4850d7626ffc3dfc90774628eeef6605a6dd8f88f30a5903', '9e7fb5b5671612c22f3c81cbe46c1ae87b031a4632bcb509e499dad6f1e2adec')
    'en_GB-jenny_dioco-medium'           = @('en_GB/jenny_dioco/medium', '62ba183a504cfcd8816ec1b50ee856ed318ccc9dd22fd0bedd7d839c95dfa20e', 'e489b3990e455d6378f12dbb4afa11e8e692a0168f1ed8e5c285dd2f08547567')
    'en_GB-northern_english_male-medium' = @('en_GB/northern_english_male/medium', '57a219ae8e638873db7d18893304be5069c42868f392bb95c3ff17f0690d0689', '69557ed3d974463453e9b0c09dd99a7ed0e52b8b87b64b357dbeeb2540a97d47')
    'en_GB-southern_english_female-low'  = @('en_GB/southern_english_female/low', 'f2f37aed1b3a093476f719d1379ba0c0b1b1cf6f1ef99288e2ebf502971a07c3', 'a1af43310f8756161506e849a2863d342a98b0853af9e2437581d39e9922d0e5')
    'en_US-amy-medium'                   = @('en_US/amy/medium', 'cf9ccdec59f05adee47173f6fb4d89e8b0c5f30c178748d2572fe4efd1d2724c', '8c9b8aa3ee122c6a63678bd68e586a067c6775116d32e13b7ec919520d8948bf')
    'en_US-lessac-medium'                = @('en_US/lessac/medium', '5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f', 'efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0')
    'en_US-ryan-high'                    = @('en_US/ryan/high', 'b3990d7606e183ec8dbfba70a4607074f162de1a0c412e0180d1ff60bb154eca', 'c6d3b98f08315cb4bebf0d49d50fc4ff491b503c64b940cd3d5ca28543b48011')
}

function Get-Verified([string] $Url, [string] $Dest, [string] $Sha) {
    $name = Split-Path $Dest -Leaf
    if ((Test-Path -LiteralPath $Dest) -and (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash -eq $Sha) {
        Write-Host "  ok        $name (already present)"
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Dest) | Out-Null
    $part = "$Dest.part"
    Write-Host "  download  $name"
    Invoke-WebRequest -Uri $Url -OutFile $part -UseBasicParsing
    $got = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash
    if ($got -ne $Sha) {
        Remove-Item -LiteralPath $part -Force
        throw "Checksum mismatch for $name (expected $Sha, got $($got.ToLower())). Nothing was installed for this file."
    }
    Move-Item -LiteralPath $part -Destination $Dest -Force
}

# --- 1. Python environment ---------------------------------------------------------------
if (-not $NoPython) {
    Write-Host 'Python environment (.venv)'
    $venvPy = Join-Path $Root '.venv\Scripts\python.exe'
    $req = Join-Path $Root 'requirements.txt'
    $uv = Get-Command uv -ErrorAction SilentlyContinue
    if ($uv) {
        # Prefer a python.org / py-launcher install over a uv-managed one: when this runs
        # inside an MSIX-packaged app (some AI desktop apps), uv's AppData is virtualized
        # and the .venv would point at a Python that SpeakBox cannot see at sign-in.
        if (-not (Test-Path $venvPy)) { & $uv.Source venv (Join-Path $Root '.venv') --python 3.13 --python-preference system --quiet; if ($LASTEXITCODE) { throw 'uv venv failed' } }
        & $uv.Source pip install --python $venvPy -r $req --link-mode copy --quiet
        if ($LASTEXITCODE) { throw 'uv pip install failed' }
    }
    else {
        if (-not (Test-Path $venvPy)) {
            $py = Get-Command py -ErrorAction SilentlyContinue
            if ($py) { & $py.Source -3 -m venv (Join-Path $Root '.venv') }
            else {
                $python = Get-Command python -ErrorAction SilentlyContinue
                if (-not $python) { throw 'Python 3.11+ not found. Install it from python.org (or install uv), then run setup.ps1 again.' }
                & $python.Source -m venv (Join-Path $Root '.venv')
            }
            if ($LASTEXITCODE) { throw 'Creating .venv failed' }
        }
        & $venvPy -m pip install --quiet --disable-pip-version-check -r $req
        if ($LASTEXITCODE) { throw 'pip install failed' }
    }
    # Warn about a .venv whose base Python may live only in a packaged app's private
    # AppData copy. Only a warning: from inside a packaged app the real and private
    # copies look the same, so a matching private copy does not prove the real one is gone.
    $venvHome = ((Get-Content (Join-Path $Root '.venv\pyvenv.cfg') | Where-Object { $_ -match '^\s*home\s*=' } | Select-Object -First 1) -replace '^\s*home\s*=\s*', '').Trim()
    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if ($venvHome -and $base -and $venvHome.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $venvHome.Substring($base.Length).TrimStart('\')
            $kind = if ($base -eq $env:APPDATA) { 'Roaming' } else { 'Local' }
            $hidden = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Packages') -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName "LocalCache\$kind\$rel\python.exe") } | Select-Object -First 1
            if ($hidden) {
                Write-Warning (".venv uses $venvHome, and a private copy of it exists inside the packaged app '$($hidden.Name)'. " +
                    'If that private copy is the only one, neural voices will fail when SpeakBox starts at sign-in ' +
                    '(speakbox.log: "did not find executable", exit code 103). To be safe: delete .venv, install Python 3.13 ' +
                    'from python.org, and run setup.ps1 again from a normal terminal.')
            }
        }
    }
    $ver = & $venvPy -c "import sys, piper, kokoro_onnx; print('Python', sys.version.split()[0])"
    if ($LASTEXITCODE) { throw 'The Python packages did not import correctly.' }
    Write-Host "  ok        $ver, piper + kokoro installed"
}

# --- 2. Kokoro -------------------------------------------------------------------------------
if (-not $NoKokoro) {
    Write-Host 'Kokoro model (models\)'
    foreach ($k in $Kokoro) { Get-Verified $k.Url (Join-Path $Root "models\$($k.Name)") $k.Sha }
}

# --- 3. Piper voices ---------------------------------------------------------------------------
$want = if ($AllVoices) { @($Piper.Keys) } else { $Voices }
Write-Host 'Piper voices (voices\piper\)'
foreach ($v in $want) {
    if (-not $Piper.Contains($v)) { throw "Unknown Piper voice '$v'. Available: $(@($Piper.Keys) -join ', ')" }
    $sub, $shaOnnx, $shaJson = $Piper[$v]
    $dir = Join-Path $Root 'voices\piper'
    Get-Verified "$PiperBase/$sub/$v.onnx" (Join-Path $dir "$v.onnx") $shaOnnx
    Get-Verified "$PiperBase/$sub/$v.onnx.json" (Join-Path $dir "$v.onnx.json") $shaJson
}

# --- 4. optional autostart ----------------------------------------------------------------------
if ($Autostart) { & (Join-Path $Root 'tools\install-autostart.ps1') }

Write-Host ''
Write-Host 'Done. Start Speak Box with:'
Write-Host "  wscript.exe `"$(Join-Path $Root 'Start-SpeakBox.vbs')`""
