# SwiftMediaMetadata 3.0.3 release checklist

- [x] MXF essence skipped via the Random Index Pack / footer partition chain,
  with fallback to the full KLV walk when no valid partition index exists.
- [x] MXF picture dimensions use the display rectangle (XAVC 1920x1080, not 1088).
- [x] Metadata parity against 3.0.2 on 63 local MXF files (Sony XAVC/XDCAM,
  FX6, Avid, DJI, Premiere transcodes); video dimensions/SAR match ffprobe.
- [x] Set CLI version, README and changelog to 3.0.3.
- [ ] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
