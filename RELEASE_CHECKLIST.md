# SwiftMediaMetadata 3.1.4 release checklist

- [x] Fragmented MP4/MOV (`mvex` + top-level `moof`): fragment samples count
  toward track duration, frame count, average frame rate and bitrate; `mehd`
  sets the movie duration when present.
- [x] Verified against ffprobe on ffmpeg `frag_keyframe`, `empty_moov`,
  `default_base_moof` and `separate_moof` files and a 320-second yt-dlp-rs
  growing-file YouTube recording: durations, frame counts and bitrates match.
- [x] Set CLI version, README and changelog to 3.1.4.
- [x] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
