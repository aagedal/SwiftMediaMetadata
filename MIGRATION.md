# SwiftMediaMetadata Migration Guide

This guide covers source migrations that are larger than a release-note entry.
The APIs described in the 2.0-to-next-release section are currently available
on `main` and have not been tagged.

## From SwiftExif 1.x to SwiftMediaMetadata 2.0

Version 2.0 renamed the package, product, and importable module. Update the
package dependency:

```swift
.package(
    url: "https://github.com/aagedal/SwiftMediaMetadata.git",
    from: "2.0.0"
)
```

Update target dependencies and imports:

```swift
.target(name: "YourApp", dependencies: ["SwiftMediaMetadata"])
```

```swift
import SwiftMediaMetadata
```

The installed command remains `swift-exif`.

## From 2.0 to 3.0

The next release adds safer APIs alongside the existing entry points. Existing
`write(to:)`, `writeToData()`, `syncIPTCToXMP()`, and `syncXMPToIPTC()` calls
continue to compile. Adopt the new APIs when the caller needs an explicit
conflict, preservation, concurrency, or filesystem policy.

### Handle the lossless XMP value case

`XMPValue.languageAlternative` retains all ordered `rdf:Alt` entries and their
exact `xml:lang` values. Add this case to exhaustive switches:

```swift
func strings(from value: XMPValue) -> [String] {
    switch value {
    case .simple(let value), .langAlternative(let value):
        return [value]
    case .languageAlternative(let alternatives):
        return alternatives.map(\.value)
    case .array(let values):
        return values
    case .structure, .structuredArray:
        return []
    }
}
```

Do not collapse `.languageAlternative` to one scalar during a read-modify-write
cycle. Use `languageAlternativeValue(namespace:property:)` when the complete
ordered value matters; scalar accessors continue to prefer `x-default`.

`PhotoMetadataValue` is new in this release. Code that switches over it should
also handle `.number(Double)`, which is used for typed GPS candidates.

### Replace compatibility synchronization where policy matters

The compatibility synchronizers retain their legacy mappings. In particular,
the old IIM-to-XMP path mirrors Object Name to `dc:title`. The standards-aware
path preserves `dc:title` and full-precision XMP dates by default:

```swift
var metadata = try ImageMetadata.read(from: imageURL)

let report = metadata.synchronizeIPTCToXMP(options: .init(
    missingValuePolicy: .preserve,
    titlePolicy: .preserveXMP,
    dateCreatedPolicy: .preserveXMPPrecision,
    explicitlyClearedTags: [.headline]
))

if report.hasConflicts {
    for conflict in report.conflicts {
        print("Conflict for \(conflict.iptcTag): \(conflict.xmpValue)")
    }
}
```

Use `.replace` only when the source carrier is authoritative and an absent
source value should remove its mapped destination value. A user clearing one
field should normally use `explicitlyClearedTags` instead.

The reverse operation can lose XMP date precision because IIM has a narrower
representation, and therefore throws if an IIM value cannot be encoded:

```swift
let report = try metadata.synchronizeXMPToIPTC(options: .merge)
```

### Project and mutate standardized photo metadata

`PhotoMetadata` provides an XMP-preferred view without discarding the carrier
candidates that lost precedence:

```swift
let projected = metadata.photoMetadata
let headline = projected.string(.headline)

if let conflict = projected.conflicts[.headline] {
    for candidate in conflict.candidates {
        print("\(candidate.source.rawValue): \(candidate.value)")
    }
}
```

Apply canonical edits with `PhotoMetadataMutation`. Always inspect
`unappliedFields`; technical camera fields are intentionally read-only through
this mutation layer:

```swift
let result = try metadata.applyPhotoMetadataMutation(.init(
    values: [
        .headline: .string("Election night"),
        .keywords: .strings(["politics", "election"]),
    ],
    clearedFields: [.credit]
))

guard result.unappliedFields.isEmpty else {
    fatalError("Unsupported fields: \(result.unappliedFields)")
}
```

`PhotoMetadata.rawXMP` retains the entire graph, including Camera Raw and
application-private namespaces. The projection is not a replacement XMP
document and should not be used to rebuild one.

### Patch structured XMP without replacing unknown siblings

Directly assigning `.structure` or `.structuredArray` replaces the whole
value. Use a patch for partial edits:

```swift
var changedFields: [String: XMPValue] = [:]
changedFields[
    namespace: XMPNamespace.plus,
    property: "ImageSupplierID"
] = .simple("supplier-42")

let applied = xmp.patchStructuredArrayItem(
    namespace: XMPNamespace.plus,
    property: "ImageSupplier",
    at: 0,
    with: XMPStructurePatch(
        values: changedFields,
        removedKeys: []
    )
)
```

`applied` is `false` when the property is absent, has the wrong value shape, or
the index is out of bounds. Keys inside `values` and `removedKeys` are expanded
namespace URI plus local-name keys. The dictionary namespace subscript shown
above avoids hand-concatenating them.

Typed IPTC Extension and PLUS setters use the same patch behavior, so an edit
to one known member retains unknown fields in the structure.

### Choose filesystem timestamp behavior explicitly

Creation dates are now preserved by default for existing destinations.
Modification dates still update by default:

```swift
let options = ImageMetadata.WriteOptions(
    fileModificationDate: .preserveExisting,
    fileCreationDate: .preserveExisting
)
try metadata.write(to: imageURL, options: options)
```

For a new output that should inherit source timestamps, obtain the dates before
writing and pass `.set(date)` for each available value. Timestamp options apply
to image, video, audio, XMP sidecar, and batch writes.

Applications that previously captured and restored creation dates around every
write can remove that workaround after their filesystem regression tests pass.
Keep an explicit app-level policy only when it intentionally differs from the
package default.

### Use content revisions for concurrent sidecar edits

Modification dates are not safe revision tokens, especially when timestamp
preservation is enabled. Read a content revision and make the mutation
transactional:

```swift
let sidecarURL = XMPSidecar.sidecarURL(for: imageURL)
let snapshot = try XMPSidecar.readSnapshot(from: sidecarURL)

let result = try XMPSidecar.update(
    at: sidecarURL,
    expectedRevision: snapshot.revision,
    maximumRetries: 3,
    options: .init(fileModificationDate: .preserveExisting)
) { latest in
    latest.rating = 5
}

print("Installed \(result.revision) after \(result.attempts) attempt(s)")
```

The closure may run again against a newer parsed packet, so it must not perform
one-shot side effects. A base revision that is stale before the first mutation
throws `XMPSidecarUpdateError.staleRevision`. Use `.missing` to express a
create-only transaction.

The transaction protects cooperating package writers with a cross-process
directory lock. It cannot force an external editor to participate, but the
content comparison prevents a detected newer packet from being silently
overwritten.

### Check carrier capabilities before choosing embedded or sidecar writes

Use the format contract instead of maintaining an application copy of the
read/write matrix:

```swift
let capabilities = metadata.metadataCapabilities
switch capabilities[.xmp].write {
case .directlyWritable:
    try metadata.write(to: outputURL)
case .sidecarOnly:
    try metadata.writeSidecar(for: outputURL)
case .unsupported:
    fatalError("XMP is unsupported for \(metadata.format)")
}
```

Known proprietary RAW filename extensions remain sidecar-only under the safe
default policy. A normal `.tif` or `.tiff` URL remains a rendered TIFF even if
its Camera Make resembles a proprietary RAW camera, so applications should not
enable `allowUnsafeRawEmbed` merely to write rendered TIFFs.

### Verify semantic preservation after writing

Compare the source metadata with bytes read back from the installed carrier:

```swift
let installed = try ImageMetadata.read(from: outputURL)
let report = metadata.preservationReport(comparedTo: installed)

if !report.isSemanticallyLossless {
    print("Removed: \(report.removed)")
    print("Changed: \(report.changed)")
    print("Unrepresentable: \(report.unrepresentable)")
}
```

The report normalizes equivalent wire spellings and separates values that the
destination cannot represent from unexpected removal or change. It reports
facts; the application still decides which differences its workflow permits.
Camera Raw and application-private XMP remain application-owned even when the
package transports them losslessly.

### Adopt typed XMP GPS without losing the packet spelling

Typed accessors validate coordinates while retaining their original lexical
form:

```swift
let gps = try xmp.parsedGPS()
print(gps.latitude?.decimalDegrees as Any)
print(gps.latitude?.originalLexicalValue as Any)

try xmp.setGPSLatitude(59.913868)
try xmp.setGPSLongitude(-10.752245)
try xmp.setGPSAltitude(23.5)
try xmp.setGPSImageDirection(271.25, reference: .trueNorth)
```

Parsing accepts decimal, directional decimal, degrees/minutes/seconds, and
degrees/decimal-minutes forms. Contradictory signs and hemispheres, invalid
references, and out-of-range values throw `XMPGPSParsingError`.

## Downstream validation checklist

Before removing a local workaround or shipping the package update:

1. Run localized-title and embedded-container tests with the upstream package,
   not only a vendored pre-2.0 fork.
2. Exercise atomic and direct writes on visible, hidden, existing, and new
   destinations; assert creation and modification dates independently.
3. Run two-writer sidecar tests through `XMPSidecar.update`, including stale
   base revisions, retry success, retry exhaustion, and mutation failure.
4. Read back each advertised writable container and evaluate
   `preservationReport(comparedTo:)` under the application's policy.
5. Keep application-owned Camera Raw and private namespaces in the raw XMP
   graph; confirm canonical mutations do not rebuild or narrow that graph.
6. Re-run exhaustive-switch compilation checks for `XMPValue` and
   `PhotoMetadataValue` before selecting the release version.

The complete feature summary remains in [CHANGELOG.md](CHANGELOG.md), and the
supported carrier table and shorter examples remain in [README.md](README.md).
