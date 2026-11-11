# Portfolio 5 – Distributed and Cloud Database Exercise

**Case study:** Finesse Klass is growing from a Lagos-only Instagram shop into a business delivering nationwide. About 46% of orders still come from the South-West, but Abuja and the North are now a quarter of the volume. The brand needs:
- the shop to **stay online** when a server fails (availability),
- **no lost or duplicated payments** (consistency),
- **fast local access** for staff in each region (fragmentation and allocation).

This portfolio builds a small **homogeneous distributed database**: four PostgreSQL 16 nodes, all running the same DBMS (Study Session 2, §2.1.2). It measures the trade-offs the course describes with the **CAP theorem** and **ACID vs BASE**.

```
                        ┌──────────────────────────┐   streaming WAL (async / sync)   ┌───────────────┐
  shop, staff apps ───► │ fk-primary  "Lagos site" │ ───────────────────────────────► │ fk-replica1   │  hot standby
                        │ read / write, 3 local    │                                  └───────────────┘
                        │ order fragments          │   streaming WAL, applied 15 s late ┌─────────────┐
                        │                          │ ─────────────────────────────────► │ fk-replica2 │  delayed standby
                        └────────────┬─────────────┘                                    └─────────────┘
                                     │ postgres_fdw (foreign partition)
                                     ▼
                        ┌──────────────────────────┐
                        │ fk-site-abuja            │  stores the NORTHERN fragment of the orders
                        └──────────────────────────┘
```

## 1. What was implemented and what it shows

| Course concept (Study Session 2 / 3) | Implementation | Evidence |
|---|---|---|
| **Full replication**, hot standby, replication transparency | `pg_basebackup` clones the primary; WAL streaming keeps 2 standbys up to date; a row written on the primary is readable on replica1 within milliseconds | R0, R1 |
| Single-primary writes | a standby refuses writes: `cannot execute INSERT in a read-only transaction` | R2 |
| **Eventual consistency** / stale reads | replica2 applies changes 15 s late: it serves the **old price** while the primary has the new one, then **converges** (≈ 15.2 s) | R3 |
| **Asynchronous replication + partition → AP** | replica1 frozen (`docker pause`, which acts as a network partition): the primary keeps committing (~10 ms) and the replica falls behind; after healing it catches up in milliseconds | R4 |
| **Synchronous replication + partition → CP** | with `synchronous_standby_names='replica1'`, commits cost ~1.5× more, and during the partition a commit **waits** (`wait_event = SyncRep`) until replica1 returns | R5 |
| **Availability / fault tolerance, failover** | primary killed → replica1 still serves **reads**, refuses **writes** → `pg_promote()` makes it the new primary in ~0.1 s, with no committed order lost | R6 |
| **Horizontal fragmentation** (rows) + **allocation** + **sharding** | `order_frag` is LIST-partitioned by region. South-West, South-East and South-South are stored in Lagos; the **North fragment is stored on a different server** (Abuja) as a foreign partition | `horizontal_fragmentation_output.txt` |
| Correctness of fragmentation | **completeness** (250,000 = 250,000), **disjointness** (no duplicates), **reconstruction** (union minus original = 0) | sections 2a–2c |
| **Fragmentation and location transparency** | queries name only `order_frag`; the optimiser reads *only* the relevant fragment (partition pruning) or sends the query to Abuja ("Remote SQL"); a new Kano order is **routed** to Abuja automatically | 3a, 3b, 3d |
| **Distributed query cost = network cost** (Study Session 4, §4.1.3.3) | global revenue report: by default **66,273 rows are shipped** from Abuja; with partition-wise aggregation Abuja aggregates locally and ships **3 rows** | 3c |
| **Vertical fragmentation** (columns) | `customer_profile` (name, region, since) vs `customer_contact` (email, phone, Instagram); **lossless join** on the key (0 differences); marketing can read profiles but gets `permission denied` on contacts | `vertical_fragmentation_output.txt` |

## 2. Analysis – CAP, ACID and BASE for Finesse Klass

The CAP theorem (§2.2.1.1) says a distributed system cannot guarantee **Consistency, Availability and Partition tolerance** all at once. Partitions *will* happen, so the real choice is **C or A while a partition lasts**. R4 and R5 show that choice on the same cluster, changed by one setting:

| | Asynchronous (R4) | Synchronous (R5) |
|---|---|---|
| During a partition | writes continue → **Available** | writes wait → **Consistent** |
| Risk | if the primary dies before the replica catches up, the last few commits can be lost | none of the committed data is lost, but checkout **stops** while the standby is unreachable |
| Cost when healthy | lowest commit time | ~1.5× commit time on one machine (more between cities, because each commit waits for a network round trip) |
| CAP / model | AP, BASE-like ("basically available, soft state, eventually consistent") | CP, ACID durability across sites |

**Decision for Finesse Klass:**
1. **Orders and payments:** synchronous replication to **one** standby in the same metro area, so the round trip is short. Losing a paid order is worse than pausing checkout for a few seconds. To avoid R5's "stuck" behaviour when that standby fails, two standbys would be listed with `ANY 1 (replica1, replica3)`, so either one can confirm.
2. **Catalogue, reports, order history:** read from **asynchronous / delayed replicas**. A product page that is a few seconds stale is acceptable (eventual consistency, R3), and these reads take load off the primary.
3. **Read-your-writes** (course consistency model): straight after paying, a customer's "My orders" page must read from the **primary**. A stale replica (R3) could otherwise show "no orders", which would alarm a customer who has just paid.
4. The **delayed replica** has a second use: if someone runs a wrong `DELETE` on the primary, the data is still on replica2 for 15 s (in production this would be hours).
5. **Fragmentation by region:** each region's staff query their local fragment (pruning). Head-office reports use **partition-wise aggregation**, so only totals cross the network, which is exactly the course's advice to minimise data transfer in distributed queries.

## 3. Moving this to the cloud (discussion)

Study Session 3 describes cloud databases as **DBaaS** with automatic scaling, backups, patching and **high availability through redundancy and automatic failover**. Each part of this lab maps to a managed feature:

| This lab (manual) | Managed cloud equivalent (course examples) |
|---|---|
| primary + synchronous standby + `pg_promote` | a managed relational service (e.g. Amazon RDS / Azure SQL Database / Google Cloud SQL) with a standby in a second availability zone and **automatic failover** |
| async/delayed read replicas | managed **read replicas** |
| fragments on different servers | a **distributed SQL / NewSQL** service (e.g. Google Spanner, CockroachDB, both named in the course) that shards automatically while staying ACID |
| catalogue in MongoDB, carts in Redis (Portfolio 4) | MongoDB Atlas, a managed key-value/cache service |

**Deployment model:** a **hybrid** approach fits a small Nigerian brand. Customer personal data stays in infrastructure the business controls, or in a cloud location that meets the **Nigeria Data Protection Act 2023**: the course notes that personal data may only be transferred outside Nigeria where adequate protection is ensured. Less sensitive workloads (the catalogue, analytics on the *vertically fragmented*, non-PII `customer_profile`) go to the **public cloud** for pay-as-you-go scaling during sales seasons. The trade-offs the course lists also apply: **vendor lock-in** with managed services, and **cost control** as usage grows.

## 4. How to run it (step by step)

You need Docker Desktop running. Open a terminal **in this folder** (on Windows: Command Prompt, see the root README).

```bash
# 1. start the 4 nodes (first time: downloads postgres:16, then ~20 s while the replicas clone the primary)
docker compose up -d
docker compose ps                 # all four should say "running"

# 2. load the Finesse Klass schema and data into the PRIMARY ONLY
#    (watch the replicas receive it through replication)
docker exec fk-primary psql -U postgres -d finesse_klass -f /p1/01_schema.sql
docker exec fk-primary psql -U postgres -d finesse_klass -f /p1/02_seed.sql

# 3. prepare the Abuja site, then fragment the orders
docker exec fk-site-abuja psql -U postgres -d finesse_site_north -f /p5/00_site_abuja_setup.sql
docker exec fk-primary psql -U postgres -d finesse_klass -f /p5/01_horizontal_fragmentation.sql > evidence/horizontal_fragmentation_output.txt 2>&1
docker exec fk-primary psql -U postgres -d finesse_klass -f /p5/02_vertical_fragmentation.sql   > evidence/vertical_fragmentation_output.txt 2>&1

# 4. replication / CAP demo (about 1 minute)
pip install "psycopg[binary]"
python distributed_demo.py

# 5. failover demo – this PROMOTES replica1, so run it last
python distributed_demo.py --failover

# 6. reset everything (deletes all 4 databases)
docker compose down -v
```

Quick checks (good for screenshots):
```bash
# which nodes are replicating, and are they sync or async?
docker exec fk-primary psql -U postgres -c "SELECT application_name, state, sync_state FROM pg_stat_replication;"
# is this node a standby?
docker exec fk-replica1 psql -U postgres -c "SELECT pg_is_in_recovery();"
# the same order count on every node
docker exec fk-replica2 psql -U postgres -d finesse_klass -c "SELECT count(*) FROM fk.customer_order;"
```
Ports for pgAdmin / DBeaver: primary `localhost:5440`, replica1 `5441`, replica2 `5442`, Abuja site `5443`. User `postgres`, password `finesse` (lab-only password).

## 5. Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | the 4-node cluster |
| `docker/primary-init.sh` | creates the replication user on first start |
| `docker/replica-entrypoint.sh` | clones the primary (`pg_basebackup -R -C -S`) and starts a hot standby, optionally delayed |
| `sql/00_site_abuja_setup.sql` | the northern fragment's table on the Abuja site |
| `sql/01_horizontal_fragmentation.sql` | fragmentation, allocation, correctness checks, pruning, location transparency, network cost |
| `sql/02_vertical_fragmentation.sql` | column fragmentation, lossless join, per-fragment access control |
| `distributed_demo.py` | R0–R6 replication, consistency, CAP and failover demo |
| `evidence/` | outputs of all runs (+ `screenshots/`) |

*Note on testing:* the scripts were developed against four PostgreSQL 16 servers configured exactly like the containers: same ports, replication settings, 15 s apply delay and foreign server. The demo pauses nodes with `docker pause`; the `FK_MODE=local` switch in `distributed_demo.py` exists only for that non-Docker test setup.
