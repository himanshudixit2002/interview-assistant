import Foundation
import Darwin

// MARK: - Arguments

struct Args {
    let positional: [String]
    let flags: [String: String]
    let switches: Set<String>

    init(_ argv: [String]) {
        var pos: [String] = []
        var flags: [String: String] = [:]
        var sw: Set<String> = []
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    flags[name] = argv[i + 1]
                    i += 1
                } else {
                    sw.insert(name)
                }
            } else {
                pos.append(a)
            }
            i += 1
        }
        positional = pos
        self.flags = flags
        switches = sw
    }

    func string(_ name: String, _ fallback: String) -> String { flags[name] ?? fallback }
    func int(_ name: String, _ fallback: Int) -> Int { flags[name].flatMap(Int.init) ?? fallback }
    func double(_ name: String, _ fallback: Double) -> Double { flags[name].flatMap(Double.init) ?? fallback }
    func has(_ name: String) -> Bool { switches.contains(name) || flags[name] != nil }
    func list(_ name: String) -> [String] { (flags[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

// MARK: - Timing

struct Stopwatch {
    let start = DispatchTime.now()
    var ms: Double { Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 }
}

private let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

func clock() -> String { isoFormatter.string(from: Date()) }

func log(_ s: String) {
    FileHandle.standardError.write("[\(clock())] \(s)\n".data(using: .utf8)!)
}

func out(_ s: String = "") {
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

func fmt(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }

// MARK: - Process memory

func residentFootprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return -1 }
    return Double(info.phys_footprint) / 1_048_576
}

// MARK: - Word error rate

func normalizeTokens(_ s: String) -> [String] {
    let lowered = s.lowercased()
    let cleaned = lowered.unicodeScalars.map { scalar -> Character in
        if CharacterSet.alphanumerics.contains(scalar) || scalar == " " { return Character(scalar) }
        return " "
    }
    return String(cleaned).split(separator: " ").map(String.init)
}

/// Levenshtein distance over tokens; returns (errors, referenceCount).
func wordErrors(reference: String, hypothesis: String) -> (errors: Int, refCount: Int) {
    let r = normalizeTokens(reference)
    let h = normalizeTokens(hypothesis)
    if r.isEmpty { return (h.count, 0) }
    var prev = Array(0...h.count)
    var cur = Array(repeating: 0, count: h.count + 1)
    for i in 1...r.count {
        cur[0] = i
        for j in stride(from: 1, through: h.count, by: 1) {
            let cost = r[i - 1] == h[j - 1] ? 0 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        }
        if h.isEmpty { cur = [i] }
        swap(&prev, &cur)
    }
    return (prev[h.count], r.count)
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    let rank = max(0, min(sorted.count - 1, Int(ceil(p / 100 * Double(sorted.count))) - 1))
    return sorted[rank]
}
