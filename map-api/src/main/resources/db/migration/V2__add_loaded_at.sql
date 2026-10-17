-- 이미 실행된 V1은 고치지 않고, 변경은 새 버전 파일로 쌓는다.
-- 언제 적재된 행인지 남긴다. 기존 행에는 이 마이그레이션이 실행된 시각이 들어간다.
ALTER TABLE buildings ADD COLUMN loaded_at TIMESTAMPTZ NOT NULL DEFAULT now();
