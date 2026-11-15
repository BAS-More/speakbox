<#
.SYNOPSIS
    Speak text aloud via the local 9Router TTS endpoint.

.DESCRIPTION
    Replacement for the read-aloud button that disappeared from the Claude
    desktop app. That toolbar is served from https://claude.ai, so it cannot
    be restored locally - see the notes at the bottom of this file.

    Posts text to $NINEROUTER_URL/v1/audio/speech, writes the audio to disk,
    and plays it. The container type is detected from the response magic bytes
    rather than assumed from the endpoint default: Gemini returns RIFF/WAVE
    even though the API nominally defaults to mp3.

.PARAMETER Text
    Text to speak. Accepts pipeline input.

.PARAMETER Path
    Read the text from a file instead of -Text.

.PARAMETER Model
    Voice / model id from $NINEROUTER_URL/v1/models/tts.

.PARAMETER OutFile
    Where to write the audio. The extension is corrected to match the real
    container. Defaults to a timestamped file under $env:TEMP\claude-tts.

.PARAMETER NoPlay
    Write the file but do not play it.

.EXAMPLE
    .\Read-Aloud.ps1 -Text "Build is green."

.EXAMPLE
    Get-Content notes.md -Raw | .\Read-Aloud.ps1 -Model gemini/gemini-2.5-pro-preview-tts
#>
[CmdletBinding(DefaultParameterSetName = 'FromText')]
param(
    [Parameter(ParameterSetName = 'FromText', Position = 0, ValueFromPipeline = $true)]
    [string] $Text,

    [Parameter(ParameterSetName = 'FromFile', Mandatory = $true)]
    [string] $Path,

    [string] $Model = 'gemini/gemini-2.5-flash-preview-tts',

    [string] $OutFile,

    [switch] $NoPlay,

    [int] $TimeoutSec = 120,

    [ValidateRange(1, 10)]
    [int] $Retries = 3
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $chunks = [System.Collections.Generic.List[string]]::new()
}

process {
    if ($PSCmdlet.ParameterSetName -eq 'FromText' -and $Text) { $chunks.Add($Text) }
}

end {
    # ---- resolve input text -------------------------------------------------
    if ($PSCmdlet.ParameterSetName -eq 'FromFile') {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Input file not found: $Path" }
        $speak = Get-Content -LiteralPath $Path -Raw
    }
    else {
        $speak = $chunks -join "`n"
    }

    if ([string]::IsNullOrWhiteSpace($speak)) {
        throw 'No text supplied. Use -Text, -Path, or pipe input.'
    }

    # ---- resolve endpoint ---------------------------------------------------
    $base = $env:NINEROUTER_URL
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw 'NINEROUTER_URL is not set. Start 9Router (see the 9router skill) and retry.'
    }
    $base = $base.TrimEnd('/')

    $headers = @{ 'Content-Type' = 'application/json' }
    if (-not [string]::IsNullOrWhiteSpace($env:NINEROUTER_KEY)) {
        $headers['Authorization'] = "Bearer $env:NINEROUTER_KEY"
    }

    # ---- request ------------------------------------------------------------
    $body = @{ model = $Model; input = $speak } | ConvertTo-Json -Compress -Depth 3

    Write-Verbose "POST $base/v1/audio/speech  model=$Model  chars=$($speak.Length)"

    # Observed in testing: a model that works fine will intermittently return 502
    # when calls are made in quick succession - upstream rate limiting surfacing
    # through the router. Retry transient failures instead of failing the caller.
    $resp = $null
    $lastError = $null
    for ($attempt = 1; $attempt -le $Retries; $attempt++) {
        try {
            $resp = Invoke-WebRequest -Uri "$base/v1/audio/speech" `
                                      -Method POST `
                                      -Headers $headers `
                                      -Body $body `
                                      -TimeoutSec $TimeoutSec `
                                      -ErrorAction Stop
            break
        }
        catch {
            $lastError = $_
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }

            # A 4xx (other than 429) means the request itself is wrong; retrying
            # it unchanged cannot help, so fail fast instead of burning backoff.
            $isTransient = ($status -eq 0 -or $status -ge 500 -or $status -eq 429)
            if (-not $isTransient -or $attempt -eq $Retries) { break }

            $backoff = [Math]::Pow(2, $attempt - 1) * 1.5
            Write-Verbose ("attempt {0}/{1} failed (status {2}); retrying in {3}s" -f $attempt, $Retries, $status, $backoff)
            Start-Sleep -Seconds $backoff
        }
    }

    if (-not $resp) {
        # A 502 usually means the upstream provider rejected or rate-limited the
        # call inside 9Router - the router itself is up. Surface both facts.
        # Parenthesise the concatenation: -f binds tighter than +, so without
        # these parens the format would apply to the trailing fragment only.
        throw (("TTS request failed for model '{0}' after {1} attempt(s): {2}. " +
                "Try a different model from {3}/v1/models/tts (gemini/* works without an OpenAI key).") `
                -f $Model, $Retries, $lastError.Exception.Message, $base)
    }

    $bytes = $resp.Content
    if ($bytes -isnot [byte[]]) { $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$bytes) }
    if ($bytes.Length -lt 128) {
        throw "TTS returned only $($bytes.Length) bytes - treating as a failed synthesis."
    }

    # ---- detect the real container -----------------------------------------
    # Do not trust the requested response_format; Gemini hands back RIFF/WAVE.
    $head = [System.Text.Encoding]::ASCII.GetString($bytes[0..3])
    $ext = if ($head -match '^RIFF') { '.wav' }
           elseif ($head -match '^ID3') { '.mp3' }
           elseif ($head -match '^OggS') { '.ogg' }
           elseif ($bytes[0] -eq 0xFF -and ($bytes[1] -band 0xE0) -eq 0xE0) { '.mp3' }
           else { '.bin' }

    # ---- resolve output path ------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
        $dir = Join-Path $env:TEMP 'claude-tts'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        $OutFile = Join-Path $dir ('speech-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + $ext)
    }
    elseif ([System.IO.Path]::GetExtension($OutFile) -ne $ext) {
        $OutFile = [System.IO.Path]::ChangeExtension($OutFile, $ext.TrimStart('.'))
    }

    [System.IO.File]::WriteAllBytes($OutFile, $bytes)
    Write-Verbose ("wrote {0} ({1} KB)" -f $OutFile, [math]::Round($bytes.Length / 1KB, 1))

    # ---- play ---------------------------------------------------------------
    if (-not $NoPlay) {
        if ($ext -eq '.wav') {
            # SoundPlayer is synchronous and needs no external player or codec.
            $player = New-Object System.Media.SoundPlayer $OutFile
            try { $player.PlaySync() } finally { $player.Dispose() }
        }
        else {
            Start-Process -FilePath $OutFile | Out-Null
        }
    }

    [pscustomobject]@{
        Path   = $OutFile
        Format = $ext.TrimStart('.')
        KB     = [math]::Round($bytes.Length / 1KB, 1)
        Model  = $Model
        Chars  = $speak.Length
    }
}

# ----------------------------------------------------------------------------
# Why this exists
#   The speaker icon in the Claude desktop app's message toolbar is rendered by
#   remotely-served claude.ai content (app.asar: getMainWindowUrl() returns
#   https://claude.ai on non-dev builds). It cannot be restored by rolling back
#   or reinstalling the desktop app. This script provides the capability locally.
#
# Model notes (verified 2026-08-15 against 9Router at 127.0.0.1:20128)
#   gemini/gemini-2.5-flash-preview-tts   works, returns WAV
#   gemini/gemini-2.5-pro-preview-tts     available, untested
#   gemini/gemini-3.1-flash-tts-preview   available, untested
#   openai/*, openrouter/*                502 - upstream key not configured
# ----------------------------------------------------------------------------
