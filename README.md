# Video Enhancer

Video Enhancer is a Windows batch tool for improving low-resolution videos with
FFmpeg and Video2X.

It was built for conservative, resumable processing on a low-end Windows PC.
The goal is not to be the fastest possible pipeline, but to avoid losing work
when a long upscale job is interrupted.

## What It Does

The main script is:

```text
Start/Start_Enhance_Videos.bat
```

When launched, it:

1. Scans `Start/To Enhance` for video files.
2. Lets you choose which video to enhance.
3. Creates a dedicated work folder for that video inside `Start/Enhanced`.
4. Splits the video into 5-minute segments.
5. Upscales each segment with Video2X using RealESRGAN.
6. Restores the original audio to each enhanced segment.
7. Validates every enhanced segment before moving on.
8. Automatically repairs missing or broken segments.
9. Compiles all valid enhanced segments into one final video.
10. Validates the final video duration, resolution, audio, and readability.
11. Keeps the working files so the job can be inspected or resumed later.

## Folder Structure

```text
Start/
  Start_Enhance_Videos.bat
  To Enhance/
  Enhanced/
  tools/
```

### `To Enhance`

Put the original videos you want to improve in this folder.

Example:

```text
Start/To Enhance/my_video.mp4
```

### `Enhanced`

The final enhanced videos are saved here.

The script also creates one work folder per video inside `Enhanced`. That folder
contains segments, temporary files, logs, and validation data.

Example after processing `my_video.mp4`:

```text
Start/Enhanced/my_video_enhanced.mp4
Start/Enhanced/my_video/
  segments/
  enhanced/
  temp/
  logs/
```

### `tools`

This folder is expected to contain FFmpeg and Video2X locally:

```text
Start/tools/ffmpeg/bin/ffmpeg.exe
Start/tools/ffmpeg/bin/ffprobe.exe
Start/tools/video2x/video2x.exe
```

The tools are not committed to Git because they are large third-party binaries.

## Output Naming

The final file is always named from the original video name.

Example:

```text
my_video.mp4
```

becomes:

```text
my_video_enhanced.mp4
```

The final output is saved in:

```text
Start/Enhanced/
```

## Upscaling Settings

The script uses conservative settings intended for reliability:

```text
Processor: RealESRGAN
Scale: 2x
Model: realesr-animevideov3
Target final height: 1080p
Segment length: 300 seconds
```

The final video is encoded with H.264 using FFmpeg.

## Resume Behavior

The pipeline is designed to survive interruptions.

If the script is stopped, closed, or interrupted, you can run it again. It will:

- reuse valid existing split segments;
- skip valid enhanced segments;
- delete and rebuild invalid enhanced segments;
- delete and rebuild invalid temp files;
- continue from the latest valid state.

This is useful for long jobs where Video2X may run for many hours.

## Validation

The script checks files before trusting them.

For each enhanced segment, it verifies:

- the output file exists;
- the file is readable by FFmpeg;
- the duration matches the source segment closely.

For the final output, it verifies:

- the final file is readable;
- the final height is 1080p;
- audio exists if the source video had audio;
- the final duration is close to the original video duration.

If something is invalid, the script tries to rebuild only the bad part instead
of restarting the whole project.

## ETA And Progress

The script shows progress during processing.

Before starting, it estimates:

- source video duration;
- expected segment count;
- rough processing time from scratch;
- rough remaining time when resuming an existing project.

During final compilation, it shows:

- percentage complete;
- current estimated segment;
- processed video time;
- elapsed time;
- ETA;
- encode speed.

## Audio Handling

The script first tries to preserve audio without re-encoding.

If audio copy fails, it retries with AAC re-encoding.

This makes the pipeline more robust when one segment has audio metadata that
FFmpeg cannot copy cleanly.

## Supported Input Formats

The script scans for these video formats:

```text
.mp4
.mkv
.mov
.avi
.m4v
.webm
```

## How To Use

1. Put one or more videos in:

```text
Start/To Enhance/
```

2. Double-click:

```text
Start/Start_Enhance_Videos.bat
```

3. Choose the video number shown in the console.
4. Let the script run.
5. The enhanced video will appear in:

```text
Start/Enhanced/
```

## Stopping And Resuming

If you need to stop during a long Video2X segment:

1. Press `Ctrl+C`.
2. Confirm termination if Windows asks.
3. Run `Start_Enhance_Videos.bat` again later.

The script will check what is already valid and continue.

## What Is Not Included In Git

The repository intentionally does not include:

- source videos;
- enhanced videos;
- split segments;
- temp files;
- logs;
- FFmpeg binaries;
- Video2X binaries.

Those are local files and can be very large.

## Notes

This project is optimized for reliability over speed. Processing can take a long
time, especially on low-end hardware or laptop GPUs.

For best results, keep the computer plugged in, avoid sleep mode, and let one
job finish before starting another.
