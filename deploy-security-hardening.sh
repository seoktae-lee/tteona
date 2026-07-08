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

echo "▶ [1/5] WAS: server.js 업로드 (trust proxy + 레이트리밋)..."
scp -i "$WAS_KEY" -P $PORT "$SCRIPT_DIR/server.js" $WAS_HOST:/home/ubuntu/tteona-api/server.js

echo "▶ [2/5] WAS: PM2 재시작..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST \
  "pm2 restart tteona-api && sleep 2 && pm2 logs tteona-api --nostream --lines 8"

echo "▶ [3/5] WEB: nginx 설정(XFF 보강) + 약관/처리방침 업로드..."
scp -i "$WEB_KEY" -P $PORT "$SCRIPT_DIR/tteona.nginx.conf" $WEB_HOST:/tmp/tteona.conf
scp -i "$WEB_KEY" -P $PORT \
  "$SCRIPT_DIR/web/privacy.html" \
  "$SCRIPT_DIR/web/terms.html" \
  $WEB_HOST:/var/www/tteona.kr/
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mv /tmp/tteona.conf /etc/nginx/conf.d/tteona.conf && sudo nginx -t && sudo nginx -s reload"

echo "▶ [4/5] Firestore 규칙 배포 (likeCount ±1, placeCache 쓰기잠금)..."
cd "$SCRIPT_DIR" && firebase deploy --only firestore:rules

echo "▶ [5/5] 동작 테스트..."
sleep 2
for u in "https://tteona.kr/health" "https://tteona.kr/privacy.html" "https://tteona.kr/terms.html" "https://tteona.kr/api/vlog/bgm"; do
  # /health, /api/vlog/bgm 는 인증 불필요 라우트 / privacy·terms 는 정적
  CODE=$(curl -s -o /dev/null -w "%{http_code}" "$u")
  echo "  $u → HTTP $CODE $([ "$CODE" = "200" ] && echo "✅" || echo "⚠️(인증 필요 라우트면 401 정상)")"
done

echo ""
echo "✅ 배포 완료. 확인 사항:"
echo "  · pm2 로그에 에러 없는지 (위 [2/5] 출력)"
echo "  · nginx -t 통과했는지 (위 [3/5] 출력)"
echo "  · req.ip가 실제 클라이언트 IP로 찍히는지 (관리자 로그인 몇 번 실패 후 429 확인)"
echo "  · 앱에서 좋아요 토글 정상 동작 (likeCount ±1 규칙)"
