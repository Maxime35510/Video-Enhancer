@echo off
setlocal EnableExtensions
set "BAT_PATH=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $p=$env:BAT_PATH; $lines=Get-Content -LiteralPath $p; $marker='### POWERSHELL_ENGINE_BELOW ###'; $i=[Array]::IndexOf($lines,$marker); if($i -lt 0){throw 'PowerShell engine marker not found'}; $code=($lines[($i+1)..($lines.Count-1)] -join [Environment]::NewLine); Invoke-Expression $code"
set "EXITCODE=%ERRORLEVEL%"
echo.
echo Finished with code %EXITCODE%.
pause
exit /b %EXITCODE%
### POWERSHELL_ENGINE_BELOW ###

$ErrorActionPreference = "Stop"

$SegmentSeconds = 300
$Scale = 2
$Model = "realesr-animevideov3"
$Processor = "realesrgan"
$TargetHeight = 1080
$DurationToleranceSeconds = 3.0
$UpscaleRealtimeFactor = 18.0
$FinalCompileSpeedFactor = 4.0
$SupportedExtensions = @(".mp4", ".mkv", ".mov", ".avi", ".m4v", ".webm")

$StartDir = Split-Path -Parent $env:BAT_PATH
$ToEnhanceDir = Join-Path $StartDir "To Enhance"
$EnhancedRootDir = Join-Path $StartDir "Enhanced"
$ToolsDir = Join-Path $StartDir "tools"
New-Item -ItemType Directory -Force -Path $ToEnhanceDir, $EnhancedRootDir, $ToolsDir | Out-Null

function Write-Header {
    Clear-Host
    Write-Host "============================================================"
    Write-Host " AI Enhance Videos - Start Tool"
    Write-Host "============================================================"
    Write-Host "Put videos here:"
    Write-Host "  $ToEnhanceDir"
    Write-Host "Enhanced videos will be saved here:"
    Write-Host "  $EnhancedRootDir"
    Write-Host ""
}

function Read-ChoiceNumber([int]$Min, [int]$Max, [string]$Prompt) {
    while ($true) {
        $raw = Read-Host $Prompt
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge $Min -and $n -le $Max) { return $n }
        Write-Host "Please enter a number from $Min to $Max."
    }
}

function Find-Exe([string]$Name, [string[]]$Candidates) {
    foreach ($candidate in $Candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "$Name was not found. Expected it in Start\tools, LIVE\tools, or PATH."
}

function Safe-Name([string]$Name) {
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    $chars = $Name.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { "_" } else { $_ } }
    $safe = (-join $chars).Trim() -replace "\s+", " "
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Video_Project" }
    return $safe
}

function Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
}

function Run-NativeLogged([string]$Exe, [string[]]$Arguments, [string]$LogPath) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Exe @Arguments *> $LogPath
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Quote-CmdArg([string]$Arg) {
    if ($null -eq $Arg) { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    return '"' + ($Arg -replace '"','\"') + '"'
}

function Format-Seconds([double]$Seconds) {
    if ($Seconds -lt 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) { $Seconds = 0 }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    return "{0:00}:{1:00}:{2:00}" -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Read-ProgressSeconds([string]$ProgressPath) {
    if (!(Test-Path -LiteralPath $ProgressPath)) { return 0.0 }
    $line = Get-Content -LiteralPath $ProgressPath -Tail 80 -ErrorAction SilentlyContinue | Where-Object { $_ -like "out_time=*" } | Select-Object -Last 1
    if ($line -match '^out_time=(\d+):(\d+):([0-9.]+)') {
        return ([double]$matches[1] * 3600.0) + ([double]$matches[2] * 60.0) + [double]::Parse($matches[3], [Globalization.CultureInfo]::InvariantCulture)
    }
    return 0.0
}

function Get-CurrentSegmentLabel([object[]]$Timeline, [double]$DoneSeconds) {
    if (!$Timeline -or $Timeline.Count -eq 0) { return "unknown" }
    foreach ($item in $Timeline) {
        if ($DoneSeconds -ge $item.StartSec -and $DoneSeconds -lt $item.EndSec) {
            return "{0} ({1}/{2})" -f $item.Name, $item.Index, $item.Total
        }
    }
    $last = $Timeline | Select-Object -Last 1
    return "{0} ({1}/{2})" -f $last.Name, $last.Index, $last.Total
}

function Run-FFmpegWithEta([string]$Exe, [string[]]$Arguments, [string]$LogPath, [double]$TotalSeconds, [object[]]$Timeline = @()) {
    $progressPath = Join-Path $script:TempDir "ffmpeg_compile_progress.txt"
    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
    $argsWithProgress = @("-nostats", "-progress", $progressPath) + $Arguments
    $quotedArgs = ($argsWithProgress | ForEach-Object { Quote-CmdArg $_ }) -join " "
    $cmdLine = '"' + $Exe + '" ' + $quotedArgs + ' > "' + $LogPath + '" 2>&1'
    $process = Start-Process -FilePath "$env:ComSpec" -ArgumentList "/d", "/c", $cmdLine -WindowStyle Hidden -PassThru
    $start = Get-Date
    $lastShown = [DateTime]::MinValue
    Write-Host ""
    Write-Host "Compile ETA will update about every 15 seconds."
    while (!$process.HasExited) {
        Start-Sleep -Seconds 3
        $now = Get-Date
        if (($now - $lastShown).TotalSeconds -lt 15) { continue }
        $doneSeconds = Read-ProgressSeconds $progressPath
        $elapsed = ($now - $start).TotalSeconds
        $percent = if ($TotalSeconds -gt 0) { [Math]::Min(100.0, ($doneSeconds / $TotalSeconds) * 100.0) } else { 0.0 }
        $speed = if ($elapsed -gt 0) { $doneSeconds / $elapsed } else { 0.0 }
        $eta = if ($speed -gt 0 -and $TotalSeconds -gt $doneSeconds) { ($TotalSeconds - $doneSeconds) / $speed } else { 0.0 }
        $segmentLabel = Get-CurrentSegmentLabel $Timeline $doneSeconds
        Write-Host ("Compile: {0,5:n1}% | segment {1} | video {2}/{3} | elapsed {4} | ETA {5} | speed {6:n2}x" -f $percent, $segmentLabel, (Format-Seconds $doneSeconds), (Format-Seconds $TotalSeconds), (Format-Seconds $elapsed), (Format-Seconds $eta), $speed)
        $lastShown = $now
    }
    $process.WaitForExit()
    $doneFinal = Read-ProgressSeconds $progressPath
    $elapsedFinal = ((Get-Date) - $start).TotalSeconds
    $finalSegmentLabel = Get-CurrentSegmentLabel $Timeline $doneFinal
    Write-Host ("Compile finished | segment {0} | video {1}/{2} | elapsed {3}" -f $finalSegmentLabel, (Format-Seconds $doneFinal), (Format-Seconds $TotalSeconds), (Format-Seconds $elapsedFinal))
    return $process.ExitCode
}

function Get-DurationSeconds([string]$File) {
    $output = & $script:FFProbe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $File 2>> $script:LogFile
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) { throw "Could not read duration: $File" }
    return [double]::Parse(($output | Select-Object -First 1), [Globalization.CultureInfo]::InvariantCulture)
}

function Test-VideoReadable([string]$File) {
    if (!(Test-Path -LiteralPath $File)) { return $false }
    if ((Get-Item -LiteralPath $File).Length -le 0) { return $false }
    & $script:FFmpeg -v error -i $File -map 0:v:0 -frames:v 1 -f null NUL 2>> $script:LogFile | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Test-DurationMatch([string]$Source, [string]$Output) {
    try {
        $a = Get-DurationSeconds $Source
        $b = Get-DurationSeconds $Output
        return ([Math]::Abs($a - $b) -le $DurationToleranceSeconds)
    } catch { return $false }
}

function Test-ProcessedSegment([string]$SourceSegment, [string]$OutputSegment) {
    if (!(Test-VideoReadable $OutputSegment)) { return $false }
    if (!(Test-DurationMatch $SourceSegment $OutputSegment)) { return $false }
    return $true
}

function Test-SplitSegmentsReady {
    $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($segments.Count -ne $script:ExpectedSegments) {
        Log "Split check failed. Expected $script:ExpectedSegments segments, found $($segments.Count)."
        return $false
    }
    for ($i = 0; $i -lt $script:ExpectedSegments; $i++) {
        $name = "segment_{0:0000}.mp4" -f $i
        $path = Join-Path $script:SegmentsDir $name
        if (!(Test-VideoReadable $path)) {
            Log "Split check failed. Segment is missing or unreadable: $name"
            return $false
        }
        try {
            $duration = Get-DurationSeconds $path
            if ($i -lt ($script:ExpectedSegments - 1) -and $duration -lt 30) {
                Log "Split check failed. Segment duration is suspiciously short: $name ($duration seconds)"
                return $false
            }
        } catch {
            Log "Split check failed. Could not read segment duration: $name"
            return $false
        }
    }
    return $true
}

function Remove-StaleLock([string]$LockDir) {
    if (!(Test-Path -LiteralPath $LockDir)) { return }
    $active = Get-Process video2x, ffmpeg -ErrorAction SilentlyContinue | Where-Object { $_.WorkingSet64 -gt 10MB }
    if ($active) { throw "Another active Video2X/FFmpeg process is running. Stop it before starting another job." }
    Write-Host "Found stale lock. Removing it: $LockDir"
    Remove-Item -LiteralPath $LockDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Detect-Video2X {
    Log "Checking Video2X CLI syntax."
    $help = & $script:Video2X --help 2>&1
    $help | Set-Content -LiteralPath $script:Video2XHelpFile -Encoding UTF8
    if ($LASTEXITCODE -ne 0) { throw "video2x --help failed. See $script:Video2XHelpFile" }
    if (($help -join "`n") -notmatch "--realesrgan-model") { throw "This Video2X build does not expose --realesrgan-model." }
    Log "Detected Video2X modern RealESRGAN CLI."
}

function Show-ProjectStatus {
    $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" -ErrorAction SilentlyContinue)
    $enhanced = @(Get-ChildItem -LiteralPath $script:EnhancedDir -Filter "segment_*_enhanced.mp4" -ErrorAction SilentlyContinue)
    $total = if ($segments.Count -gt 0) { $segments.Count } else { $script:ExpectedSegments }
    $remaining = [Math]::Max(0, $total - $enhanced.Count)
    Write-Host ""
    Write-Host "Status:"
    Write-Host "  Project:   $script:ProjectDir"
    Write-Host "  Segments:  $($segments.Count)"
    Write-Host "  Enhanced:  $($enhanced.Count) / $total"
    Write-Host "  Remaining: $remaining"
    Write-Host "  Log:       $script:LogFile"
    Write-Host ""
}

function Show-InitialEstimate([double]$DurationSeconds, [int]$ExpectedSegments) {
    $existingEnhanced = @(Get-ChildItem -LiteralPath $script:EnhancedDir -Filter "segment_*_enhanced.mp4" -ErrorAction SilentlyContinue).Count
    $remainingSegments = [Math]::Max(0, $ExpectedSegments - $existingEnhanced)
    $remainingFraction = if ($ExpectedSegments -gt 0) { $remainingSegments / $ExpectedSegments } else { 1.0 }

    $estimatedUpscaleAll = $DurationSeconds * $UpscaleRealtimeFactor
    $estimatedUpscaleRemaining = $estimatedUpscaleAll * $remainingFraction
    $estimatedCompile = if ($FinalCompileSpeedFactor -gt 0) { $DurationSeconds / $FinalCompileSpeedFactor } else { 0.0 }
    $estimatedChecks = 300 + ($ExpectedSegments * 30)
    $estimatedFromScratch = $estimatedUpscaleAll + $estimatedCompile + $estimatedChecks
    $estimatedResume = $estimatedUpscaleRemaining + $estimatedCompile + $estimatedChecks

    Write-Host ""
    Write-Host "Rough estimate for this PC:"
    Write-Host "  Video duration:       $(Format-Seconds $DurationSeconds)"
    Write-Host "  Expected segments:    $ExpectedSegments x $SegmentSeconds seconds"
    Write-Host "  From scratch:         $(Format-Seconds $estimatedFromScratch)"
    if ($existingEnhanced -gt 0) {
        Write-Host "  Resume estimate:      $(Format-Seconds $estimatedResume) ($existingEnhanced existing enhanced file(s) found)"
    }
    Write-Host "  Note: Video2X speed can vary a lot by scene, heat, and GPU load."
    Write-Host ""

    Log "Estimate from scratch: $(Format-Seconds $estimatedFromScratch). Existing enhanced files: $existingEnhanced. Resume estimate: $(Format-Seconds $estimatedResume)."
}

function Split-VideoIfNeeded {
    if ((Test-Path -LiteralPath $script:SplitDoneFile) -and (Test-SplitSegmentsReady)) {
        $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" -ErrorAction SilentlyContinue)
        Log "Split already completed and validated. Segment count: $($segments.Count)"
        return
    }
    Log "Preparing clean split into $SegmentSeconds-second segments."
    Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $splitArgs = @("-hide_banner","-y","-i",$script:InputVideo,"-map","0","-c","copy","-f","segment","-segment_time","$SegmentSeconds","-reset_timestamps","1","-avoid_negative_ts","make_zero",(Join-Path $script:SegmentsDir "segment_%04d.mp4"))
    $code = Run-NativeLogged $script:FFmpeg $splitArgs $script:SplitLogFile
    if ($code -ne 0) { throw "FFmpeg split failed. See $script:SplitLogFile" }
    if (!(Test-SplitSegmentsReady)) { throw "Split finished but segment validation failed. See $script:SplitLogFile and $script:LogFile" }
    $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" -ErrorAction SilentlyContinue)
    New-Item -ItemType File -Force -Path $script:SplitDoneFile | Out-Null
    Log "Split completed. Segment count: $($segments.Count)"
}

function Process-Segments {
    $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" | Sort-Object Name)
    if ($segments.Count -eq 0) { throw "No segments found." }
    $i = 0
    foreach ($segment in $segments) {
        $i++
        $base = [IO.Path]::GetFileNameWithoutExtension($segment.Name)
        $temp = Join-Path $script:TempDir "$base`_video2x.mp4"
        $enhanced = Join-Path $script:EnhancedDir "$base`_enhanced.mp4"
        if (Test-ProcessedSegment $segment.FullName $enhanced) { Log "Skipping valid enhanced segment $i/$($segments.Count): $base"; continue }
        if (Test-Path -LiteralPath $enhanced) { Log "Deleting invalid enhanced segment: $base"; Remove-Item -LiteralPath $enhanced -Force -ErrorAction SilentlyContinue }
        if ((Test-Path -LiteralPath $temp) -and !(Test-ProcessedSegment $segment.FullName $temp)) { Log "Deleting invalid temp segment: $base"; Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        Log "Processing segment $i/$($segments.Count): $base"
        Write-Host ""
        Write-Host "Video2X segment $i/$($segments.Count): $base"
        Write-Host "Press q inside Video2X to abort, then rerun this BAT to resume."
        if (!(Test-Path -LiteralPath $temp)) {
            & $script:Video2X -i $segment.FullName -o $temp -p $Processor -s $Scale --realesrgan-model $Model -c libx264 --pix-fmt yuv420p -e preset=veryfast -e crf=20
            if ($LASTEXITCODE -ne 0) { throw "Video2X failed on $base." }
        } else { Log "Using existing valid temp output: $base" }
        if (!(Test-ProcessedSegment $segment.FullName $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; throw "Video2X output failed validation for $base." }
        Log "Restoring source audio: $base"
        $audioCopyArgs = @("-hide_banner","-y","-i",$temp,"-i",$segment.FullName,"-map","0:v:0","-map","1:a?","-c:v","copy","-c:a","copy","-shortest",$enhanced)
        $code = Run-NativeLogged $script:FFmpeg $audioCopyArgs $script:AudioLogFile
        if ($code -ne 0) {
            Log "Audio copy failed. Retrying AAC: $base"
            $audioAacArgs = @("-hide_banner","-y","-i",$temp,"-i",$segment.FullName,"-map","0:v:0","-map","1:a?","-c:v","copy","-c:a","aac","-b:a","192k","-shortest",$enhanced)
            $code = Run-NativeLogged $script:FFmpeg $audioAacArgs $script:AudioLogFile
            if ($code -ne 0) { throw "Audio restoration failed for $base." }
        }
        if (!(Test-ProcessedSegment $segment.FullName $enhanced)) { throw "Enhanced segment failed final validation: $base." }
        Log "Finished segment: $base"
        Show-ProjectStatus
    }
}

function Validate-AllEnhancedSegments {
    $segments = @(Get-ChildItem -LiteralPath $script:SegmentsDir -Filter "segment_*.mp4" | Sort-Object Name)
    $bad = @()
    foreach ($segment in $segments) {
        $base = [IO.Path]::GetFileNameWithoutExtension($segment.Name)
        $enhanced = Join-Path $script:EnhancedDir "$base`_enhanced.mp4"
        if (!(Test-ProcessedSegment $segment.FullName $enhanced)) {
            $bad += $base
            if (Test-Path -LiteralPath $enhanced) {
                Log "Deleting bad enhanced segment during check: $base"
                Remove-Item -LiteralPath $enhanced -Force -ErrorAction SilentlyContinue
            }
            $temp = Join-Path $script:TempDir "$base`_video2x.mp4"
            if (Test-Path -LiteralPath $temp) {
                Log "Deleting bad temp segment during check: $base"
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($bad.Count -gt 0) {
        Log "Validation found bad/missing segments: $($bad -join ', ')"
        return $false
    }
    Log "All enhanced segments are valid."
    return $true
}

function Repair-And-ValidateSegments {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Log "Enhance/repair pass $attempt."
        Process-Segments
        if (Validate-AllEnhancedSegments) { return }
        Log "Some segments were repaired/deleted. Running another pass."
    }
    throw "Segments are still invalid after 3 repair passes. Check logs before continuing."
}

function Compile-Final {
    $segments = @(Get-ChildItem -LiteralPath $script:EnhancedDir -Filter "segment_*_enhanced.mp4" | Sort-Object Name)
    if ($segments.Count -eq 0) { throw "No enhanced segments to compile." }
    $lines = $segments | ForEach-Object { "file '$($_.FullName.Replace('\','/'))'" }
    Set-Content -LiteralPath $script:ConcatFile -Value $lines -Encoding ASCII
    if (Test-Path -LiteralPath $script:FinalOutput) { Log "Deleting existing final output before automatic recompile."; Remove-Item -LiteralPath $script:FinalOutput -Force -ErrorAction SilentlyContinue }
    $totalCompileSeconds = 0.0
    $compileTimeline = @()
    for ($idx = 0; $idx -lt $segments.Count; $idx++) {
        $segment = $segments[$idx]
        try {
            $dur = Get-DurationSeconds $segment.FullName
            $name = [IO.Path]::GetFileNameWithoutExtension($segment.Name) -replace '_enhanced$',''
            $compileTimeline += [pscustomobject]@{ Name=$name; Index=($idx + 1); Total=$segments.Count; StartSec=$totalCompileSeconds; EndSec=($totalCompileSeconds + $dur) }
            $totalCompileSeconds += $dur
        } catch {}
    }
    if ($totalCompileSeconds -le 0) { $totalCompileSeconds = Get-DurationSeconds $script:InputVideo }
    Log "Compiling final output."
    $copyArgs = @("-hide_banner","-y","-f","concat","-safe","0","-i",$script:ConcatFile,"-map","0:v:0","-map","0:a?","-vf","scale=-2:$TargetHeight`:flags=lanczos","-c:v","libx264","-preset","veryfast","-crf","20","-pix_fmt","yuv420p","-c:a","copy","-movflags","+faststart","-fflags","+genpts","-avoid_negative_ts","make_zero",$script:FinalOutput)
    $code = Run-FFmpegWithEta $script:FFmpeg $copyArgs $script:FinalMergeLog $totalCompileSeconds $compileTimeline
    if ($code -ne 0) {
        Log "Final compile with copied audio failed. Retrying AAC."
        $aacArgs = @("-hide_banner","-y","-f","concat","-safe","0","-i",$script:ConcatFile,"-map","0:v:0","-map","0:a?","-vf","scale=-2:$TargetHeight`:flags=lanczos","-c:v","libx264","-preset","veryfast","-crf","20","-pix_fmt","yuv420p","-c:a","aac","-b:a","192k","-movflags","+faststart","-fflags","+genpts","-avoid_negative_ts","make_zero",$script:FinalOutput)
        $code = Run-FFmpegWithEta $script:FFmpeg $aacArgs $script:FinalMergeLog $totalCompileSeconds $compileTimeline
        if ($code -ne 0) { throw "Final compile failed. See $script:FinalMergeLog" }
    }
    if (!(Test-VideoReadable $script:FinalOutput)) { throw "Final output is not readable." }
    $finalHeight = (& $script:FFProbe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 $script:FinalOutput 2>> $script:LogFile | Select-Object -First 1)
    if ([int]$finalHeight -ne $TargetHeight) { throw "Final video height mismatch. Expected $TargetHeight, got $finalHeight" }
    $sourceAudio = (& $script:FFProbe -v error -select_streams a -show_entries stream=index -of csv=p=0 $script:InputVideo 2>> $script:LogFile | Select-Object -First 1)
    $finalAudio = (& $script:FFProbe -v error -select_streams a -show_entries stream=index -of csv=p=0 $script:FinalOutput 2>> $script:LogFile | Select-Object -First 1)
    if (![string]::IsNullOrWhiteSpace($sourceAudio) -and [string]::IsNullOrWhiteSpace($finalAudio)) { throw "Final output is missing audio track." }
    $sourceDuration = Get-DurationSeconds $script:InputVideo
    $finalDuration = Get-DurationSeconds $script:FinalOutput
    if ([Math]::Abs($sourceDuration - $finalDuration) -gt 5.0) { throw "Final duration mismatch. Source=$sourceDuration Final=$finalDuration" }
    Log "Final output created and validated: $script:FinalOutput"
}

function Cleanup-ProjectArtifacts {
    Log "Final validation passed. Keeping project working files for review/resume."
    Write-Host "Kept project folder:"
    Write-Host "  $script:ProjectDir"
    Write-Host "Kept segments, enhanced segments, temp files, and logs."
}
try {
    Write-Header
    $script:FFmpeg = Find-Exe "ffmpeg.exe" @((Join-Path $ToolsDir "ffmpeg\bin\ffmpeg.exe"))
    $script:FFProbe = Find-Exe "ffprobe.exe" @((Join-Path $ToolsDir "ffmpeg\bin\ffprobe.exe"))
    $script:Video2X = Find-Exe "video2x.exe" @((Join-Path $ToolsDir "video2x\video2x.exe"))
    $videos = @(Get-ChildItem -LiteralPath $ToEnhanceDir -File | Where-Object { $SupportedExtensions -contains $_.Extension.ToLowerInvariant() } | Sort-Object Name)
    if ($videos.Count -eq 0) { Write-Host "No videos found in:`n  $ToEnhanceDir`nAdd one or more videos there, then rerun this BAT."; exit 0 }
    Write-Host "Found $($videos.Count) video(s):"
    for ($i = 0; $i -lt $videos.Count; $i++) { $gb = [Math]::Round($videos[$i].Length / 1GB, 2); Write-Host ("  {0}. {1} ({2} GB)" -f ($i + 1), $videos[$i].Name, $gb) }
    Write-Host ""
    $choice = Read-ChoiceNumber 1 $videos.Count "Choose video number"
    $script:InputVideo = $videos[$choice - 1].FullName
    $projectName = Safe-Name ([IO.Path]::GetFileNameWithoutExtension($script:InputVideo))
    $script:ProjectDir = Join-Path $EnhancedRootDir $projectName
    $script:SegmentsDir = Join-Path $script:ProjectDir "segments"
    $script:EnhancedDir = Join-Path $script:ProjectDir "enhanced"
    $script:TempDir = Join-Path $script:ProjectDir "temp"
    $script:LogsDir = Join-Path $script:ProjectDir "logs"
    $script:FinalDir = Join-Path $script:ProjectDir "final"
    $script:LogFile = Join-Path $script:LogsDir "progress.log"
    $script:Video2XHelpFile = Join-Path $script:LogsDir "video2x_help.txt"
    $script:SplitLogFile = Join-Path $script:LogsDir "split.log"
    $script:AudioLogFile = Join-Path $script:LogsDir "audio_restore.log"
    $script:FinalMergeLog = Join-Path $script:LogsDir "final_merge.log"
    $script:ConcatFile = Join-Path $script:TempDir "concat_list.txt"
    $script:SplitDoneFile = Join-Path $script:ProjectDir "split.complete"
    $script:LockDir = Join-Path $script:TempDir "pipeline.lock"
    $script:FinalOutput = Join-Path $EnhancedRootDir "$projectName`_enhanced.mp4"
    New-Item -ItemType Directory -Force -Path $script:ProjectDir, $script:SegmentsDir, $script:EnhancedDir, $script:TempDir, $script:LogsDir, $script:FinalDir | Out-Null
    Set-Content -LiteralPath (Join-Path $script:ProjectDir "source_video.txt") -Value $script:InputVideo -Encoding UTF8
    Remove-StaleLock $script:LockDir
    New-Item -ItemType Directory -Force -Path $script:LockDir | Out-Null
    try {
        Log "============================================================"
        Log "Selected video: $script:InputVideo"
        Log "Project: $script:ProjectDir"
        Log "FFmpeg: $script:FFmpeg"
        Log "FFprobe: $script:FFProbe"
        Log "Video2X: $script:Video2X"
        if (!(Test-VideoReadable $script:InputVideo)) { throw "Input video is not readable." }
        Detect-Video2X
        $duration = Get-DurationSeconds $script:InputVideo
        $script:ExpectedSegments = [Math]::Ceiling($duration / $SegmentSeconds)
        Log "Input duration: $([Math]::Round($duration, 2)) seconds. Expected segments: $script:ExpectedSegments"
        Show-InitialEstimate $duration $script:ExpectedSegments
        Split-VideoIfNeeded
        Show-ProjectStatus
        Repair-And-ValidateSegments
        Show-ProjectStatus
        Log "All segments valid. Starting automatic final compile."
        Compile-Final
        Cleanup-ProjectArtifacts
        Write-Host "`nDONE.`nFinal output:`n  $script:FinalOutput"
    } finally {
        if (Test-Path -LiteralPath $script:LockDir) { Remove-Item -LiteralPath $script:LockDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
} catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($script:LogFile) { try { Log "ERROR: $($_.Exception.Message)" } catch {}; Write-Host "Log:`n  $script:LogFile" }
    exit 1
}




