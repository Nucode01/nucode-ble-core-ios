#!/usr/bin/env bash
# 릴리스 수동 점검표(README "점검 항목별 절차") 9개를 iPhone 에서 사람 없이 돌린다.
#
#   auto/run-checklist.sh                 # 처음부터(빌드·설치 포함)
#   auto/run-checklist.sh --from 7        # 재부팅 뒤 이어서(잠금 해제 뒤, 9v 와 같다). 단계: prep 1 2 3 6 4 5 8 9 9v report
#   auto/run-checklist.sh --no-build      # 빌드·설치 없이(이미 빌드된 시험으로)
#   auto/run-checklist.sh --only "5 6"    # 그 단계만 다시(그 뒤 report). 1·2·3 은 이어진 흐름이라 "1 2 3" 처럼 함께
#   PRIME_AIRPLANE=1 ...                  # 6 앞에서 "비행기 모드가 블루투스를 끄도록" 기기 설정을 맞춘다(비행기 모드 중 블루투스 끄기)
#
# 순서와 이유
#   prep → 1 → 2 → 3 → 6 → 4 → 5 → 8 → 9(+7) → report
#   - 1·2·3 은 한 흐름(Ready 에서 끄기 → 꺼진 채 명령 → 켜서 자동 재연결). 3 이 Ready·구독·autoReconnect 켬을 남기므로 곧바로 6(비행기 모드).
#   - 4(autoReconnect 끔)는 해제·재연결이 필요해 6 뒤. 5 는 앱을 새로 실행하므로 그 뒤.
#   - 8 은 등록 저장·앱 재실행이 필요하고, 8 이 남긴 복원 재실행 세션(등록·Ready·구독)이 곧 9 의 준비다.
#   - 9 와 7 은 재부팅 한 번으로 함께 본다: 재부팅 전 둘 다 "시작". 9 는 시작 뒤 첫 실행(복원 재실행이어야 함)으로,
#     7 은 시작 뒤 마지막 실행의 uptime<10분과 그 실행의 첫 연결(connect 또는 등록 기기의 Connecting)이 Ready 인지로 판정된다.
#     그래서 재부팅 → 앱을 열지 않고 알림 → 앱 열기 한 번으로 둘 다 판정된다. 복원 재실행이 없으면 연 순간이 사용자 실행이 되어
#     9 는 실패, 7 은 그 실행으로 판정된다. 7 의 기한은 시작 뒤 900초, 9 는 600초라 재부팅 뒤 오래 기다리지 않는다.
#
# Mac 쪽 동작: DK 준비(RTT), 시험 중 probe 알림(NOTIFY 1 을 4초마다), 8 의 SIGKILL(devicectl), 9·7 의 재부팅(devicectl).
# 재부팅 뒤 잠금(암호)이 걸려 있으면 "iPhone 잠금 해제 필요" 로 멈춘다. 잠금 해제 뒤 --from 7 로 잇는다.
set -uo pipefail

UDID=00008020-0008642C1138003A
CORE_ID=CAD5BC69-480F-5906-8EB3-B3A4D31104E8
BUNDLE=kr.co.nucode.ble.ManualTest
FW=${FW:-$HOME/Desktop/01_work/04_zephyr_projects/peripheral_uart}
PY="$FW/.venv/bin/python"
RTT="$FW/tools/rtt_ctl.py"
HERE=$(cd "$(dirname "$0")/.." && pwd)
PRODUCTS="$HERE/build/Build/Products"
OUT=${OUT:-$HERE/build/auto/$(date +%Y%m%d-%H%M%S)}
TESTS=ManualTestUITests/ManualTestUITests
PHASES=(prep 1 2 3 6 4 5 8 9 9v report)   # 7 = 9v

FROM=prep
ONLY=
BUILD=1
NOBUILD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --no-build) BUILD=0; NOBUILD=1; shift ;;
    --only) ONLY="$2 report"; FROM=only; shift 2 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) echo "모르는 인자: $1"; exit 2 ;;
  esac
done
# 이어서 할 때는 앱을 다시 설치하지 않는다(설치는 앱 프로세스를 죽인다)
[ "$FROM" != prep ] && BUILD=0
mkdir -p "$OUT"
LOG="$OUT/run.log"
say() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
die() { say "중단: $*"; say "등록이 남아 시험 기기가 붙들려 있을 수 있다. 이어서 돌리지 않을 거면: $0 --only report (끝에 연결·등록 해제)"; stop_notify; exit 1; }

# MARK: DK

rtt() { "$PY" "$RTT" "$@" 2>&1 | tee -a "$LOG"; }

NOTIFY_PID=
start_notify() {
  stop_notify
  ( while true; do "$PY" "$RTT" "NOTIFY 1" >>"$OUT/notify.log" 2>&1; sleep 4; done ) &
  NOTIFY_PID=$!
}
stop_notify() {
  if [ -n "$NOTIFY_PID" ]; then kill "$NOTIFY_PID" 2>/dev/null; wait "$NOTIFY_PID" 2>/dev/null; NOTIFY_PID=; fi
}
trap 'stop_notify' EXIT

prepare_dk() {
  if command -v adb >/dev/null && adb get-state >/dev/null 2>&1; then
    adb shell am force-stop kr.co.nucode.ble.sample >/dev/null 2>&1
    adb shell am force-stop kr.co.nucode.ble.sample.test >/dev/null 2>&1
    say "Android 시험 앱 강제 종료"
  fi
  rtt ADV_ON "NTFY_PERIODIC ON" >/dev/null
  local status; status=$(rtt STATUS | tail -1)
  if [ "$FROM" != prep ]; then say "DK: $status (이어서 하는 중이라 연결 검사 안 함)"; return 0; fi
  if ! grep -q 'conn=0' <<<"$status"; then
    say "DK 연결 있음($status). LINK_DROP"
    rtt LINK_DROP >/dev/null; sleep 5
    status=$(rtt STATUS | tail -1)
  fi
  grep -q 'conn=0' <<<"$status" || die "DK 가 연결돼 있다: $status (다른 폰의 시험 앱을 끄고 다시)"
  grep -q 'periodic=1' <<<"$status" || die "DK 주기 알림이 꺼져 있다: $status"
  say "DK 준비: $status"
}

# MARK: 빌드·설치

XCTESTRUN="$OUT/attach.xctestrun"
build() {
  cd "$HERE" || die "폴더 없음"
  /opt/homebrew/bin/xcodegen generate >>"$LOG" 2>&1 || die "xcodegen 실패"
  say "빌드(앱 + UI 시험)"
  xcodebuild -project ManualTest.xcodeproj -scheme ManualTest -destination "id=$UDID" -derivedDataPath build \
    -allowProvisioningUpdates build-for-testing >"$OUT/build.log" 2>&1 || die "빌드 실패: $OUT/build.log"
}
# 이어서 할 때는 빌드만 하고 앱은 설치하지 않는다(UI 시험 번들만 새로 들어간다)
build_install() {
  build
  say "앱 설치"
  xcrun devicectl device install app --device "$UDID" "$PRODUCTS/Debug-iphoneos/ManualTest.app" >>"$LOG" 2>&1 || die "설치 실패"
}

# 대상 앱을 다시 설치하지 않는 xctestrun: 앱은 DependentProductPaths 에서 뺀다(UITargetAppPath 는 필수라 둔다).
# 시험은 번들 ID 로 이미 설치·실행 중인 앱에 붙는다
make_xctestrun() {
  local src; src=$(ls -t "$PRODUCTS"/ManualTest_*.xctestrun 2>/dev/null | head -1)
  [ -n "$src" ] || die "xctestrun 없음(먼저 빌드)"
  sed "s#__TESTROOT__#$PRODUCTS#g" "$src" >"$XCTESTRUN"
  local i=0
  while path=$(/usr/libexec/PlistBuddy -c "Print :ManualTestUITests:DependentProductPaths:$i" "$XCTESTRUN" 2>/dev/null); do
    if [[ "$path" == */ManualTest.app ]]; then
      /usr/libexec/PlistBuddy -c "Delete :ManualTestUITests:DependentProductPaths:$i" "$XCTESTRUN"
    else
      i=$((i + 1))
    fi
  done
}

# MARK: 시험 실행

# xcodebuild 는 TEST_RUNNER_<이름> 을 시험 프로세스에 <이름> 으로 넘긴다
[ "${PRIME_AIRPLANE:-0}" = 1 ] && export TEST_RUNNER_PRIME_AIRPLANE=1

# $1 시험 이름, $2 이어서 할 단계(비우면 실패해도 계속). 판정 줄(AUTO|)을 보이고, 시험 실패(자동화 문제)면 멈춘다
run_test() {
  local name=$1 resume=${2:-}
  say "── $name"
  xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination "id=$UDID" \
    -only-testing:"$TESTS/$name" >"$OUT/$name.log" 2>&1
  local rc=$?
  grep -a 'AUTO| ' "$OUT/$name.log" | sed 's/^.*AUTO| /    /' | tee -a "$LOG"
  if [ $rc -ne 0 ]; then
    [ -z "$resume" ] && { say "$name 실패(무시)"; return 1; }
    grep -a -E 'error: -\[|XCTAssert|failed \(' "$OUT/$name.log" | head -5 | tee -a "$LOG"
    die "$name 실패(자동화). 로그 $OUT/$name.log · 이어서: $0 --from $resume"
  fi
}

app_pid() {
  xcrun devicectl device info processes --device "$UDID" 2>/dev/null | awk '/ManualTest\.app\/ManualTest/ {print $1; exit}'
}

# 재부팅 뒤 기기가 돌아올 때까지. 잠금 상태를 본다
wait_device_back() {
  local deadline=$((SECONDS + 420)) state
  sleep 20
  while [ $SECONDS -lt $deadline ]; do
    if state=$(xcrun devicectl device info lockState --device "$UDID" 2>/dev/null) && grep -q passcodeRequired <<<"$state"; then
      echo "$state" >>"$LOG"
      if grep -q 'passcodeRequired: true' <<<"$state"; then
        die "iPhone 잠금 해제 필요. 잠금 해제한 뒤(앱은 열지 말 것) 이어서: $0 --from 9v   (9 기한: 시작 뒤 600초)"
      fi
      say "기기 돌아옴(잠금 없음)"
      return 0
    fi
    sleep 5
  done
  die "재부팅 뒤 기기가 돌아오지 않음"
}

# MARK: 끝정리

# 연결 해제·등록 해제 → 앱 종료 → 시험 기기가 풀렸는지 본다. 등록이 남으면 앱을 종료해도 OS 가 연결을 붙들어
# 다른 폰(Android 점검표·lab/run.sh)이 기기를 찾지 못한다. 풀리지 않으면 기기 쪽에서 링크를 끊는다.
release_device() {
  run_test testReleaseDevice || true
  local pid; pid=$(app_pid)
  if [ -n "$pid" ]; then
    xcrun devicectl device process terminate --device "$UDID" --pid "$pid" >>"$LOG" 2>&1 || true
  fi
  local status=
  for _ in 1 2 3 4 5 6; do
    sleep 2
    status=$("$PY" "$RTT" STATUS 2>&1)
    case "$status" in *conn=0*) say "기기 풀림: $status"; return 0 ;; esac
  done
  say "기기가 아직 연결됨($status). 기기 쪽에서 링크를 끊는다"
  rtt LINK_DROP >/dev/null
  sleep 3
  status=$("$PY" "$RTT" STATUS 2>&1)
  case "$status" in
    *conn=0*) say "기기 풀림: $status" ;;
    *) say "주의: 기기가 여전히 연결됨($status). iPhone 앱 등록을 확인한다" ;;
  esac
}

# MARK: 보고

report() {
  say "앱 데이터 복사"
  rm -rf "$OUT/data"
  xcrun devicectl device copy from --device "$UDID" --domain-type appDataContainer --domain-identifier "$BUNDLE" \
    --source "Library/Application Support/ManualTest" --destination "$OUT/data" >>"$LOG" 2>&1 || say "복사 실패"
  python3 - "$OUT/data" <<'PY' | tee -a "$LOG"
import json, sys, os
d = sys.argv[1]
try:
    results = json.load(open(os.path.join(d, "checklist.json")))
except Exception as e:
    print("checklist.json 없음:", e); sys.exit(0)
titles = {1: "Ready 에서 블루투스 끄기", 2: "꺼진 상태 read·connect", 3: "블루투스 다시 켜기", 4: "autoReconnect 끄고 반복",
          5: "블루투스 끈 채 앱 시작", 6: "비행기 모드로 1–3", 7: "재부팅 뒤 첫 연결", 8: "SIGKILL 뒤 복원 재실행", 9: "재부팅 뒤 복원 재실행"}
print()
print(f"{'#':<2} {'항목':<24} {'판정':<11} 내용")
for i in range(1, 10):
    r = results.get(str(i))
    if not r:
        print(f"{i:<2} {titles[i]:<24} {'미실시':<11}"); continue
    auto = r.get("auto") or {}
    outcome = auto.get("outcome") or {}
    kind = next(iter(outcome), "-")
    body = outcome.get(kind, {}) or {}
    text = body.get("_0", "") if isinstance(body, dict) else ""
    print(f"{i:<2} {titles[i]:<24} {r.get('verdict','?') + '/' + r.get('source','?'):<11} {text}")
    for line in auto.get("evidence", [])[:8]:
        print(f"     · {line}")
PY
  say "결과: $OUT (data/checklist.json, data/events.jsonl, 단계별 로그)"
}

# MARK: 단계

started=0
should() {
  if [ -n "$ONLY" ]; then [[ " $ONLY " == *" $1 "* ]]; return; fi
  [ "$started" = 1 ] || { [ "$1" = "$FROM" ] && started=1; }; [ "$started" = 1 ]; }
case "$FROM" in only|prep|1|2|3|6|4|5|8|9|9v|7|report) ;; *) die "--from 은 ${PHASES[*]} 중 하나" ;; esac
[ "$FROM" = 7 ] && FROM=9v   # 7 은 9 와 같은 재부팅으로 판정한다

say "출력: $OUT"
if [ "$FROM" != report ]; then
  if [ "$BUILD" = 1 ]; then build_install; elif [ "$NOBUILD" = 0 ]; then build; fi
  make_xctestrun
  prepare_dk
  start_notify
fi

if should prep; then run_test testPrepareConnectSubscribe prep; fi
if should 1; then run_test testItem1_BluetoothOff 1; fi
if should 2; then run_test testItem2_OffCommands 2; fi
if should 3; then run_test testItem3_BluetoothOn 3; fi
if should 6; then run_test testItem6_AirplaneMode 6; fi
if should 4; then run_test testItem4_NoAutoReconnect 4; fi
if should 5; then run_test testItem5_LaunchWithBluetoothOff 5; fi
if should 8; then
  run_test testItem8_Arm 8
  pid=$(app_pid)
  [ -n "$pid" ] || die "8: 앱 프로세스 없음"
  say "8: SIGKILL pid=$pid"
  xcrun devicectl device process signal --device "$UDID" --signal SIGKILL --pid "$pid" >>"$LOG" 2>&1 || die "SIGKILL 실패"
  say "8: 펌웨어 알림 계속(앱은 열지 않는다)"
  relaunched=
  for _ in $(seq 1 18); do
    sleep 5
    new=$(app_pid)
    if [ -n "$new" ] && [ "$new" != "$pid" ]; then relaunched=$new; break; fi
  done
  if [ -n "$relaunched" ]; then say "8: iOS 가 앱을 다시 실행함 pid=$relaunched"; sleep 15; else say "8: 90초 안에 앱 프로세스가 다시 뜨지 않음"; fi
  run_test testItem8_Verify 8
fi
if should 9; then
  run_test testItem9And7_Arm 9
  say "9·7: 재부팅"
  xcrun devicectl device reboot --device "$UDID" >>"$LOG" 2>&1 || die "재부팅 명령 실패"
  wait_device_back
fi
if should 9v; then
  say "9: 앱을 열지 않고 펌웨어 알림 90초"
  seen=
  for _ in $(seq 1 18); do
    sleep 5
    p=$(app_pid)
    if [ -n "$p" ] && [ -z "$seen" ]; then seen=$p; say "9: 앱 프로세스 뜸 pid=$p(앱을 열기 전)"; fi
  done
  [ -z "$seen" ] && say "9: 앱을 열기 전 앱 프로세스 없음"
  run_test testItem9And7_Verify 9v
fi
if should report; then
  stop_notify
  run_test testRestoreRadios
  report
  release_device
fi
