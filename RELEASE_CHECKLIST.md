# SwiftMediaMetadata 3.1.2 release checklist

- [x] MXF AVC Long GOP picture coding labels (`04.01.02.02.01.31.xx.xx`,
  SMPTE RP 2008) map to `avc1` with the profile from byte 14; MPEG-2 MP@HL /
  422P@HL labels (`01.03.xx` / `01.04.xx`) map to `mpeg2video`.
- [x] Verified against Sony/Resolve XAVC Long 4:2:2 10-bit MXF (25p, 50i,
  59.94p) and XDCAM HD422 MXF: codec and profile match ffprobe.
- [x] Set CLI version, README and changelog to 3.1.2.
- [x] Run complete release preflight on the final release tree.
- [ ] Merge the reviewed release changes into `main` before tagging. The release
  workflow rejects tags whose commits are not in `main`'s history.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.

Historical local library/CLI tests do not replace final-tree release validation.
