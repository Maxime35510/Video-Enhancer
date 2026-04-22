# Video Enhancer

Windows batch workflow for conservative video enhancement with FFmpeg and Video2X.

## Structure

- `Start/Start_Enhance_Videos.bat` - main launcher.
- `Start/To Enhance` - put source videos here.
- `Start/Enhanced` - enhanced videos and per-video work folders are written here.
- `Start/tools` - local FFmpeg and Video2X binaries, not committed to Git.

## Output naming

If the source video is:

```text
example.mp4
```

the final enhanced video is saved as:

```text
example_enhanced.mp4
```

inside `Start/Enhanced`.

## Notes

The script is resumable and validates segments before skipping them. It keeps working files after completion so interrupted or future jobs can be checked and resumed.

