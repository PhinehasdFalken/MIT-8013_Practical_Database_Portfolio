"""
Generate the relational-schema diagram (logical design) directly from the
PostgreSQL catalogue, so the picture always matches 01_schema.sql.

Usage:
    pip install "psycopg[binary]"
    python generate_schema_diagram.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass"
    dot -Tpng -Gdpi=130 finesse_klass_relational_schema.dot -o finesse_klass_relational_schema.png
"""
import sys
import psycopg

DSN = sys.argv[1] if len(sys.argv) > 1 else "postgresql://postgres@localhost:5432/finesse_klass"

COLS = """
SELECT c.table_name, c.column_name, c.data_type, c.character_maximum_length,
       c.numeric_precision, c.numeric_scale, c.is_nullable, c.ordinal_position
FROM information_schema.columns c
WHERE c.table_schema = 'fk'
ORDER BY c.table_name, c.ordinal_position
"""
KEYS = """
SELECT tc.table_name, kcu.column_name, tc.constraint_type
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
WHERE tc.table_schema = 'fk' AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')
"""
FKS = """
SELECT DISTINCT cl.relname AS child, pcl.relname AS parent
FROM pg_constraint con
JOIN pg_class cl  ON cl.oid  = con.conrelid
JOIN pg_class pcl ON pcl.oid = con.confrelid
JOIN pg_namespace n ON n.oid = cl.relnamespace
WHERE con.contype = 'f' AND n.nspname = 'fk'
"""

def pretty_type(dt, length, prec, scale):
    if dt == "character varying":
        return f"varchar({length})"
    if dt == "numeric":
        return f"numeric({prec},{scale})"
    if dt.startswith("timestamp"):
        return "timestamp"
    return dt

with psycopg.connect(DSN) as conn:
    cols = conn.execute(COLS).fetchall()
    keys = conn.execute(KEYS).fetchall()
    fks = conn.execute(FKS).fetchall()

pk = {(t, c) for t, c, k in keys if k == "PRIMARY KEY"}
fk = {(t, c) for t, c, k in keys if k == "FOREIGN KEY"}

tables = {}
for t, c, dt, ln, pr, sc, nullable, _ in cols:
    tables.setdefault(t, []).append((c, pretty_type(dt, ln, pr, sc), nullable))

out = ['digraph schema {',
       '  graph [rankdir=LR, splines=ortho, nodesep=0.5, ranksep=1.1, fontname="Helvetica",',
       '         label="Finesse Klass – Relational Schema (generated from PostgreSQL catalogue)", labelloc=t, fontsize=18];',
       '  node  [shape=plain, fontname="Helvetica", fontsize=10];',
       '  edge  [arrowhead=tee, arrowtail=crow, dir=both, color="#555555"];']
for t, columns in sorted(tables.items()):
    rows = [f'<tr><td bgcolor="#2f5d8a" colspan="2"><font color="white"><b>{t}</b></font></td></tr>']
    for c, typ, nullable in columns:
        tag = ("PK " if (t, c) in pk else "") + ("FK" if (t, c) in fk else "")
        name = f"<u>{c}</u>" if (t, c) in pk else c
        if nullable == "NO" and (t, c) not in pk:
            name += " *"
        rows.append(f'<tr><td align="left">{tag.strip()} {name}</td><td align="left"><font color="#666666">{typ}</font></td></tr>')
    out.append(f'  {t} [label=<<table border="0" cellborder="1" cellspacing="0" cellpadding="3">{"".join(rows)}</table>>];')
# parent (one side) -> child (many side). NB: with splines=ortho Graphviz draws the
# tail glyph at the head end, hence arrowtail=crow / arrowhead=tee above.
for child, parent in sorted(fks):
    out.append(f"  {parent} -> {child};")
out.append('  legend [label=<<table border="0" cellborder="0"><tr><td align="left">PK = primary key (underlined), FK = foreign key, * = NOT NULL<br/>crow\'s foot = "many" side, bar = "one" side</td></tr></table>>];')
out.append("}")

with open("finesse_klass_relational_schema.dot", "w", encoding="utf-8") as f:
    f.write("\n".join(out))
print(f"Wrote finesse_klass_relational_schema.dot with {len(tables)} tables and {len(fks)} relationships")
