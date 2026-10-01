#!/usr/bin/env python3
"""가이드 문서의 코드 블록이 Snippets 소스와 같은지 본다.

문서에서 `<!-- snippet: 이름 -->` 바로 다음 ```swift 블록을 Snippets/Sources 의
`// region guide:이름` ~ `// endregion` 블록(공통 들여쓰기 제거)과 글자 그대로 대조한다.
컴파일 확인은 `cd Snippets && swift build` 가 한다. 종료 코드 0 모두 일치, 1 불일치.
`--write` 를 주면 문서의 블록을 소스 내용으로 바꿔 쓴다(소스를 고친 뒤 문서를 맞출 때).
"""
import pathlib
import re
import sys
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent
REGION = re.compile(r"^[ \t]*// region guide:(\S+)[ \t]*\n(.*?)^[ \t]*// endregion[ \t]*$", re.S | re.M)
MARKER = re.compile(r"<!-- snippet: (\S+) -->\n```swift\n(.*?)```", re.S)


def regions():
    found = {}
    for path in sorted((ROOT / "Snippets" / "Sources").rglob("*.swift")):
        for name, body in REGION.findall(path.read_text()):
            if name in found:
                sys.exit(f"중복 region: {name}")
            found[name] = textwrap.dedent(body).rstrip("\n")
    return found


def docs():
    return sorted(d for d in ROOT.rglob("*.md") if ".build" not in d.parts)


def main():
    code = regions()
    if "--write" in sys.argv:
        for doc in docs():
            text = doc.read_text()
            fixed = MARKER.sub(
                lambda m: f"<!-- snippet: {m[1]} -->\n```swift\n{code[m[1]]}\n```" if m[1] in code else m[0], text
            )
            if fixed != text:
                doc.write_text(fixed)
    used = set()
    failures = []
    for doc in docs():
        for name, block in MARKER.findall(doc.read_text()):
            used.add(name)
            rel = doc.relative_to(ROOT)
            if name not in code:
                failures.append(f"{rel}: region 없음 {name}")
            elif block.rstrip("\n") != code[name]:
                failures.append(f"{rel}: 다름 {name}")
    for name in sorted(set(code) - used):
        failures.append(f"문서에 안 쓴 region: {name}")
    for line in failures:
        print(line)
    print(f"snippet {len(used)}개 대조, 불일치 {len(failures)}건")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
