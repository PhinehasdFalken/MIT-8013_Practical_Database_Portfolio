# Portfolio 3 – Transactions and Concurrency

**Case study:** Finesse Klass. The critical operation is **placing an order**: an order header, its lines, stock decrements, an audit trail, the total and the payment must all succeed or fail **together**. The critical concurrency risk is **two customers buying the last pair of a size at the same moment**. This is a real problem for a small shoe brand, where many sizes run to only 1–3 pairs (see Q6 in Portfolio 2).

## 1. ACID, mapped to evidence

The course defines a transaction's guarantees as **ACID** (Study Session 2, §2.2.1.2). Each one is demonstrated here:

| Property | Course definition (paraphrased) | Demonstrated by | Evidence |
|---|---|---|---|
| **Atomicity** | all-or-nothing | T1 commits 6 changes as one unit; T2 rolls everything back when the 2nd stock update fails | `evidence/01_…`, `evidence/02_…` |
| **Consistency** | valid state → valid state | `CHECK (stock_qty >= 0)` rejects the sale of a sold-out loafer (T2), and the whole order is undone | `evidence/02_…` |
| **Isolation** | concurrent transactions behave as if run one after another | S1–S6 in the two-session demo | `evidence/concurrency_demo_output.txt` |
| **Durability** | committed data survives failures | a throwaway PostgreSQL container is killed with `docker kill` (power-cut style); on restart PostgreSQL **replays its write-ahead log**: the committed order is there, the uncommitted one is not | `evidence/04_durability_crash_test.txt` |

## 2. Transaction examples (single session)

| Script | What it shows | Key output |
|---|---|---|
| `sql/01_commit_place_order.sql` | **COMMIT**: Ngozi Ibe buys 2 pairs; header + 2 lines + 2 stock decrements + 2 audit rows + total + payment + status in **one** transaction | order 250002 `paid`, ₦120,100; stock 11→10 and 20→19 (order_id 250001 was used up by a *rejected* insert in P1 test T6 – identity values are never reused) |
| `sql/02_rollback_atomicity.sql` | **Automatic ROLLBACK**: the 1st decrement succeeds (boot stock 10→9 *inside* the transaction); the 2nd breaks `stock_qty >= 0` → `ERROR`; PostgreSQL refuses every later statement ("current transaction is aborted") → `ROLLBACK` → boot stock back to **10**, 0 order rows, 0 line rows. Plus an **explicit ROLLBACK** when the customer changes her mind | `evidence/02_rollback_atomicity_output.txt` |
| `sql/03_savepoint.sql` | **SAVEPOINT / partial rollback**: a bespoke order's 8-letter monogram fails (`VARCHAR(6)`); `ROLLBACK TO SAVEPOINT` undoes only that step; measurements are saved with initials and the order still commits | `evidence/03_savepoint_output.txt` |
| `durability_crash_test.py` | **Crash recovery**: log lines `database system was not properly shut down; automatic recovery in progress` → `redo starts … redo done`; committed order present, uncommitted order absent | `evidence/04_durability_crash_test.txt` |

## 3. Concurrency – the "last pair" problem and three control mechanisms

`concurrency_demo.py` opens **two real sessions (A = Kemi, B = Halima)** plus an **observer** session. It runs every step in a fixed order, so the race happens on every run. Statements that must wait for a lock run in a background thread, and the observer reads `pg_stat_activity` to prove the wait (`waiting on Lock/transactionid, blocked by pid …`).

| # | Scenario | What happened | Pairs sold from 1 in stock |
|---|---|---|---|
| **S1** | **Problem – lost update.** Both read `stock_qty = 1`; both write `1 − 1 = 0` | B's write overwrites A's. The `CHECK` cannot help, because 0 is a legal value | **2 ❌ (oversold)** |
| S2 | **Fix 1 – pessimistic locking**: `SELECT … FOR UPDATE` | B **waits** (observer shows the lock wait); after A commits, B reads 0 → "sold out" | 1 ✅ |
| S3 | **Fix 2 – stricter isolation**: `REPEATABLE READ` | B's update fails with `could not serialize access due to concurrent update`; the app **retries**, sees 0 | 1 ✅ |
| S4 | **Fix 3 – atomic conditional update**: `UPDATE … SET stock_qty = stock_qty − 1 WHERE … AND stock_qty >= 1` | B waits for A's row lock; after A commits, the condition is checked again → **0 rows updated** → sold out | 1 ✅ |
| S5 | **Isolation levels** | A's uncommitted price change is invisible to B (**no dirty read**). In `READ COMMITTED`, B's second read in the same transaction sees the new price (**non-repeatable read**). In `REPEATABLE READ`, B keeps its **snapshot** for the whole checkout | – |
| S6 | **Deadlock** | A locks X then wants Y; B locks Y then wants X → `DeadlockDetected` → PostgreSQL aborts one session so the other can continue. **Fix:** both lock variants in ascending `variant_id` order → B simply waits, no cycle | – |

### Why these behave as they do (course concepts)

- The course lists **concurrency and locking issues** ("locking and deadlocks, affecting performance") as a limitation of traditional DBMSs, and says the DBMS "schedules concurrent accesses … such that users can think of the data as being accessed by only one user at a time". S1 shows what happens when the *application* breaks that illusion by reading a value and writing it back later. S2–S4 restore it.
- PostgreSQL implements isolation with **multi-version concurrency control (MVCC)**, which the course names among the techniques of modern systems. Readers see a committed *version* of a row instead of waiting for writers. That is why B in S5 sees the old price, not a dirty one. Writers still take **row locks** on the rows they change, which is why B waits in S2, S4 and S6.
- **Trade-offs:** S2 (locking) is simple, but locks are held while the customer's payment is processed, which lowers throughput. S3 (repeatable read) avoids waiting but needs **retry logic** in the application. S4 is the shortest critical section: one statement, no extra round trip.

### Decision for Finesse Klass
1. Decrement stock with the **atomic conditional update (S4)**, and treat "0 rows updated" as *sold out*. Keep `CHECK (stock_qty >= 0)` as the last line of defence.
2. For orders with several items, lock variants **in ascending `variant_id` order** (S6 fix) to rule out deadlocks.
3. Use `REPEATABLE READ` for the **checkout summary** so the customer pays the price they were shown (S5).

## 4. How to run it

Prerequisite: the `finesse_klass` database from Portfolio 1.

```bash
# single-session transaction scripts
psql -U postgres -d finesse_klass -f sql/01_commit_place_order.sql  > evidence/01_commit_place_order_output.txt
psql -U postgres -d finesse_klass -f sql/02_rollback_atomicity.sql  > evidence/02_rollback_atomicity_output.txt 2>&1
psql -U postgres -d finesse_klass -f sql/03_savepoint.sql           > evidence/03_savepoint_output.txt 2>&1

# two-session concurrency demo (about 10 s; cleans up after itself)
pip install "psycopg[binary]"
python concurrency_demo.py "postgresql://postgres:YOURPASSWORD@localhost:5432/finesse_klass"

# durability crash test (needs Docker Desktop running; uses its own throwaway container, ~30 s)
python durability_crash_test.py
```
(`2>&1` also saves the expected ERROR lines into the evidence file.)

### Doing S1 and S2 by hand in two windows (for screenshots)

Open **two** psql windows (or two pgAdmin Query Tool tabs) on `finesse_klass` and run the steps in this order. Reset first: `UPDATE fk.product_variant SET stock_qty = 1 WHERE sku = 'FK-027-44-WHI';`

| Step | Window A | Window B |
|---|---|---|
| 1 | `BEGIN;` | |
| 2 | `SELECT stock_qty FROM fk.product_variant WHERE sku='FK-027-44-WHI' FOR UPDATE;` → 1 | |
| 3 | | `BEGIN;` |
| 4 | | `SELECT stock_qty FROM fk.product_variant WHERE sku='FK-027-44-WHI' FOR UPDATE;` → **hangs (waiting)** 📸 |
| 5 | `UPDATE fk.product_variant SET stock_qty = stock_qty - 1 WHERE sku='FK-027-44-WHI';` | |
| 6 | `COMMIT;` | → returns **0** immediately 📸 |
| 7 | | `ROLLBACK;` |

For **S1 (the problem)**, repeat without `FOR UPDATE`, and in step 5 use `SET stock_qty = 0` in *both* windows (that is what an application does when it computes `1 − 1` itself). Both commit: two sales of one pair.


## 5. Files

| File | Purpose |
|---|---|
| `sql/01_commit_place_order.sql` | T1 – COMMIT |
| `sql/02_rollback_atomicity.sql` | T2 – automatic and explicit ROLLBACK |
| `sql/03_savepoint.sql` | T3 – SAVEPOINT |
| `concurrency_demo.py` | S1–S6 with two sessions and an observer |
| `durability_crash_test.py` | crash (docker kill) and WAL recovery test |
| `evidence/*.txt` | outputs of every run, including the crash test |
| `evidence/screenshots/` | screenshots from my machine (two-window S1/S2 runs) |
