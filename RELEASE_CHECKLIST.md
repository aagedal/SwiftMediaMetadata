# SwiftMediaMetadata 3.1.1 release checklist

- [x] ProRes 4444 / 4444 XQ alpha follows the sample-entry depth (32 alpha,
  24 opaque), falling back to the first frame header's alpha_channel_type.
- [x] Verified against ffmpeg-encoded `ap4h` / `ap4x` MOVs with and without
  alpha, including copies with the depth zeroed: `pixelFormat` matches ffprobe.
- [x] Set CLI version, README and changelog to 3.1.1.
- [x] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
