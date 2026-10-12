// `properties` 레인(CANDIDATE-30). 줄 모양과 관찰 입구를 한곳에 둔다.
// 관찰 입구가 모인 ScenarioEngine.swift 는 baseline 400줄 초과라 이 레인을 따로 둔다

extension ContractLog {
    /// `{이름=p1+p2,…}` 모양. characteristic 은 이름순, properties 도 이름순으로 `+` 로 잇는다.
    /// properties 는 기기 정의 어휘(`read`·`write`·`writeWithoutResponse`·`notify`·`indicate`)로 받는다. 비면 `이름=`
    public static func renderProperties(_ entries: [String: Set<String>]) -> String {
        let items = entries.keys.sorted().map { symbol in
            symbol + "=" + entries[symbol, default: []].sorted().joined(separator: "+")
        }
        return "{" + items.joined(separator: ",") + "}"
    }
}

extension ScenarioObserver {
    /// `properties` 레인. 기기 정의에 있는 characteristic 마다 properties(기기 정의 어휘). 첫 값(빈 목록)도 넣는다.
    /// `services` 와 같은 원천에서 부른다. 시나리오의 `expect`에 이 레인이 없으면 버린다
    public func properties(_ entries: [String: Set<String>]) {
        let entry = ContractLog.renderProperties(entries)
        recorder.update(lane: .properties) { $0.log.append(entry, to: .properties) }
    }
}
