import BleContract
import Foundation
import Testing

/// 로더는 모르는 것을 조용히 건너뛰지 않고 이유를 담아 거부한다
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

    struct Bad: Sendable, CustomTestStringConvertible {
        let label: String
        let json: String
        let fragment: String
        var testDescription: String { label }
    }

    static let cases: [Bad] = raw.map { Bad(label: $0.0, json: $0.1, fragment: $0.2) }

    private static let raw: [(String, String, String)] = [
        ("unknown top-level key", scenario(extra: #", "extra": 1"#), #"unknown key(s) "extra""#),
        ("unknown key in step", scenario(steps: #"{ "call": "connect", "retry": true }"#), #"unknown key(s) "retry""#),
        ("unknown step kind", scenario(steps: #"{ "wait": 100 }"#), "unknown step"),
        ("two step kinds", scenario(steps: #"{ "call": "connect", "sleep": 1 }"#), "unknown step"),
        ("unknown call", scenario(steps: #"{ "call": "bond" }"#), #"unknown call "bond""#),
        ("unknown await", scenario(steps: #"{ "await": "services" }"#), #"unknown condition "services""#),
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

    @Test func writeBytes() throws {
        let s = try Contract.scenario(Self.scenario(steps: """
            { "call": "write", "char": "nus.rx", "hex": "0aFF" },
            { "call": "write", "char": "nus.rx", "text": "hi", "mode": "withoutResponse" }
            """))
        let rx = try #require(try Contract.probe().characteristics["nus.rx"])
        #expect(s.steps[0] == .call(CallStep(action: .write(rx, bytes: [0x0A, 0xFF], withResponse: true), asyncName: nil, timeoutMs: 15_000)))
        #expect(s.steps[1] == .call(CallStep(action: .write(rx, bytes: [0x68, 0x69], withResponse: false), asyncName: nil, timeoutMs: 15_000)))
    }
}
