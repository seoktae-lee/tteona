#!/bin/bash
# 2026-08-02 브이로그 자막 커스터마이징 + 자막 자동 축소 배포
#  - WAS: server.js —
#    · job options에 subtitleFields(both|place|time) / subtitleColor(키) / caption(20자) 저장
#    · 색은 키만 받아 서버 표(VLOG_SUBTITLE_COLORS)에서 색값을 찾는다.
#      hex를 그대로 받으면 `:`·`,` 한 글자로 drawtext 필터 체인을 조작할 수 있다.
#    · 자막을 고정 2줄에서 가변 스택으로 — 꺼 둔 항목은 자리도 차지하지 않는다.
#      기본값(both)일 때의 좌표는 기존과 완전히 동일하다(해상도 3종 × 크기 3단 검증 완료).
#    · 자막을 전부 끄면 overlays가 비어 워터마크 경로 필터가 깨지던 문제도 함께 막았다.
#  - nginx는 건드리지 않는다 (2026-07 /ws/ 덮어쓰기 사고 재발 방지)
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="https://tteona.kr/api/vlog"

echo "▶ [1/6] 로컬 문법 검사..."
node --check "$SCRIPT_DIR/server.js"

echo "▶ [2/6] WAS: 현재 server.js 백업..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cp /home/ubuntu/tteona-api/server.js /home/ubuntu/tteona-api/server.js.bak-$(date +%Y%m%d-%H%M%S)"

echo "▶ [3/6] WAS: server.js 업로드 + PM2 재시작..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "cd /home/ubuntu/tteona-api && node --check server.js && pm2 restart tteona-api && sleep 3 && pm2 logs tteona-api --nostream --lines 10"

echo "▶ [4/6] 기본 검증 (health + WS 핸드셰이크)..."
sleep 2
HEALTH=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
WS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==" \
  https://tteona.kr/ws/location)
echo "  /api/health → $HEALTH (기대 200)"
echo "  /ws/location 핸드셰이크 → $WS (기대 101)"
[ "$HEALTH" = "200" ] && [ "$WS" = "101" ] || { echo "❌ 기본 검증 실패"; exit 1; }

echo "▶ [5/6] 기존 경로 회귀 스모크 (옵션 미지정 = 기본 자막)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

# 기본 경로만 통과하면 새 분기는 한 번도 실행되지 않은 채 배포된다.
# 표시항목·색·캡션을 모두 바꾼 잡을 실제로 렌더해 drawtext 체인이 성립하는지 확인한다.
echo "▶ [6/6] 새 자막 옵션 경로 스모크 (place + mint + 캡션)..."
CLIP="$SCRIPT_DIR/assets/smoke-clip.mp4"
[ -f "$CLIP" ] || { echo "✗ 스모크 클립 없음: $CLIP"; exit 1; }

JOB=$(curl -sf --max-time 15 -X POST "$BASE/jobs" -H 'Content-Type: application/json' \
  -d '{"userId":"deploy-smoke","courseName":"__smoke_sub__","tag":"커플","bgm":"auto",
       "subtitleFields":"place","subtitleColor":"mint","caption":"오늘의 한 줄",
       "places":[{"order":0,"placeName":"smoke","shotAt":"2026.08.02  18:00"}]}' \
  | sed -E 's/.*"jobId":([0-9]+).*/\1/')
[[ "$JOB" =~ ^[0-9]+$ ]] || { echo "✗ 잡 생성 실패 (응답: $JOB)"; exit 1; }
echo "  jobId=$JOB"

curl -sf --max-time 60 -X POST "$BASE/jobs/$JOB/clips?order=0" -F "clip=@$CLIP;type=video/mp4" > /dev/null \
  || { echo "✗ 클립 업로드 실패"; exit 1; }
curl -sf --max-time 15 -X POST "$BASE/jobs/$JOB/start" > /dev/null \
  || { echo "✗ 잡 시작 실패"; exit 1; }

for i in $(seq 1 90); do
  sleep 2
  ST=$(curl -s --max-time 10 "$BASE/jobs/$JOB" || true)
  STATUS=$(echo "$ST" | sed -E 's/.*"status":"([a-z]+)".*/\1/')
  case "$STATUS" in
    completed)
      URL=$(echo "$ST" | sed -E 's/.*"outputUrl":"([^"]+)".*/\1/')
      SIZE=$(curl -sI --max-time 30 "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
      [ "${SIZE:-0}" -gt 10000 ] || { echo "✗ 완성본이 비었다: size=${SIZE:-?}"; exit 1; }
      echo "✅ 새 옵션 경로 통과: $URL (${SIZE} bytes)"
      echo
      echo "✅ 배포 완료 — 표시항목/색/캡션이 반영된 브이로그가 실제로 합성됨"
      echo "   ※ 위 URL을 직접 열어 '장소만·민트색·캡션 한 줄'로 나오는지 눈으로도 확인 권장"
      exit 0
      ;;
    failed)
      echo "✗ 새 옵션 경로 합성 실패: $ST"
      echo "  → drawtext 체인 오류 가능성. pm2 logs tteona-api 확인"
      exit 1
      ;;
  esac
done
echo "✗ 타임아웃(180초)"
exit 1
