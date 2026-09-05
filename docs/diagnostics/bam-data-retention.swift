// Bounded reproduction of BAMStreamDeck UDSClient consumed-prefix retention.
// macOS: swiftc -O bam-data-retention.swift -o /tmp/bam-data-retention
// Run with no argument (existing behavior), "fixed" (copy tail), or "remove".
import Foundation
import Darwin

var buffer = Data()
let payload = Data((String(repeating: "x", count: 199) + "\n").utf8)
let fixed = CommandLine.arguments.contains("fixed")
let remove = CommandLine.arguments.contains("remove")
for i in 1...1_000_000 {
    buffer.append(payload)
    while let idx = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<idx])
        precondition(line.count == 199)
        if remove {
            buffer.removeSubrange(buffer.startIndex...idx)
        } else {
            let tail = buffer[buffer.index(after: idx)...]
            buffer = fixed ? Data(tail) : tail
        }
    }
    if i % 200_000 == 0 {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("frames=\(i) count=\(buffer.count) start=\(buffer.startIndex) maxRSS=\(usage.ru_maxrss)")
    }
}

for method in ["fixed", "remove"] {
    var fragmented = Data()
    var lines: [String] = []
    for chunk in ["a", "bc\ndef\n\ng", "hi", "\nj"] {
        fragmented.append(contentsOf: chunk.utf8)
        while let idx = fragmented.firstIndex(of: 0x0A) {
            let line = Data(fragmented[fragmented.startIndex..<idx])
            if method == "remove" {
                fragmented.removeSubrange(fragmented.startIndex...idx)
            } else {
                fragmented = Data(fragmented[fragmented.index(after: idx)...])
            }
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
    }
    precondition(lines == ["abc", "def", "ghi"])
    precondition(String(decoding: fragmented, as: UTF8.self) == "j")
    precondition(fragmented.startIndex == 0)
    print("fragmented/multiple/empty-lines validation passed: \(method)")
}
