// check-coverage.swift checks that the tests cover every line of
// Sources/VSQL, and lists the lines that they don't:
//
//   swift test --enable-code-coverage
//   swift scripts/check-coverage.swift "$(swift test --show-codecov-path)"
//
// The argument is the coverage JSON that `swift test --enable-code-coverage`
// writes (llvm-cov export). Code that can't be reached by a test should be
// restructured (or removed) rather than left out.

import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: swift scripts/check-coverage.swift COVERAGE.json")
    exit(2)
}

let json = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let data = ((json as! [String: Any])["data"] as! [[String: Any]])[0]
let files = data["files"] as! [[String: Any]]

/// A segment is [line, column, count, hasCount, isRegionEntry, isGapRegion].
struct Segment {
    let line: Int
    let count: Int
    let hasCount: Bool
    let isRegionEntry: Bool
    let isGapRegion: Bool

    init(_ a: [Any]) {
        line = a[0] as! Int
        count = a[2] as! Int
        hasCount = a[3] as! Bool
        isRegionEntry = a[4] as! Bool
        isGapRegion = a.count > 5 ? a[5] as! Bool : false
    }

    var isStartOfRegion: Bool { !isGapRegion && hasCount && isRegionEntry }
}

/// The lines that aren't covered, the same way that llvm-cov counts lines
/// (LineCoverageStats).
func uncoveredLines(_ segments: [Segment]) -> [Int] {
    guard let last = segments.last?.line else { return [] }
    var uncovered: [Int] = []
    var wrapped: Segment?
    var i = 0
    for line in 1...last {
        var lineSegments: [Segment] = []
        while i < segments.count && segments[i].line == line {
            lineSegments.append(segments[i])
            i += 1
        }
        let regions = lineSegments.filter(\.isStartOfRegion)
        let startOfSkippedRegion =
            lineSegments.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
        let mapped =
            !startOfSkippedRegion && (wrapped?.hasCount == true || !regions.isEmpty)
        if mapped {
            let count = ([wrapped?.hasCount == true ? wrapped!.count : 0] + regions.map(\.count))
                .max()!
            if count == 0 {
                uncovered.append(line)
            }
        }
        if let lastSegment = lineSegments.last {
            wrapped = lastSegment
        }
    }
    return uncovered
}

var failed = false
for file in files {
    let name = file["filename"] as! String
    guard let range = name.range(of: "/Sources/VSQL/") else { continue }
    let lines = (file["summary"] as! [String: Any])["lines"] as! [String: Any]
    let covered = lines["covered"] as! Int
    let count = lines["count"] as! Int
    let path = "Sources/VSQL/" + name[range.upperBound...]
    print("\(path): \(covered)/\(count) lines")
    if covered < count {
        failed = true
        let segments = (file["segments"] as! [[Any]]).map(Segment.init)
        let source =
            (try? String(contentsOfFile: name, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        var lines = uncoveredLines(segments)
        if lines.isEmpty {
            // The line is covered, but a region in it isn't (such as the
            // right side of ??).
            lines = Array(Set(segments.filter { $0.isStartOfRegion && $0.count == 0 }.map(\.line)))
                .sorted()
        }
        for line in lines {
            let text = line <= source.count ? source[line - 1] : ""
            print("  \(path):\(line): \(text.trimmingCharacters(in: .whitespaces))")
        }
    }
}

if failed {
    print("The tests don't cover every line of Sources/VSQL.")
    exit(1)
}
print("The tests cover every line of Sources/VSQL.")
