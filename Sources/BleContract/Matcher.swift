/// README §기대값 대조. 목록 전체를 처음부터 끝까지 맞춘다
public enum ContractMatcher {
    public static func matches(expected: [String], actual: [String]) -> Bool {
        let patterns = expected.map(Pattern.init)
        let entries = actual.map(Array.init)
        let n = patterns.count, m = entries.count
        // ok[i][j]: patterns[i...] 가 entries[j...] 와 맞는가. 선택 항목 때문에 되짚기가 필요해 표로 푼다
        var ok = Array(repeating: Array(repeating: false, count: m + 1), count: n + 1)
        ok[n][m] = true
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m, through: 0, by: -1) {
                let p = patterns[i]
                if j < m, ok[i + 1][j + 1], glob(p.chars, entries[j]) {
                    ok[i][j] = true
                } else if p.optional, ok[i + 1][j] {
                    ok[i][j] = true
                }
            }
        }
        return ok[0][0]
    }

    /// 항목 하나에 대한 대조(`await state`). 앞의 `?`/`??` 규칙도 같이 따른다
    public static func matchesEntry(pattern: String, entry: String) -> Bool {
        matches(expected: [pattern], actual: [entry])
    }

    private struct Pattern {
        let optional: Bool
        let chars: [Character]

        init(_ raw: String) {
            if raw.hasPrefix("??") {
                optional = false
                chars = Array(raw.dropFirst())
            } else if raw.hasPrefix("?") {
                optional = true
                chars = Array(raw.dropFirst())
            } else {
                optional = false
                chars = Array(raw)
            }
        }
    }

    /// `*`만 특수 글자인 글자열 대조
    private static func glob(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0
        var star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] != "*", p[pi] == s[si] {
                pi += 1
                si += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = si
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                si = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
