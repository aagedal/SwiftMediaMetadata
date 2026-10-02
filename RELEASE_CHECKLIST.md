# SwiftMediaMetadata 3.0.2 release checklist

- [x] Preserve the upstream manifest, Benchmark and ArgumentParser lockfile.
- [x] Retain bounded-MXF source and regression coverage from tested commit
  `8297324bb00ad1358b4070575c1ea59e698d3f2f`.
- [x] Set CLI version, README and changelog to 3.0.2.
- [ ] Run complete release preflight on the final release tree.
- [ ] Publish the semantic-version tag and verify CI release checks.
- [ ] Download and verify the published archive and CLI/resource smoke checks.
- [ ] Resolve and pin the downstream application from a fresh package cache.
- [ ] Repeat authentic-media application profiles against the published package.

Historical local library/CLI tests do not replace final-tree release validation.
Real-volume I/O, multi-hour scaling, same-size concurrent mutation, Linux,
supported macOS and base-M1 application performance remain separate acceptance.
