#!/bin/bash
# 2026-07-19 Android App Links 도메인 검증 수정
#  - WEB: /var/www/tteona.kr/.well-known/assetlinks.json 신규 배포
#    Play Console 딥링크 탭의 "도메인 검사 실패"(tteona.kr) 해소용.
#    지문 3개 = Play 앱 서명 키 / 업로드 키 / debug 키(로컬 테스트용, 패키지 suffix 없음).
#
# nginx는 건드리지 않는다 — .well-known은 기존 정적 루트로 이미 서빙됨(AASA가 200으로 증명).
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_SRC="$HOME/Documents/tteona-web"

echo "▶ [1/3] 로컬 JSON 문법 검사..."
python3 -c "import json,sys; json.load(open('$WEB_SRC/.well-known/assetlinks.json'))"

echo "▶ [2/3] 업로드..."
scp -i "$WEB_KEY" -P $PORT "$WEB_SRC/.well-known/assetlinks.json" $WEB_HOST:/tmp/assetlinks.json
ssh -i "$WEB_KEY" -p $PORT $WEB_HOST \
  "sudo mkdir -p /var/www/tteona.kr/.well-known && \
   sudo mv /tmp/assetlinks.json /var/www/tteona.kr/.well-known/assetlinks.json && \
   sudo chown www-data:www-data /var/www/tteona.kr/.well-known/assetlinks.json && \
   sudo chmod 644 /var/www/tteona.kr/.well-known/assetlinks.json"

echo "▶ [3/3] 공개 URL 검증..."
URL="https://tteona.kr/.well-known/assetlinks.json"
CODE=$(curl -s -o /tmp/al.json -w "%{http_code}" "$URL")
CTYPE=$(curl -s -o /dev/null -w "%{content_type}" "$URL")
echo "   $URL → $CODE ($CTYPE)"
[ "$CODE" = "200" ] || { echo "❌ 200이 아님"; exit 1; }
case "$CTYPE" in application/json*) ;; *) echo "⚠️  Content-Type이 application/json이 아님 — Google 검증이 거부할 수 있음";; esac
python3 -c "import json; d=json.load(open('/tmp/al.json')); print('   ✅ 지문', len(d[0]['target']['sha256_cert_fingerprints']), '개 게시됨')"

echo
echo "✅ 배포 완료. Google 측 검증 요청:"
echo "   https://digitalassetlinks.googleapis.com/v1/statements:list?source.web.site=https://tteona.kr&relation=delegate_permission/common.handle_all_urls"
echo "   Play Console 딥링크 탭 상태 갱신은 최대 며칠 걸릴 수 있음(캐시)."
