-- ═══════════════════════════════════════════════════
-- Base de données : Distributeur automatique animaux
-- À exécuter sur le RPi4 (MariaDB)
-- ═══════════════════════════════════════════════════

CREATE DATABASE IF NOT EXISTS feeder_db
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_general_ci;

USE feeder_db;

-- ─── Utilisateur dédié ───
CREATE USER IF NOT EXISTS 'feeder'@'localhost' IDENTIFIED BY 'feeder2025';
GRANT ALL PRIVILEGES ON feeder_db.* TO 'feeder'@'localhost';
FLUSH PRIVILEGES;

-- ─── Table : événements de distribution ───
-- Chaque fois que la vis sans fin distribue de la nourriture
CREATE TABLE IF NOT EXISTS feed_events (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    animal          VARCHAR(32)     NOT NULL,
    requested_g     INT             NOT NULL COMMENT 'Grammes demandés',
    distributed_g   FLOAT           NOT NULL COMMENT 'Grammes réellement distribués',
    bowl_weight_g   FLOAT           NOT NULL COMMENT 'Poids gamelle après distribution',
    feed_count      INT             NOT NULL COMMENT 'Numéro du repas',
    ts              DATETIME        NOT NULL COMMENT 'Horodatage ESP32',
    created_at      DATETIME        DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ─── Table : scans RFID ───
-- Chaque passage de badge devant le lecteur
CREATE TABLE IF NOT EXISTS rfid_scans (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    animal          VARCHAR(32)     NOT NULL,
    uid             VARCHAR(16)     NOT NULL COMMENT 'UID du badge RFID',
    ts              DATETIME        NOT NULL COMMENT 'Horodatage ESP32',
    created_at      DATETIME        DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ─── Table : poids gamelle (historique) ───
-- Permet de tracer les variations de poids dans le temps
CREATE TABLE IF NOT EXISTS bowl_weight (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    weight_g        FLOAT           NOT NULL,
    stock_percent   INT             DEFAULT 0 COMMENT 'Niveau stock croquettes %',
    ts              DATETIME        NOT NULL,
    created_at      DATETIME        DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ─── Table : erreurs système ───
CREATE TABLE IF NOT EXISTS errors (
    id              INT AUTO_INCREMENT PRIMARY KEY,
    error_type      VARCHAR(32)     NOT NULL,
    animal          VARCHAR(32)     DEFAULT NULL,
    ts              DATETIME        NOT NULL,
    created_at      DATETIME        DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ─── Index pour les requêtes Grafana ───
CREATE INDEX idx_feed_ts     ON feed_events(ts);
CREATE INDEX idx_feed_animal ON feed_events(animal);
CREATE INDEX idx_rfid_ts     ON rfid_scans(ts);
CREATE INDEX idx_rfid_animal ON rfid_scans(animal);
CREATE INDEX idx_bowl_ts     ON bowl_weight(ts);
CREATE INDEX idx_errors_ts   ON errors(ts);
