#!/usr/bin/env bash
# iOS 기기 러너: 연결된 iPhone 에서 계약 시나리오(runsOn: device, platforms: ios)를 XCTest 로 돌린다.
#   ios/lab/run-device.sh <contract 폴더>
#   DEVICE_ID=<id> ios/lab/run-device.sh <contract 폴더>     # 기본은 iPhone XR
# 기록 줄(CONTRACT|ios|…)을 표준 출력에 낸다. 원본 출력은 DeviceTests/build/xcodebuild.log.
# 종료 코드: 0 모든 시나리오 PASS, 1 FAIL 이 있음, 2 준비 문제(기기·빌드·서명·권한 등, 기록 없음).
# 호스트 앱은 권한을 받은 번들 ID 를 재사용하고 지우지 않는다. 전제: lab/README.md §준비
set -uo pipefail

if [[ $# -ne 1 || ! -d "$1/scenarios" || ! -d "$1/peripherals" ]]; then
  echo "사용법: $0 <contract 폴더>" >&2
  exit 2
fi
CONTRACT="$(cd "$1" && pwd)"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_ID="${DEVICE_ID:-00008020-0008642C1138003A}"   # iPhone XR
PROJECT_DIR="$ROOT/DeviceTests"
BUILD="$PROJECT_DIR/build"
LOG="$BUILD/xcodebuild.log"

mkdir -p "$BUILD"
# 표 출력은 CoreDevice 식별자만 보여 주므로 UDID 가 들어 있는 JSON 출력에서 찾는다
if ! xcrun devicectl list devices --json-output "$BUILD/devices.json" > /dev/null 2>&1 \
  || ! grep -q "\"$DEVICE_ID\"" "$BUILD/devices.json"; then
  echo "기기 $DEVICE_ID 를 찾지 못했다(연결·신뢰·잠금 해제 확인)" >&2
  exit 2
fi

# 기기는 Mac 경로를 못 읽으므로 계약 폴더를 시험 번들 리소스 자리에 복사한다
mkdir -p "$PROJECT_DIR/Contract"
find "$PROJECT_DIR/Contract" -mindepth 1 ! -name .gitkeep -delete
cp -R "$CONTRACT/scenarios" "$CONTRACT/peripherals" "$PROJECT_DIR/Contract/" || exit 2

cd "$PROJECT_DIR" || exit 2
xcodegen generate --quiet || { echo "xcodegen 실패" >&2; exit 2; }

xcodebuild test -project ContractDeviceTests.xcodeproj -scheme ContractDeviceTests \
  -destination "id=$DEVICE_ID" -derivedDataPath "$BUILD/dd" -allowProvisioningUpdates > "$LOG" 2>&1
build_code=$?

grep -o 'CONTRACT|.*' "$LOG" || true
verdicts="$(grep -c 'CONTRACT|ios|.*|verdict|' "$LOG" || true)"
failed="$(grep -c 'CONTRACT|ios|.*|verdict|FAIL' "$LOG" || true)"

if [[ "$verdicts" -eq 0 ]]; then
  echo "시나리오 기록이 없다(xcodebuild 종료 $build_code). 원본: $LOG" >&2
  tail -20 "$LOG" >&2
  exit 2
fi
if [[ "$failed" -gt 0 || "$build_code" -ne 0 ]]; then
  exit 1
fi
exit 0
