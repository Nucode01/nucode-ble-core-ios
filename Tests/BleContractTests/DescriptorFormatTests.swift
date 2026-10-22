import BleContract
import Foundation
import Testing

/// FakeBackend 의 descriptor 호출. 정의의 `value`를 돌려주고 쓰기는 받기만 한다
extension FakeBackend {
    func readDescriptor(_ target: DescriptorTarget) -> CallOutcome {
        .descriptorRead(target.descriptor.value ?? [])
    }

    func writeDescriptor(_ target: DescriptorTarget, bytes: [UInt8]) -> CallOutcome {
        .ok
    }
}

/// descriptor 형식(CANDIDATE-32): 기기 정의 `descriptors`, `readDescriptor`·`writeDescriptor`, `descriptors` 레인
@Suite(.needsContract)
struct DescriptorFormatTests {
    static let ready = #"{ "call": "connect" }, { "await": "state", "is": "Ready" }"#

    @Test func probeDefinitionHasTheContractDescriptors() throws {
        let probe = try Contract.probe()
        let value = try #require(probe.characteristics["probe.value"])
        #expect(value.descriptors.map(\.name) == ["ccc", "cpf"], "정의 파일에 적힌 순서")
        #expect(value.descriptor(named: "ccc")?.uuid == DescriptorDefinition.cccdUUID)
        #expect(value.descriptor(named: "ccc")?.value == nil)
        #expect(value.descriptor(named: "cpf")?.properties == ["read"])
        #expect(value.descriptor(named: "cpf")?.value == [0x19, 0x00, 0x00, 0x27, 0x01, 0x00, 0x00])
        let control = try #require(probe.characteristics["probe.control"])
        #expect(control.descriptors.map(\.name) == ["cud", "echo"])
        #expect(control.descriptor(named: "cud")?.value == Array("probe control".utf8))
        #expect(control.descriptor(named: "echo")?.properties == ["read", "write"])
        #expect(control.descriptor(named: "none") == nil)
        #expect(probe.characteristics["nus.tx"]?.descriptors.map(\.name) == ["ccc"])
        #expect(probe.characteristics["nus.rx"]?.descriptors.isEmpty == true)
    }

    /// 이름순이 아니라 정의 파일에 적힌 순서로 읽는다(JSON 객체 키 순서, 033decc low)
    @Test func descriptorsKeepTheDefinitionOrder() throws {
        let json = """
        {"format": 1, "name": "p", "advertisedName": "n", "characteristics": {"probe.value": {
          "service": "6e7a0001-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "uuid": "6e7a0002-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "properties": ["read"],
          "descriptors": {
            "zz": {"uuid": "00002904-0000-1000-8000-00805f9b34fb", "properties": ["read"]},
            "aa": {"uuid": "00002901-0000-1000-8000-00805f9b34fb", "properties": ["read"]},
            "mm": {"uuid": "00002902-0000-1000-8000-00805f9b34fb", "properties": ["read", "write"]}
          }}}}
        """
        let profile = try PeripheralProfile.parse(Data(json.utf8), expectedName: "p")
        #expect(profile.characteristics["probe.value"]?.descriptors.map(\.name) == ["zz", "aa", "mm"])
    }

    @Test func callsOnRunnerOnlyCharacteristicAreRead() throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: Self.ready + #", { "call": "readDescriptor", "desc": "probe.control/cud" }, { "call": "writeDescriptor", "desc": "probe.control/echo", "hex": "A55A01" }, { "call": "writeDescriptor", "desc": "probe.control/echo", "text": "ab" }"#
        ))
        guard case .call(let read) = s.steps[2], case .call(let hex) = s.steps[3], case .call(let text) = s.steps[4] else {
            Issue.record("descriptor steps are not calls")
            return
        }
        #expect(read.action.label == "readDescriptor probe.control/cud")
        guard case .writeDescriptor(let target, let hexBytes) = hex.action, case .writeDescriptor(_, let textBytes) = text.action else {
            Issue.record("not writeDescriptor")
            return
        }
        #expect(target.symbol == "probe.control/echo")
        #expect(target.characteristic.runnerOnly)
        #expect(hexBytes == [0xA5, 0x5A, 0x01])
        #expect(textBytes == Array("ab".utf8))
    }

    @Test func duplicateDescriptorPropertiesAreRejected() {
        let json = """
        {"format": 1, "name": "p", "advertisedName": "n", "characteristics": {"probe.value": {
          "service": "6e7a0001-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "uuid": "6e7a0002-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "properties": ["read"],
          "descriptors": {"cpf": {"uuid": "00002904-0000-1000-8000-00805f9b34fb", "properties": ["read", "read"]}}}}}
        """
        #expect {
            try PeripheralProfile.parse(Data(json.utf8), expectedName: "p")
        } throws: { error in
            (error as? ContractError)?.message.contains("duplicate property") == true
        }
    }

    @Test func readResultCarriesUppercaseHex() {
        #expect(CallOutcome.descriptorRead([0x70, 0x0A]).rendered == "ok 700A")
        #expect(CallOutcome.descriptorRead([]).rendered == "ok")
    }

    @Test func engineWritesDescriptorResultLines() async throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: Self.ready + #", { "call": "readDescriptor", "desc": "probe.control/cud" }, { "call": "writeDescriptor", "desc": "probe.control/echo", "hex": "01" }"#,
            expect: #"{ "result": ["connect ok", "readDescriptor probe.control/cud ok 70726F626520636F6E74726F6C", "writeDescriptor probe.control/echo ok"] }"#
        ))
        let report = await ScenarioEngine(backend: FakeBackend(), clock: ScenarioEngineTests.clock).run(s)
        #expect(report.verdict == .pass)
    }

    @Test func descriptorScenariosAndPlatforms() throws {
        for id in ["descriptors-discovered", "descriptor-read-write", "descriptor-read-during-link-loss"] {
            #expect(try Contract.dir.loadScenario(id: id).platforms.contains(.ios), "\(id)")
        }
        for id in ["descriptor-cccd-write-syncs-subscription", "descriptor-cccd-write-restored"] {
            #expect(try Contract.dir.loadScenario(id: id).platforms == [.android], "\(id)")
        }
        #expect(try Contract.dir.loadScenario(id: "descriptor-cccd-write-rejected").platforms == [.ios])
    }

    /// README §레인 `descriptors` 모양: characteristic 은 이름순, descriptor 는 받은 순서
    @Test func descriptorsLaneRendering() {
        #expect(ContractLog.renderDescriptors([:]) == "{}")
        #expect(ContractLog.renderDescriptors(["probe.value": ["ccc", "cpf"], "nus.rx": [], "probe.control": ["echo", "cud"]])
                == "{nus.rx=,probe.control=echo+cud,probe.value=ccc+cpf}")
    }
}
