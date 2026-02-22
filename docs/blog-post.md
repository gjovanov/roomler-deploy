# From Docker to K8s: Migrating a Full WebRTC Stack Without Dropping a Single Call

*How I moved Roomler (MongoDB, Redis, Janus, Node.js) from Docker Compose to Kubernetes — with zero downtime, a MongoDB major version upgrade, and automated backups. Plus all the things that went wrong along the way.*

---

Remember when I said running Roomler on Docker was "fine"? Well, "fine" got me through a few years. But at some point, I looked at my setup — seven Docker containers held together by `docker run` commands and prayers — and thought: "There has to be a better way."

Meanwhile, my inbox was filling up with messages from the community:

> "How do I run the full Roomler stack in K8s?"
> "Is there an Ansible playbook for deploying Roomler?"
> "I followed your first blog post and got COTURN working. What about the rest?"

So I decided to do the migration live — on a production system with real users and real data. Because nothing motivates you to write good rollback scripts like knowing actual people are using your app.

This is the story of that migration. The good parts, the bad parts, and the "why is MongoDB 4.0 still running years after EOL" parts.

---

## The Starting Point: Docker Spaghetti

Here's what my Docker setup looked like before the migration:

```mermaid
graph TB
    subgraph Docker["Docker on Bare Metal Host"]
        NGX["nginx<br/>HTTP/3 + Brotli + GeoIP2<br/>(custom compiled)"]
        NGX2["nginx2<br/>Stream proxy for COTURN"]
        RM["roomler<br/>Node.js + PM2<br/>port 3000"]
        MG["mongo<br/>MongoDB 4.0.3<br/>(yes, really)"]
        RD["redis<br/>pub/sub"]
        JN["janus<br/>WebRTC Gateway"]
        CT["coturn<br/>(now redundant!)"]
    end

    NGX -->|":3000"| RM
    NGX -->|":8088/:8188"| JN
    RM --> MG
    RM --> RD

    style Docker fill:#1a1a2e,color:#fff
```

Six containers. Two nginx instances. A MongoDB version so old it stopped receiving security patches in 2022. A COTURN container that was now redundant since we already deployed it in K8s (see [Part 1](https://github.com/gjovanov/k8s-cluster/blob/main/docs/blog-post.md)).

It worked. But it was held together with duct tape and good intentions.

## The Target: Clean K8s Architecture

Here's what we're building:

```mermaid
graph TB
    subgraph Internet
        U["Users"]
        WR["WebRTC Clients"]
    end

    subgraph Host["Bare Metal Host"]
        NGX["Docker: nginx<br/>(stays on host — HTTP/3, Brotli, GeoIP2)"]
    end

    subgraph K8s["K8s Cluster"]
        subgraph Roomler["namespace: roomler"]
            APP["Roomler Pod<br/>Nuxt SSR + Fastify<br/>PM2 cluster x4"]
            MG["MongoDB 7.x<br/>StatefulSet<br/>PV: 5Gi"]
            RD["Redis 7<br/>Alpine<br/>(pub/sub, no persistence)"]
            JN["Janus Gateway<br/>hostNetwork<br/>WebRTC SFU"]
        end

        subgraph COTURN["namespace: coturn"]
            CT1["COTURN Worker1"]
            CT2["COTURN Worker2"]
        end
    end

    U -->|"HTTPS"| NGX
    WR -->|"WSS"| NGX
    NGX -->|":30030"| APP
    NGX -->|":30818"| JN
    APP --> MG
    APP --> RD

    style Host fill:#1a1a2e,color:#fff
    style Roomler fill:#533483,color:#fff
    style COTURN fill:#0f3460,color:#fff
```

Notice that nginx stays on the host. Why? Because it's a custom-compiled build with HTTP/3 (QUIC), Brotli compression, and GeoIP2 blocking — features that no K8s Ingress controller supports out of the box. Moving it into K8s would mean maintaining a custom Docker image for the ingress controller, and honestly, life's too short.

Everything else moves into K8s. Clean separation, proper resource limits, health probes, and automated restarts.

## The Migration Strategy: Don't Be a Hero

There's a temptation to do the migration all at once — stop Docker, deploy K8s, pray. Don't do that. Here's our approach:

```mermaid
graph LR
    A["1. Copy Data<br/>to K8s worker"] --> B["2. Deploy<br/>K8s services"]
    B --> C["3. Restore<br/>MongoDB"]
    C --> D["4. Test<br/>internally"]
    D --> E["5. Switch<br/>nginx upstreams"]
    E --> F["6. Test<br/>externally"]
    F --> G["7. Stop<br/>Docker containers"]
    G --> H["8. Setup<br/>backups"]

    style A fill:#e94560,color:#fff
    style E fill:#e94560,color:#fff
```

The key insight: **Docker containers keep running until we've verified K8s is working perfectly.** If anything goes wrong at step 6, we just revert the nginx config and reload. The Docker containers never stopped. Zero downtime.

## Step 1: Data Migration — The Careful Part

We have two pieces of data to migrate:

| Data | Size | Source | Destination |
|------|------|--------|-------------|
| MongoDB | ~519 MB | Docker container `mongo2` | K8s worker1: `/data/roomler/mongodb` |
| User uploads | ~768 MB (745 files) | Docker volume `/roomler/uploads` | K8s worker1: `/data/roomler/uploads` |

### MongoDB: The Great Version Leap

Here's a fun fact: you can't just copy MongoDB 4.0 data files and mount them in MongoDB 7.x. The storage engine format has changed multiple times between versions. You need `mongodump`/`mongorestore` — the official migration path.

```bash
# Dump from Docker (MongoDB 4.0)
docker exec mongo2 mongodump --db roomlerdb --archive --gzip > /tmp/roomlerdb.archive.gz

# Copy to K8s worker node
scp /tmp/roomlerdb.archive.gz k8s-worker1:/data/roomler/roomlerdb.archive.gz
```

<details>
<summary><strong>Deep Dive: Why upgrade from MongoDB 4.0 to 7.x?</strong></summary>

MongoDB 4.0 reached end-of-life in April 2022. That's **three years** without security patches. Here's what you gain by upgrading to 7.x:

| Feature | MongoDB 4.0 | MongoDB 7.x |
|---------|------------|-------------|
| Security patches | EOL (none) | Active LTS |
| Queryable encryption | No | Yes |
| Time series collections | No | Yes |
| Atlas Search integration | No | Yes |
| Aggregation pipeline improvements | Basic | Major improvements |
| Change streams | Limited | Full support |

The migration via `mongodump`/`mongorestore` is atomic — it either works completely or fails completely. No partial states to worry about. In our case, the dump was 519 MB and the restore took about 30 seconds. Anticlimactic, honestly. I was expecting drama.

</details>

### Uploads: rsync to the Rescue

For the uploads directory (user avatars, shared files), a simple rsync does the job:

```bash
rsync -av /roomler/uploads/ k8s-worker1:/data/roomler/uploads/
```

745 files, 768 MB, done in seconds over the local network. Moving on.

## Step 2: K8s Deployment — The Fun Part

The entire stack is deployed via a single Ansible playbook. Here's what it creates:

```mermaid
graph TB
    subgraph NS["Namespace: roomler"]
        subgraph Storage
            PV1["PV: mongodb<br/>hostPath: /data/roomler/mongodb"]
            PV2["PV: uploads<br/>hostPath: /data/roomler/uploads"]
            PVC1["PVC: mongodb-data<br/>5Gi"]
            PVC2["PVC: roomler-uploads<br/>5Gi"]
        end

        subgraph Pods
            MG["MongoDB<br/>StatefulSet<br/>1 replica"]
            RD["Redis<br/>Deployment<br/>1 replica"]
            JN["Janus<br/>Deployment<br/>hostNetwork"]
            RL["Roomler<br/>Deployment<br/>PM2 x4 workers"]
        end

        subgraph Config
            CM["ConfigMap<br/>roomler-config<br/>(env vars)"]
            SEC["Secret<br/>roomler-secret<br/>(passwords, keys)"]
        end

        subgraph Services
            S1["mongodb<br/>ClusterIP :27017"]
            S2["redis<br/>ClusterIP :6379"]
            S3["janus<br/>ClusterIP :8088/:8188"]
            S4["roomler<br/>NodePort :30030"]
            S5["janus-nodeport<br/>NodePort :30808/:30818"]
        end
    end

    PVC1 --> PV1
    PVC2 --> PV2
    PVC1 --> MG
    PVC2 --> RL
    CM --> RL
    SEC --> RL
    MG --> S1
    RD --> S2
    JN --> S3
    JN --> S5
    RL --> S4

    style NS fill:#533483,color:#fff
    style Storage fill:#0f3460,color:#fff
    style Config fill:#16213e,color:#fff
```

<details>
<summary><strong>Deep Dive: Why StatefulSet for MongoDB but Deployment for everything else?</strong></summary>

**MongoDB** needs a StatefulSet because:
- It has persistent storage (data must survive pod restarts)
- The pod name is stable (`mongodb-0`), which means the PVC binding is deterministic
- If we ever scale to a replica set, StatefulSet handles ordered startup/shutdown

**Redis** is a Deployment because:
- No persistence needed (it's only used for pub/sub message relay)
- If the pod dies, it restarts with a clean state — which is totally fine for our use case (0 stored keys)

**Janus** is a Deployment with `hostNetwork: true` because:
- WebRTC media needs direct network access (no NAT/proxy)
- The SFU negotiates dynamic UDP ports with browsers — can't go through K8s services
- Pinned to worker1 via `nodeSelector` for predictable networking

**Roomler** is a Deployment because:
- Stateless app server (state is in MongoDB + Redis)
- Could be scaled to multiple replicas for zero-downtime deploys
- Uploads are on a shared PVC

</details>

### TURN Credentials: The Tricky Bit

Roomler's Janus integration needs TURN server credentials to pass to WebRTC clients. With COTURN in `use-auth-secret` mode, credentials are ephemeral — generated from a shared secret via HMAC-SHA1.

The problem? Roomler's codebase hardcodes `TURN_USERNAME` and `TURN_PASSWORD` from environment variables. It doesn't generate ephemeral credentials on the fly.

The solution? We pre-compute a long-lived credential pair:

```bash
# Username format: expiry_timestamp:label
# Far-future timestamp (Nov 2286) = effectively permanent
username="9999999999:roomler"

# Credential = Base64(HMAC-SHA1(secret, username))
password=$(echo -n "9999999999:roomler" | \
  openssl dgst -sha1 -hmac "$COTURN_AUTH_SECRET" -binary | base64)
```

The Ansible template computes this automatically from the shared secret in `.env`. No manual credential management needed.

## Step 3: The Cutover — Deep Breath

This is the moment of truth. We've got K8s services running, MongoDB restored, pods healthy. Time to point nginx at the new backends.

```mermaid
sequenceDiagram
    participant nginx as Host nginx
    participant Docker as Docker Containers
    participant K8s as K8s Pods

    Note over nginx,Docker: Before cutover
    nginx->>Docker: roomler.live → localhost:3000
    nginx->>Docker: janus.roomler.live → localhost:8088

    Note over nginx,K8s: Update nginx upstreams
    nginx->>K8s: roomler.live → 10.10.10.11:30030
    nginx->>K8s: janus.roomler.live → 10.10.10.11:30808/30818

    Note over nginx: nginx -s reload
    Note over Docker: Docker still running (safety net!)

    Note over nginx,K8s: Verify: curl https://roomler.live → 200 OK
    Note over nginx,K8s: Verify: WebSocket connects
    Note over nginx,K8s: Verify: Uploads load

    Note over Docker: All good? Stop Docker containers
    Docker->>Docker: docker stop roomler2 mongo2 redis janus nginx2
```

The cutover script handles this automatically:
1. Backs up current nginx configs (with timestamps)
2. Rewrites upstream blocks to point to K8s NodePorts
3. Tests the new config (`nginx -t`)
4. Reloads nginx

If anything breaks, rollback is one command:
```bash
cp roomler.live.conf.bak-* roomler.live.conf
docker exec nginx nginx -s reload
```

## Step 4: Backups — Because Data Loss is Not an Option

With the migration done, we set up automated daily backups:

```mermaid
graph TB
    subgraph Cron["Daily Cron Jobs (Host)"]
        C1["03:00<br/>backup-mongodb.sh"]
        C2["03:30<br/>backup-uploads.sh"]
        C3["04:00<br/>verify-backups.sh"]
    end

    subgraph K8s["K8s Cluster"]
        MG["MongoDB Pod"]
        UL["Uploads PV<br/>(on worker1)"]
    end

    subgraph Backup["Host: ~/backup/"]
        MB["mongodb/<br/>roomlerdb-YYYY-MM-DD.archive.gz<br/>(~50 MB/day)"]
        UB["uploads/<br/>YYYY-MM-DD/<br/>(hard-linked snapshots)"]
    end

    C1 -->|"kubectl exec mongodump --gzip"| MG --> MB
    C2 -->|"rsync --link-dest"| UL --> UB
    C3 -->|"check age + size + count"| MB
    C3 -->|"check age + size + count"| UB

    style Cron fill:#e94560,color:#fff
    style K8s fill:#533483,color:#fff
    style Backup fill:#0f3460,color:#fff
```

| Backup | Method | Daily Size | 7-Day Retention |
|--------|--------|-----------|-----------------|
| MongoDB | `mongodump --gzip` from K8s pod | ~50 MB | ~350 MB |
| Uploads | rsync with hard-link rotation | ~0 (incremental) | ~768 MB |
| **Total** | | | **~1.1 GB** |

<details>
<summary><strong>Deep Dive: Hard-link Rotation for Uploads</strong></summary>

The uploads backup uses a clever trick: `rsync --link-dest`. Here's how it works:

```bash
DATE=$(date +%F)
rsync -av --link-dest=/backup/uploads/latest \
  k8s-worker1:/data/roomler/uploads/ \
  /backup/uploads/$DATE/
```

The `--link-dest` flag tells rsync: "If a file is identical to the one in `latest/`, create a hard link instead of copying it." Hard links share the same disk blocks — they take zero additional space.

Result: the first backup is 768 MB. Every subsequent backup is essentially free (only new or changed files consume additional space). After 7 days, we have 7 "full" snapshots that only take ~768 MB total on disk.

The verification script checks three things:
1. Latest backup exists and is < 25 hours old
2. MongoDB archive is non-trivially sized (> 1 KB)
3. Uploads snapshot has the expected file count

If any check fails, it exits with code 1 — which means cron's MAILTO kicks in and I get an email. Simple but effective.

</details>

## Things That Went Wrong (Because Of Course They Did)

No migration story is complete without the war stories. Here are the highlights:

### 1. The CrashLoopBackOff Surprise

After deploying Roomler to K8s, the pod kept crashing and restarting. The logs showed `ioredis ETIMEDOUT` errors, but Redis was perfectly healthy. The actual problem? **The startup probe was too aggressive.**

Roomler uses PM2 in cluster mode, which spawns 4 Node.js workers. Each worker needs to:
- Connect to MongoDB
- Connect to Redis
- Build Nuxt SSR renderer

This takes about 30-60 seconds. But the liveness probe started checking at 30 seconds with only a 5-failure budget. The pod was getting killed before it could finish starting.

Fix: Add a proper **startup probe** with generous timeouts:

```yaml
startupProbe:
  tcpSocket:
    port: 3000
  initialDelaySeconds: 10
  periodSeconds: 5
  failureThreshold: 30    # 10 + (30 * 5) = 160 seconds to start
```

### 2. The COTURN Auth Mode Saga

COTURN supports two auth modes:
- `lt-cred-mech` — static username/password (simple but less secure)
- `use-auth-secret` — ephemeral HMAC-SHA1 credentials (more secure)

I accidentally switched to `lt-cred-mech` in an earlier session, then forgot about it. Roomler was sending ephemeral credentials to a server expecting static passwords. Every TURN connection failed silently — users just couldn't join video calls.

The debugging was extra painful because `turnutils_uclient` (the CLI test tool) doesn't properly support `use-auth-secret` mode. It always says "cannot find credentials" even when the config is correct. The only reliable way to test is with a real browser.

### 3. The Wildcard DNS Trap

I had a wildcard DNS record `*.roomler.live` pointing to an old server IP. When I added `coturn.roomler.live` as an explicit A record, it worked fine. But `janus.roomler.live` — which I forgot to add explicitly — still resolved to the old IP via the wildcard.

I spent an embarrassingly long time debugging "why Janus can't connect" before realizing the DNS was pointing to a server 500km away.

### 4. MongoDB 4.0 → 7.x Was... Anticlimactic?

I was bracing for pain with the major version upgrade. Backup strategies, rollback plans, test restores. In the end:

```bash
mongodump --db roomlerdb --archive --gzip > backup.archive.gz
# Copy to K8s...
mongorestore --archive < backup.archive.gz
```

30 seconds. 17,000+ documents. Zero errors. All data intact. I felt slightly robbed of a war story, but I'll take it.

## The Full Playbook (Literally)

Everything is automated with Ansible. Here's how to reproduce the entire deployment:

```bash
# Clone the repo
git clone https://github.com/gjovanov/roomler-deploy.git
cd roomler-deploy

# Configure secrets
cp .env.example .env
vi .env

# First-time migration (from Docker)
./scripts/migrate-data.sh
./scripts/deploy.sh
./scripts/restore-mongodb.sh

# Cut over from Docker to K8s
sudo ./scripts/cutover.sh

# Set up automated backups
./scripts/setup-backup-cron.sh

# Verify everything
./scripts/verify-backups.sh
curl -I https://roomler.live  # Should be 200 OK
```

Total time from "I have a Docker setup" to "everything runs in K8s with backups": about 30 minutes. Not bad for a full production migration.

## Was It Worth It?

Absolutely. Here's what we gained:

| Before (Docker) | After (K8s) |
|-----------------|-------------|
| Manual container management | Declarative deployments, auto-restart |
| No health checks | Startup + liveness + readiness probes |
| No resource limits | CPU/memory requests and limits |
| No backup automation | Daily cron: mongodump + rsync + verify |
| MongoDB 4.0 (EOL since 2022) | MongoDB 7.x (current LTS) |
| 7 Docker containers (2 nginx) | 4 K8s pods + 1 nginx |
| "It works on my machine" | Reproducible Ansible playbook |

And the best part? The Roomler community now has a fully documented, open-source deployment guide. No more "how do I deploy this in K8s?" questions. Just point them here.

## Related Resources

- **K8s cluster setup** (Part 1): [github.com/gjovanov/k8s-cluster](https://github.com/gjovanov/k8s-cluster) — bootstrapping the cluster + COTURN deployment
- **This deployment repo**: [github.com/gjovanov/roomler-deploy](https://github.com/gjovanov/roomler-deploy) — full Ansible playbook + scripts
- **Roomler app**: [github.com/gjovanov/roomler](https://github.com/gjovanov/roomler) — the application source code
- **Live demo**: [roomler.live](https://roomler.live) — try it yourself!

If you found this useful, star the repos, share with your K8s-curious friends, and drop me an issue if something doesn't work for you. I actually fix those. Usually.

Talk to you soon!
