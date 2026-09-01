#!/usr/bin/env swift
//
// build_geolocation.swift
// Builds the bundled geolocation database from downloaded GeoNames data.
//
// Usage (after placing the three source files in /tmp):
//   swift Scripts/build_geolocation.swift
//
// Data source: GeoNames (https://www.geonames.org/) - Creative Commons Attribution 4.0

import Foundation

// MARK: - Data Structures

struct City {
    let name: String
    let latitude: Float
    let longitude: Float
    let countryCode2: String  // ISO alpha-2
    let admin1Code: String
    let population: Int
}

// MARK: - Parse GeoNames Files

func parseCities(from path: String) -> [City] {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        fatalError("Cannot read \(path)")
    }

    var cities: [City] = []
    for line in content.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 15 else { continue }

        let name = String(fields[1])       // name
        let lat = Float(fields[4]) ?? 0
        let lon = Float(fields[5]) ?? 0
        let cc = String(fields[8])         // country code (alpha-2)
        let admin1 = String(fields[10])    // admin1 code
        let pop = Int(fields[14]) ?? 0

        cities.append(City(name: name, latitude: lat, longitude: lon,
                          countryCode2: cc, admin1Code: admin1, population: pop))
    }
    return cities
}

func parseCountryInfo(from path: String) -> (alpha2ToAlpha3: [String: String], alpha2ToName: [String: String]) {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        fatalError("Cannot read \(path)")
    }

    var a2toa3: [String: String] = [:]
    var a2toName: [String: String] = [:]
    for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 5 else { continue }
        let alpha2 = String(fields[0])
        let alpha3 = String(fields[1])
        let name = String(fields[4])
        a2toa3[alpha2] = alpha3
        a2toName[alpha2] = name
    }
    return (a2toa3, a2toName)
}

func parseAdmin1(from path: String) -> [String: String] {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else {
        fatalError("Cannot read \(path)")
    }

    var regions: [String: String] = [:]  // "CC.ADMIN1" -> name
    for line in content.split(separator: "\n") {
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 2 else { continue }
        let code = String(fields[0])     // e.g., "NO.03"
        let name = String(fields[1])     // e.g., "Oslo"
        regions[code] = name
    }
    return regions
}

// MARK: - String Deduplication

func buildStringTable(_ strings: [String]) -> (table: [String], indices: [Int]) {
    var uniqueStrings: [String] = []
    var stringToIndex: [String: Int] = [:]
    var indices: [Int] = []

    for s in strings {
        if let idx = stringToIndex[s] {
            indices.append(idx)
        } else {
            let idx = uniqueStrings.count
            uniqueStrings.append(s)
            stringToIndex[s] = idx
            indices.append(idx)
        }
    }
    return (uniqueStrings, indices)
}

// MARK: - Main

let tmpDir = "/tmp"
let citiesPath = "\(tmpDir)/cities15000.txt"
let countryPath = "\(tmpDir)/countryInfo.txt"
let admin1Path = "\(tmpDir)/admin1CodesASCII.txt"

// Check files exist
for path in [citiesPath, countryPath, admin1Path] {
    guard FileManager.default.fileExists(atPath: path) else {
        fatalError("Missing file: \(path). Download from https://download.geonames.org/export/dump/")
    }
}

print("Parsing cities...")
let cities = parseCities(from: citiesPath)
print("  \(cities.count) cities loaded")

print("Parsing country info...")
let (alpha2ToAlpha3, alpha2ToName) = parseCountryInfo(from: countryPath)
print("  \(alpha2ToAlpha3.count) countries")

print("Parsing admin1 codes...")
let admin1Regions = parseAdmin1(from: admin1Path)
print("  \(admin1Regions.count) regions")

// Build region names for each city
let regionNames = cities.map { city -> String in
    let key = "\(city.countryCode2).\(city.admin1Code)"
    return admin1Regions[key] ?? ""
}

let countryNames = cities.map { alpha2ToName[$0.countryCode2] ?? "" }

// The city parser above only needs the core record fields. Re-read column 17
// separately to build the deduplicated IANA timezone table.
func parseCitiesWithTimezone(from path: String) -> [String] {
    guard let data = FileManager.default.contents(atPath: path),
          let content = String(data: data, encoding: .utf8) else { return [] }

    return content.split(separator: "\n").compactMap { line -> String? in
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 18 else { return nil }
        return String(fields[17])  // timezone column
    }
}

let timezones = parseCitiesWithTimezone(from: citiesPath)

// Build deduped string tables
let (regionTable, regionIndices) = buildStringTable(regionNames)
let (countryTable, countryIndices) = buildStringTable(countryNames)
let (tzTable, tzIndices) = buildStringTable(timezones)
let (cc2Table, cc2Indices) = buildStringTable(cities.map { $0.countryCode2 })

print("String tables: \(regionTable.count) regions, \(countryTable.count) countries, \(tzTable.count) timezones")

// MARK: - Binary Encoding

struct DatabaseWriter {
    var data = Data([0x53, 0x4D, 0x4D, 0x47, 0x45, 0x4F, 0x31, 0x00]) // SMMGEO1\0

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func append(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func append(_ value: Int32) {
        append(UInt32(bitPattern: value))
    }

    mutating func append(_ value: Float) {
        append(value.bitPattern)
    }

    mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        append(UInt32(bytes.count))
        data.append(bytes)
    }

    mutating func appendArray<Element>(
        _ values: [Element],
        element: (inout Self, Element) -> Void
    ) {
        append(UInt32(values.count))
        for value in values {
            element(&self, value)
        }
    }
}

print("Generating binary resource...")
var writer = DatabaseWriter()
writer.append(UInt32(1)) // format version
writer.appendArray(cities.map(\.name)) { $0.append($1) }
writer.appendArray(cities.map(\.latitude)) { $0.append($1) }
writer.appendArray(cities.map(\.longitude)) { $0.append($1) }
writer.appendArray(cities.map { Int32(clamping: $0.population) }) { $0.append($1) }
writer.appendArray(regionIndices.map { UInt16($0) }) { $0.append($1) }
writer.appendArray(countryIndices.map { UInt8($0) }) { $0.append($1) }
writer.appendArray(tzIndices.map { UInt16($0) }) { $0.append($1) }
writer.appendArray(cc2Indices.map { UInt8($0) }) { $0.append($1) }
writer.appendArray(regionTable) { $0.append($1) }
writer.appendArray(countryTable) { $0.append($1) }
writer.appendArray(tzTable) { $0.append($1) }
writer.appendArray(cc2Table) { $0.append($1) }

let sortedCountryCodes = alpha2ToAlpha3.sorted { $0.key < $1.key }
writer.append(UInt32(sortedCountryCodes.count))
for (alpha2, alpha3) in sortedCountryCodes {
    writer.append(alpha2)
    writer.append(alpha3)
}

let resourcesDirectory = FileManager.default.currentDirectoryPath
    + "/Sources/SwiftMediaMetadata/Resources"
try FileManager.default.createDirectory(
    atPath: resourcesDirectory,
    withIntermediateDirectories: true
)
let outputPath = resourcesDirectory + "/GeoLocationDatabase.bin"
try writer.data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)

print("Generated \(outputPath)")
print("Cities: \(cities.count)")
print("File size: \(writer.data.count / 1024) KB")
print("Done!")
