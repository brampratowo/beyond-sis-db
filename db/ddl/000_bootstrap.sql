-- 000_bootstrap.sql — ekstensi & utilitas (PostgreSQL 16+)
CREATE EXTENSION IF NOT EXISTS pgcrypto;      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS btree_gist;    -- exclusion constraints (range tanpa overlap)

-- Skema per domain agar navigasi jelas untuk pihak ketiga
CREATE SCHEMA IF NOT EXISTS identity;   -- D1
CREATE SCHEMA IF NOT EXISTS curriculum; -- D2
CREATE SCHEMA IF NOT EXISTS delivery;   -- D3
CREATE SCHEMA IF NOT EXISTS academics;  -- D4 penilaian/rapor
CREATE SCHEMA IF NOT EXISTS quality;    -- D5 mutu pengajaran
CREATE SCHEMA IF NOT EXISTS montessori; -- D6
CREATE SCHEMA IF NOT EXISTS crm;        -- D7
CREATE SCHEMA IF NOT EXISTS finance;    -- D8
CREATE SCHEMA IF NOT EXISTS platform;   -- D9

SET search_path TO identity, curriculum, delivery, academics, quality, montessori, crm, finance, platform, public;

-- Helper: skala nilai 1-5 (aturan: 3.0 = batas kesiapan)
CREATE DOMAIN score_scale AS numeric(3,2) CHECK (value BETWEEN 1.00 AND 5.00);
-- Helper: uang rupiah
CREATE DOMAIN money AS numeric(14,2) CHECK (value >= 0);

COMMENT ON DOMAIN score_scale IS 'Skala 1-5, satu angka desimal. 3.0 = readiness threshold (program_assessment_config.readiness_min_score)';
COMMENT ON DOMAIN money IS 'Jumlah rupiah, selalu positif; arah via kolom direction/debit-credit';

-- trigger updated_at generik
CREATE FUNCTION platform.set_updated_at() RETURNS trigger AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END $$ LANGUAGE plpgsql;
