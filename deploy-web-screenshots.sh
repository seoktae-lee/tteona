#!/bin/bash
# 2026-09-05 tteona.kr 웹 갱신
#  - 장면 카드 스크린샷을 스토어 등록용 최신 화면(shot-*.jpg 5종)으로 교체
#  - App Store / Google Play 버튼 동일 규격 (index/course/room)
#  - 모바일 여정 세로 스택 전환 (카드 겹침 해결)
#
# WAS/nginx는 건드리지 않는다 — /var/www/tteona.kr 정적 파일만 교체한다.
# 백업은 웹 루트 바깥(/home/ubuntu/web-backups)에 둔다.
set -euo pipefail

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_SRC="$HOME/Documents/tteona-web"
WEB_ROOT="/var/www/tteona.kr"
BACKUP_DIR="/home/ubuntu/web-backups"
STAMP=$(date +%Y%m%d-%H%M%S)

PAGES=(index.html course.html room.html)
SHOTS=(shot-course.jpg shot-capture.jpg shot-explore.jpg shot-format.jpg shot-caption.jpg)
ALL=("${PAGES[@]}" "${SHOTS[@]}")

cd "$WEB_SRC"

echo "▶ [0/5] 로컬 검사..."
for f in "${ALL[@]}"; do test -f "$f" || { echo "  ✗ 누락: $f"; exit 1; }; done
for f in "${SHOTS[@]}"; do
  grep -q "$f" index.html || { echo "  ✗ index.html이 $f 를 참조하지 않음"; exit 1; }
done
grep -q 'app-course.png\|app-map.png' index.html && { echo "  ✗ 구버전 스크린샷 참조가 남아있음"; exit 1; }
echo "  파일 ${#ALL[@]}개 · 스크린샷 참조 확인"

echo "▶ [1/5] 배포 꾸러미 생성..."
tar czf /tmp/web-shots-deploy.tgz "${ALL[@]}"
tar tzf /tmp/web-shots-deploy.tgz | sed 's/^/  /'

echo "▶ [2/5] WEB: 기존 파일 백업 (웹 루트 바깥)..."
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "mkdir -p $BACKUP_DIR && chmod 700 $BACKUP_DIR && cd $WEB_ROOT && \
   sudo tar czf $BACKUP_DIR/web-shots-$STAMP.tgz ${PAGES[*]} && \
   sudo chown ubuntu:ubuntu $BACKUP_DIR/web-shots-$STAMP.tgz && \
   ls -la $BACKUP_DIR/web-shots-$STAMP.tgz"

echo "▶ [3/5] WEB: 업로드 + 전개..."
scp -i "$WEB_KEY" -P $PORT /tmp/web-shots-deploy.tgz "$WEB_HOST":/tmp/
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo tar xzf /tmp/web-shots-deploy.tgz -C $WEB_ROOT && \
   sudo chown www-data:www-data ${ALL[*]/#/$WEB_ROOT/} && \
   sudo chmod 644 ${ALL[*]/#/$WEB_ROOT/} && \
   rm -f /tmp/web-shots-deploy.tgz && \
   ls -la ${SHOTS[*]/#/$WEB_ROOT/}"
rm -f /tmp/web-shots-deploy.tgz

echo "▶ [4/5] 검증 (HTTP)..."
fail=0
for f in "${SHOTS[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://tteona.kr/$f")
  echo "  $f → $code"; [ "$code" = "200" ] || fail=1
done
for f in "${PAGES[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "https://tteona.kr/$f")
  echo "  $f → $code"; [ "$code" = "200" ] || fail=1
done
curl -s "https://tteona.kr/index.html" | grep -q 'shot-explore.jpg' \
  && echo "  index.html 최신 스크린샷 참조 OK" || { echo "  ✗ index.html이 구버전"; fail=1; }

echo "▶ [5/5] 결과"
if [ $fail -eq 0 ]; then
  echo "  ✅ 배포 완료"
else
  echo "  ⚠️ 검증 실패 — 롤백:"
  echo "   ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo tar xzf $BACKUP_DIR/web-shots-$STAMP.tgz -C $WEB_ROOT\""
  exit 1
fi
