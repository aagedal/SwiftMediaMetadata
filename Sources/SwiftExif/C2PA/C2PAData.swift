import Foundation

// MARK: - Top-Level

/// Parsed C2PA (Coalition for Content Provenance and Authenticity) data from an image.
public struct C2PAData: Sendable {
    /// All manifests in the manifest store, in order.
    public let manifests: [C2PAManifest]

    /// The active manifest (last in the store, whose bindings apply to the current asset).
    public var activeManifest: C2PAManifest? {
        manifests.last
    }

    public init(manifests: [C2PAManifest]) {
        self.manifests = manifests
    }
}

// MARK: - Manifest

/// A single C2PA manifest containing a claim, signature, and assertions.
public struct C2PAManifest: Sendable {
    /// The manifest label (URN identifier, e.g. "urn:c2pa:{uuid}").
    public let label: String
    /// The parsed claim.
    public let claim: C2PAClaim
    /// The parsed claim signature.
    public let signature: C2PASignature
    /// Parsed assertions from the assertion store.
    public let assertions: [C2PAAssertion]

    public init(label: String, claim: C2PAClaim, signature: C2PASignature, assertions: [C2PAAssertion]) {
        self.label = label
        self.claim = claim
        self.signature = signature
        self.assertions = assertions
    }
}

// MARK: - Claim

/// A parsed C2PA claim (CBOR-encoded).
public struct C2PAClaim: Sendable {
    /// The claim generator string (v1) or name from generator info (v2).
    public let claimGenerator: String
    /// Structured generator info (v2 only).
    public let claimGeneratorInfo: C2PAGeneratorInfo?
    /// Unique instance identifier for this version of the asset.
    public let instanceID: String?
    /// Media type (v1: dc:format).
    public let format: String?
    /// Asset title (dc:title).
    public let title: String?
    /// Hash algorithm used for assertions (e.g. "sha256").
    public let algorithm: String?
    /// Referenced assertions with their hashes.
    public let assertionReferences: [C2PAHashedURI]
    /// The full decoded CBOR claim for custom field access.
    public let raw: CBORValue

    public init(
        claimGenerator: String,
        claimGeneratorInfo: C2PAGeneratorInfo? = nil,
        instanceID: String? = nil,
        format: String? = nil,
        title: String? = nil,
        algorithm: String? = nil,
        assertionReferences: [C2PAHashedURI] = [],
        raw: CBORValue = .null
    ) {
        self.claimGenerator = claimGenerator
        self.claimGeneratorInfo = claimGeneratorInfo
        self.instanceID = instanceID
        self.format = format
        self.title = title
        self.algorithm = algorithm
        self.assertionReferences = assertionReferences
        self.raw = raw
    }
}

/// Structured claim generator information (C2PA v2).
public struct C2PAGeneratorInfo: Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

/// A hashed URI reference to an assertion or resource.
public struct C2PAHashedURI: Sendable {
    /// JUMBF URI (e.g. "self#jumbf=/c2pa/{manifest}/c2pa.assertions/{label}").
    public let url: String
    /// Hash algorithm identifier (e.g. "sha256").
    public let algorithm: String?
    /// Hash value.
    public let hash: Data

    public init(url: String, algorithm: String? = nil, hash: Data = Data()) {
        self.url = url
        self.algorithm = algorithm
        self.hash = hash
    }
}

// MARK: - Signature

/// A parsed C2PA claim signature (COSE Sign1).
public struct C2PASignature: Sendable {
    /// The signing algorithm.
    public let algorithm: C2PASignatureAlgorithm?
    /// DER-encoded X.509 certificate chain (if present in protected header).
    public let certificateChain: [Data]
    /// RFC 3161 timestamp token (DER-encoded, if present).
    public let timestamp: Data?
    /// Raw signature bytes.
    public let signatureBytes: Data
    /// The full decoded COSE Sign1 structure for custom access.
    public let raw: CBORValue

    public init(
        algorithm: C2PASignatureAlgorithm? = nil,
        certificateChain: [Data] = [],
        timestamp: Data? = nil,
        signatureBytes: Data = Data(),
        raw: CBORValue = .null
    ) {
        self.algorithm = algorithm
        self.certificateChain = certificateChain
        self.timestamp = timestamp
        self.signatureBytes = signatureBytes
        self.raw = raw
    }
}

/// COSE signature algorithm identifiers used by C2PA.
public enum C2PASignatureAlgorithm: Sendable, CustomStringConvertible {
    case es256    // ECDSA P-256 + SHA-256 (COSE -7)
    case es384    // ECDSA P-384 + SHA-384 (COSE -35)
    case es512    // ECDSA P-521 + SHA-512 (COSE -36)
    case ps256    // RSASSA-PSS + SHA-256 (COSE -37)
    case ps384    // RSASSA-PSS + SHA-384 (COSE -38)
    case ps512    // RSASSA-PSS + SHA-512 (COSE -39)
    case edDSA    // Edwards-curve DSA (COSE -8)
    case unknown(Int64)

    /// Create from a COSE algorithm integer value.
    public init(coseValue: Int64) {
        switch coseValue {
        case -7:  self = .es256
        case -35: self = .es384
        case -36: self = .es512
        case -37: self = .ps256
        case -38: self = .ps384
        case -39: self = .ps512
        case -8:  self = .edDSA
        default:  self = .unknown(coseValue)
        }
    }

    public var description: String {
        switch self {
        case .es256: return "ES256"
        case .es384: return "ES384"
        case .es512: return "ES512"
        case .ps256: return "PS256"
        case .ps384: return "PS384"
        case .ps512: return "PS512"
        case .edDSA: return "EdDSA"
        case .unknown(let v): return "Unknown(\(v))"
        }
    }
}

// MARK: - Assertions

/// A parsed C2PA assertion.
public struct C2PAAssertion: Sendable {
    /// The assertion label (e.g. "c2pa.actions", "c2pa.hash.data", "c2pa.ingredient").
    public let label: String
    /// Parsed assertion content.
    public let content: C2PAAssertionContent

    public init(label: String, content: C2PAAssertionContent) {
        self.label = label
        self.content = content
    }
}

/// Typed assertion content.
public enum C2PAAssertionContent: Sendable {
    /// Action assertion (c2pa.actions / c2pa.actions.v2).
    case actions(C2PAActions)
    /// Data hash assertion (c2pa.hash.data).
    case hashData(C2PAHashData)
    /// Ingredient assertion (c2pa.ingredient / c2pa.ingredient.v3).
    case ingredient(C2PAIngredient)
    /// Thumbnail binary data with format string (e.g. "jpeg", "png").
    case thumbnail(Data, format: String)
    /// Raw CBOR content for unrecognized or custom assertions.
    case cbor(CBORValue)
    /// Raw JSON content.
    case json(Data)
    /// Raw binary content.
    case binary(Data)
}

/// Parsed c2pa.actions assertion.
public struct C2PAActions: Sendable {
    public let actions: [C2PAAction]

    public init(actions: [C2PAAction]) {
        self.actions = actions
    }
}

/// A single action within an actions assertion.
public struct C2PAAction: Sendable {
    /// Action type (e.g. "c2pa.created", "c2pa.edited", "c2pa.opened").
    public let action: String
    /// Software agent that performed the action.
    public let softwareAgent: String?
    /// Human-readable description.
    public let description: String?
    /// IPTC digital source type URI.
    public let digitalSourceType: String?
    /// Additional parameters as raw CBOR.
    public let parameters: CBORValue?

    public init(
        action: String,
        softwareAgent: String? = nil,
        description: String? = nil,
        digitalSourceType: String? = nil,
        parameters: CBORValue? = nil
    ) {
        self.action = action
        self.softwareAgent = softwareAgent
        self.description = description
        self.digitalSourceType = digitalSourceType
        self.parameters = parameters
    }
}

/// Parsed c2pa.hash.data assertion (hard binding).
public struct C2PAHashData: Sendable {
    /// Hash algorithm identifier (e.g. "sha256").
    public let algorithm: String
    /// Computed hash value.
    public let hash: Data
    /// Byte ranges excluded from hashing (where the manifest store is embedded).
    public let exclusions: [C2PAExclusion]

    public init(algorithm: String, hash: Data, exclusions: [C2PAExclusion] = []) {
        self.algorithm = algorithm
        self.hash = hash
        self.exclusions = exclusions
    }
}

/// A byte range exclusion for data hash computation.
public struct C2PAExclusion: Sendable {
    /// Start byte offset in the asset.
    public let start: UInt64
    /// Number of bytes to exclude.
    public let length: UInt64

    public init(start: UInt64, length: UInt64) {
        self.start = start
        self.length = length
    }
}

/// Parsed c2pa.ingredient assertion.
public struct C2PAIngredient: Sendable {
    /// Asset title.
    public let title: String?
    /// Media type (MIME).
    public let format: String?
    /// Unique instance identifier.
    public let instanceID: String?
    /// Relationship to the parent asset: "parentOf", "componentOf", or "inputTo".
    public let relationship: String?

    public init(title: String? = nil, format: String? = nil, instanceID: String? = nil, relationship: String? = nil) {
        self.title = title
        self.format = format
        self.instanceID = instanceID
        self.relationship = relationship
    }
}

// MARK: - Thumbnail Convenience

/// An extracted C2PA thumbnail with its source label and image format.
public struct C2PAThumbnail: Sendable {
    /// Full assertion label, e.g. "c2pa.thumbnail.claim.jpeg" or "c2pa.thumbnail.ingredient.png".
    public let label: String
    /// Raw image bytes from the JUMBF `bidb` box.
    public let data: Data
    /// Image format suffix from the assertion label, e.g. "jpeg", "png".
    public let format: String

    public init(label: String, data: Data, format: String) {
        self.label = label
        self.data = data
        self.format = format
    }
}
