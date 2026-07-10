#!/bin/bash
# Vlog 파이프라인 E2E 스모크 테스트
# 잡 생성 → 클립 업로드 → 합성(BGM 믹스 포함) → 완성본 다운로드(nginx /uploads 프록시 경유)까지
# 실제 유저 경로 전체를 관통 검증한다. 배포 스크립트 마지막 단계에서 호출 — 실패 시 exit 1.
#
# 테스트 잡(user_id=deploy-smoke)의 파일·DB 행은 서버 정리 크론이 1시간 후 자동 삭제한다.
# ※ 완화 모드(AUTH_ENFORCE=false) 전제 — 인증을 강제로 켜면 Firebase 토큰 발급을 추가해야 한다.
set -e

BASE="https://tteona.kr/api/vlog"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLIP="$SCRIPT_DIR/assets/smoke-clip.mp4"

[ -f "$CLIP" ] || { echo "✗ 스모크 클립 없음: $CLIP"; exit 1; }

echo "▶ 스모크: 잡 생성..."
JOB=$(curl -sf --max-time 15 -X POST "$BASE/jobs" -H 'Content-Type: application/json' \
  -d '{"userId":"deploy-smoke","courseName":"__smoke__","tag":"커플","bgm":"auto","places":[{"order":0,"placeName":"smoke"}]}' \
  | sed -E 's/.*"jobId":([0-9]+).*/\1/')
[[ "$JOB" =~ ^[0-9]+$ ]] || { echo "✗ 잡 생성 실패 (응답: $JOB)"; exit 1; }
echo "  jobId=$JOB"

echo "▶ 스모크: 클립 업로드 + 시작..."
curl -sf --max-time 60 -X POST "$BASE/jobs/$JOB/clips?order=0" -F "clip=@$CLIP;type=video/mp4" > /dev/null \
  || { echo "✗ 클립 업로드 실패"; exit 1; }
curl -sf --max-time 15 -X POST "$BASE/jobs/$JOB/start" > /dev/null \
  || { echo "✗ 잡 시작 실패"; exit 1; }

echo "▶ 스모크: 합성 대기 (최대 180초)..."
for i in $(seq 1 90); do
  sleep 2
  ST=$(curl -s --max-time 10 "$BASE/jobs/$JOB" || true)
  STATUS=$(echo "$ST" | sed -E 's/.*"status":"([a-z]+)".*/\1/')
  case "$STATUS" in
    completed)
      URL=$(echo "$ST" | sed -E 's/.*"outputUrl":"([^"]+)".*/\1/')
      CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$URL")
      SIZE=$(curl -sI --max-time 30 "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}')
      if [ "$CODE" = "200" ] && [ "${SIZE:-0}" -gt 10000 ]; then
        echo "✅ 스모크 통과: $URL (${SIZE} bytes, ${i}회 폴링)"
        exit 0
      fi
      echo "✗ 완성본 다운로드 실패: HTTP $CODE, size=${SIZE:-?} ($URL)"
      echo "  → nginx /uploads 프록시 또는 WAS 정적 서빙 확인 필요"
      exit 1
      ;;
    failed)
      echo "✗ 서버 합성 실패: $ST"
      exit 1
      ;;
  esac
done
echo "✗ 타임아웃(180초) — 대기열이 밀렸거나 워커가 멈춤. /api/health 확인 필요"
exit 1
