# SwiftMediaMetadata 3.1.3 release checklist

- [x] MXF essence coding labels decoded by RP 224 category and codec family
  (cross-checked against FFmpeg's mxf tables and bmx's label table): ProRes,
  DNxHD/DNxHR, DV, D-10, JPEG 2000, FFV1, VC-1, DNxUncompressed, v210 and
  compressed sound labels map to ffprobe-style codecs and profiles.
- [x] ProRes in MXF uses decode depth; 4444 alpha from AlphaSampleDepth or the
  first frame header.
- [x] Verified against FFmpeg-written MXF for every codec its muxer supports
  and Sony/Resolve/XDCAM/DNxHR/FX6 samples: codec, profile and pix_fmt match
  ffprobe.
- [x] Set CLI version, README and changelog to 3.1.3.
- [x] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
