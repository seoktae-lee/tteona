#!/bin/bash
# 보안 하드닝 배포: trust proxy + API 레이트리밋 + Firestore 규칙(likeCount ±1, placeCache 잠금)
#                 + 약관/처리방침 개정(구독조항·국외이전·보호책임자) + nginx XFF 보강
# 2026-07-08
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── nginx conf 덮어쓰기 안전장치 ────────────────────────────────────────────
# 아래 scp+mv 는 라이브 conf를 저장소 사본으로 통째로 교체한다. 사본이 뒤처져 있으면
# 라이브에만 있는 블록(/ws/ 등)이 조용히 사라진다. 실제로 /ws/ 가 날아가 채팅·위치공유가
# 끊긴 사고가 있었다. nginx -t 는 이걸 못 잡는다 — 블록이 통째로 없어져도 "문법은 정상"이라
# 통과하기 때문이다. 그래서 덮어쓰기 전에 내용 손실 여부를 직접 비교한다.
nginx_overwrite_guard() {
  local live="$(mktemp)"
  ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" "sudo cat /etc/nginx/conf.d/tteona.conf" > "$live"
  [ -s "$live" ] || { echo "❌ 라이브 nginx conf를 읽지 못했다 — 중단"; rm -f "$live"; exit 1; }
  local lost
  lost=$(diff "$SCRIPT_DIR/tteona.nginx.conf" "$live" | grep '^>' || true)
  if [ -n "$lost" ]; then
    echo "❌ 덮어쓰면 라이브에만 있는 아래 설정이 사라진다:"
    echo "$lost" | sed 's/^/     /'
    echo ""
    echo "   저장소 사본이 라이브보다 뒤처져 있다. 먼저 동기화할 것:"
    echo "     ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo cat /etc/nginx/conf.d/tteona.conf\" > \"$SCRIPT_DIR/tteona.nginx.conf\""
    echo "   내용을 확인하고 커밋한 뒤 이 스크립트를 다시 실행할 것."
    rm -f "$live"; exit 1
  fi
  rm -f "$live"
  echo "  ✅ 손실되는 설정 없음 — 덮어쓰기 진행"
}
# ───────────────────────────────────────────────────────────────────────────

echo "▶ [1/6] WAS: server.js 업로드 (trust proxy + 레이트리밋)..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js

echo "▶ [2/6] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [3/6] WEB: nginx 설정(XFF 보강) + 약관/처리방침 업로드..."
nginx_overwrite_guard
scp -i "$WEB_KEY" -P $PORT "$SCRIPT_DIR/tteona.nginx.conf" $WEB_HOST:/tmp/tteona.conf
scp -i "$WEB_KEY" -P $PORT \
  "$SCRIPT_DIR/web/privacy.html" \
  "$SCRIPT_DIR/web/terms.html" \
  $WEB_HOST:/var/www/tteona.kr/
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/tteona.conf /etc/nginx/conf.d/tteona.conf && sudo nginx -t && sudo nginx -s reload"

echo "▶ [4/6] Firestore 규칙 배포 (likeCount ±1, placeCache 쓰기잠금)..."
cd "$SCRIPT_DIR" && firebase deploy --only firestore:rules

echo "▶ [5/6] 동작 테스트..."
sleep 2
for u in "https://tteona.kr/api/health" "https://tteona.kr/privacy.html" "https://tteona.kr/terms.html" "https://tteona.kr/api/vlog/bgm"; do
  # /api/health, /api/vlog/bgm 는 인증 불필요 라우트 / privacy·terms 는 정적
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "  $u → HTTP $CODE $([ "$CODE" = "200" ] && echo "✅" || echo "⚠️(인증 필요 라우트면 401 정상)")"
done

echo "▶ [6/6] Vlog E2E 스모크 테스트 (잡 생성→합성→완성본 다운로드 관통)..."
"$SCRIPT_DIR/smoke-test-vlog.sh"

echo ""
echo "✅ 배포 완료. 확인 사항:"
echo "  · pm2 로그에 에러 없는지 (위 [2/6] 출력)"
echo "  · nginx -t 통과했는지 (위 [3/6] 출력)"
echo "  · req.ip가 실제 클라이언트 IP로 찍히는지 (관리자 로그인 몇 번 실패 후 429 확인)"
echo "  · 앱에서 좋아요 토글 정상 동작 (likeCount ±1 규칙)"
