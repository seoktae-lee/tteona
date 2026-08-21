#!/bin/bash
# 이용약관(web/terms.html) 배포 — 2026-08-21 개정
#   · 3조: 공식 큐레이션 코스 탐색을 서비스 설명에 반영
#   · 10조: TourAPI 이용 범위에 '여행코스 정보' 추가
#   · 11조 신설: 공공데이터 이용 및 출처 표기 (공공데이터포털 활용신청서상 의무)
#   · 12~16조: 번호 재정렬 (본문 상호 참조 없음을 확인함)
# 배포 전 기존 파일을 백업한다 — 약관은 이용자와의 계약 문서라 되돌릴 수 있어야 한다.
set -e

cd "$(dirname "$0")"
KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WEB_KEY="$KEYDIR/aeron-web-key.pem"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
WEB_ROOT="/var/www/tteona.kr"
BACKUP_DIR="/home/ubuntu/backups"
STAMP=$(date +%Y%m%d-%H%M%S)

echo "▶ 1/4 로컬 파일 점검"
test -f web/terms.html || { echo "  ✗ web/terms.html 없음"; exit 1; }
grep -q "공공데이터 이용 및 출처 표기" web/terms.html || { echo "  ✗ 11조(한국어)가 없음"; exit 1; }
grep -q "Public Data Use" web/terms.html          || { echo "  ✗ 11조(영어)가 없음"; exit 1; }
echo "  ✓ 개정 내용 확인"

echo "▶ 2/4 원격 백업"
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo mkdir -p $BACKUP_DIR && sudo cp $WEB_ROOT/terms.html $BACKUP_DIR/terms-$STAMP.html && ls -l $BACKUP_DIR/terms-$STAMP.html"

echo "▶ 3/4 업로드"
scp -i "$WEB_KEY" -P $PORT web/terms.html "$WEB_HOST":/tmp/terms.html
ssh -i "$WEB_KEY" -p $PORT "$WEB_HOST" \
  "sudo cp /tmp/terms.html $WEB_ROOT/terms.html && sudo chown www-data:www-data $WEB_ROOT/terms.html && sudo chmod 644 $WEB_ROOT/terms.html && rm -f /tmp/terms.html"

echo "▶ 4/4 검증"
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" https://tteona.kr/terms.html)
echo "  HTTP $CODE"
curl -s https://tteona.kr/terms.html | grep -q "공공데이터 이용 및 출처 표기" \
  && echo "  ✓ 11조(한국어) 반영 확인" || { echo "  ✗ 반영 안 됨"; exit 1; }
curl -s https://tteona.kr/terms.html | grep -q "Public Data Use" \
  && echo "  ✓ 11조(영어) 반영 확인" || { echo "  ✗ 영어판 반영 안 됨"; exit 1; }
curl -s https://tteona.kr/terms.html | grep -o "최종 개정일: [^<]*" | head -1

echo
echo "✅ 배포 완료."
echo "   되돌리려면: ssh -i \"\$WEB_KEY\" -p $PORT $WEB_HOST \"sudo cp $BACKUP_DIR/terms-$STAMP.html $WEB_ROOT/terms.html\""
