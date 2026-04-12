import Foundation

/// Reconstructs an AVIF file from parsed components.
public struct AVIFWriter {

    /// Reconstruct an AVIF file from its boxes, with updated metadata.
    public static func write(_ file: AVIFFile, exif: ExifData?, xmp: XMPData?) throws -> Data {
        var updatedBoxes = file.boxes

        // Build new Exif property box data (4-byte offset prefix + TIFF)
        let exifBoxData: Data? = exif.map {
            var data = Data([0x00, 0x00, 0x00, 0x00]) // offset prefix
            data.append(ExifWriter.writeTIFF($0))
            return data
        }

        // Build new XMP mime box data (null-terminated content type + XML)
        let xmpBoxData: Data? = xmp.map {
            var data = Data("application/rdf+xml".utf8)
            data.append(0x00) // null terminator
            data.append(Data(XMPWriter.generateXML($0).utf8))
            return data
        }

        // Update or create the meta box
        if let metaIndex = updatedBoxes.firstIndex(where: { $0.type == "meta" }) {
            let newMetaData = try rebuildMetaBox(updatedBoxes[metaIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            updatedBoxes[metaIndex] = ISOBMFFBox(type: "meta", data: newMetaData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            // Create a new meta box from scratch
            let metaData = buildNewMetaBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            updatedBoxes.append(ISOBMFFBox(type: "meta", data: metaData))
        }

        return ISOBMFFBoxWriter.serialize(boxes: updatedBoxes)
    }

    // MARK: - Private

    /// Rebuild meta box data with updated Exif/XMP property boxes.
    private static func rebuildMetaBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?) throws -> Data {
        // meta is a FullBox: 4 bytes version+flags, then child boxes
        guard data.count > 4 else {
            return buildNewMetaBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        }

        let fullBoxHeader = Data(data.prefix(4))
        let childData = Data(data.suffix(from: data.startIndex + 4))

        var children: [ISOBMFFBox]
        if let parsed = try? ISOBMFFBoxReader.parseBoxes(from: childData), !parsed.isEmpty {
            children = parsed
        } else {
            // Fall back: treat entire data as children without FullBox header
            children = (try? ISOBMFFBoxReader.parseBoxes(from: data)) ?? []
            // If we got children without the FullBox header, the meta box doesn't have one
            let result = rebuildIprpInChildren(&children, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            return ISOBMFFBoxWriter.serialize(boxes: result)
        }

        var result = children
        rebuildIprpInChildren(&result, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)

        var writer = BinaryWriter(capacity: data.count + 256)
        writer.writeBytes(fullBoxHeader)
        ISOBMFFBoxWriter.writeBoxes(&writer, boxes: result)
        return writer.data
    }

    @discardableResult
    private static func rebuildIprpInChildren(_ children: inout [ISOBMFFBox], exifBoxData: Data?, xmpBoxData: Data?) -> [ISOBMFFBox] {
        if let iprpIndex = children.firstIndex(where: { $0.type == "iprp" }) {
            let newIprpData = rebuildIprpBox(children[iprpIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            children[iprpIndex] = ISOBMFFBox(type: "iprp", data: newIprpData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            // Create iprp -> ipco from scratch
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            let iprpData = ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
            children.append(ISOBMFFBox(type: "iprp", data: iprpData))
        }
        return children
    }

    private static func rebuildIprpBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        guard var iprpChildren = try? ISOBMFFBoxReader.parseBoxes(from: data) else {
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            return ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
        }

        if let ipcoIndex = iprpChildren.firstIndex(where: { $0.type == "ipco" }) {
            let newIpcoData = rebuildIpcoBox(iprpChildren[ipcoIndex].data, exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            iprpChildren[ipcoIndex] = ISOBMFFBox(type: "ipco", data: newIpcoData)
        } else if exifBoxData != nil || xmpBoxData != nil {
            let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
            iprpChildren.insert(ISOBMFFBox(type: "ipco", data: ipcoData), at: 0)
        }

        return ISOBMFFBoxWriter.serialize(boxes: iprpChildren)
    }

    private static func rebuildIpcoBox(_ data: Data, exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        guard var properties = try? ISOBMFFBoxReader.parseBoxes(from: data) else {
            return buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        }

        // Replace or add Exif box
        if let exifData = exifBoxData {
            if let index = properties.firstIndex(where: { $0.type == "Exif" }) {
                properties[index] = ISOBMFFBox(type: "Exif", data: exifData)
            } else {
                properties.append(ISOBMFFBox(type: "Exif", data: exifData))
            }
        }

        // Replace or add mime box for XMP
        if let xmpData = xmpBoxData {
            if let index = properties.firstIndex(where: { $0.type == "mime" && isMimeXMP($0) }) {
                properties[index] = ISOBMFFBox(type: "mime", data: xmpData)
            } else {
                properties.append(ISOBMFFBox(type: "mime", data: xmpData))
            }
        }

        return ISOBMFFBoxWriter.serialize(boxes: properties)
    }

    private static func buildIpcoBox(exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        var properties: [ISOBMFFBox] = []
        if let exifData = exifBoxData {
            properties.append(ISOBMFFBox(type: "Exif", data: exifData))
        }
        if let xmpData = xmpBoxData {
            properties.append(ISOBMFFBox(type: "mime", data: xmpData))
        }
        return ISOBMFFBoxWriter.serialize(boxes: properties)
    }

    private static func buildNewMetaBox(exifBoxData: Data?, xmpBoxData: Data?) -> Data {
        var writer = BinaryWriter(capacity: 256)
        // FullBox header: version 0, flags 0
        writer.writeUInt32BigEndian(0x00000000)
        // iprp -> ipco
        let ipcoData = buildIpcoBox(exifBoxData: exifBoxData, xmpBoxData: xmpBoxData)
        let iprpData = ISOBMFFBoxWriter.serialize(boxes: [ISOBMFFBox(type: "ipco", data: ipcoData)])
        ISOBMFFBoxWriter.writeBox(&writer, box: ISOBMFFBox(type: "iprp", data: iprpData))
        return writer.data
    }

    private static func isMimeXMP(_ box: ISOBMFFBox) -> Bool {
        let contentType = "application/rdf+xml"
        guard box.data.count > contentType.utf8.count else { return false }
        return box.data.prefix(contentType.utf8.count) == Data(contentType.utf8)
    }
}
