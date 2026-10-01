import Foundation
import NucodeBleCore

// region guide:auto-reconnect
/// 끊겨도 다시 붙는 연결. autoReconnect 연결에는 링크 기한이 없어 기기가 멀리 있으면 무한히 기다린다
func keepConnected(_ client: any BLEClient, _ id: PeripheralID) async throws -> any BLESession {
    let session = try await client.connect(id, options: ConnectOptions(autoReconnect: true))
    do {
        try await waitUntilReady(session, timeout: .seconds(60)) // 첫 연결의 기한은 앱이 정한다
    } catch {
        await session.disconnect() // 포기하면 OS 대기 연결도 거둔다
        throw error
    }
    try await session.subscribe(NUS.tx) // 한 번 켜 두면 재연결 때마다 Ready 전에 자동으로 다시 켜진다
    return session
}
// endregion

// region guide:recovering-watch
/// 연결 상태를 따라가며 화면 문구를 정하고, 복구가 너무 오래 걸리면 포기한다
func watchConnection(_ session: any BLESession, giveUpAfter limit: Duration = .seconds(300)) -> Task<Void, Never> {
    Task {
        var giveUp: Task<Void, Never>?
        for await state in session.connectionStates {
            giveUp?.cancel()
            giveUp = nil
            switch state {
            case .ready:
                print("연결됨")
            case .recovering(let lastFailure):
                print("다시 연결하는 중:", lastFailure.code.value)
                giveUp = Task {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await session.disconnect() // Recovering 에는 기한이 없다. 앱이 포기 시점을 정한다
                }
            case .disconnected(reason: .failed(let failure)) where failure.code == .adapterUnavailable:
                print("블루투스가 꺼졌다. 다시 켜지면 한 번 자동으로 연결한다")
            case .disconnected(reason: .failed(let failure)):
                print("끊김:", failure.code.value, failure.message)
            case .disconnected:
                print("연결 안 됨")
            case .connecting, .discoveringServices, .configuring:
                print("연결 중")
            case .disconnecting:
                print("해제 중")
            }
        }
    }
}
// endregion

// region guide:multi-device
/// 기기마다 세션이 따로 있고 GATT 작업 줄도 따로다. 한 기기의 느린 작업이 다른 기기를 막지 않는다
func connectAll(_ client: any BLEClient, _ ids: [PeripheralID]) async -> [PeripheralID: Result<any BLESession, any Error>] {
    await withTaskGroup(of: (PeripheralID, Result<any BLESession, any Error>).self) { group in
        for id in ids {
            group.addTask {
                do {
                    let session = try await client.connect(id, options: ConnectOptions(autoReconnect: true))
                    try await waitUntilReady(session)
                    return (id, .success(session))
                } catch {
                    return (id, .failure(error))
                }
            }
        }
        var outcome: [PeripheralID: Result<any BLESession, any Error>] = [:]
        for await (id, result) in group { outcome[id] = result }
        return outcome
    }
}

/// 연결된 모든 기기에 같은 명령을 동시에 보낸다
func broadcast(_ command: Data, to sessions: [any BLESession]) async {
    await withTaskGroup(of: Void.self) { group in
        for session in sessions {
            group.addTask { _ = try? await session.write(NUS.rx, value: command, options: WriteOptions()) }
        }
    }
}
// endregion

func sessionReuseExample(_ client: any BLEClient, _ id: PeripheralID) throws {
    // region guide:session-reuse
    // 같은 ID 로 얻은 세션은 같은 연결을 본다. 화면마다 따로 얻어도 된다
    let a = try client.session(for: id)
    let b = try client.session(for: id)
    // a.connectionStates 와 b.connectionStates 는 같은 값을 준다. 연결하지 않고 상태만 볼 때도 session(for:) 를 쓴다
    // endregion
    _ = (a, b)
}
