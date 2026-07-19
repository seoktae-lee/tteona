#!/bin/bash
# WAS .env에 누락된 API 키 3종(ODSAY_KEY / KAKAO_REST_KEY / TOUR_API_KEY) 복구
#
# 배경: e8e70f1 커밋에서 하드코딩 키를 env 방식으로 전환했지만 서버 .env에는
# 키를 넣지 않아 대중교통 경로(ODsay)·관광공사 사진(TourAPI)이 죽어 있었음 (2026-07-19 발견).
# 키 값 원본은 git 히스토리(e8e70f1 직전 버전)에 남아 있어 거기서 추출한다.
# 값은 화면에 마스킹되어 표시되고, 서버 .env에만 기록됨.
set -e

cd "$(dirname "$0")"
KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS="ubuntu@114.110.181.49"
PORT=30022
ENV_FILE=/home/ubuntu/tteona-api/.env

SRC=$(mktemp)
trap 'rm -f "$SRC"' EXIT
git show e8e70f1^:server.js > "$SRC"

# const KEY = process.env.KEY || 'value'; 형태에서 value 추출 (줄바꿈 이어짐 허용)
extract() {
  local key="$1"
  tr '\n' ' ' < "$SRC" | grep -oE "const $key = process\.env\.$key[[:space:]]*\|\|[[:space:]]*'[^']+'" \
    | sed -E "s/.*'([^']+)'/\1/" | head -1
}

PAYLOAD=""
for KEY in ODSAY_KEY KAKAO_REST_KEY TOUR_API_KEY; do
  VAL=$(extract "$KEY" || true)
  if [ -z "$VAL" ] && [ "$KEY" = "KAKAO_REST_KEY" ]; then
    # 폴백: 현재 iOS 소스의 카카오 REST 키
    VAL=$(grep -oE 'kakaoAPIKey = "[a-f0-9]+"' tteona/Core/Services/PlaceSearchService.swift | sed -E 's/.*"([a-f0-9]+)"/\1/' | head -1)
  fi
  if [ -n "$VAL" ]; then
    echo "  $KEY: 발견 (${VAL:0:4}****, ${#VAL}자)"
    PAYLOAD="$PAYLOAD$KEY=$VAL"$'\n'
  else
    echo "  ⚠️ $KEY: git 히스토리에서 못 찾음 — 발급처에서 직접 확인 필요"
  fi
done

[ -z "$PAYLOAD" ] && { echo "복구할 키 없음, 중단"; exit 1; }

echo "▶ WAS .env에 누락분만 추가 + PM2 재시작..."
printf '%s' "$PAYLOAD" | ssh -i "$WAS_KEY" -p $PORT "$WAS" '
  set -e
  while IFS= read -r line; do
    k="${line%%=*}"
    grep -q "^$k=" '"$ENV_FILE"' || { echo "$line" >> '"$ENV_FILE"'; echo "  추가됨: $k"; }
  done
  chmod 600 '"$ENV_FILE"'
  cd /home/ubuntu/tteona-api && pm2 restart tteona-api --update-env >/dev/null
  sleep 3
  pm2 list | grep tteona-api
  echo "--- 등록된 키 목록 ---"
  cut -d= -f1 '"$ENV_FILE"'
'

echo ""
echo "▶ 검증: 30초 뒤 에러 로그에 ODsay/TourAPI 키 에러가 더 안 찍히는지 확인"
sleep 5
ssh -i "$WAS_KEY" -p $PORT "$WAS" 'curl -s -o /dev/null -w "health=%{http_code}\n" http://localhost:3000/health; tail -3 /home/ubuntu/.pm2/logs/tteona-api-error.log'
echo ""
echo "✅ 완료. 앱에서 탐색 상세 → 대중교통 경로/장소 사진이 뜨는지 확인하세요."
