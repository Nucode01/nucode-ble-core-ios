import Foundation

// MARK: 명령 진입 검사 (contract/states.md §5 명령 진입 검사 순서)
// Session.swift 는 baseline 400줄 초과라 따로 둔다. GATT 명령은 1~4, readRSSI 는 1~3 을 본다

extension Session {
    /// 진입 검사 1~3: 닫힘 → 어댑터(§6) → 세션 Ready 아님(`NOT_READY`). 판정은 `ConnectionCore.gattAdmission` 이 한다.
    /// 어댑터가 `unknown` 일 때만 판정을 기다리고(§6, connect 와 같은 대기), 기다린 뒤의 확인은 모두 대기 이후에 한다
    func admitReady() async throws {
        if case .awaitAdapterDecision = ConnectionCore.gattAdmission(core, adapter: context.adapter.current) {
            let gate = context.adapter.gate()
            try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: {
                Task { @BLECoreActor in gate.cancel() }
            }
        }
        switch ConnectionCore.gattAdmission(core, adapter: context.adapter.current) {
        case .admit:
            break
        case .reject(let failure):
            throw BLEError(failure: failure)
        case .awaitAdapterDecision:
            // 판정을 받은 뒤 다시 unknown 이 됐다
            throw BLEError(failure: AdapterCore.leftReady)
        }
    }

    /// 진입 검사 1~4: `admitReady` 뒤 참조 없음(`CHARACTERISTIC_NOT_FOUND`). 통과하면 포트 참조. 확인과 큐 접수 사이에는 `await` 가 없다
    func admitGatt(_ characteristic: CharacteristicRef) async throws -> CharacteristicRef {
        try await admitReady()
        guard let portRef = portRefs[characteristic] else {
            throw BLEError(failure: BLEFailure(code: .characteristicNotFound, message: "이 기기에 없는 characteristic 이다"))
        }
        return portRef
    }
}
