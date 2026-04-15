#!/usr/bin/env swift
//
// build_geolocation.swift
// Downloads GeoNames data and generates GeoLocationDatabase.swift
//
// Usage: swift Scripts/build_geolocation.swift
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

// MARK: - Swift Escaping

func escapeSwiftString(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
     .replacingOccurrences(of: "\"", with: "\\\"")
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

// Collect unique timezone data — not in our files, so we skip timezone for now
// (GeoNames timezone is column 17, which we can add)
// For now, let's re-parse to get timezones
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

// Generate Swift file
print("Generating Swift source...")

let outputPath = FileManager.default.currentDirectoryPath + "/Sources/SwiftExif/Geolocation/GeoLocationDatabase.swift"

var out = """
// GeoLocationDatabase.swift
// AUTO-GENERATED by Scripts/build_geolocation.swift — do not edit manually.
// Data source: GeoNames (https://www.geonames.org/) — Creative Commons Attribution 4.0
// Generated from cities15000.txt (\(cities.count) cities with population >= 15,000)

import Foundation

enum GeoLocationDatabase {
    static let cityCount = \(cities.count)

"""

// City names
out += "    static let cityNames: [String] = [\n"
for (i, city) in cities.enumerated() {
    let comma = i < cities.count - 1 ? "," : ""
    out += "        \"\(escapeSwiftString(city.name))\"\(comma)\n"
}
out += "    ]\n\n"

// Latitudes
out += "    static let latitudes: [Float] = [\n"
for chunk in stride(from: 0, to: cities.count, by: 10) {
    let end = min(chunk + 10, cities.count)
    let vals = cities[chunk..<end].map { String(format: "%.5f", $0.latitude) }
    let comma = end < cities.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Longitudes
out += "    static let longitudes: [Float] = [\n"
for chunk in stride(from: 0, to: cities.count, by: 10) {
    let end = min(chunk + 10, cities.count)
    let vals = cities[chunk..<end].map { String(format: "%.5f", $0.longitude) }
    let comma = end < cities.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Populations
out += "    static let populations: [Int32] = [\n"
for chunk in stride(from: 0, to: cities.count, by: 10) {
    let end = min(chunk + 10, cities.count)
    let vals = cities[chunk..<end].map { String(min($0.population, Int(Int32.max))) }
    let comma = end < cities.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Region indices
out += "    static let regionIndices: [UInt16] = [\n"
for chunk in stride(from: 0, to: regionIndices.count, by: 20) {
    let end = min(chunk + 20, regionIndices.count)
    let vals = regionIndices[chunk..<end].map { String($0) }
    let comma = end < regionIndices.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Country indices
out += "    static let countryIndices: [UInt8] = [\n"
for chunk in stride(from: 0, to: countryIndices.count, by: 20) {
    let end = min(chunk + 20, countryIndices.count)
    let vals = countryIndices[chunk..<end].map { String($0) }
    let comma = end < countryIndices.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Timezone indices
out += "    static let timezoneIndices: [UInt16] = [\n"
for chunk in stride(from: 0, to: tzIndices.count, by: 20) {
    let end = min(chunk + 20, tzIndices.count)
    let vals = tzIndices[chunk..<end].map { String($0) }
    let comma = end < tzIndices.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Country code indices
out += "    static let countryCodeIndices: [UInt8] = [\n"
for chunk in stride(from: 0, to: cc2Indices.count, by: 20) {
    let end = min(chunk + 20, cc2Indices.count)
    let vals = cc2Indices[chunk..<end].map { String($0) }
    let comma = end < cc2Indices.count ? "," : ""
    out += "        \(vals.joined(separator: ", "))\(comma)\n"
}
out += "    ]\n\n"

// Region string table
out += "    static let regionNames: [String] = [\n"
for (i, name) in regionTable.enumerated() {
    let comma = i < regionTable.count - 1 ? "," : ""
    out += "        \"\(escapeSwiftString(name))\"\(comma)\n"
}
out += "    ]\n\n"

// Country string table
out += "    static let countryNames: [String] = [\n"
for (i, name) in countryTable.enumerated() {
    let comma = i < countryTable.count - 1 ? "," : ""
    out += "        \"\(escapeSwiftString(name))\"\(comma)\n"
}
out += "    ]\n\n"

// Timezone string table
out += "    static let timezoneNames: [String] = [\n"
for (i, tz) in tzTable.enumerated() {
    let comma = i < tzTable.count - 1 ? "," : ""
    out += "        \"\(escapeSwiftString(tz))\"\(comma)\n"
}
out += "    ]\n\n"

// Country code string table (alpha-2)
out += "    static let countryCode2s: [String] = [\n"
for (i, cc) in cc2Table.enumerated() {
    let comma = i < cc2Table.count - 1 ? "," : ""
    out += "        \"\(cc)\"\(comma)\n"
}
out += "    ]\n\n"

// Alpha-2 to Alpha-3 mapping
out += "    static let alpha2ToAlpha3: [String: String] = [\n"
for (i, (k, v)) in alpha2ToAlpha3.sorted(by: { $0.key < $1.key }).enumerated() {
    let comma = i < alpha2ToAlpha3.count - 1 ? "," : ""
    out += "        \"\(k)\": \"\(v)\"\(comma)\n"
}
out += "    ]\n"

out += "}\n"

try! out.write(toFile: outputPath, atomically: true, encoding: .utf8)

let fileSize = try! FileManager.default.attributesOfItem(atPath: outputPath)[.size] as! UInt64
print("Generated \(outputPath)")
print("File size: \(fileSize / 1024) KB")
print("Done!")
