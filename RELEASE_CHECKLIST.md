# SwiftMediaMetadata 3.1.0 release checklist

- [x] Matroska `Attachments` exposed as `VideoMetadata.attachments`, skipping
  incomplete entries so indices match ffmpeg's `t:<n>` attachment streams.
- [x] Verified against an ffmpeg-muxed MKV with three font attachments (names,
  MIME types and payload sizes match ffmpeg).
- [x] Set CLI version, README and changelog to 3.1.0.
- [x] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
