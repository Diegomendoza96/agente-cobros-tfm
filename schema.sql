-- =====================================================================
-- AGENTE DE COBROS - Recreación con PostgreSQL (sustituye Snowflake)
-- Diego Mendoza - TFM
-- =====================================================================
-- Dos schemas separados, replicando la arquitectura del TFM:
--   1) warehouse   -> simula la vista Customer_ledger_view de Snowflake
--                     (fuente de verdad, solo lectura desde n8n)
--   2) credit_ops  -> tablas operativas que en el PoC vivían en Google
--                     Sheets (credit_cases, email_threads, thread_case_map,
--                     agent_action_log, closed_threads)
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto; -- para gen_random_uuid()

-- =====================================================================
-- SCHEMA: warehouse (fuente de verdad - simula Snowflake)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS warehouse;

CREATE TABLE warehouse.customer_ledger_view (
    -- Detalles del documento
    document_number      VARCHAR(50)  NOT NULL,
    document_type        VARCHAR(50)  NOT NULL,  -- Invoices / Credit Notes / Chargebacks / R1-A/R Drafts
    record_type          VARCHAR(50),
    invoice_date         DATE         NOT NULL,
    due_date             DATE         NOT NULL,
    days_past_due_date   INTEGER      NOT NULL,  -- negativo = aún no vence
    open_amount          NUMERIC(12,2) NOT NULL,
    total_amount         NUMERIC(12,2) NOT NULL,

    -- Info. de contacto
    punto_contacto_owner       VARCHAR(150),
    punto_contacto_owner_email VARCHAR(150),
    punto_contacto_payer       VARCHAR(150),
    billing_address             VARCHAR(50)  NOT NULL,
    punto_de_entrega             VARCHAR(150),

    -- Acciones / incidencias
    comment                              TEXT,
    comment_type                         VARCHAR(30), -- Comment / Estado de gestión / Incidence / NULL
    incidence_number                     VARCHAR(50),
    last_incidence_management_status     VARCHAR(100),
    date_updated                         TIMESTAMP DEFAULT now(),

    -- Campo de segmentación (para poder filtrar Customer_Group = 'SIN' como en el TFM)
    customer_group VARCHAR(20) NOT NULL DEFAULT 'SIN',

    PRIMARY KEY (billing_address, document_number, document_type)
);

CREATE INDEX idx_ledger_days_past_due ON warehouse.customer_ledger_view (days_past_due_date);
CREATE INDEX idx_ledger_billing       ON warehouse.customer_ledger_view (billing_address);
CREATE INDEX idx_ledger_customer_grp  ON warehouse.customer_ledger_view (customer_group);

COMMENT ON TABLE warehouse.customer_ledger_view IS
  'Simula la vista Customer_ledger_view de Snowflake. Solo lectura desde el flujo de n8n (WF01).';

-- =====================================================================
-- SCHEMA: credit_ops (tablas operativas - antes en Google Sheets)
-- =====================================================================
CREATE SCHEMA IF NOT EXISTS credit_ops;

-- 1) credit_cases: detalle y estado por documento
CREATE TABLE credit_ops.credit_cases (
    case_key            VARCHAR(150) PRIMARY KEY, -- billing_address + document_number + document_type
    billing_address     VARCHAR(50)  NOT NULL,
    payer_label         VARCHAR(150),
    payer_email         VARCHAR(150),
    owner_name          VARCHAR(150),
    owner_email         VARCHAR(150),
    document_number     VARCHAR(50)  NOT NULL,
    document_type       VARCHAR(50)  NOT NULL,
    invoice_date        DATE,
    due_date            DATE,
    days_past_due       INTEGER,
    aging_bucket        VARCHAR(20), -- Not due / 0-15 / 16-30 / 31-60 / 60+
    open_amount         NUMERIC(12,2),
    total_amount        NUMERIC(12,2),
    record_type         VARCHAR(50),

    -- Estado de seguimiento (fuente principal: email_threads, pero se cachea aquí)
    status_followup     VARCHAR(30) DEFAULT 'NEW', -- NEW / WAITING_REPLY / REPLIED / CLOSED
    thread_id           VARCHAR(100),

    -- Resultado de la última clasificación LLM
    last_classification VARCHAR(50),
    last_confidence     NUMERIC(5,2),
    routing_team        VARCHAR(50), -- AR_CREDITS / SALES_OWNER / BACKOFFICE / UNKNOWN
    next_action         VARCHAR(30), -- WAIT / FOLLOWUP / ESCALATE / CLOSE / REQUEST_INFO
    last_comment        TEXT,
    last_status_code    VARCHAR(50),

    created_at          TIMESTAMP DEFAULT now(),
    updated_at          TIMESTAMP DEFAULT now(),
    is_active           BOOLEAN DEFAULT TRUE
);

CREATE INDEX idx_cases_billing  ON credit_ops.credit_cases (billing_address);
CREATE INDEX idx_cases_status   ON credit_ops.credit_cases (status_followup);
CREATE INDEX idx_cases_thread   ON credit_ops.credit_cases (thread_id);

-- 2) email_threads: estado operativo del hilo de comunicación
CREATE TABLE credit_ops.email_threads (
    thread_id           VARCHAR(100) PRIMARY KEY, -- REF-<billing_address>-<timestamp>
    billing_address     VARCHAR(50) NOT NULL,
    payer_label         VARCHAR(150),
    payer_email         VARCHAR(150),
    owner_email         VARCHAR(150),

    status_followup     VARCHAR(30) DEFAULT 'NEW', -- NEW / WAITING_REPLY / REPLIED / CLOSED
    followup_count      INTEGER DEFAULT 0,
    next_followup_at    DATE,

    last_message_id     VARCHAR(150),
    last_direction       VARCHAR(10), -- OUTBOUND / INBOUND
    last_outbound_at    TIMESTAMP,
    last_inbound_at     TIMESTAMP,
    last_inbound_from   VARCHAR(150),
    subject_normalized  TEXT,
    lock_until          TIMESTAMP,

    created_at          TIMESTAMP DEFAULT now(),
    updated_at          TIMESTAMP DEFAULT now()
);

CREATE INDEX idx_threads_status_nextfu ON credit_ops.email_threads (status_followup, next_followup_at);
CREATE INDEX idx_threads_billing       ON credit_ops.email_threads (billing_address);

-- 3) thread_case_map: puente hilo <-> documentos (N:M)
CREATE TABLE credit_ops.thread_case_map (
    thread_id   VARCHAR(100) NOT NULL REFERENCES credit_ops.email_threads(thread_id),
    case_key    VARCHAR(150) NOT NULL REFERENCES credit_ops.credit_cases(case_key),
    is_active   BOOLEAN DEFAULT TRUE,
    created_at  TIMESTAMP DEFAULT now(),
    updated_at  TIMESTAMP DEFAULT now(),
    PRIMARY KEY (thread_id, case_key)
);

-- 4) agent_action_log: auditoría append-only de acciones del agente
CREATE TABLE credit_ops.agent_action_log (
    event_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_timestamp   TIMESTAMP DEFAULT now(),
    run_id            VARCHAR(100), -- execution id de n8n
    scope             VARCHAR(10) CHECK (scope IN ('THREAD','CASE')),
    thread_id         VARCHAR(100),
    case_key          VARCHAR(150),
    action_type       VARCHAR(50), -- contact_1 / followup_n / classify_reply / reply_sent / close_thread
    status_before     VARCHAR(30),
    status_after      VARCHAR(30),
    result            VARCHAR(20) CHECK (result IN ('OK','ERROR','SKIPPED')),
    idempotency_key   VARCHAR(150),
    error_detail      TEXT,
    payload_ref       TEXT
);

CREATE INDEX idx_log_thread ON credit_ops.agent_action_log (thread_id);
CREATE INDEX idx_log_case   ON credit_ops.agent_action_log (case_key);
CREATE UNIQUE INDEX idx_log_idempotency ON credit_ops.agent_action_log (idempotency_key)
  WHERE idempotency_key IS NOT NULL;

-- 5) closed_threads: histórico de cierres a nivel hilo/payer
CREATE TABLE credit_ops.closed_threads (
    thread_id               VARCHAR(100) PRIMARY KEY REFERENCES credit_ops.email_threads(thread_id),
    billing_address         VARCHAR(50),
    payer_label             VARCHAR(150),
    closed_reason           VARCHAR(50), -- CLIENT_CONFIRMED_PAID / LEDGER_PAID_OPEN_AMOUNT_0 / NO_RESPONSE_5 / MOVED_TO_MANUAL
    closed_at               TIMESTAMP DEFAULT now(),
    followup_count          INTEGER,
    last_open_amount_total  NUMERIC(12,2),
    notes                   TEXT,
    created_at              TIMESTAMP DEFAULT now()
);

COMMENT ON SCHEMA credit_ops IS
  'Tablas operativas del agente de cobros. Equivalente a las hojas de Google Sheets del PoC original.';
