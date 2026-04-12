import Foundation

/// XMP namespace constants and IIM-to-XMP mapping.
public enum XMPNamespace {
    public static let xmpIdentifier = "http://ns.adobe.com/xap/1.0/\0"

    public static let dc        = "http://purl.org/dc/elements/1.1/"
    public static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    public static let iptcCore  = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
    public static let iptcExt   = "http://iptc.org/std/Iptc4xmpExt/2008-02-29/"
    public static let xmp       = "http://ns.adobe.com/xap/1.0/"
    public static let xmpRights = "http://ns.adobe.com/xap/1.0/rights/"
    public static let rdf       = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"

    /// Mapping from IPTC IIM tags to XMP namespace + property.
    public static let iimToXMP: [IPTCTag: (namespace: String, property: String)] = [
        .objectName:                    (dc, "title"),
        .keywords:                      (dc, "subject"),
        .specialInstructions:           (photoshop, "Instructions"),
        .dateCreated:                   (photoshop, "DateCreated"),
        .byline:                        (dc, "creator"),
        .bylineTitle:                   (photoshop, "AuthorsPosition"),
        .city:                          (photoshop, "City"),
        .sublocation:                   (iptcCore, "Location"),
        .provinceState:                 (photoshop, "State"),
        .countryPrimaryLocationCode:    (iptcCore, "CountryCode"),
        .countryPrimaryLocationName:    (photoshop, "Country"),
        .originalTransmissionReference: (photoshop, "TransmissionReference"),
        .headline:                      (photoshop, "Headline"),
        .credit:                        (photoshop, "Credit"),
        .source:                        (photoshop, "Source"),
        .copyrightNotice:               (dc, "rights"),
        .captionAbstract:               (dc, "description"),
        .writerEditor:                  (photoshop, "CaptionWriter"),
    ]

    /// Namespace prefix mappings for XMP serialization.
    public static let prefixes: [String: String] = [
        dc: "dc",
        photoshop: "photoshop",
        iptcCore: "Iptc4xmpCore",
        iptcExt: "Iptc4xmpExt",
        xmp: "xmp",
        xmpRights: "xmpRights",
        rdf: "rdf",
    ]
}
