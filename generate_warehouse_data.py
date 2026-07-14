"""
Genera datos sintéticos para warehouse.customer_ledger_view,
simulando la vista Customer_ledger_view de Snowflake del TFM
"Agente de cobros".

Respeta las estadísticas descritas en el TFM:
  - Customer_Group = 'SIN' (excluye Grandes Cuentas)
  - ~20-25% de las facturas abiertas están vencidas
  - Documentos vencidos o próximos a vencer (DAYS_PAST_DUE_DATE >= 0
    o BETWEEN -5 AND -1), igual que el filtro de WF01
  - OPEN_AMOUNT > 0

Uso:
    pip install faker psycopg2-binary --break-system-packages
    export PGHOST=localhost PGPORT=5432 PGDATABASE=progrss \
           PGUSER=postgres PGPASSWORD=xxxx
    python3 generate_warehouse_data.py --clientes 80 --facturas-por-cliente 4
"""

import argparse
import os
import random
import uuid
from datetime import date, timedelta

import psycopg2
from faker import Faker

fake = Faker("es_ES")
Faker.seed(42)
random.seed(42)

DOCUMENT_TYPES = ["Invoices", "Invoices", "Invoices", "Credit Notes", "Chargebacks"]
RECORD_TYPES = ["FACTURA", "FACTURA", "ABONO", "CARGO"]
COMMENT_TYPES = [None, None, None, "Comment", "Estado de gestión", "Incidence"]
LAST_STATUSES = [
    None, None,
    "Pendiente de revisión",
    "En gestión por Créditos",
    "Incidencia abierta - factura no recibida",
    "Incidencia abierta - error EDI",
]


def aging_bucket(days_past_due: int) -> str:
    if days_past_due < 0:
        return "Not due"
    if days_past_due <= 15:
        return "0-15"
    if days_past_due <= 30:
        return "16-30"
    if days_past_due <= 60:
        return "31-60"
    return "60+"


def build_invoice(billing_address: str, owner_name: str, owner_email: str,
                   payer_name: str, punto_entrega: str) -> dict:
    """Genera una factura respetando ~22% de tasa de vencidas."""
    today = date.today()

    # ~22% vencida (DAYS_PAST_DUE_DATE >= 0), resto próxima a vencer o al día
    if random.random() < 0.22:
        days_past_due = random.randint(0, 90)
    else:
        days_past_due = random.randint(-45, -1)

    due_date = today - timedelta(days=days_past_due)
    invoice_date = due_date - timedelta(days=random.choice([30, 45, 60, 90]))

    total_amount = round(random.uniform(150, 18000), 2)
    # Algunas facturas ya tienen pago parcial
    open_amount = total_amount if random.random() > 0.15 else round(
        total_amount * random.uniform(0.1, 0.9), 2
    )

    document_type = random.choice(DOCUMENT_TYPES)
    comment_type = random.choice(COMMENT_TYPES)
    has_incidence = comment_type == "Incidence"

    return {
        "document_number": f"DOC-{uuid.uuid4().hex[:8].upper()}",
        "document_type": document_type,
        "record_type": random.choice(RECORD_TYPES),
        "invoice_date": invoice_date,
        "due_date": due_date,
        "days_past_due_date": days_past_due,
        "open_amount": open_amount,
        "total_amount": total_amount,
        "punto_contacto_owner": owner_name,
        "punto_contacto_owner_email": owner_email,
        "punto_contacto_payer": payer_name,
        "billing_address": billing_address,
        "punto_de_entrega": punto_entrega,
        "comment": fake.sentence(nb_words=8) if comment_type else None,
        "comment_type": comment_type,
        "incidence_number": f"INC-{uuid.uuid4().hex[:6].upper()}" if has_incidence else None,
        "last_incidence_management_status": random.choice(LAST_STATUSES) if has_incidence else None,
        "customer_group": "SIN",
    }


def generate_clients(n_clients: int):
    clients = []
    for i in range(n_clients):
        billing_address = f"{100000 + i}-{fake.company().upper().replace(' ', '')[:12]}"
        clients.append({
            "billing_address": billing_address,
            "owner_name": fake.name(),
            "owner_email": fake.company_email(),
            "payer_name": fake.company(),
            "punto_entrega": f"{fake.city()} - Almacén {random.randint(1,5)}",
        })
    return clients


def insert_batch(conn, rows: list[dict]):
    cols = list(rows[0].keys())
    placeholders = ", ".join(["%s"] * len(cols))
    col_names = ", ".join(cols)
    sql = f"""
        INSERT INTO warehouse.customer_ledger_view ({col_names})
        VALUES ({placeholders})
        ON CONFLICT (billing_address, document_number, document_type) DO NOTHING
    """
    with conn.cursor() as cur:
        for row in rows:
            cur.execute(sql, [row[c] for c in cols])
    conn.commit()


def main():
    parser = argparse.ArgumentParser(description="Genera facturas sintéticas para warehouse.customer_ledger_view")
    parser.add_argument("--clientes", type=int, default=60, help="Número de clientes (billing_address) a generar")
    parser.add_argument("--facturas-por-cliente", type=int, default=3, help="Media de facturas por cliente")
    parser.add_argument("--truncate", action="store_true", help="Vacía la tabla antes de insertar")
    args = parser.parse_args()

    conn = psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=os.environ.get("PGPORT", "5432"),
        dbname=os.environ["PGDATABASE"],
        user=os.environ["PGUSER"],
        password=os.environ["PGPASSWORD"],
    )

    if args.truncate:
        with conn.cursor() as cur:
            cur.execute("TRUNCATE TABLE warehouse.customer_ledger_view")
        conn.commit()
        print("Tabla warehouse.customer_ledger_view vaciada.")

    clients = generate_clients(args.clientes)
    all_rows = []
    for client in clients:
        n_invoices = max(1, int(random.gauss(args.facturas_por_cliente, 1.2)))
        for _ in range(n_invoices):
            all_rows.append(build_invoice(
                billing_address=client["billing_address"],
                owner_name=client["owner_name"],
                owner_email=client["owner_email"],
                payer_name=client["payer_name"],
                punto_entrega=client["punto_entrega"],
            ))

    insert_batch(conn, all_rows)
    conn.close()

    vencidas = sum(1 for r in all_rows if r["days_past_due_date"] >= 0)
    print(f"Insertadas {len(all_rows)} facturas para {len(clients)} clientes.")
    print(f"Vencidas: {vencidas} ({vencidas / len(all_rows):.1%}) — objetivo TFM: 20-25%")


if __name__ == "__main__":
    main()
