#!/bin/bash
# map-api를 WEB 서버(Docker)에 배포한다. 실패하면 직전 이미지로 되돌린다.
#
# 사용법(map-api 폴더에서):  WEB_KEY=<web pem 경로> deploy/deploy.sh
# 전제: 서버 ~/map-api/.env 가 이미 있다(KAKAO_REST_KEY, DB_PASSWORD, FIREBASE_PROJECT_ID, MAPAPI_TAG). 비밀 값은 이 스크립트가 다루지 않는다.
set -euo pipefail

: "${WEB_KEY:?WEB_KEY(웹 서버 pem 경로)를 지정할 것}"
WEB_HOST="ubuntu@114.110.182.45"
PORT=30022
SSH=(ssh -i "$WEB_KEY" -p "$PORT" -o BatchMode=yes "$WEB_HOST")

[ -z "$(git status --porcelain -- .)" ] || { echo "❌ 커밋하지 않은 변경이 있다. 배포 버전은 커밋으로 추적한다."; exit 1; }
TAG=$(git rev-parse --short HEAD)
echo "▶ 배포 버전: $TAG"

echo "▶ 테스트 + jar 빌드"
./gradlew test bootJar --no-daemon -q

PKG=$(mktemp -t mapapi).tgz
COPYFILE_DISABLE=1 tar czf "$PKG" Dockerfile build/libs/map-api-0.0.1-SNAPSHOT.jar data deploy/compose.prod.yaml
scp -q -i "$WEB_KEY" -P "$PORT" -o BatchMode=yes "$PKG" "$WEB_HOST:/tmp/mapapi.tgz"
rm -f "$PKG"

echo "▶ 서버에서 이미지 빌드 + 교체"
"${SSH[@]}" bash -s "$TAG" <<'REMOTE'
set -euo pipefail
TAG=$1
cd ~/map-api
PREV=$(grep '^MAPAPI_TAG=' .env | cut -d= -f2)
tar xzf /tmp/mapapi.tgz 2>/dev/null && rm /tmp/mapapi.tgz
cp deploy/compose.prod.yaml compose.yaml
DOCKER_BUILDKIT=0 sudo docker build -q -t "tteona/map-api:$TAG" . >/dev/null
sed -i "s/^MAPAPI_TAG=.*/MAPAPI_TAG=$TAG/" .env
if sudo docker compose up -d --wait --wait-timeout 120 >/tmp/mapapi-up.log 2>&1 \
   && curl -fs -o /dev/null http://127.0.0.1:8081/tiles/16/55898/25384.mvt; then
  echo "  ✅ $TAG 정상 (직전: $PREV)"
else
  echo "  ❌ $TAG 기동 실패 → $PREV 로 되돌림"; tail -5 /tmp/mapapi-up.log
  sed -i "s/^MAPAPI_TAG=.*/MAPAPI_TAG=$PREV/" .env
  sudo docker compose up -d --wait --wait-timeout 120
  exit 1
fi
# 직전 버전 하나만 남기고 오래된 이미지는 지운다(디스크 30GB 서버).
# 지울 이미지가 없으면 grep이 1을 돌려주므로 || true (set -e로 여기서 멈추던 문제).
{ sudo docker images tteona/map-api --format '{{.Tag}}' | grep -vxE "$TAG|$PREV" || true; } | xargs -r -I{} sudo docker rmi -f "tteona/map-api:{}" >/dev/null
REMOTE

echo "▶ 외부 확인"
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }
[ "$(code https://tteona.kr/map-api/tiles/16/55898/25384.mvt)" = 200 ] || { echo "❌ 타일 외부 응답 이상"; exit 1; }
[ "$(code 'https://tteona.kr/map-api/places/keyword?query=a')" = 401 ] || { echo "❌ 장소 검색이 토큰 없이 401이 아님(인증 확인 필요)"; exit 1; }
[ "$(code https://tteona.kr/api/health)" = 200 ] || { echo "❌ 기존 Node API 이상"; exit 1; }
echo "  ✅ 타일 200 · 무토큰 401 · Node 200"
echo "완료: tteona/map-api:$TAG"
