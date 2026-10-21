import Foundation

/// write 한 호출의 조각을 끊기지 않고 연달아 보내는 작업(contract/states.md §8). 큐가 소유하고 큐의 한 자리를 차지한다.
/// withResponse 는 조각마다 `didWriteValue` 를 기다리고, withoutResponse 는 플랫폼이 받을 수 있을 때만 보낸다.
@BLECoreActor
package final class WriteJob {
    /// 플랫폼이 `canSendWriteWithoutResponse` 를 되돌려 주지 않을 때의 대체 대기(docs/v1/ios-design.md §13 실측)
    package static let readyFallbackMilliseconds = 1000

    private let chunks: [Data]
    private let mode: WriteMode
    private let clock: any BLEClock
    private let canSend: @BLECoreActor () -> Bool
    private let send: @BLECoreActor (Data) -> Void
    /// 큐가 끼운다. 결과가 정해지면 한 번 부른다
    var finish: (@BLECoreActor (Result<Data, BLEError>) -> Void)?
    /// 큐가 끼운다. 조각 하나가 진행될 때마다(확인됐거나 보내졌을 때) 부른다. 큐는 조각 단위로 기한을 다시 건다
    var progress: (@BLECoreActor () -> Void)?
    private var index = 0
    private var fallback: Task<Void, Never>?
    private var isFinished = false

    package init(
        chunks: [Data],
        mode: WriteMode,
        clock: any BLEClock,
        canSend: @escaping @BLECoreActor () -> Bool,
        send: @escaping @BLECoreActor (Data) -> Void
    ) {
        self.chunks = chunks
        self.mode = mode
        self.clock = clock
        self.canSend = canSend
        self.send = send
    }

    /// 조각 크기(states.md §8): automatic 은 `limit`, fixed(n) 은 n, disabled 는 값 전체. disabled·fixed 가 `limit` 를 넘으면
    /// 아무것도 보내지 않도록 `PAYLOAD_TOO_LARGE` 를 던진다
    package static func chunkSize(_ chunking: WriteChunking, valueCount: Int, limit: Int) throws -> Int {
        let size: Int
        switch chunking {
        case .automatic:
            return limit
        case .disabled:
            size = valueCount
        case .fixed(let bytes):
            guard bytes >= 1 else {
                throw BLEError(failure: BLEFailure(code: .payloadTooLarge, message: "나누기 크기는 1 이상이어야 한다"))
            }
            size = bytes
        }
        guard size <= limit else {
            throw BLEError(failure: BLEFailure(
                code: .payloadTooLarge,
                message: "한 번에 보낼 수 있는 \(limit)바이트를 넘는다(\(size)바이트). 나누기를 automatic 으로 바꾼다"
            ))
        }
        return size
    }

    /// 값을 `limit` 바이트 이하 조각으로 자른다. 빈 값은 빈 조각 하나다
    package static func split(_ value: Data, limit: Int) -> [Data] {
        guard !value.isEmpty else { return [Data()] }
        let size = max(1, limit)
        return stride(from: 0, to: value.count, by: size).map { start in
            Data(value[(value.startIndex + start)..<(value.startIndex + min(start + size, value.count))])
        }
    }

    func start() {
        switch mode {
        case .withResponse: sendNextAwaitingResponse()
        case .withoutResponse: pump(forced: false)
        }
    }

    func cancel() {
        isFinished = true
        fallback?.cancel()
        fallback = nil
    }

    // MARK: 콜백

    /// 응답 있는 조각 하나가 확인됐다
    func didWrite(error: PortError?) {
        guard mode == .withResponse, !isFinished else { return }
        if let error {
            done(.failure(BLEError(failure: GattFailure.status(error, operation: "write"))))
            return
        }
        index += 1
        if index >= chunks.count {
            done(.success(Data()))
        } else {
            progress?()
            sendNextAwaitingResponse()
        }
    }

    func readyToSendWithoutResponse() {
        guard mode == .withoutResponse, !isFinished, fallback != nil else { return }
        fallback?.cancel()
        fallback = nil
        pump(forced: false)
    }

    // MARK: 전송

    private func sendNextAwaitingResponse() {
        send(chunks[index])
    }

    /// 보낼 수 있는 만큼 연달아 보낸다. 못 보내면 준비 콜백이나 대체 타이머를 기다린다. `forced` 는 대체 타이머 뒤 한 조각을 무조건 보낸다
    private func pump(forced: Bool) {
        var force = forced
        while index < chunks.count {
            guard canSend() || force else {
                armFallback()
                return
            }
            force = false
            send(chunks[index])
            index += 1
            if index < chunks.count { progress?() }
        }
        done(.success(Data()))
    }

    private func armFallback() {
        fallback?.cancel()
        fallback = Task { @BLECoreActor [weak self, clock] in
            do { try await clock.sleep(milliseconds: Self.readyFallbackMilliseconds) } catch { return }
            guard let self, !self.isFinished else { return }
            self.fallback = nil
            self.pump(forced: true)
        }
    }

    private func done(_ result: Result<Data, BLEError>) {
        guard !isFinished else { return }
        isFinished = true
        fallback?.cancel()
        fallback = nil
        finish?(result)
    }
}
