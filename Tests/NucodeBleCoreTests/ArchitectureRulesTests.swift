import Foundation
import XCTest

// 구조 규칙 시험(R1·R2·R3·R4·R5). Sources/NucodeBleCore 소스를 읽어 패키지(바로 아래 디렉터리) 사이의 의존을 검사한다.
// 규칙 함수는 [패키지: [상대경로: 소스]] 를 받는 순수 함수이고, 실제 소스와 자기 점검이 같은 함수를 부른다.
// 위반 한 줄: "<규칙 id>: <상대경로>:<줄> <from> -> <to> (<이름>)". 규칙 id 는 시험 이름과 같다(게이트가 센다).

/// 패키지 분류표. 표에 없는 패키지는 domain 으로 보고 noPackageCycles 가 따로 실패시킨다.
private struct PackageClassification {
    var model: Set<String>
    var ports: Set<String>
    var driver: Set<String>
    var factory: Set<String>
    var domain: Set<String>
    var core: Set<String> = []

    enum Kind { case model, ports, driver, factory, domain, core, unclassified }

    func kind(of package: String) -> Kind {
        if model.contains(package) { return .model }
        if ports.contains(package) { return .ports }
        if driver.contains(package) { return .driver }
        if factory.contains(package) { return .factory }
        if domain.contains(package) { return .domain }
        if core.contains(package) { return .core }
        return .unclassified
    }

    /// domain 규칙을 적용할 패키지(분류 안 된 것은 보수적으로 domain 으로 본다)
    func isDomainLike(_ package: String) -> Bool {
        let k = kind(of: package)
        return k == .domain || k == .unclassified
    }

    /// 플랫폼 타입·Driver 참조 규칙을 적용할 안쪽 층 = Model·Ports·core·domain (Android INNER_LAYERS 와 같은 뜻)
    func isInnerLayer(_ package: String) -> Bool {
        let k = kind(of: package)
        return k == .model || k == .ports || k == .core || k == .domain || k == .unclassified
    }

    static let project = PackageClassification(
        model: ["Model"],
        ports: ["Ports"],
        driver: ["Driver"],
        factory: ["Factory"],
        domain: ["Adapter", "Client", "Concurrency", "Connection", "Gatt", "Restore", "Scan", "Session"],
        core: ["Core"]
    )
}

private typealias PackageSources = [String: [String: String]]

private struct Edge {
    let file: String
    let line: Int
    let from: String
    let to: String
    let name: String

    var location: String { "\(file):\(line)" }
}

private struct Declaration {
    let kind: String
    let package: String
}

private struct Analysis {
    /// 주석·문자열을 지운 소스. (패키지, 상대경로, 줄 목록)
    var files: [(package: String, file: String, lines: [String])] = []
    var declarations: [String: [Declaration]] = [:]
    /// extension 멤버 이름 → 그 멤버를 선언한 패키지들. 같은 모듈에서는 import·타입 이름 없이 부를 수 있어 이름으로 간선을 만든다.
    var extensionMembers: [String: Set<String>] = [:]
    var edges: [Edge] = []
    var packages: [String] = []
}

private enum RuleScanner {
    static let declKeywords: Set<String> = ["class", "struct", "enum", "protocol", "actor", "typealias", "func", "let", "var"]
    static let modifiers: Set<String> = ["public", "package", "internal", "final", "open", "nonisolated", "indirect"]

    // MARK: lexer

    /// 주석과 문자열 리터럴의 글자를 공백으로 지운다(줄바꿈은 남긴다). 보간 `\( … )` 안의 식은 남긴다.
    static func stripSource(_ src: String) -> String {
        let c = Array(src.unicodeScalars)
        let n = c.count
        var out = String.UnicodeScalarView()
        var i = 0

        func at(_ k: Int) -> Unicode.Scalar? { k >= 0 && k < n ? c[k] : nil }
        func blank(_ ch: Unicode.Scalar) { out.append(ch == "\n" ? "\n" : " ") }

        // i 는 여는 따옴표 위치(앞의 # 은 이미 지웠다). 닫는 구분자까지 지우고 i 를 그 뒤로 옮긴다.
        func string(hashes h: Int) {
            let multiline = at(i + 1) == "\"" && at(i + 2) == "\""
            let quotes = multiline ? 3 : 1
            for _ in 0..<quotes { blank("\""); i += 1 }
            while i < n {
                let ch = c[i]
                if ch == "\\" {
                    var hashesMatch = true
                    for t in 0..<h where at(i + 1 + t) != "#" { hashesMatch = false }
                    if hashesMatch {
                        let p = i + 1 + h
                        if at(p) == "(" {
                            for _ in 0..<(h + 2) { out.append(" ") }
                            i = p + 1
                            code(inInterpolation: true)
                            if i < n, c[i] == ")" { blank(")"); i += 1 }
                            continue
                        }
                        for _ in 0..<(h + 1) { out.append(" ") }
                        i += h + 1
                        if i < n { blank(c[i]); i += 1 }
                        continue
                    }
                    blank(ch); i += 1
                    continue
                }
                if ch == "\"" {
                    var closes = true
                    for t in 0..<quotes where at(i + t) != "\"" { closes = false }
                    if closes {
                        for t in 0..<h where at(i + quotes + t) != "#" { closes = false }
                    }
                    if closes {
                        for _ in 0..<(quotes + h) { out.append(" ") }
                        i += quotes + h
                        return
                    }
                }
                blank(ch); i += 1
            }
        }

        func code(inInterpolation: Bool) {
            var parens = 0
            while i < n {
                let ch = c[i]
                if ch == "/", at(i + 1) == "/" {
                    while i < n, c[i] != "\n" { blank(c[i]); i += 1 }
                    continue
                }
                if ch == "/", at(i + 1) == "*" {
                    var depth = 0
                    repeat {
                        if c[i] == "/", at(i + 1) == "*" {
                            depth += 1; blank(c[i]); blank(c[i + 1]); i += 2
                        } else if c[i] == "*", at(i + 1) == "/" {
                            depth -= 1; blank(c[i]); blank(c[i + 1]); i += 2
                        } else {
                            blank(c[i]); i += 1
                        }
                    } while depth > 0 && i < n
                    continue
                }
                if ch == "#" || ch == "\"" {
                    var h = 0
                    var j = i
                    while at(j) == "#" { h += 1; j += 1 }
                    if at(j) == "\"" {
                        for _ in 0..<h { out.append(" ") }
                        i = j
                        string(hashes: h)
                        continue
                    }
                }
                if inInterpolation {
                    if ch == "(" {
                        parens += 1
                    } else if ch == ")" {
                        if parens == 0 { return }
                        parens -= 1
                    }
                }
                out.append(ch)
                i += 1
            }
        }

        code(inInterpolation: false)
        return String(out)
    }

    static func isIdentStart(_ s: Unicode.Scalar) -> Bool {
        (s >= "a" && s <= "z") || (s >= "A" && s <= "Z") || s == "_"
    }

    static func isIdentPart(_ s: Unicode.Scalar) -> Bool {
        isIdentStart(s) || (s >= "0" && s <= "9")
    }

    static func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 한 줄의 식별자 토큰
    static func identifiers(in line: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for s in line.unicodeScalars {
            if current.isEmpty {
                if isIdentStart(s) { current.append(s) }
            } else if isIdentPart(s) {
                current.append(s)
            } else {
                result.append(String(current)); current = String.UnicodeScalarView()
                if isIdentStart(s) { current.append(s) }
            }
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    // MARK: 선언

    /// 열 0 에서 시작하는 top-level 선언(`memberIndent` 면 그 들여쓰기 깊이의 멤버 선언).
    /// private/fileprivate 는 파일 밖에서 못 보므로 제외한다. `private(set)` 은 읽기가 보이므로 수식어로 본다.
    static func parseDeclaration(_ line: String, memberIndent: Int = 0) -> (kind: String, name: String)? {
        let c = Array(line.unicodeScalars)
        let n = c.count
        guard n > memberIndent else { return nil }
        for k in 0..<memberIndent where c[k] != " " { return nil }
        let first = c[memberIndent]
        guard isIdentStart(first) || first == "@" else { return nil }
        var i = memberIndent

        func skipSpaces() { while i < n, c[i] == " " || c[i] == "\t" { i += 1 } }
        func ident() -> String {
            var v = String.UnicodeScalarView()
            if i < n, isIdentStart(c[i]) {
                while i < n, isIdentPart(c[i]) { v.append(c[i]); i += 1 }
            }
            return String(v)
        }
        func skipBalancedParens() {
            guard i < n, c[i] == "(" else { return }
            var depth = 0
            while i < n {
                if c[i] == "(" { depth += 1 } else if c[i] == ")" { depth -= 1 }
                i += 1
                if depth == 0 { return }
            }
        }

        while true {
            skipSpaces()
            guard i < n else { return nil }
            if c[i] == "@" {
                i += 1
                _ = ident()
                skipBalancedParens()
                continue
            }
            let word = ident()
            if word.isEmpty { return nil }
            if word == "private" || word == "fileprivate" {
                if i < n, c[i] == "(" {
                    skipBalancedParens()
                    continue
                }
                return nil
            }
            if modifiers.contains(word) {
                skipBalancedParens()
                continue
            }
            if declKeywords.contains(word) {
                skipSpaces()
                let name = ident()
                return name.isEmpty ? nil : (word, name)
            }
            return nil
        }
    }

    /// 열 0 의 `extension X` 머리면 X(앞에 오는 것은 속성·접근 수식어뿐, private/fileprivate 는 제외). 아니면 nil.
    static func extensionTarget(_ line: String) -> String? {
        var words = identifiers(in: line)
        if line.hasPrefix("@"), !words.isEmpty { words.removeFirst() }
        var index = 0
        while index < words.count {
            let w = words[index]
            if w == "extension" { return index + 1 < words.count ? words[index + 1] : nil }
            if !modifiers.contains(w) { return nil }
            index += 1
        }
        return nil
    }

    // MARK: 분석

    static func analyze(_ sources: PackageSources) -> Analysis {
        var analysis = Analysis()
        analysis.packages = sources.keys.sorted()
        var pendingMembers: [(type: String, name: String, package: String)] = []
        for package in analysis.packages {
            for file in sources[package]!.keys.sorted() {
                let lines = splitLines(stripSource(sources[package]![file]!))
                analysis.files.append((package, file, lines))
                var extendedType: String?
                for line in lines {
                    if let d = parseDeclaration(line) {
                        analysis.declarations[d.name, default: []].append(Declaration(kind: d.kind, package: package))
                    }
                    if let f = line.unicodeScalars.first, f != " ", f != "\t" {
                        extendedType = extensionTarget(line)
                    }
                    if let type = extendedType, let m = parseDeclaration(line, memberIndent: 4), m.kind != "typealias" {
                        pendingMembers.append((type, m.name, package))
                    }
                }
            }
        }
        // 같은 패키지 타입의 extension 은 타입 이름으로 이미 간선이 보인다. 다른 패키지(또는 외부) 타입을 확장할 때만 멤버 이름을 본다.
        for m in pendingMembers {
            let typeOwners = Set((analysis.declarations[m.type] ?? []).map(\.package))
            if typeOwners == [m.package] { continue }
            analysis.extensionMembers[m.name, default: []].insert(m.package)
        }
        for entry in analysis.files {
            for (index, line) in entry.lines.enumerated() {
                for name in identifiers(in: line) {
                    var owners = Set((analysis.declarations[name] ?? []).map(\.package))
                    owners.formUnion(analysis.extensionMembers[name] ?? [])
                    if owners.isEmpty { continue }
                    if owners.contains(entry.package) { continue }
                    for owner in owners.sorted() {
                        analysis.edges.append(Edge(file: entry.file, line: index + 1, from: entry.package, to: owner, name: name))
                    }
                }
            }
        }
        return analysis
    }

    /// 파일 쪽 줄 번호를 위해 (줄, 인덱스+1) 로 돌려준다
    static func numbered(_ lines: [String]) -> [(number: Int, text: String)] {
        lines.enumerated().map { ($0.offset + 1, $0.element) }
    }

    // MARK: 규칙

    static func noPackageCycles(_ sources: PackageSources, _ classification: PackageClassification, minEdges: Int = 10) -> [String] {
        let id = "R1_noPackageCycles"
        let a = analyze(sources)
        var violations: [String] = []

        for package in a.packages where classification.kind(of: package) == .unclassified {
            violations.append("\(id): unclassified package \(package) (분류표에 없다)")
        }
        for name in a.declarations.keys.sorted() {
            let owners = Set(a.declarations[name]!.map(\.package))
            if owners.count > 1 {
                violations.append("\(id): ambiguous declaration \(name) in \(owners.sorted().joined(separator: ", "))")
            }
        }

        var graph: [String: Set<String>] = [:]
        for e in a.edges { graph[e.from, default: []].insert(e.to) }
        let edgeCount = graph.values.reduce(0) { $0 + $1.count }
        if edgeCount < minEdges {
            violations.append("\(id): 패키지 간선이 \(edgeCount)개뿐이다(최소 \(minEdges)) — 검사가 비었다")
        }

        func reachable(from start: String) -> Set<String> {
            var seen: Set<String> = []
            var stack = [start]
            while let n = stack.popLast() {
                for m in graph[n] ?? [] where !seen.contains(m) {
                    seen.insert(m); stack.append(m)
                }
            }
            return seen
        }
        var reach: [String: Set<String>] = [:]
        for p in a.packages { reach[p] = reachable(from: p) }

        var assigned: Set<String> = []
        for p in a.packages where !assigned.contains(p) {
            let component = a.packages.filter { reach[p]!.contains($0) && reach[$0]!.contains(p) }
            guard component.count >= 2 else { continue }
            assigned.formUnion(component)
            // 가장 짧은 되돌아오는 경로를 보여 준다
            let start = component[0]
            let members = Set(component)
            var queue: [[String]] = [[start]]
            var visited: Set<String> = [start]
            var found: [String]?
            search: while !queue.isEmpty {
                let path = queue.removeFirst()
                for next in (graph[path.last!] ?? []).sorted() where members.contains(next) {
                    if next == start {
                        found = path + [start]
                        break search
                    }
                    if visited.insert(next).inserted { queue.append(path + [next]) }
                }
            }
            violations.append("\(id): cycle: \((found ?? component + [start]).joined(separator: " -> "))")
        }
        return violations
    }

    static func domainDoesNotUsePlatformTypes(_ sources: PackageSources, _ classification: PackageClassification) -> [String] {
        let id = "R1_domainDoesNotUsePlatformTypes"
        let a = analyze(sources)
        var violations: [String] = []
        let importRegex = try! NSRegularExpression(pattern: #"\bimport\s+CoreBluetooth\b"#)
        for entry in a.files where classification.isInnerLayer(entry.package) {
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                if importRegex.firstMatch(in: line, range: range) != nil {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) -> CoreBluetooth (import CoreBluetooth)")
                }
                for name in identifiers(in: line) where name.hasPrefix("CB") && name.dropFirst(2).first.map({ $0 >= "A" && $0 <= "Z" }) == true {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) -> CoreBluetooth (\(name))")
                }
            }
        }
        for e in a.edges where classification.isInnerLayer(e.from) && classification.kind(of: e.to) == .driver {
            violations.append("\(id): \(e.location) \(e.from) -> \(e.to) (\(e.name))")
        }
        return violations
    }

    static func driverDoesNotUseDomain(_ sources: PackageSources, _ classification: PackageClassification) -> [String] {
        let id = "R1_driverDoesNotUseDomain"
        let allowed: Set<PackageClassification.Kind> = [.driver, .ports, .model]
        return analyze(sources).edges
            .filter { classification.kind(of: $0.from) == .driver && !allowed.contains(classification.kind(of: $0.to)) }
            .map { "\(id): \($0.location) \($0.from) -> \($0.to) (\($0.name))" }
    }

    /// (파일, 줄, 패키지, 타입 이름) — `T(` 또는 `T.init(`
    static func constructions(of types: Set<String>, in files: [(package: String, file: String, lines: [String])]) -> [(file: String, line: Int, package: String, name: String)] {
        var result: [(file: String, line: Int, package: String, name: String)] = []
        let regexes = types.sorted().map { name in
            (name, try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])"# + NSRegularExpression.escapedPattern(for: name) + #"(?:\s*\.\s*init)?\s*\("#))
        }
        for entry in files {
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                for (name, regex) in regexes where regex.firstMatch(in: line, range: range) != nil {
                    result.append((entry.file, number, entry.package, name))
                }
            }
        }
        return result
    }

    static func onlyFactoryConstructsDriver(_ sources: PackageSources, _ classification: PackageClassification) -> [String] {
        let id = "R1_onlyFactoryConstructsDriver"
        let a = analyze(sources)
        var driverTypes: Set<String> = []
        for (name, decls) in a.declarations {
            for d in decls where classification.kind(of: d.package) == .driver && ["class", "struct", "enum", "actor"].contains(d.kind) {
                driverTypes.insert(name)
            }
        }
        var violations: [String] = []
        if driverTypes.isEmpty {
            violations.append("\(id): driver 패키지에 생성 대상 타입이 없다 — 검사가 비었다")
        }
        // Driver 안에서 Driver 를 만드는 것(CB 객체 감싸기)은 허용한다
        let outside = a.files.filter { ![.driver, .factory].contains(classification.kind(of: $0.package)) }
        for c in constructions(of: driverTypes, in: outside) {
            violations.append("\(id): \(c.file):\(c.line) \(c.package) -> Driver (\(c.name))")
        }
        let inFactory = a.files.filter { classification.kind(of: $0.package) == .factory }
        if constructions(of: driverTypes, in: inFactory).isEmpty {
            violations.append("\(id): Factory 에 Driver 생성이 없다")
        }
        return violations
    }

    // MARK: R2 시간을 포트로

    /// 안쪽 층이 쓰면 안 되는 시간 API 식별자(목록에 더하기만 한다)
    static let timeIdentifiers: Set<String> = [
        "ContinuousClock", "SuspendingClock", "Clock", "DispatchTime", "DispatchWallTime", "Date", "Timer",
        "asyncAfter", "makeTimerSource", "CFAbsoluteTimeGetCurrent", "CACurrentMediaTime", "mach_absolute_time",
        "mach_continuous_time", "clock_gettime", "systemUptime", "timeIntervalSinceNow", "timeIntervalSince1970",
        "timeIntervalSinceReferenceDate", "usleep", "nanosleep",
    ]

    /// 한 줄에서 쓴 시간 API 이름들(출현마다 하나)
    static func timeAPIs(in line: String) -> [String] {
        var found = identifiers(in: line).filter { timeIdentifiers.contains($0) }
        let member = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(Task|Thread)\s*\.\s*sleep(?![A-Za-z0-9_])"#)
        let free = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])sleep\s*\("#)
        let range = NSRange(line.startIndex..., in: line)
        for m in member.matches(in: line, range: range) {
            found.append("\(line[Range(m.range(at: 1), in: line)!]).sleep")
        }
        for m in free.matches(in: line, range: range) {
            let prefix = String(line[..<Range(m.range, in: line)!.lowerBound])
            let trimmed = prefix.reversed().drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.first == "." { continue }
            if identifiers(in: prefix).last == "func" { continue }
            found.append("sleep")
        }
        return found
    }

    /// `class|struct|enum|actor|extension X: …clockPort…` 머리의 타입 이름(한 줄 머리만 본다)
    static func clockAdoption(_ line: String, clockPort: String) -> String? {
        let head = try! NSRegularExpression(pattern: #"^(?:@\w+(?:\([^)]*\))?\s+|(?:public|package|internal|final|open|private|fileprivate)\s+)*(?:class|struct|enum|actor|extension)\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*:\s*([^{]*)"#)
        let range = NSRange(line.startIndex..., in: line)
        guard let m = head.firstMatch(in: line, range: range),
              let name = Range(m.range(at: 1), in: line),
              let clause = Range(m.range(at: 2), in: line),
              identifiers(in: String(line[clause])).contains(clockPort) else { return nil }
        return String(line[name])
    }

    static func domainUsesClockPort(_ sources: PackageSources, _ classification: PackageClassification, clockPort: String = "BLEClock") -> [String] {
        let id = "R2_domainUsesClockPort"
        let a = analyze(sources)
        var violations: [String] = []

        // a: 안쪽 층은 시간 API 를 직접 쓰지 않는다
        for entry in a.files where classification.isInnerLayer(entry.package) {
            for (number, line) in numbered(entry.lines) {
                for api in timeAPIs(in: line) {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) uses \(api)")
                }
            }
        }

        // b: 포트가 Ports 에 정확히 한 번 선언된다
        let declared = (a.declarations[clockPort] ?? []).filter { $0.kind == "protocol" && classification.kind(of: $0.package) == .ports }.count
        if declared == 0 {
            violations.append("\(id): no \(clockPort) declaration in ports")
        } else if declared > 1 {
            violations.append("\(id): \(clockPort) declared \(declared) times")
        }

        // c: 포트 구현은 Driver 에만 있고, 하나 이상 있다
        var driverImplementations = 0
        for entry in a.files {
            for (number, line) in numbered(entry.lines) {
                guard let type = clockAdoption(line, clockPort: clockPort) else { continue }
                if classification.kind(of: entry.package) == .driver {
                    driverImplementations += 1
                } else {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) implements \(clockPort) (\(type))")
                }
            }
        }
        if driverImplementations == 0 {
            violations.append("\(id): no \(clockPort) implementation in driver")
        }

        // d: 도메인이 포트를 하나 이상 참조한다
        let referenced = a.files.contains { entry in
            classification.kind(of: entry.package) == .domain && entry.lines.contains { identifiers(in: $0).contains(clockPort) }
        }
        if !referenced {
            violations.append("\(id): domain does not reference \(clockPort)")
        }
        return violations
    }

    // MARK: R3 연결 상태 기계

    /// Core 에서 쓰면 안 되는 async·동시성·입출력 API 식별자(시간 API 는 timeAPIs 가 본다. 목록에 더하기만 한다)
    static let coreForbiddenIdentifiers: Set<String> = [
        "async", "await", "actor", "Task", "TaskGroup", "withTaskGroup", "withThrowingTaskGroup", "withTaskCancellationHandler",
        "withCheckedContinuation", "withCheckedThrowingContinuation", "withUnsafeContinuation", "withUnsafeThrowingContinuation",
        "AsyncStream", "AsyncThrowingStream", "AsyncSequence", "MainActor", "BLECoreActor", "globalActor", "nonisolated", "escaping",
        "DispatchQueue", "DispatchGroup", "DispatchSemaphore", "DispatchWorkItem", "Thread", "NSLock", "NSRecursiveLock", "Mutex",
        "OSAllocatedUnfairLock", "RunLoop", "OperationQueue", "NotificationCenter",
        "print", "debugPrint", "NSLog", "os_log", "Logger", "FileManager", "FileHandle", "URLSession", "UserDefaults", "ProcessInfo", "Bundle",
    ]

    /// domain 이 스스로 정하면 안 되는 연결 상태 토큰(implicit member)
    static let connectionStateMembers = ["discoveringServices", "configuring", "recovering", "disconnecting"]

    /// core 층 전체에 대한 순수성 검사(b~d2). 메시지 id 는 부른 규칙 id.
    static func coreIsPure(id: String, sources: PackageSources, classification: PackageClassification) -> [String] {
        let a = analyze(sources)
        var violations: [String] = []

        // b: Model·Core 밖 내부 패키지를 참조하지 않는다
        for e in a.edges where classification.kind(of: e.from) == .core {
            let k = classification.kind(of: e.to)
            if k != .model && k != .core {
                violations.append("\(id): \(e.location) \(e.from) -> \(e.to) (\(e.name))")
            }
        }

        let importRegex = try! NSRegularExpression(pattern: #"^\s*(?:@\w+\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_]\w*)"#)
        let classRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])class\s+([A-Za-z_]\w*)"#)
        let staticVarRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])static\s+(?:(?:public|package|internal|private|fileprivate|nonisolated|final|@\w+)(?:\([^)]*\))?\s+)*var\s+([A-Za-z_]\w*)"#)
        let globalVarRegex = try! NSRegularExpression(pattern: #"^(?:(?:public|package|internal|private|fileprivate|nonisolated|@\w+)(?:\([^)]*\))?\s+)*var\s+([A-Za-z_]\w*)"#)

        for entry in a.files where classification.kind(of: entry.package) == .core {
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                let at = "\(id): \(entry.file):\(number) \(entry.package)"
                // c: 플랫폼 타입
                if let m = importRegex.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line), line[r] != "Foundation" {
                    violations.append("\(at) imports \(line[r])")
                }
                for name in identifiers(in: line) where name.hasPrefix("CB") && name.dropFirst(2).first.map({ $0 >= "A" && $0 <= "Z" }) == true {
                    violations.append("\(at) -> CoreBluetooth (\(name))")
                }
                // d: async·동시성·입출력·시간
                for name in identifiers(in: line) where coreForbiddenIdentifiers.contains(name) {
                    violations.append("\(at) uses \(name)")
                }
                for api in timeAPIs(in: line) {
                    violations.append("\(at) uses \(api)")
                }
                // d2: 가변 공유 상태
                for m in classRegex.matches(in: line, range: range) {
                    let name = String(line[Range(m.range(at: 1), in: line)!])
                    if ["func", "var", "let"].contains(name) { continue }
                    violations.append("\(at) declares class \(name)")
                }
                for m in staticVarRegex.matches(in: line, range: range) {
                    violations.append("\(at) declares static var \(line[Range(m.range(at: 1), in: line)!])")
                }
                for m in globalVarRegex.matches(in: line, range: range) {
                    violations.append("\(at) declares global var \(line[Range(m.range(at: 1), in: line)!])")
                }
            }
        }
        return violations
    }

    /// a: `coreType` 이 core 층에 정확히 한 번 선언되고 step 이 있다(R3·R4 공용)
    private static func coreDeclared(id: String, coreType: String, analysis a: Analysis, classification: PackageClassification) -> [String] {
        var violations: [String] = []
        let coreFiles = a.files.filter { classification.kind(of: $0.package) == .core }
        if coreFiles.isEmpty {
            violations.append("\(id): no core package")
        }
        var declaringFiles: [[String]] = []
        for entry in coreFiles {
            for line in entry.lines {
                if let d = parseDeclaration(line), d.name == coreType, d.kind == "enum" || d.kind == "struct" {
                    declaringFiles.append(entry.lines)
                }
            }
        }
        if declaringFiles.isEmpty {
            violations.append("\(id): \(coreType) not declared in core")
        } else if declaringFiles.count > 1 {
            violations.append("\(id): \(coreType) declared \(declaringFiles.count) times")
        } else {
            let step = try! NSRegularExpression(pattern: #"\bfunc\s+step\s*[(<]"#)
            let hasStep = declaringFiles[0].contains { step.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            if !hasStep { violations.append("\(id): \(coreType) has no step") }
        }
        return violations
    }

    /// e: domain 파일 하나 이상이 `coreType.step(` 을 부른다(R3·R4 공용)
    private static func domainCallsStep(id: String, coreType: String, analysis a: Analysis, classification: PackageClassification) -> [String] {
        let call = try! NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: coreType) + #"\s*\.\s*step\s*\("#)
        let called = a.files.contains { entry in
            classification.isDomainLike(entry.package)
                && entry.lines.contains { call.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        }
        return called ? [] : ["\(id): domain does not call \(coreType).step"]
    }

    /// 큐 기한 판정 실패 코드 식별자. Core·Model 밖에서 쓰면 위반(f)
    static let queueTimeoutIdentifier = "operationTimeout"
    static let queueTimeoutCodeValue = "OPERATION_TIMEOUT"
    /// 큐 차례 상태를 담는 저장 속성 이름. domain 에서 가변으로 들면 위반(g)
    static let queueStateNames = ["waiting", "current", "inFlight", "nextOperationID", "deadlineToken"]

    static func gattQueueCoreIsPure(_ sources: PackageSources, _ classification: PackageClassification, coreType: String = "GattQueueCore") -> [String] {
        let id = "R4_gattQueueCoreIsPure"
        let a = analyze(sources)
        var violations: [String] = []

        // a: 큐 Core 가 core 층에 정확히 한 번 있고 step 이 있다
        violations += coreDeclared(id: id, coreType: coreType, analysis: a, classification: classification)

        // b~d2
        violations += coreIsPure(id: id, sources: sources, classification: classification)

        // e: domain 이 step 을 부른다
        violations += domainCallsStep(id: id, coreType: coreType, analysis: a, classification: classification)

        // f: 큐 기한 판정은 Core 만 한다 — Model·Core 밖에서 operationTimeout 을 만들거나 분기하지 않는다.
        //    식별자 외에 실패 코드 문자열 "OPERATION_TIMEOUT" 도 센다(공개 init 으로 같은 코드를 만드는 길)
        let timeoutLiteral = "\"" + queueTimeoutCodeValue + "\""
        for entry in a.files {
            let k = classification.kind(of: entry.package)
            if k == .model || k == .core { continue }
            for (number, line) in numbered(entry.lines) {
                for name in identifiers(in: line) where name == queueTimeoutIdentifier {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) decides operation timeout (\(name))")
                }
            }
            let raw = splitLines(sources[entry.package]![entry.file]!)
            for (number, line) in numbered(raw) where line.contains(timeoutLiteral) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                violations.append("\(id): \(entry.file):\(number) \(entry.package) decides operation timeout (\(timeoutLiteral))")
            }
        }

        // g: 큐 차례 상태를 domain 이 저장 속성으로 들지 않는다.
        //    계산 속성(`var x: T { … }`, 초기값 `=` 없음, didSet/willSet 관찰자 아님)만 제외한다
        let held = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])var\s+("# + queueStateNames.joined(separator: "|") + #")(?![A-Za-z0-9_])(.*)$"#)
        let computed = try! NSRegularExpression(pattern: #"^[^={]*\{(?!\s*(?:didSet|willSet)\b)"#)
        for entry in a.files where classification.isDomainLike(entry.package) {
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                for m in held.matches(in: line, range: range) {
                    let rest = String(line[Range(m.range(at: 2), in: line)!])
                    if computed.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil { continue }
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) holds queue state (var \(line[Range(m.range(at: 1), in: line)!]))")
                }
            }
        }
        return violations
    }

    /// 스캔·어댑터 판정 실패 코드 식별자와 코드 문자열. Core·Model 밖에서 쓰면 위반(f)
    static let scanAdapterFailureIdentifiers: Set<String> = ["adapterUnavailable", "bleUnsupported", "permissionDenied", "scanAlreadyRunning", "scanStoppedByAdapter"]
    static let scanAdapterFailureCodes = ["ADAPTER_UNAVAILABLE", "BLE_UNSUPPORTED", "PERMISSION_DENIED", "SCAN_ALREADY_RUNNING", "SCAN_STOPPED_BY_ADAPTER"]
    /// 스캔 수명·어댑터 판정 대기 상태를 담는 저장 속성 이름. domain 에서 가변으로 들면 위반(g)
    static let scanAdapterStateNames = ["userRequest", "internalScans", "nextInternalID", "applied", "adapterIsReady", "restoredPlatformScan",
                                        "deadlineReached", "pendingGates", "nextGateID"]

    static func scanAdapterCoreIsPure(_ sources: PackageSources, _ classification: PackageClassification) -> [String] {
        let id = "R5_scanAdapterCoreIsPure"
        let a = analyze(sources)
        var violations: [String] = []

        // a: 스캔 Core 와 어댑터 Core 가 core 층에 각각 정확히 한 번 있고 step 이 있다(`no core package` 는 한 번만)
        violations += coreDeclared(id: id, coreType: "ScanCore", analysis: a, classification: classification)
        violations += coreDeclared(id: id, coreType: "AdapterCore", analysis: a, classification: classification)
            .filter { $0 != "\(id): no core package" }

        // b~d2
        violations += coreIsPure(id: id, sources: sources, classification: classification)

        // e: domain 이 두 Core 의 step 을 각각 부른다
        violations += domainCallsStep(id: id, coreType: "ScanCore", analysis: a, classification: classification)
        violations += domainCallsStep(id: id, coreType: "AdapterCore", analysis: a, classification: classification)

        // f: 판정표·스캔 수명 실패는 Core 만 만든다 — Model·Core 밖에서 식별자와 코드 문자열 리터럴 금지
        for entry in a.files {
            let k = classification.kind(of: entry.package)
            if k == .model || k == .core { continue }
            for (number, line) in numbered(entry.lines) {
                for name in identifiers(in: line) where scanAdapterFailureIdentifiers.contains(name) {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) decides scan/adapter failure (\(name))")
                }
            }
            let raw = splitLines(sources[entry.package]![entry.file]!)
            for (number, line) in numbered(raw) where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                for code in scanAdapterFailureCodes {
                    let literal = "\"" + code + "\""
                    for _ in 0..<(line.components(separatedBy: literal).count - 1) {
                        violations.append("\(id): \(entry.file):\(number) \(entry.package) decides scan/adapter failure (\(literal))")
                    }
                }
            }
        }

        // g: 스캔 수명·판정 대기 상태를 domain 이 저장 속성으로 들지 않는다.
        //    계산 속성(`var x: T { … }`, 초기값 `=` 없음, didSet/willSet 관찰자 아님)만 제외한다
        let held = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])var\s+("# + scanAdapterStateNames.joined(separator: "|") + #")(?![A-Za-z0-9_])"#)
        let gateArray = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])var\s+(\w+)\s*:\s*\[\s*AdapterGate\s*\]"#)
        let computed = try! NSRegularExpression(pattern: #"^[^={]*\{(?!\s*(?:didSet|willSet)\b)"#)
        //    이름을 바꿔도 잡히도록 타입으로도 본다: (1) 스캔 Core 를 부르는 파일의 저장 속성이 스캔 요청·플랫폼 스캔 타입을 든다
        //    (2) AdapterGate 를 든 컬렉션(Set·배열·사전)은 `[GateID: AdapterGate]` 핸들 저장소만 허용한다(순서·기한은 Core 상태에 있다)
        let scanTyped = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])var\s+(\w+)\s*:[^={]*(?<![A-Za-z0-9_])(?:ScanRequest|PlatformScan|InternalScan)(?![A-Za-z0-9_])"#)
        let gateSet = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])var\s+(\w+)\s*(?::|=)[^{]*(?:Set\s*<\s*AdapterGate\s*>|\[[^\]:]*:\s*AdapterGate\s*\])"#)
        let gateHandleStore = try! NSRegularExpression(pattern: #"\[\s*(?:\w+\s*\.\s*)?GateID\s*:\s*AdapterGate\s*\]"#)
        let scanCall = try! NSRegularExpression(pattern: #"\bScanCore\s*\.\s*step\s*\("#)
        for entry in a.files where classification.isDomainLike(entry.package) {
            let runsScanCore = entry.lines.contains { scanCall.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                var names: [String] = []
                var extra: [(NSRegularExpression, Bool)] = [(gateSet, true)]
                if runsScanCore { extra.append((scanTyped, false)) }
                for (regex, isGate) in extra {
                    for m in regex.matches(in: line, range: range) {
                        if isGate, gateHandleStore.firstMatch(in: line, range: range) != nil { continue }
                        let rest = String(line[Range(m.range, in: line)!.upperBound...])
                        if computed.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil { continue }
                        let name = String(line[Range(m.range(at: 1), in: line)!])
                        if !names.contains(name) { names.append(name) }
                    }
                }
                for regex in [held, gateArray] {
                    for m in regex.matches(in: line, range: range) {
                        let rest = String(line[Range(m.range, in: line)!.upperBound...])
                        if computed.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)) != nil { continue }
                        let name = String(line[Range(m.range(at: 1), in: line)!])
                        if !names.contains(name) { names.append(name) }
                    }
                }
                for name in names {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) holds scan/adapter state (var \(name))")
                }
            }
        }

        // h: 공개 scanState·adapterState 게시(`states.send(`)는 dispatch·perform 안에서만 한다
        let send = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])states\s*\.\s*send\s*\("#)
        let publishers: Set<String> = ["dispatch", "perform"]
        //    dispatch·perform 는 이름만이 아니라 Core step 을 부르는 파일(= Runtime)에 있어야 인정한다
        let adapterCall = try! NSRegularExpression(pattern: #"\bAdapterCore\s*\.\s*step\s*\("#)
        for entry in a.files where classification.isDomainLike(entry.package) {
            let runsCore = entry.lines.contains { l in
                let r = NSRange(l.startIndex..., in: l)
                return scanCall.firstMatch(in: l, range: r) != nil || adapterCall.firstMatch(in: l, range: r) != nil
            }
            for (number, line, openNames) in functionScopes(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                if runsCore, openNames.contains(where: { publishers.contains($0) }) { continue }
                for _ in send.matches(in: line, range: range) {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) publishes scan/adapter state outside dispatch (states.send()")
                }
            }
        }
        return violations
    }

    /// 줄마다 그 줄 끝에서 열려 있는 함수 이름들을 붙인다(R3 g·R5 h 공용).
    /// 본문 여는 중괄호 앞의 쓰기는 이 줄의 바깥 함수에 속한다. 같은 줄의 쓰기는 줄 끝 상태로 본다
    static func functionScopes(_ lines: [String]) -> [(number: Int, text: String, openNames: [String])] {
        let funcName = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])func\s+([A-Za-z_]\w*)"#)
        var depth = 0
        var pending: String?
        var open: [(name: String, depth: Int)] = []
        var result: [(number: Int, text: String, openNames: [String])] = []
        for (number, line) in numbered(lines) {
            let range = NSRange(line.startIndex..., in: line)
            if let m = funcName.firstMatch(in: line, range: range) { pending = String(line[Range(m.range(at: 1), in: line)!]) }
            for ch in line {
                if ch == "{" {
                    depth += 1
                    if let name = pending { open.append((name, depth)); pending = nil }
                } else if ch == "}" {
                    if open.last?.depth == depth { open.removeLast() }
                    depth -= 1
                }
            }
            result.append((number, line, open.map { $0.name }))
        }
        return result
    }

    static func connectionCoreIsPure(_ sources: PackageSources, _ classification: PackageClassification, coreType: String = "ConnectionCore") -> [String] {
        let id = "R3_connectionCoreIsPure"
        let a = analyze(sources)
        var violations: [String] = []

        // a: 연결 Core 가 core 층에 정확히 한 번 있고 step 이 있다
        violations += coreDeclared(id: id, coreType: coreType, analysis: a, classification: classification)

        // b~d2
        violations += coreIsPure(id: id, sources: sources, classification: classification)

        // e: domain 이 step 을 부른다
        violations += domainCallsStep(id: id, coreType: coreType, analysis: a, classification: classification)

        // f: domain 은 연결 상태를 스스로 정하지 않는다
        let members = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_)\]?!>])\.(\#(connectionStateMembers.joined(separator: "|")))(?![A-Za-z0-9_])"#)
        let disconnected = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_)\]?!>])\.disconnected\s*\(\s*reason\s*:"#)
        let qualified = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])ConnectionState\s*\.\s*(discoveringServices|configuring|recovering|disconnecting|ready|connecting|disconnected)(?![A-Za-z0-9_])"#)
        for entry in a.files where classification.isDomainLike(entry.package) {
            for (number, line) in numbered(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                var tokens: [(Int, String)] = []
                for m in members.matches(in: line, range: range) {
                    tokens.append((m.range.location, "." + String(line[Range(m.range(at: 1), in: line)!])))
                }
                for m in disconnected.matches(in: line, range: range) {
                    tokens.append((m.range.location, ".disconnected(reason:)"))
                }
                for m in qualified.matches(in: line, range: range) {
                    tokens.append((m.range.location, "ConnectionState." + String(line[Range(m.range(at: 1), in: line)!])))
                }
                for (_, token) in tokens.sorted(by: { $0.0 < $1.0 }) {
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) decides connection state (\(token))")
                }
            }
        }

        // g: 연결 상태 쓰기(`core` 대입, `state.send(`)는 dispatch·perform 안에서만 한다.
        // `injectPhaseForTesting` 는 시험이 단계를 심는 이름 붙은 입구 하나다. 그 밖의 함수는 위반이다
        let writes = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])(?<!var\s)(?<!let\s)core\s*(?:\.\s*\w+\s*)*(?:=|\+=|-=)(?![=])|(?<![A-Za-z0-9_])state\s*\.\s*send\s*\("#)
        let writers: Set<String> = ["dispatch", "perform", "injectPhaseForTesting"]
        for entry in a.files where classification.isDomainLike(entry.package) {
            for (number, line, openNames) in functionScopes(entry.lines) {
                let range = NSRange(line.startIndex..., in: line)
                let inWriter = openNames.contains { writers.contains($0) }
                let lineWrites = writes.matches(in: line, range: range)
                if !lineWrites.isEmpty, !inWriter {
                    let hit = String(line[Range(lineWrites[0].range, in: line)!]).trimmingCharacters(in: .whitespaces)
                    violations.append("\(id): \(entry.file):\(number) \(entry.package) writes connection state outside dispatch (\(hit))")
                }
            }
        }

        // h: Ports·Model 은 Core 를 모른다(Core → Model 은 허용, 반대 방향은 위반)
        for e in a.edges where classification.kind(of: e.to) == .core {
            let k = classification.kind(of: e.from)
            if k == .ports || k == .model {
                violations.append("\(id): \(e.location) \(e.from) -> \(e.to) (\(e.name))")
            }
        }
        return violations
    }
}

final class ArchitectureRulesTests: XCTestCase {
    /// 시험 파일 위치에서 ../../Sources/NucodeBleCore 를 찾아 모든 .swift 를 읽는다
    private func loadSources() throws -> PackageSources {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Sources/NucodeBleCore")
            .standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            XCTFail("소스 디렉터리를 열 수 없다: \(root.path)")
            return [:]
        }
        var sources: PackageSources = [:]
        for case let url as URL in walker where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            let relative = String(path.dropFirst(rootPath.count))
            let parts = relative.split(separator: "/").map(String.init)
            let package = parts.count > 1 ? parts[0] : "(root)"
            sources[package, default: [:]][relative] = try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertFalse(sources.isEmpty, "소스 파일이 0개다 — 검사가 비었다: \(root.path)")
        return sources
    }

    private func report(_ violations: [String]) {
        for v in violations { XCTFail(v) }
    }

    func test_R1_noPackageCycles() throws {
        report(RuleScanner.noPackageCycles(try loadSources(), .project))
    }

    func test_R1_domainDoesNotUsePlatformTypes() throws {
        report(RuleScanner.domainDoesNotUsePlatformTypes(try loadSources(), .project))
    }

    func test_R1_driverDoesNotUseDomain() throws {
        report(RuleScanner.driverDoesNotUseDomain(try loadSources(), .project))
    }

    func test_R1_onlyFactoryConstructsDriver() throws {
        report(RuleScanner.onlyFactoryConstructsDriver(try loadSources(), .project))
    }

    func test_R2_domainUsesClockPort() throws {
        report(RuleScanner.domainUsesClockPort(try loadSources(), .project))
    }

    func test_R3_connectionCoreIsPure() throws {
        report(RuleScanner.connectionCoreIsPure(try loadSources(), .project))
    }

    func test_R4_gattQueueCoreIsPure() throws {
        report(RuleScanner.gattQueueCoreIsPure(try loadSources(), .project))
    }

    func test_R5_scanAdapterCoreIsPure() throws {
        report(RuleScanner.scanAdapterCoreIsPure(try loadSources(), .project))
    }

    // MARK: 자기 점검 — 같은 규칙 함수를 합성 소스에 부른다(이름에 규칙 id 를 넣지 않는다)

    func test_clockRuleScannerSelfCheck() {
        let c = PackageClassification(model: ["M"], ports: ["P"], driver: ["D"], factory: ["F"], domain: ["Dom"])
        let port = "protocol BLEClock {}"
        let impl = "struct RealClock: BLEClock {}"
        let use = "func f(_ c: any BLEClock) { try await c.sleep(milliseconds: 5) }"

        func check(model: String = "struct ModelThing {}", ports: String = port, driver: String = impl,
                   factory: String = "struct FactoryThing {}", dom: String = use) -> [String] {
            RuleScanner.domainUsesClockPort([
                "M": ["M/X.swift": model],
                "P": ["P/X.swift": ports],
                "D": ["D/X.swift": driver],
                "F": ["F/X.swift": factory],
                "Dom": ["Dom/X.swift": dom],
            ], c)
        }

        XCTAssertEqual(check(), [])

        // a: 안쪽 층의 시간 API
        let domainViolations = [
            "let t = ContinuousClock.now",
            "try await Task.sleep(for: .seconds(1))",
            "try await Task . sleep(nanoseconds: 1)",
            "DispatchQueue.main.asyncAfter(deadline: .now() + 1) {}",
            "let d = Date()",
            "sleep(1)",
            "Thread.sleep(forTimeInterval: 1)",
        ]
        for body in domainViolations {
            XCTAssertEqual(check(dom: use + "\n" + body).count, 1, body)
        }
        XCTAssertEqual(check(dom: use + "\n" + "sleep(1)").first, "R2_domainUsesClockPort: Dom/X.swift:2 Dom uses sleep")
        XCTAssertEqual(check(dom: use + "\nlet t = ContinuousClock.now").first, "R2_domainUsesClockPort: Dom/X.swift:2 Dom uses ContinuousClock")
        XCTAssertEqual(check(dom: use + "\nlet t = (ContinuousClock.now, Date())").count, 2)
        XCTAssertEqual(check(ports: port + "\nlet t = ContinuousClock.now").count, 1)
        XCTAssertEqual(check(model: "let t = ContinuousClock.now").count, 1)
        let allowed = [
            "// Task.sleep",
            "let s = \"ContinuousClock\"",
            "func cancelTimers() {}",
            "func sleep(milliseconds: Int) async throws",
            "try await clock.sleep(milliseconds: 1)",
        ]
        for body in allowed {
            XCTAssertEqual(check(dom: use + "\n" + body), [], body)
        }
        XCTAssertEqual(check(driver: impl + "\nlet t = ContinuousClock.now\nfunc g() async throws { try await Task.sleep(for: .seconds(1)) }"), [])
        XCTAssertEqual(check(factory: "let t = ContinuousClock.now\nfunc g() async throws { try await Task.sleep(for: .seconds(1)) }"), [])

        // b: 선언은 Ports 에 정확히 한 번
        XCTAssertEqual(check(ports: "struct Other {}"), ["R2_domainUsesClockPort: no BLEClock declaration in ports"])
        XCTAssertEqual(check(ports: port + "\n" + "protocol BLEClock {}"), ["R2_domainUsesClockPort: BLEClock declared 2 times"])

        // c: 구현은 Driver 에만, 하나 이상
        XCTAssertEqual(check(ports: port + "\nstruct PortClock: BLEClock {}"), ["R2_domainUsesClockPort: P/X.swift:2 P implements BLEClock (PortClock)"])
        XCTAssertEqual(check(dom: use + "\nextension Foo: Sendable, BLEClock {}"), ["R2_domainUsesClockPort: Dom/X.swift:2 Dom implements BLEClock (Foo)"])
        XCTAssertEqual(check(driver: "struct Other {}"), ["R2_domainUsesClockPort: no BLEClock implementation in driver"])
        XCTAssertEqual(check(dom: use + "\nlet c: BLEClock"), [])
        XCTAssertEqual(check(dom: use + "\nfunc h(_ c: any BLEClock) {}"), [])
        XCTAssertEqual(check(driver: impl + "\nfinal class Other: NSObject, BLEClock {}"), [])

        // d: 도메인이 포트를 참조한다
        XCTAssertEqual(check(dom: "struct X {}"), ["R2_domainUsesClockPort: domain does not reference BLEClock"])
    }

    func test_coreRuleScannerSelfCheck() {
        let c = PackageClassification(model: ["M"], ports: ["P"], driver: ["D"], factory: ["F"], domain: ["Dom"], core: ["C"])
        let id = "R3_connectionCoreIsPure"
        let baseCore = "enum ConnectionCore {\n    static func step(_ s: ModelThing, _ e: Int) -> ModelThing { s }\n}"
        let baseDom = "struct DomThing {}\nfunc run() { _ = ConnectionCore.step(ModelThing(), 1) }"

        /// coreFiles 가 비면 C 패키지를 뺀다. extra 는 C/X.swift 로 더한다.
        func check(coreFiles: [String: String] = ["C/ConnectionCore.swift": baseCore], extra: String? = nil, dom: String = baseDom,
                   model: String = "struct ModelThing {}", ports: String = "struct PortThing {}", driver: String = "struct DriverThing {}",
                   factory: String = "struct FactoryThing {}") -> [String] {
            var sources: PackageSources = [
                "M": ["M/X.swift": model],
                "P": ["P/X.swift": ports],
                "D": ["D/X.swift": driver],
                "F": ["F/X.swift": factory],
                "Dom": ["Dom/X.swift": dom],
            ]
            var files = coreFiles
            if let extra { files["C/X.swift"] = extra }
            if !files.isEmpty { sources["C"] = files }
            return RuleScanner.connectionCoreIsPure(sources, c)
        }
        func core(_ body: String) -> [String] { check(extra: body) }

        XCTAssertEqual(check(), [])

        // a: core 층에 ConnectionCore 가 정확히 한 번, step 과 함께
        XCTAssertEqual(check(coreFiles: [:]), ["\(id): no core package", "\(id): ConnectionCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "struct Other {}"]), ["\(id): ConnectionCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": baseCore, "C/B.swift": "struct ConnectionCore {\n    func step() {}\n}"]), ["\(id): ConnectionCore declared 2 times"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "enum ConnectionCore {}"]), ["\(id): ConnectionCore has no step"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "enum ConnectionCore {\n    static func step<T>(_ s: T) -> T { s }\n}"]), [])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "enum ConnectionCore {\n    static func stepper() {}\n}"]), ["\(id): ConnectionCore has no step"])
        // 다른 층에 선언된 ConnectionCore 는 core 선언이 아니다
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "struct Other {}"], driver: "enum ConnectionCore {\n    static func step() {}\n}"), ["\(id): ConnectionCore not declared in core"])

        // b: Model·Core 밖 내부 패키지 참조
        XCTAssertEqual(core("func f(_ p: PortThing) {}"), ["\(id): C/X.swift:1 C -> P (PortThing)"])
        XCTAssertEqual(core("func f(_ p: DomThing) {}"), ["\(id): C/X.swift:1 C -> Dom (DomThing)"])
        XCTAssertEqual(core("func f(_ p: DriverThing) {}"), ["\(id): C/X.swift:1 C -> D (DriverThing)"])
        XCTAssertEqual(core("func f(_ p: ModelThing) {}"), [])

        // c: 플랫폼 타입
        XCTAssertEqual(core("import CoreBluetooth"), ["\(id): C/X.swift:1 C imports CoreBluetooth"])
        XCTAssertEqual(core("import Combine"), ["\(id): C/X.swift:1 C imports Combine"])
        XCTAssertEqual(core("import Foundation"), [])
        XCTAssertEqual(core("let m: CBPeripheral? = nil"), ["\(id): C/X.swift:1 C -> CoreBluetooth (CBPeripheral)"])

        // d: async·동시성·입출력·시간
        XCTAssertEqual(core("func f() async {}"), ["\(id): C/X.swift:1 C uses async"])
        XCTAssertEqual(core("let t = Task { }"), ["\(id): C/X.swift:1 C uses Task"])
        XCTAssertEqual(core("@BLECoreActor func f() {}"), ["\(id): C/X.swift:1 C uses BLECoreActor"])
        XCTAssertEqual(core("print(1)"), ["\(id): C/X.swift:1 C uses print"])
        XCTAssertEqual(core("func f(_ c: @escaping () -> Void) {}"), ["\(id): C/X.swift:1 C uses escaping"])
        XCTAssertEqual(core("let d = Date()"), ["\(id): C/X.swift:1 C uses Date"])
        XCTAssertEqual(core("DispatchQueue.main.async {}"), ["\(id): C/X.swift:1 C uses DispatchQueue", "\(id): C/X.swift:1 C uses async"])
        for body in ["// await Task", "let s = \"async\"", "let asyncCount = 1", "case task"] {
            XCTAssertEqual(core(body), [], body)
        }
        for body in ["func f() async {}", "let t = Task { }", "print(1)", "let d = Date()", "import CoreBluetooth"] {
            XCTAssertEqual(check(driver: "struct DriverThing {}\n" + body), [], body)
            XCTAssertEqual(check(factory: "struct FactoryThing {}\n" + body), [], body)
        }

        // d2: 가변 공유 상태
        XCTAssertEqual(core("final class Box {}"), ["\(id): C/X.swift:1 C declares class Box"])
        XCTAssertEqual(core("    static var counter = 0"), ["\(id): C/X.swift:1 C declares static var counter"])
        XCTAssertEqual(core("var x = 0"), ["\(id): C/X.swift:1 C declares global var x"])
        XCTAssertEqual(core("private(set) var x = 0"), ["\(id): C/X.swift:1 C declares global var x"])
        XCTAssertEqual(core("fileprivate var x = 0"), ["\(id): C/X.swift:1 C declares global var x"])
        XCTAssertEqual(core("nonisolated(unsafe) var x = 0"), ["\(id): C/X.swift:1 C uses nonisolated", "\(id): C/X.swift:1 C declares global var x"])
        XCTAssertEqual(core("    static private(set) var counter = 0"), ["\(id): C/X.swift:1 C declares static var counter"])
        XCTAssertEqual(core("    static fileprivate var counter = 0"), ["\(id): C/X.swift:1 C declares static var counter"])
        XCTAssertEqual(core("    private static var counter = 0"), ["\(id): C/X.swift:1 C declares static var counter"])
        for body in ["static let x = 0", "struct S {\n    var phase: Int\n}", "let klass = 1", "class func make() {}"] {
            XCTAssertEqual(core(body), [], body)
        }

        // e: domain 이 ConnectionCore.step 을 부른다
        let noCall = ["\(id): domain does not call ConnectionCore.step"]
        XCTAssertEqual(check(dom: "struct DomThing {}"), noCall)
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = ConnectionCore . step (ModelThing(), 1) }"), [])
        XCTAssertEqual(check(dom: "struct DomThing {}", driver: "struct DriverThing {}\nfunc go() { _ = ConnectionCore.step(ModelThing(), 1) }"), noCall)
        XCTAssertEqual(check(dom: "struct DomThing {}", factory: "struct FactoryThing {}\nfunc go() { _ = ConnectionCore.step(ModelThing(), 1) }"), noCall)

        // f: domain 은 연결 상태를 스스로 정하지 않는다
        func domain(_ body: String) -> [String] { check(dom: baseDom + "\n" + body) }
        let at = "\(id): Dom/X.swift:3 Dom decides connection state"
        XCTAssertEqual(domain("publish(.configuring)"), ["\(at) (.configuring)"])
        XCTAssertEqual(domain("case .discoveringServices: break"), ["\(at) (.discoveringServices)"])
        XCTAssertEqual(domain("if case .recovering = s {}"), ["\(at) (.recovering)"])
        XCTAssertEqual(domain("case .disconnecting: break"), ["\(at) (.disconnecting)"])
        XCTAssertEqual(domain("send(.disconnected(reason: .requested))"), ["\(at) (.disconnected(reason:))"])
        XCTAssertEqual(domain("send(.disconnected( reason : .requested))"), ["\(at) (.disconnected(reason:))"])
        let negatives = [
            "let b = x == PortPeripheralState.disconnecting", "let b = a.configuring", "let b = f()?.recovering", "case .disconnected: break",
            "let b = s == .ready", "let b = s == .connecting", "// .configuring", "let lit = \".recovering\"",
        ]
        for body in negatives {
            XCTAssertEqual(domain(body), [], body)
        }
        // 타입을 적은 형태도 같은 뜻이다
        XCTAssertEqual(domain("publish(ConnectionState.configuring)"), ["\(at) (ConnectionState.configuring)"])
        XCTAssertEqual(domain("send(ConnectionState . disconnected(reason: .requested))"), ["\(at) (ConnectionState.disconnected)"])
        XCTAssertEqual(domain("if s == ConnectionState.ready {}"), ["\(at) (ConnectionState.ready)"])
        XCTAssertEqual(domain("let b = MyConnectionState.configuring"), [])

        // g: 연결 상태 쓰기는 dispatch·perform 안에서만
        let wat = "\(id): Dom/X.swift:3 Dom writes connection state outside dispatch"
        XCTAssertEqual(domain("func x() { core.phase = .ready }"), ["\(wat) (core.phase =)"])
        XCTAssertEqual(domain("func x() { state.send(p) }"), ["\(wat) (state.send()"])
        XCTAssertEqual(domain("func x() {\n    core = next\n}").count, 1)
        XCTAssertEqual(domain("func dispatch() {\n    core = next\n    state.send(p)\n}"), [])
        XCTAssertEqual(domain("func perform() {\n    switch e {\n    case .a:\n        state.send(p)\n    }\n}"), [])
        XCTAssertEqual(domain("func injectPhaseForTesting() {\n    core.phase = p\n}"), [])
        XCTAssertEqual(domain("func dispatch() {}\nfunc y() {\n    core.live = nil\n}").count, 1)
        XCTAssertEqual(domain("func y() { let c = core; _ = core.phase; if core.live == 1 {} }"), [])
        // 다른 층은 이 규칙 밖이다
        XCTAssertEqual(check(driver: "struct DriverThing {}\nfunc x() { core.phase = p; state.send(p) }"), [])

        // h: Ports·Model 은 Core 를 모른다. Core → Model 은 허용
        let refCore = "func f(_ c: ConnectionCore) {}"
        XCTAssertEqual(check(ports: "struct PortThing {}\n" + refCore), ["\(id): P/X.swift:2 P -> C (ConnectionCore)"])
        XCTAssertEqual(check(model: "struct ModelThing {}\n" + refCore), ["\(id): M/X.swift:2 M -> C (ConnectionCore)"])

        let positives = ["publish(.configuring)", "case .discoveringServices: break", "send(.disconnected(reason: .requested))"]
        for body in positives {
            XCTAssertEqual(core(body), [], body)
            XCTAssertEqual(check(model: "struct ModelThing {}\n" + body), [], body)
            XCTAssertEqual(check(driver: "struct DriverThing {}\n" + body), [], body)
        }
    }

    func test_gattQueueRuleScannerSelfCheck() {
        let c = PackageClassification(model: ["M"], ports: ["P"], driver: ["D"], factory: ["F"], domain: ["Dom"], core: ["C"])
        let id = "R4_gattQueueCoreIsPure"
        let baseCore = "enum GattQueueCore {\n    static func step(_ s: ModelThing, _ e: Int) -> ModelThing { s }\n}"
        let baseDom = "struct DomThing {}\nfunc run() { _ = GattQueueCore.step(ModelThing(), 1) }"

        /// coreFiles 가 비면 C 패키지를 뺀다. extra 는 C/X.swift 로 더한다.
        func check(coreFiles: [String: String] = ["C/GattQueueCore.swift": baseCore], extra: String? = nil, dom: String = baseDom,
                   model: String = "struct ModelThing {}", ports: String = "struct PortThing {}", driver: String = "struct DriverThing {}",
                   factory: String = "struct FactoryThing {}") -> [String] {
            var sources: PackageSources = [
                "M": ["M/X.swift": model],
                "P": ["P/X.swift": ports],
                "D": ["D/X.swift": driver],
                "F": ["F/X.swift": factory],
                "Dom": ["Dom/X.swift": dom],
            ]
            var files = coreFiles
            if let extra { files["C/X.swift"] = extra }
            if !files.isEmpty { sources["C"] = files }
            return RuleScanner.gattQueueCoreIsPure(sources, c)
        }
        func core(_ body: String) -> [String] { check(extra: body) }

        XCTAssertEqual(check(), [])

        // a: core 층에 GattQueueCore 가 정확히 한 번, step 과 함께
        XCTAssertEqual(check(coreFiles: [:]), ["\(id): no core package", "\(id): GattQueueCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "struct Other {}"]), ["\(id): GattQueueCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": baseCore, "C/B.swift": "struct GattQueueCore {\n    func step() {}\n}"]), ["\(id): GattQueueCore declared 2 times"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "enum GattQueueCore {}"]), ["\(id): GattQueueCore has no step"])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "enum GattQueueCore {\n    static func step<T>(_ s: T) -> T { s }\n}"]), [])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "struct Other {}"], driver: "enum GattQueueCore {\n    static func step() {}\n}"), ["\(id): GattQueueCore not declared in core"])

        // b~d2: 공유 순수성 검사가 R4 id 로 불린다
        XCTAssertEqual(core("import CoreBluetooth"), ["\(id): C/X.swift:1 C imports CoreBluetooth"])
        XCTAssertEqual(core("func f() async {}"), ["\(id): C/X.swift:1 C uses async"])
        XCTAssertEqual(core("final class Box {}"), ["\(id): C/X.swift:1 C declares class Box"])
        XCTAssertEqual(core("func f(_ p: PortThing) {}"), ["\(id): C/X.swift:1 C -> P (PortThing)"])
        XCTAssertEqual(core("func f(_ p: ModelThing) {}"), [])

        // e: domain 이 GattQueueCore.step 을 부른다(ConnectionCore.step 은 세지 않는다)
        let noCall = ["\(id): domain does not call GattQueueCore.step"]
        XCTAssertEqual(check(dom: "struct DomThing {}"), noCall)
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = GattQueueCore . step (ModelThing(), 1) }"), [])
        XCTAssertEqual(check(dom: "struct DomThing {}", driver: "struct DriverThing {}\nfunc go() { _ = GattQueueCore.step(ModelThing(), 1) }"), noCall)
        XCTAssertEqual(check(dom: "struct DomThing {}", factory: "struct FactoryThing {}\nfunc go() { _ = GattQueueCore.step(ModelThing(), 1) }"), noCall)
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = ConnectionCore.step(ModelThing(), 1) }"), noCall)

        // f: Core·Model 밖에서 operationTimeout 식별자 금지
        let timeoutAt = { (file: String, pkg: String) in ["\(id): \(file):3 \(pkg) decides operation timeout (operationTimeout)"] }
        func domain(_ body: String) -> [String] { check(dom: baseDom + "\n" + body) }
        XCTAssertEqual(domain("let c = FailureCode.operationTimeout"), timeoutAt("Dom/X.swift", "Dom"))
        XCTAssertEqual(domain("f(code: .operationTimeout)"), timeoutAt("Dom/X.swift", "Dom"))
        let timeoutLine = "struct Local {}\nlet c = FailureCode.operationTimeout"
        XCTAssertEqual(check(driver: timeoutLine).count, 1)
        XCTAssertEqual(check(factory: timeoutLine).count, 1)
        XCTAssertEqual(check(ports: timeoutLine).count, 1)
        XCTAssertEqual(check(driver: timeoutLine), ["\(id): D/X.swift:2 D decides operation timeout (operationTimeout)"])
        XCTAssertEqual(check(model: timeoutLine), [])
        XCTAssertEqual(core("let c = FailureCode.operationTimeout"), [])
        for body in ["// operationTimeout", "let lit = \"operationTimeout\"", "let operationTimeoutMillis = 1", "// \"OPERATION_TIMEOUT\"", "let lit = \"OPERATION_TIMEOUT_X\""] {
            XCTAssertEqual(domain(body), [], body)
        }
        // 실패 코드 문자열 리터럴로 만드는 길도 막는다(Model·Core 는 제외)
        let literalAt = { (file: String, pkg: String) in ["\(id): \(file):3 \(pkg) decides operation timeout (\"OPERATION_TIMEOUT\")"] }
        XCTAssertEqual(domain("let c = FailureCode(value: \"OPERATION_TIMEOUT\", category: .operation)"), literalAt("Dom/X.swift", "Dom"))
        XCTAssertEqual(check(driver: "struct DriverThing {}\nlet c = X(\"OPERATION_TIMEOUT\")"), ["\(id): D/X.swift:2 D decides operation timeout (\"OPERATION_TIMEOUT\")"])
        XCTAssertEqual(check(model: "struct ModelThing {}\nlet c = X(\"OPERATION_TIMEOUT\")"), [])
        XCTAssertEqual(core("let c = X(\"OPERATION_TIMEOUT\")"), [])

        // g: domain 이 큐 차례 상태를 저장 속성으로 들지 않는다
        let held = { (name: String) in ["\(id): Dom/X.swift:3 Dom holds queue state (var \(name))"] }
        XCTAssertEqual(domain("private var waiting: [Int] = []"), held("waiting"))
        XCTAssertEqual(domain("var current: Int?"), held("current"))
        XCTAssertEqual(domain("var inFlight = 0"), held("inFlight"))
        XCTAssertEqual(domain("var nextOperationID: UInt64 = 0"), held("nextOperationID"))
        XCTAssertEqual(domain("var deadlineToken = 0"), held("deadlineToken"))
        // 관찰자가 붙은 저장 속성과 클로저로 초기화한 저장 속성도 저장 속성이다
        XCTAssertEqual(domain("private var current: Int? { didSet { log() } }"), held("current"))
        XCTAssertEqual(domain("var waiting: Int { willSet { log() } }"), held("waiting"))
        XCTAssertEqual(domain("private var waiting: [Int] = { [] }()"), held("waiting"))
        for body in ["var current: Int { 0 }", "var current: Int { get { 0 } }", "let waiting = 1", "var waitingCount = 0", "// var waiting = 1"] {
            XCTAssertEqual(domain(body), [], body)
        }
        // domain 밖(Core 안 멤버·Driver)은 g 밖이다
        for body in ["var waiting: [Int] = []", "var current: Int?", "var inFlight = 0", "var nextOperationID: UInt64 = 0", "var deadlineToken = 0"] {
            XCTAssertEqual(core("struct S {\n    " + body + "\n}"), [], body)
            XCTAssertEqual(check(driver: "struct DriverThing {\n    " + body + "\n}"), [], body)
        }
    }

    func test_scanAdapterRuleScannerSelfCheck() {
        let c = PackageClassification(model: ["M"], ports: ["P"], driver: ["D"], factory: ["F"], domain: ["Dom"], core: ["C"])
        let id = "R5_scanAdapterCoreIsPure"
        let scanCore = "enum ScanCore {\n    static func step(_ s: ModelThing, _ e: Int) -> ModelThing { s }\n}"
        let adapterCore = "enum AdapterCore {\n    static func step(_ s: ModelThing, _ e: Int) -> ModelThing { s }\n}"
        let baseCoreFiles = ["C/ScanCore.swift": scanCore, "C/AdapterCore.swift": adapterCore]
        let baseDom = "struct DomThing {}\nfunc run() { _ = ScanCore.step(ModelThing(), 1); _ = AdapterCore.step(ModelThing(), 1) }"

        /// coreFiles 가 비면 C 패키지를 뺀다. extra 는 C/X.swift 로 더한다.
        func check(coreFiles: [String: String] = baseCoreFiles, extra: String? = nil, dom: String = baseDom,
                   model: String = "struct ModelThing {}", ports: String = "struct PortThing {}", driver: String = "struct DriverThing {}",
                   factory: String = "struct FactoryThing {}") -> [String] {
            var sources: PackageSources = [
                "M": ["M/X.swift": model],
                "P": ["P/X.swift": ports],
                "D": ["D/X.swift": driver],
                "F": ["F/X.swift": factory],
                "Dom": ["Dom/X.swift": dom],
            ]
            var files = coreFiles
            if let extra { files["C/X.swift"] = extra }
            if !files.isEmpty { sources["C"] = files }
            return RuleScanner.scanAdapterCoreIsPure(sources, c)
        }
        func core(_ body: String) -> [String] { check(extra: body) }
        func domain(_ body: String) -> [String] { check(dom: baseDom + "\n" + body) }

        XCTAssertEqual(check(), [])

        // a: 두 Core 가 core 층에 각각 정확히 한 번, step 과 함께. no core package 는 한 번만
        XCTAssertEqual(check(coreFiles: [:]), ["\(id): no core package", "\(id): ScanCore not declared in core", "\(id): AdapterCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/ScanCore.swift": scanCore]), ["\(id): AdapterCore not declared in core"])
        XCTAssertEqual(check(coreFiles: ["C/AdapterCore.swift": adapterCore]), ["\(id): ScanCore not declared in core"])
        XCTAssertEqual(check(coreFiles: baseCoreFiles.merging(["C/B.swift": "struct ScanCore {\n    func step() {}\n}"]) { $1 }), ["\(id): ScanCore declared 2 times"])
        XCTAssertEqual(check(coreFiles: ["C/ScanCore.swift": scanCore, "C/AdapterCore.swift": "enum AdapterCore {}"]), ["\(id): AdapterCore has no step"])
        XCTAssertEqual(check(coreFiles: ["C/ScanCore.swift": "enum ScanCore {\n    static func step<T>(_ s: T) -> T { s }\n}", "C/AdapterCore.swift": adapterCore]), [])
        XCTAssertEqual(check(coreFiles: ["C/A.swift": "struct Other {}"], driver: "enum ScanCore {\n    static func step() {}\n}"),
                       ["\(id): ScanCore not declared in core", "\(id): AdapterCore not declared in core"])

        // b~d2: 공유 순수성 검사가 R5 id 로 불린다
        XCTAssertEqual(core("import CoreBluetooth"), ["\(id): C/X.swift:1 C imports CoreBluetooth"])
        XCTAssertEqual(core("func f() async {}"), ["\(id): C/X.swift:1 C uses async"])
        XCTAssertEqual(core("final class Box {}"), ["\(id): C/X.swift:1 C declares class Box"])
        XCTAssertEqual(core("func f(_ p: PortThing) {}"), ["\(id): C/X.swift:1 C -> P (PortThing)"])
        XCTAssertEqual(core("func f(_ p: ModelThing) {}"), [])

        // e: domain 이 ScanCore.step·AdapterCore.step 을 각각 부른다(다른 Core 의 step 은 세지 않는다)
        let noScan = "\(id): domain does not call ScanCore.step"
        let noAdapter = "\(id): domain does not call AdapterCore.step"
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = AdapterCore.step(ModelThing(), 1) }"), [noScan])
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = ScanCore.step(ModelThing(), 1) }"), [noAdapter])
        XCTAssertEqual(check(dom: "struct DomThing {}"), [noScan, noAdapter])
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = ScanCore . step (ModelThing(), 1); _ = AdapterCore . step (ModelThing(), 1) }"), [])
        let calls = "\nfunc go() { _ = ScanCore.step(ModelThing(), 1); _ = AdapterCore.step(ModelThing(), 1) }"
        XCTAssertEqual(check(dom: "struct DomThing {}", driver: "struct DriverThing {}" + calls), [noScan, noAdapter])
        XCTAssertEqual(check(dom: "struct DomThing {}", factory: "struct FactoryThing {}" + calls), [noScan, noAdapter])
        XCTAssertEqual(check(dom: "struct DomThing {}\nfunc run() { _ = GattQueueCore.step(ModelThing(), 1); _ = ConnectionCore.step(ModelThing(), 1) }"), [noScan, noAdapter])

        // f: Core·Model 밖에서 판정표·스캔 수명 실패 식별자와 코드 문자열 금지
        let failAt = { (file: String, pkg: String, line: Int, what: String) in ["\(id): \(file):\(line) \(pkg) decides scan/adapter failure (\(what))"] }
        XCTAssertEqual(domain("let c = FailureCode.scanAlreadyRunning"), failAt("Dom/X.swift", "Dom", 3, "scanAlreadyRunning"))
        for name in ["adapterUnavailable", "bleUnsupported", "permissionDenied", "scanAlreadyRunning", "scanStoppedByAdapter"] {
            XCTAssertEqual(domain("let c = FailureCode.\(name)"), failAt("Dom/X.swift", "Dom", 3, name), name)
        }
        XCTAssertEqual(domain("f(code: .adapterUnavailable)"), failAt("Dom/X.swift", "Dom", 3, "adapterUnavailable"))
        XCTAssertEqual(domain("let c = FailureCode(value: \"SCAN_STOPPED_BY_ADAPTER\", category: .scan)"),
                       failAt("Dom/X.swift", "Dom", 3, "\"SCAN_STOPPED_BY_ADAPTER\""))
        for code in ["ADAPTER_UNAVAILABLE", "BLE_UNSUPPORTED", "PERMISSION_DENIED", "SCAN_ALREADY_RUNNING", "SCAN_STOPPED_BY_ADAPTER"] {
            XCTAssertEqual(domain("let c = X(\"\(code)\")").count, 1, code)
        }
        let failLine = "struct Local {}\nlet c = FailureCode.adapterUnavailable"
        XCTAssertEqual(check(driver: failLine), failAt("D/X.swift", "D", 2, "adapterUnavailable"))
        XCTAssertEqual(check(factory: failLine), failAt("F/X.swift", "F", 2, "adapterUnavailable"))
        XCTAssertEqual(check(ports: failLine), failAt("P/X.swift", "P", 2, "adapterUnavailable"))
        XCTAssertEqual(check(model: failLine), [])
        XCTAssertEqual(core("let c = FailureCode.adapterUnavailable"), [])
        XCTAssertEqual(check(driver: "struct DriverThing {}\nlet c = X(\"BLE_UNSUPPORTED\")"), failAt("D/X.swift", "D", 2, "\"BLE_UNSUPPORTED\""))
        XCTAssertEqual(check(model: "struct ModelThing {}\nlet c = X(\"BLE_UNSUPPORTED\")"), [])
        XCTAssertEqual(core("let c = X(\"BLE_UNSUPPORTED\")"), [])
        for body in ["// adapterUnavailable", "let lit = \"adapterUnavailable\"", "let adapterUnavailableCount = 1", "// \"SCAN_ALREADY_RUNNING\"",
                     "let lit = \"BLE_UNSUPPORTED_X\"", "let c = FailureCode.operationTimeout"] {
            XCTAssertEqual(domain(body), [], body)
        }

        // g: domain 이 스캔 수명·판정 대기 상태를 저장 속성으로 들지 않는다
        let held = { (name: String) in ["\(id): Dom/X.swift:3 Dom holds scan/adapter state (var \(name))"] }
        XCTAssertEqual(domain("private var userRequest: Int? = nil"), held("userRequest"))
        for name in RuleScanner.scanAdapterStateNames {
            XCTAssertEqual(domain("var \(name) = 0"), held(name), name)
        }
        XCTAssertEqual(domain("private var pending: [AdapterGate] = []"), held("pending"))
        XCTAssertEqual(domain("var gates: [AdapterGate]"), held("gates"))
        XCTAssertEqual(domain("private var applied: Int? { didSet { log() } }"), held("applied"))
        XCTAssertEqual(domain("var pendingGates: [AdapterGate] = []"), held("pendingGates"))
        // 이름을 바꾼 우회: 게이트 컬렉션(Set·사전)과, 스캔 Core 를 부르는 파일의 스캔 요청·플랫폼 스캔 저장 속성
        XCTAssertEqual(domain("var waitingGates: Set<AdapterGate> = []"), held("waitingGates"))
        XCTAssertEqual(domain("var gates: [UInt64: AdapterGate] = [:]"), held("gates"))
        XCTAssertEqual(domain("var byOrder: [Int: AdapterGate] = [:]"), held("byOrder"))
        XCTAssertEqual(domain("private var activeRequest: ScanRequest?"), held("activeRequest"))
        XCTAssertEqual(domain("private var current: PlatformScan?"), held("current"))
        XCTAssertEqual(domain("var mine: [UInt64: InternalScan] = [:]"), held("mine"))
        XCTAssertEqual(domain("var request: ScanRequest? { nil }"), [])
        for body in ["var applied: Bool { true }", "let userRequest = 1", "var appliedCount = 0", "var pending: [PendingService] = []",
                     "var gates: [AdapterCore.GateID: AdapterGate] = [:]", "var gates: [GateID: AdapterGate] = [:]", "var gate: AdapterGate?", "// var userRequest = 1"] {
            XCTAssertEqual(domain(body), [], body)
        }
        // domain 밖(Core 안 멤버·Driver)은 g 밖이다
        for body in ["var userRequest: Int? = nil", "var applied: Int?", "var pending: [AdapterGate] = []"] {
            XCTAssertEqual(core("struct S {\n    " + body + "\n}"), [], body)
            XCTAssertEqual(check(driver: "struct DriverThing {\n    " + body + "\n}"), [], body)
        }

        // h: domain 의 states.send( 는 dispatch·perform 함수 안에서만
        let sendAt = { (line: Int) in ["\(id): Dom/X.swift:\(line) Dom publishes scan/adapter state outside dispatch (states.send()"] }
        XCTAssertEqual(domain("func start() { states.send(1) }"), sendAt(3))
        XCTAssertEqual(domain("func start() { self.states.send(1) }"), sendAt(3))
        XCTAssertEqual(domain("func dispatch() {}\nfunc y() {\n    states.send(1)\n}"), sendAt(5))
        XCTAssertEqual(domain("func injectPhaseForTesting() { states.send(1) }"), sendAt(3))
        for body in ["func dispatch() {\n    states.send(1)\n}",
                     "func perform(_ e: Int) {\n    switch e {\n    case 1:\n        states.send(1)\n    default: break\n    }\n}",
                     "func close() { states.close() }", "func x() { state.send(1) }"] {
            XCTAssertEqual(domain(body), [], body)
        }
        // dispatch·perform 라는 이름만으로는 부족하다: Core step 을 부르지 않는 파일이면 위반
        let publisher = "func dispatch() {\n    states.send(1)\n}"
        XCTAssertTrue(check(dom: "struct DomThing {}\n" + publisher).contains(sendAt(3)[0]))
        let sendBody = "func start() { states.send(1) }"
        XCTAssertEqual(check(driver: "struct DriverThing {}\n" + sendBody), [])
        XCTAssertEqual(core(sendBody), [])
    }

    func test_ruleScannerSelfCheck() {
        let c = PackageClassification(model: ["M"], ports: ["P"], driver: ["D"], factory: ["F"], domain: ["A", "B", "Dom"])

        func cycles(_ s: PackageSources) -> [String] {
            RuleScanner.noPackageCycles(s, c, minEdges: 0).filter { $0.contains("cycle:") }
        }

        // 순환
        let cyclic: PackageSources = [
            "A": ["A/A.swift": "struct AThing { let b: BThing }"],
            "B": ["B/B.swift": "struct BThing { let a: AThing }"],
        ]
        XCTAssertEqual(cycles(cyclic), ["R1_noPackageCycles: cycle: A -> B -> A"])
        let acyclic: PackageSources = [
            "A": ["A/A.swift": "struct AThing { let b: BThing }"],
            "B": ["B/B.swift": "struct BThing { let x: Int }"],
        ]
        XCTAssertEqual(cycles(acyclic).count, 0)
        XCTAssertTrue(RuleScanner.noPackageCycles(acyclic, c).contains { $0.contains("검사가 비었다") }, "간선이 적으면 실패해야 한다")
        XCTAssertTrue(RuleScanner.noPackageCycles(["Z": ["Z/Z.swift": "struct ZThing {}"]], c, minEdges: 0).contains { $0.contains("unclassified package Z") })
        XCTAssertTrue(RuleScanner.noPackageCycles(
            ["A": ["A/A.swift": "struct Same {}"], "B": ["B/B.swift": "struct Same {}"]], c, minEdges: 0
        ).contains { $0.contains("ambiguous declaration Same") })

        // lexer: 주석·문자열은 간선을 만들지 않고 보간은 만든다
        let target = ["B": ["B/B.swift": "struct BThing { static let x = 1 }\nprivate struct Hidden {}"]]
        func edgeCount(_ body: String) -> Int {
            RuleScanner.analyze(target.merging(["A": ["A/A.swift": body]]) { $1 }).edges.filter { $0.from == "A" }.count
        }
        XCTAssertEqual(edgeCount("// BThing"), 0)
        XCTAssertEqual(edgeCount("/* BThing */"), 0)
        XCTAssertEqual(edgeCount("/* outer /* BThing */ BThing */"), 0)
        XCTAssertEqual(edgeCount("let s = \"BThing\""), 0)
        XCTAssertEqual(edgeCount("let s = \"http://BThing\""), 0)
        XCTAssertEqual(edgeCount("let s = \"a \\\" BThing\""), 0)
        XCTAssertEqual(edgeCount("let s = \"\"\"\nBThing\n\"\"\""), 0)
        XCTAssertEqual(edgeCount("let s = #\"BThing \\(BThing)\"#"), 0)
        XCTAssertEqual(edgeCount("let s = \"\\(BThing.x)\""), 1)
        XCTAssertEqual(edgeCount("let s = \"a \\(f(\"BThing\") + \"\\(BThing.x)\")\""), 1)
        XCTAssertEqual(edgeCount("let s = #\"\\#(BThing.x)\"#"), 1)
        XCTAssertEqual(edgeCount("let s = \"\"\"\n\\(BThing.x)\n\"\"\""), 1)
        XCTAssertEqual(edgeCount("let s = \"x\" // c\nlet t: BThing"), 1)
        XCTAssertEqual(edgeCount("let h: Hidden"), 0, "private 선언은 선언이 아니다")
        let lined = RuleScanner.analyze(target.merging(["A": ["A/A.swift": "// c\n\nlet t: BThing"]]) { $1 }).edges
        XCTAssertEqual(lined.map(\.line), [3])
        // 선언 파서
        XCTAssertEqual(RuleScanner.parseDeclaration("@MainActor public final class Foo: Bar {")?.name, "Foo")
        XCTAssertEqual(RuleScanner.parseDeclaration("@available(iOS 17, *) package enum Foo {")?.name, "Foo")
        XCTAssertNil(RuleScanner.parseDeclaration("private struct Foo {"))
        XCTAssertNil(RuleScanner.parseDeclaration("fileprivate func foo() {"))
        XCTAssertNil(RuleScanner.parseDeclaration("extension Foo {"))
        XCTAssertEqual(RuleScanner.parseDeclaration("public private(set) var foo = 0")?.name, "foo")
        XCTAssertEqual(RuleScanner.parseDeclaration("package private(set) var foo = 0")?.name, "foo")
        XCTAssertNil(RuleScanner.parseDeclaration("private(set) private var foo = 0"))
        XCTAssertEqual(RuleScanner.parseDeclaration("    func foo() {", memberIndent: 4)?.name, "foo")
        XCTAssertNil(RuleScanner.parseDeclaration("    private func foo() {", memberIndent: 4))
        XCTAssertNil(RuleScanner.parseDeclaration("        func foo() {", memberIndent: 4))
        XCTAssertEqual(RuleScanner.extensionTarget("extension Foo {"), "Foo")
        XCTAssertEqual(RuleScanner.extensionTarget("package extension Foo {"), "Foo")
        XCTAssertEqual(RuleScanner.extensionTarget("@MainActor public extension Foo {"), "Foo")
        XCTAssertNil(RuleScanner.extensionTarget("private extension Foo {"))
        XCTAssertNil(RuleScanner.extensionTarget("struct Foo {"))
        XCTAssertNil(RuleScanner.parseDeclaration("    struct Nested {"))

        // extension 멤버 이름 참조도 간선이다
        let ext: PackageSources = [
            "B": ["B/B.swift": "extension Other {\n    func viaExt() {}\n    private func hid() {}\n}"],
            "A": ["A/A.swift": "func f(_ o: Other) { o.viaExt(); o.hid() }"],
        ]
        XCTAssertEqual(RuleScanner.analyze(ext).edges.map(\.name), ["viaExt"])
        let priv: PackageSources = [
            "B": ["B/B.swift": "public private(set) var bGlobal = 0"],
            "A": ["A/A.swift": "let x = bGlobal"],
        ]
        XCTAssertEqual(RuleScanner.analyze(priv).edges.map(\.name), ["bGlobal"])

        // 도메인: 플랫폼 타입과 Driver 선언 참조
        func domain(_ dom: String) -> [String] {
            RuleScanner.domainDoesNotUsePlatformTypes([
                "Dom": ["Dom/X.swift": dom],
                "D": ["D/D.swift": "struct DriverThing {}"],
            ], c)
        }
        XCTAssertEqual(domain("import CoreBluetooth\nstruct X {}").count, 1)
        XCTAssertEqual(domain("@preconcurrency import CoreBluetooth\nstruct X {}").count, 1)
        XCTAssertEqual(domain("struct X { let m: CBCentralManager }").count, 1)
        XCTAssertEqual(domain("struct X { let d: DriverThing }").count, 1)
        XCTAssertEqual(domain("struct X { let d: Int } // CBCentralManager, DriverThing").count, 0)
        func inner(_ pkg: String, _ body: String) -> [String] {
            RuleScanner.domainDoesNotUsePlatformTypes([pkg: ["\(pkg)/X.swift": body], "D": ["D/D.swift": "struct DriverThing {}"]], c)
        }
        XCTAssertEqual(inner("M", "import CoreBluetooth\npackage typealias PlatformUUID = CBUUID").count, 2)
        XCTAssertEqual(inner("P", "import CoreBluetooth\nfunc hold(_ p: CBPeripheral)").count, 2)
        XCTAssertEqual(inner("P", "func hold(_ p: DriverThing)").count, 1)
        XCTAssertEqual(inner("F", "import CoreBluetooth\nstruct X { let m: CBCentralManager }").count, 0)
        XCTAssertEqual(domain("import CoreBluetooth\nstruct X {}").first?.hasPrefix("R1_domainDoesNotUsePlatformTypes: Dom/X.swift:1 Dom -> CoreBluetooth") ?? false, true)

        // Driver: 도메인 참조는 위반, model·ports 참조는 위반이 아니다
        func driver(_ body: String) -> [String] {
            RuleScanner.driverDoesNotUseDomain([
                "D": ["D/D.swift": body],
                "Dom": ["Dom/X.swift": "struct DomThing {}"],
                "M": ["M/M.swift": "struct ModelThing {}"],
                "P": ["P/P.swift": "protocol PortThing {}"],
                "F": ["F/F.swift": "struct FactoryThing {}"],
            ], c)
        }
        XCTAssertEqual(driver("struct DriverThing { let d: DomThing }"), ["R1_driverDoesNotUseDomain: D/D.swift:1 D -> Dom (DomThing)"])
        XCTAssertEqual(driver("struct DriverThing { let f: FactoryThing }").count, 1)
        XCTAssertEqual(driver("struct DriverThing { let m: ModelThing; let p: PortThing }").count, 0)

        // Factory: 도메인의 Driver 생성은 위반, Factory·Driver 의 같은 코드는 위반이 아니다. Factory 에 생성이 없으면 실패
        func factory(dom: String, fac: String, drv: String = "struct DriverThing {}") -> [String] {
            RuleScanner.onlyFactoryConstructsDriver([
                "D": ["D/D.swift": drv],
                "Dom": ["Dom/X.swift": dom],
                "F": ["F/F.swift": fac],
            ], c)
        }
        let made = "func make() { _ = DriverThing() }"
        XCTAssertEqual(factory(dom: "struct X {}", fac: made), [])
        XCTAssertEqual(factory(dom: "func f() { _ = DriverThing() }", fac: made), ["R1_onlyFactoryConstructsDriver: Dom/X.swift:1 Dom -> Driver (DriverThing)"])
        XCTAssertEqual(factory(dom: "func f() { _ = DriverThing.init() }", fac: made).count, 1)
        XCTAssertEqual(factory(dom: "func f() { _ = DriverThing . init () }", fac: made).count, 1)
        XCTAssertEqual(factory(dom: "func f(_ t: DriverThing) {}  // DriverThing()", fac: made), [])
        XCTAssertEqual(factory(dom: "struct X {}", fac: "func make() { _ = DriverThing.init() }"), [])
        XCTAssertEqual(factory(dom: "struct X {}", fac: "struct Y {}").count, 1)
        XCTAssertEqual(factory(dom: "struct X {}", fac: made, drv: "struct DriverThing { func again() { _ = DriverThing() } }"), [])
    }
}
