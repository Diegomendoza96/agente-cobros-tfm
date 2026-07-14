-- =====================================================================
-- MIGRACIÓN: columnas de control descubiertas en las Google Sheets reales
-- (añadidas a posteriori de la entrega del TFM, no documentadas en la memoria)
-- =====================================================================

-- credit_cases: columnas de control usadas durante el upsert (WF01)
ALTER TABLE credit_ops.credit_cases
  ADD COLUMN IF NOT EXISTS followup_count  INTEGER DEFAULT 0,      -- caché del contador (fuente real: email_threads)
  ADD COLUMN IF NOT EXISTS row_exists      BOOLEAN,                -- flag: ¿ya existía el case_key al hacer upsert? ("exists" es palabra reservada en Postgres, se renombra
  ADD COLUMN IF NOT EXISTS update_row      BOOLEAN DEFAULT FALSE,  -- flag de control de flujo en n8n (rama IF)
  ADD COLUMN IF NOT EXISTS insert_row      BOOLEAN DEFAULT FALSE,  -- flag de control de flujo en n8n (rama IF)
  ADD COLUMN IF NOT EXISTS existing_keys   TEXT;                   -- lista de case_keys ya indexados en memoria (WF01 paso 2)

-- email_threads: columnas que el TFM menciona en texto pero no estaban en la
-- tabla de campos (case_keys y cases como JSON, más metadatos de envío)
ALTER TABLE credit_ops.email_threads
  ADD COLUMN IF NOT EXISTS case_keys       TEXT,          -- CSV de case_keys incluidos en el hilo
  ADD COLUMN IF NOT EXISTS cases           JSONB,         -- detalle documental completo (auditoría demo)
  ADD COLUMN IF NOT EXISTS error           TEXT,          -- error de envío si el mail falló
  ADD COLUMN IF NOT EXISTS sent_message_id VARCHAR(150),  -- id del mensaje en el envío concreto (vs last_message_id que es "el último")
  ADD COLUMN IF NOT EXISTS sent_at         TIMESTAMP;     -- timestamp del envío concreto

-- agent_action_log: columnas de resumen de la ejecución + datos del email generado
ALTER TABLE credit_ops.agent_action_log
  ADD COLUMN IF NOT EXISTS rows_total    INTEGER,      -- filas leídas en esa ejecución
  ADD COLUMN IF NOT EXISTS rows_updated  INTEGER,      -- filas actualizadas
  ADD COLUMN IF NOT EXISTS rows_inserted INTEGER,      -- filas insertadas
  ADD COLUMN IF NOT EXISTS notify_to     VARCHAR(150), -- destinatario de la notificación/email
  ADD COLUMN IF NOT EXISTS email_subject TEXT,         -- asunto del email generado (contact_1/followup)
  ADD COLUMN IF NOT EXISTS email_body    TEXT;         -- cuerpo del email generado
