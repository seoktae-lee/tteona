#!/bin/bash
# 관리자 대시보드 확장 배포
#  - WAS: server.js — /api/admin/stats에 시스템 지표 추가 + 신규 분석 API 4종
#         (/analytics/growth·activity·content·subscription)
#  - WEB: admin/index.html — 탭 7개(개요·성장 지표·콘텐츠·PRO 구독·신고·유저·시스템) + 차트
#  선택: RevenueCat 연동은 WAS .env에 REVENUECAT_API_KEY / REVENUECAT_PROJECT_ID 추가 후 재시작
# 2026-07-16
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "▶ [1/5] WAS: server.js 업로드..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js

echo "▶ [2/5] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [3/5] WEB: admin/index.html 업로드 (백업 후 교체)..."
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo cp /var/www/tteona.kr/admin/index.html /var/www/tteona.kr/admin/index.html.bak-\$(date +%Y%m%d-%H%M%S)"
scp -i "$WEB_KEY" -P $PORT "$SCRIPT_DIR/admin/index.html" $WEB_HOST:/tmp/admin-index.html
scp -i "$WEB_KEY" -P $PORT "$SCRIPT_DIR/admin/tteona.png" $WEB_HOST:/tmp/admin-tteona.png
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/admin-index.html /var/www/tteona.kr/admin/index.html && sudo mv /tmp/admin-tteona.png /var/www/tteona.kr/admin/tteona.png"

echo "▶ [4/5] 검증 (무인)..."
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/health)
echo "  /api/health → HTTP $CODE $([ "$CODE" = "200" ] && echo ✅ || echo ❌)"
# 신규 분석 API도 무인증이면 전부 401이어야 함
for EP in stats analytics/growth analytics/activity analytics/content analytics/subscription; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/api/admin/$EP)
  echo "  무인증 admin/$EP → HTTP $CODE $([ "$CODE" = "401" ] && echo ✅ || echo ❌)"
done
# WS 프록시 생존 확인 (재배포 후 101 확인은 상시 수칙)
WS=$(curl -s -o /dev/null -w "%{http_code}" -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Sec-WebSocket-Version: 13" -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://tteona.kr/ws/location)
echo "  /ws/location 업그레이드 → HTTP $WS $([ "$WS" = "101" ] && echo ✅ || echo "❌ (/ws/ 블록 확인!)")"

echo "▶ [5/5] 검증 (선택 — 실제 로그인 E2E)..."
read -r -s -p "  관리자 비밀번호 (엔터만 치면 건너뜀): " ADMIN_PW; echo
if [ -n "$ADMIN_PW" ]; then
  TOKEN=$(curl -s -X POST https://tteona.kr/api/admin/login \
    -H "Content-Type: application/json" -d "{\"password\":\"$ADMIN_PW\"}" |
    python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")
  if [ -z "$TOKEN" ]; then echo "  로그인 실패 ❌"; exit 1; fi
  echo "  로그인 → 세션 토큰 발급 ✅ (${TOKEN:0:8}…)"
  for EP in stats analytics/growth analytics/activity analytics/content analytics/subscription; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/$EP)
    echo "  admin/$EP → HTTP $CODE $([ "$CODE" = "200" ] && echo ✅ || echo ❌)"
  done
  # 응답 샘플 확인
  echo "  growth 응답 샘플:"
  curl -s -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/analytics/growth |
    python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"    totalUsers={d['totalUsers']} newToday={d['newToday']} monthly={len(d['monthly'])}개월 langDist={[(r['lang'],r['count']) for r in d['langDist']]}\")"
  curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" https://tteona.kr/api/admin/logout
fi

echo ""
echo "✅ 배포 완료. https://tteona.kr/admin/ 에서 확인하세요."
echo "  · PRO 구독 지표를 보려면 WAS .env에 REVENUECAT_API_KEY(v2 secret)·REVENUECAT_PROJECT_ID 추가 후 pm2 restart"
echo "  · 언어 분포는 userPrivate.lang(푸시 등록 시 수집) 기준 — 푸시 미등록 유저는 '미상'으로 잡힘"
