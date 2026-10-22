import BleContract
import Foundation
import Testing

/// 로더는 모르는 것을 조용히 건너뛰지 않고 이유를 담아 거부한다
@Suite(.needsContract)
struct LoaderRejectionTests {
    static func scenario(
        id: String = "inline",
        format: String = "1",
        steps: String = #"{ "call": "connect" }"#,
        expect: String = #"{ "result": ["connect ok"] }"#,
        extra: String = ""
    ) -> String {
        """
        {
          "format": \(format),
          "id": "\(id)",
          "summary": "s",
          "status": "draft",
          "runsOn": ["sim"],
          "peripheral": "probe",
          "steps": [\(steps)],
          "expect": \(expect)\(extra)
        }
        """
    }

    static func write(_ fields: String) -> String {
        scenario(steps: #"{ "call": "write", "char": "nus.rx", \#(fields) }"#)
    }

    struct Bad: Sendable, CustomTestStringConvertible {
        let label: String
        let json: String
        let fragment: String
        var testDescription: String { label }
    }

    static let cases: [Bad] = raw.map { Bad(label: $0.0, json: $0.1, fragment: $0.2) }

    private static let raw: [(String, String, String)] = [
        ("unknown top-level key", scenario(extra: #", "extra": 1"#), #"unknown key(s) "extra""#),
        // 키 순서를 지키는 파서(JSONParser)의 엄격함
        ("duplicate key", scenario(extra: #", "summary": "a", "summary": "b""#), "invalid JSON"),
        ("trailing comma", scenario(steps: #"{ "call": "connect", }"#), "invalid JSON"),
        ("unquoted key", scenario(steps: #"{ call: "connect" }"#), "invalid JSON"),
        ("content after value", scenario() + " {}", "invalid JSON"),
        ("unknown key in step", scenario(steps: #"{ "call": "connect", "retry": true }"#), #"unknown key(s) "retry""#),
        ("unknown step kind", scenario(steps: #"{ "wait": 100 }"#), "unknown step"),
        ("two step kinds", scenario(steps: #"{ "call": "connect", "sleep": 1 }"#), "unknown step"),
        ("unknown call", scenario(steps: #"{ "call": "bond" }"#), #"unknown call "bond""#),
        ("unknown await", scenario(steps: #"{ "await": "gatt" }"#), #"unknown condition "gatt""#),
        ("unknown device event", scenario(steps: #"{ "device": "reboot" }"#), #"unknown device event "reboot""#),
        ("id mismatch", scenario(id: "other"), #"id "other" does not match file name "inline""#),
        ("format 2", scenario(format: "2"), "unsupported format 2"),
        ("format as string", scenario(format: #""1""#), "format: expected integer, got string"),
        ("unknown char", scenario(steps: #"{ "call": "read", "char": "probe.nope" }"#), #"unknown symbol "probe.nope""#),
        ("runnerOnly char", scenario(steps: #"{ "call": "read", "char": "probe.control" }"#), "runnerOnly"),
        ("timeout wrong type", scenario(steps: #"{ "call": "connect", "timeoutMs": "20000" }"#), "timeoutMs: expected integer, got string"),
        ("autoReconnect wrong type", scenario(steps: #"{ "call": "connect", "autoReconnect": 1 }"#), "autoReconnect: expected boolean, got integer"),
        ("async without name", scenario(steps: #"{ "call": "connect", "async": true }"#), #""async": true requires "name""#),
        ("await unknown result", scenario(steps: #"{ "await": "result", "name": "r1" }"#), #"no earlier async call named "r1""#),
        ("write with text and hex", scenario(steps: #"{ "call": "write", "char": "nus.rx", "text": "a", "hex": "01" }"#), "exactly one of"),
        ("write with neither", scenario(steps: #"{ "call": "write", "char": "nus.rx" }"#), "exactly one of"),
        ("write bad hex", scenario(steps: #"{ "call": "write", "char": "nus.rx", "hex": "+f" }"#), "invalid hex"),
        ("write bad mode", scenario(steps: #"{ "call": "write", "char": "nus.rx", "text": "a", "mode": "fast" }"#), #"unknown value "fast""#),
        ("linkDropHide without ms", scenario(steps: #"{ "device": "linkDropHide" }"#), #"missing required key "ms""#),
        ("runsOn outside set", scenario().replacingOccurrences(of: #"["sim"]"#, with: #"["cloud"]"#), #"runsOn: unknown value "cloud""#),
        ("platforms outside set", scenario(extra: #", "platforms": ["web"]"#), #"platforms: unknown value "web""#),
        ("unknown lane", scenario().replacingOccurrences(of: #"{ "result""#, with: #"{ "events""#), #"unknown lane "events""#),
        ("adapter step with device", scenario(steps: #"{ "adapter": "PoweredOff" }"#).replacingOccurrences(of: #"["sim"]"#, with: #"["sim", "device"]"#), "sim-only"),
        ("adapter unknown value", scenario(steps: #"{ "adapter": "Off" }"#), #"unknown value "Off""#),
        ("adapter Unauthorized without canRequest", scenario(steps: #"{ "adapter": "Unauthorized" }"#), #"unknown value "Unauthorized""#),
        ("pattern not multiple of 256", write(#""pattern": 100"#), "multiple of 256"),
        ("pattern too large", write(#""pattern": 65792"#), "multiple of 256"),
        ("pattern with text", write(#""pattern": 256, "text": "a""#), "exactly one of"),
        ("fixed without chunkBytes", write(#""text": "a", "chunking": "fixed""#), #"requires "chunkBytes""#),
        ("chunkBytes with automatic", write(#""text": "a", "chunkBytes": 20"#), "only allowed with"),
        ("chunkBytes 0", write(#""text": "a", "chunking": "fixed", "chunkBytes": 0"#), "must be >= 1"),
        ("unknown chunking", write(#""text": "a", "chunking": "lots""#), #"unknown value "lots""#),
        ("pattern on read", scenario(steps: #"{ "call": "read", "char": "probe.value", "pattern": 256 }"#), #"unknown key(s) "pattern""#),
        ("scan filter unknown service", scenario(steps: #"{ "call": "startScan", "filter": { "services": ["nope"] } }"#), #"unknown service symbol "nope""#),
        ("scan filter characteristic symbol", scenario(steps: #"{ "call": "startScan", "filter": { "services": ["nus.rx"] } }"#), #"unknown service symbol "nus.rx""#),
        ("scan filter empty services", scenario(steps: #"{ "call": "startScan", "filter": { "services": [] } }"#), "must not be empty"),
        ("scan filter unknown key", scenario(steps: #"{ "call": "startScan", "filter": { "rssi": 1 } }"#), #"unknown key(s) "rssi""#),
        ("stopScan with filter", scenario(steps: #"{ "call": "stopScan", "filter": {} }"#), #"unknown key(s) "filter""#),
        ("await found without lane", scenario(steps: #"{ "await": "found", "count": 1 }"#), #"needs lane "found""#),
        ("await scan without lane", scenario(steps: #"{ "await": "scan", "is": "Idle" }"#), #"needs lane "scan""#),
        ("await found with is", scenario(steps: #"{ "await": "found", "is": "probe" }"#, expect: #"{ "found": [] }"#), #"unknown key(s) "is""#),
        ("await peer", scenario(steps: #"{ "await": "peer", "count": 1 }"#, expect: #"{ "peer": [] }"#), #"unknown condition "peer""#),
        ("rxCheck without peer lane", scenario(steps: #"{ "device": "rxCheck" }"#), #"needs lane "peer""#),
        ("diffIgnore unknown lane", scenario(extra: #", "diffIgnore": ["gatt|x"]"#), "diffIgnore[0]"),
        ("missing steps", scenario().replacingOccurrences(of: #""steps""#, with: #""stepz""#), #"unknown key(s) "stepz""#),
    ]

    @Test(arguments: cases)
    func rejects(_ bad: Bad) {
        let (label, json, fragment) = (bad.label, bad.json, bad.fragment)
        do {
            let s = try Contract.scenario(json)
            Issue.record("\(label): accepted \(s.id)")
        } catch let error as ContractError {
            #expect(error.message.contains(fragment), "\(label): \(error.message)")
        } catch {
            Issue.record("\(label): unexpected error \(error)")
        }
    }

    @Test func baseScenarioIsValid() throws {
        #expect(try Contract.scenario(Self.scenario()).steps.count == 1)
    }

    /// JSONParser 의 문자열 escape: 짧은 escape, `\u`, 서로게이트 쌍
    @Test func stringEscapesAreDecoded() throws {
        let json = Self.scenario().replacingOccurrences(of: #""summary": "s""#, with: #""summary": "a\"b\\c\/d\né😀""#)
        #expect(try Contract.scenario(json).summary == "a\"b\\c/d\né😀")
    }

    @Test func writeBytes() throws {
        let s = try Contract.scenario(Self.scenario(steps: """
            { "call": "write", "char": "nus.rx", "hex": "0aFF" },
            { "call": "write", "char": "nus.rx", "text": "hi", "mode": "withoutResponse" }
            """))
        let rx = try #require(try Contract.probe().characteristics["nus.rx"])
        #expect(s.steps[0] == .call(CallStep(action: .write(rx, bytes: [0x0A, 0xFF], withResponse: true), asyncName: nil, timeoutMs: 15_000)))
        #expect(s.steps[1] == .call(CallStep(action: .write(rx, bytes: [0x68, 0x69], withResponse: false), asyncName: nil, timeoutMs: 15_000)))
    }

    @Test func writeExtensions() throws {
        let s = try Contract.scenario(Self.scenario(steps: """
            { "call": "write", "char": "nus.rx", "pattern": 512, "chunking": "fixed", "chunkBytes": 20 },
            { "call": "write", "char": "nus.rx", "pattern": 256, "chunking": "disabled" }
            """))
        let rx = try #require(try Contract.probe().characteristics["nus.rx"])
        let pattern = (0..<512).map { UInt8($0 % 256) }
        #expect(s.steps[0] == .call(CallStep(action: .write(rx, bytes: pattern, withResponse: true, chunking: .fixed(bytes: 20)))))
        #expect(s.steps[1] == .call(CallStep(action: .write(rx, bytes: Array(pattern[0..<256]), withResponse: true, chunking: .disabled))))
    }

    @Test func scanFilterResolvesServiceUuids() throws {
        let s = try Contract.scenario(Self.scenario(steps: """
            { "call": "startScan", "filter": { "name": "N", "services": ["probe"] } },
            { "call": "startScan", "filter": {} },
            { "call": "startScan" }
            """))
        let probe = try Contract.probe().services["probe"]
        let ref = ServiceRef(symbol: "probe", uuid: try #require(probe).uuid)
        #expect(s.steps[0] == .call(CallStep(action: .startScan(ScanFilter(name: "N", services: [ref])))))
        #expect(s.steps[1] == .call(CallStep(action: .startScan(.none))))
        #expect(s.steps[2] == .call(CallStep(action: .startScan(.none))))
    }

    @Test func newWaitsAndAdapterStep() throws {
        let s = try Contract.scenario(Self.scenario(steps: """
            { "adapter": "Unauthorized(false)" },
            { "await": "adapter", "is": "Unauth*" },
            { "await": "found", "count": 2 },
            { "await": "services", "is": "{}" }
            """, expect: #"{ "adapter": [], "found": [], "services": [] }"#))
        #expect(s.steps[0] == .adapter(.unauthorizedDenied))
        #expect(s.steps[1] == .wait(AwaitStep(condition: .value(.adapter, pattern: "Unauth*"))))
        #expect(s.steps[2] == .wait(AwaitStep(condition: .found(count: 2))))
    }
}
