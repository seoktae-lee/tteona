#!/bin/bash
# PostgreSQL 야간 백업 구축 (1회 실행하면 크론까지 등록됨)
#
# 구조: WAS 서버(114.110.181.49)에서 매일 03:30 원격 pg_dump로 DB 서버(10.30.10.170)를 덤프.
#  - 백업이 DB 서버 "밖"(WAS 디스크)에 쌓이므로 DB 서버 디스크 유실 시에도 백업 생존
#  - WAS는 이미 PG 자격증명(.env)과 5432 접근권을 갖고 있어 새 SSH 신뢰관계 불필요
#  - 커스텀 포맷(-Fc) 덤프 + pg_restore --list 무결성 확인 + 14일 보존
# 2026-07-14
set -e

KEYDIR="$HOME/Downloads/2026 클라우드 인프라 지원 사업 선정/260701/에어론 펨키"
WAS_KEY="$KEYDIR/aeron-was-key.pem"
WAS_HOST="ubuntu@114.110.181.49"
PORT=30022

echo "▶ WAS 서버에 백업 스크립트 + 크론 설치..."
ssh -i "$WAS_KEY" -p $PORT $WAS_HOST 'bash -s' <<'REMOTE'
set -e

# 1) pg_dump 준비 (postgresql-client)
if ! command -v pg_dump >/dev/null 2>&1; then
  echo "  postgresql-client 설치 중..."
  sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client
fi
echo "  pg_dump: $(pg_dump --version)"

# 2) 백업 스크립트 설치
mkdir -p /home/ubuntu/backups/pg
cat > /home/ubuntu/backups/pg-backup.sh <<'SCRIPT'
#!/bin/bash
# tteona PG 야간 백업 — 크론이 매일 03:30에 실행
set -e
ENV_FILE=/home/ubuntu/tteona-api/.env
export PGPASSWORD="$(grep '^PG_PASSWORD=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")"
PG_HOST_V="$(grep '^PG_HOST=' "$ENV_FILE" | cut -d= -f2- || true)"; PG_HOST_V=${PG_HOST_V:-10.30.10.170}
PG_USER_V="$(grep '^PG_USER=' "$ENV_FILE" | cut -d= -f2- || true)"; PG_USER_V=${PG_USER_V:-tteona}
PG_DB_V="$(grep '^PG_DB=' "$ENV_FILE" | cut -d= -f2- || true)";   PG_DB_V=${PG_DB_V:-tteona_db}

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="/home/ubuntu/backups/pg/tteona-$STAMP.dump"

if pg_dump -h "$PG_HOST_V" -U "$PG_USER_V" -d "$PG_DB_V" -Fc -f "$OUT" \
   && pg_restore --list "$OUT" >/dev/null; then
  echo "$(date -Is) OK $OUT $(du -h "$OUT" | cut -f1)"
  # 성공한 뒤에만 14일 지난 백업 정리 (연속 실패 시 마지막 성공본 보존)
  find /home/ubuntu/backups/pg -name 'tteona-*.dump' -mtime +14 -delete
else
  echo "$(date -Is) FAIL $OUT"
  rm -f "$OUT"
  exit 1
fi
SCRIPT
chmod 700 /home/ubuntu/backups/pg-backup.sh
chmod 700 /home/ubuntu/backups/pg

# 3) 크론 등록 (기존 등록 제거 후 재등록 — 중복 방지)
( crontab -l 2>/dev/null | grep -v 'pg-backup.sh' ; \
  echo "30 3 * * * /home/ubuntu/backups/pg-backup.sh >> /home/ubuntu/backups/pg/backup.log 2>&1" ) | crontab -
echo "  크론 등록 완료:"
crontab -l | grep pg-backup

# 4) 즉시 1회 실행하여 관통 검증
echo "  첫 백업 실행 중..."
/home/ubuntu/backups/pg-backup.sh
echo "  백업 파일:"
ls -lh /home/ubuntu/backups/pg/*.dump | tail -3
REMOTE

echo ""
echo "✅ PG 야간 백업 구축 완료 (매일 03:30, 14일 보존, WAS:/home/ubuntu/backups/pg/)"
echo "  복원 방법: pg_restore -h 10.30.10.170 -U tteona -d tteona_db --clean <덤프파일>"
echo "  점검 방법: ssh WAS 후 tail /home/ubuntu/backups/pg/backup.log (OK 줄이 매일 찍히는지)"
