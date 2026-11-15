# Portfolio 5: Distributed and cloud database exercise

Everything here was **built and run**, not only discussed. Three distributed set-ups run as Docker containers on one laptop. That is a local stand-in for three servers or availability zones:

| Set-up | Containers | Demonstrates |
|---|---|---|
| **A. Citus** (distributed PostgreSQL) | `citus-coord`, `citus-w1`, `citus-w2` | Sharding (hash by `patient_id`), reference tables, router vs fan-out queries, co-located joins, cross-shard 2PC, constraint limits |
| **B. MongoDB replica set** `rs0` | `mongo1` (priority 2), `mongo2`, `mongo3` | Majority writes, secondary reads, **automatic failover**, behaviour when a majority is lost |
| **C. PostgreSQL streaming replication** | `pg-primary` -> `pg-replica` (hot standby, replication slot) | Lag, read-only standby, stale reads, sync vs async commit, standby outage, **failover by promotion** |

## Files

| File | Purpose |
|---|---|
| `../docker-compose.yml` | The whole topology (root of the repository) |
| `../infra/postgres/primary-init/00-replication.sh` | Creates the `replicator` role, the `replica1_slot` slot, and the `pg_hba` replication rule |
| `../infra/postgres/replica-entrypoint.sh` | Clones the primary with `pg_basebackup -R` on first start, then runs as a hot standby |
| `../infra/mongo/init-replica-set.js` | Initiates `rs0` (idempotent) |
| `citus_schema.sql` | Sharded schema: reference tables, distributed and co-located tables |
| `distributed_demo.py` | Orchestrates all scenarios: stops and starts containers, measures failover times, writes the evidence. Standard-library Python on the host. |
| `results/sharding_citus_output.txt`, `results/mongo_replica_set_output.txt`, `results/postgres_replication_output.txt` | Evidence from the last run |

Run (after Parts 1 and 4): `python portfolio-5-distributed-cloud/distributed_demo.py`, or pass `sharding`, `mongo` or `replication` to run one part. The script returns the lab to its original state when it finishes. Part C deliberately crashes the primary, so it discards the promoted replica and re-clones a fresh one.

## A. Sharding with Citus: results

- **Distribution key `patient_id`, 8 hash shards, 4 per worker.** `appointments` is *co-located* with `patients`: shard *n* of both tables sits on the same worker. `doctors` and `departments` are *reference tables*, copied to every node.
- **Router query** (`WHERE patient_id = 12345`): `Task Count: 1`, so exactly one shard on one worker is touched. This is the most common clinical query, and it scales linearly as workers are added.
- **Fan-out query** (`WHERE doctor_id = 12`): `Task Count: 8`. Every shard is scanned in parallel and the coordinator merges the partial counts. Fine for occasional reports; costly if it were the main access path.
- **Co-located join plus reference joins** (patients ⋈ appointments ⋈ doctors ⋈ departments): pushed down entirely to the workers. Each worker joins and pre-aggregates its own shards, so no rows cross the network.
- **Constraint limit:** `UNIQUE (hospital_no)` is **rejected**. A distributed table can only enforce uniqueness on constraints that include the distribution column, because each worker only sees its own shards.
- **Cross-shard transaction:** one transaction updated patients on both workers. Citus commits multi-node writes with **two-phase commit**.

**Choosing the shard key.** `patient_id` was chosen because almost every operation is "for one patient". Rejected alternatives:

| Candidate | Why rejected |
|---|---|
| `doctor_id` | Only 35 clinic doctors, so shards would be skewed and hot. Every patient history would also fan out. |
| `start_at` (time) | All of today's writes would hit one shard (a hotspot) |

**When GraceCare would need this.** A single hospital fits comfortably on one PostgreSQL server: the whole data set is under 100 MB. Sharding becomes relevant if GraceCare becomes a **network of hospitals** sharing one record system (e.g. a state-wide health information exchange). Even then, a read replica is the first step, and sharding comes later.

## B. MongoDB replica set: results

| Scenario | Observed (see results file) |
|---|---|
| `w: "majority"` write, then a read from a secondary | Acknowledged after 2 of 3 members had it; the secondary returned the document |
| **Primary crashes** (`docker stop -t 0`) | A new primary was **elected automatically in 2.9 s** in the recorded run; in an earlier run it took 12 s. The time depends on when the missed heartbeats are noticed, bounded by the default `electionTimeoutMillis` of 10 s.. Majority writes continued. When mongo1 restarted it caught up from the oplog and, with priority 2, took over again. |
| **2 of 3 members down** (majority lost) | The survivor **stepped down to SECONDARY within about 10 s**. Writes were rejected (`NotWritablePrimary`), and reads still worked (possibly stale). |

## C. PostgreSQL streaming replication: results

| Scenario | Observed (see results file) |
|---|---|
| Status | Replica `replica1` streaming, `async`, 0 bytes behind; all 60,000 patients present |
| Single-write propagation | Visible on the replica within a few hundred ms. That figure is dominated by the `docker exec` polling overhead; the true lag is milliseconds. |
| 300,000-row burst | The replica caught up within about a second of the commit |
| Write on replica | `ERROR: cannot execute INSERT in a read-only transaction` |
| **Stale read** (replica applying WAL 3 s late) | Immediately after the commit the replica returned 0 rows; about 3 s later it returned 1. This is eventual consistency made visible. |
| **Synchronous commit** (`synchronous_standby_names = 'replica1'`) | Higher commit latency than async (measured), in exchange for RPO = 0 |
| **Sync standby down** | The INSERT **hung**: `wait_event = SyncRep`. `statement_timeout` does not end the wait. After `pg_cancel_backend()` the client was told *"already committed locally, but might not have been replicated"*. Switching back to async restored availability. |
| **Failover** | Primary killed, then replica promoted with `pg_promote()`. Writes were accepted again about 2 s after the crash; the new timeline is visible in the WAL file name. |

## CAP and PACELC in practice

Two quick definitions:

- **CAP:** when the network splits (a partition), a distributed database must choose between consistency (C: refuse writes that could conflict) and availability (A: keep accepting writes on both sides).
- **PACELC** adds the normal case: **E**lse, with no partition, the trade-off is between latency (L) and consistency (C).

| System | During a partition (P) | Normal operation (else) | Evidence |
|---|---|---|---|
| MongoDB replica set, `w: majority` | **C over A**: the minority side refuses writes | Latency vs consistency set per operation (`w`, `readConcern`, `readPreference`) | B3 |
| PostgreSQL, **synchronous** replication | **C over A**: writes block while the standby is unreachable | Higher latency, RPO = 0 | C6, C7 |
| PostgreSQL, **asynchronous** replication | **A over C**: the primary keeps writing, and a failover may lose the last commits | Low latency; replicas may be stale | C5, C8 |

## Recommended architecture for GraceCare

| Concern | Decision | Trade-off accepted |
|---|---|---|
| **Availability** | Primary plus one *synchronous* standby in a second building on the hospital LAN (low latency), plus one *asynchronous* replica in the cloud for disaster recovery. Automatic failover with Patroni and etcd (3 nodes) with fencing. | Commits wait for the standby, adding a few ms on the LAN, in return for no data loss. Sync mode `ANY 1` of 2 standbys avoids a stall when one standby is down (the C7 lesson). |
| **RPO / RTO targets** | Clinical data: RPO 0, RTO under 1 minute (sync standby + Patroni). Cloud DR copy: RPO in seconds, RTO under 30 minutes. Plus daily base backups and WAL archiving for point-in-time recovery, e.g. after accidental deletions, which replication would faithfully copy. | |
| **Consistency of reads** | Clinical screens (read-your-own-writes) go to the primary. Reports, dashboards and the MongoDB ETL go to replicas. | Reports may be a few seconds stale (C5) |
| **Scale** | No sharding for one hospital. Citus with `patient_id` as the key only for a multi-hospital network. | |
| **Document store** | MongoDB 3-member replica set (an odd number avoids split votes), `w: majority` for clinical writes | Writes pause for a few seconds (up to about 12 s) during an election (B2) |
| **Cache** | Redis with short TTLs and delete-on-write; no clinical decision is made from the cache alone | Cache misses after a restart |
| **Unreliable power and network** (a common Nigerian constraint) | The LAN-local primary keeps the hospital running even if the internet link drops. Only WAL shipping to the cloud is affected: it queues in the replication slot and catches up later. Slot size is monitored and capped (`max_slot_wal_keep_size`) so a long outage cannot fill the primary's disk. | The DR copy lags during outages |

### Cloud deployment option

A managed alternative to running the database servers on-premise:

| Component | Managed service (example) | Notes |
|---|---|---|
| PostgreSQL | Azure Database for PostgreSQL Flexible Server (zone-redundant HA) or AWS RDS for PostgreSQL Multi-AZ | Synchronous standby in a second availability zone and automatic failover are built in; PITR up to 35 days |
| MongoDB | MongoDB Atlas, 3-node replica set across 3 zones | Same `rs` semantics as the lab |
| Redis | Azure Cache for Redis / Amazon ElastiCache | |
| Region | Nearest regions are South Africa North (Azure) or af-south-1 Cape Town (AWS) | Health data is sensitive personal data under the **NDPA 2023**. Storing it outside Nigeria needs a lawful transfer basis (adequacy or appropriate safeguards). Many hospitals keep the primary on-premise or with a Nigerian provider and send only encrypted backups abroad. |
| Security | TLS in transit, encryption at rest with customer-managed keys, private networking (no public IP), least-privilege roles from Part 1, audit logging | |

The lab in this repository was **not** deployed to a public cloud: no cloud account or budget was used. The container topology mirrors the managed services above, which is why all the failover and consistency behaviour could be measured locally.
