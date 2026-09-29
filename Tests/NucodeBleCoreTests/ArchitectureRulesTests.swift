import Foundation
import XCTest

// 구조 규칙 시험(R1). Sources/NucodeBleCore 소스를 읽어 패키지(바로 아래 디렉터리) 사이의 의존을 검사한다.
// 규칙 함수는 [패키지: [상대경로: 소스]] 를 받는 순수 함수이고, 실제 소스와 자기 점검이 같은 함수를 부른다.
// 위반 한 줄: "<규칙 id>: <상대경로>:<줄> <from> -> <to> (<이름>)". 규칙 id 는 시험 이름과 같다(게이트가 센다).

/// 패키지 분류표. 표에 없는 패키지는 domain 으로 보고 noPackageCycles 가 따로 실패시킨다.
private struct PackageClassification {
    var model: Set<String>
    var ports: Set<String>
    var driver: Set<String>
    var factory: Set<String>
    var domain: Set<String>

    enum Kind { case model, ports, driver, factory, domain, unclassified }

    func kind(of package: String) -> Kind {
        if model.contains(package) { return .model }
        if ports.contains(package) { return .ports }
        if driver.contains(package) { return .driver }
        if factory.contains(package) { return .factory }
        if domain.contains(package) { return .domain }
        return .unclassified
    }

    /// domain 규칙을 적용할 패키지(분류 안 된 것은 보수적으로 domain 으로 본다)
    func isDomainLike(_ package: String) -> Bool {
        let k = kind(of: package)
        return k == .domain || k == .unclassified
    }

    /// 플랫폼 타입·Driver 참조 규칙을 적용할 안쪽 층 = Model·Ports·domain (Android INNER_LAYERS 와 같은 뜻)
    func isInnerLayer(_ package: String) -> Bool {
        let k = kind(of: package)
        return k == .model || k == .ports || k == .domain || k == .unclassified
    }

    static let project = PackageClassification(
        model: ["Model"],
        ports: ["Ports"],
        driver: ["Driver"],
        factory: ["Factory"],
        domain: ["Adapter", "Client", "Concurrency", "Connection", "Gatt", "Restore", "Scan", "Session"]
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

    // MARK: 자기 점검 — 같은 규칙 함수를 합성 소스에 부른다(이름에 규칙 id 를 넣지 않는다)

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
