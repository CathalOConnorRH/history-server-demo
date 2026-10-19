# KubeRay History Server + Dashboard — Deployment Package

This directory is a self-contained package to reproduce the Ray job/task
**history server**, its **collector** sidecar, and the **KubeRay dashboard**
on another OpenShift cluster, backed by **AWS S3 by default** (MinIO /
other S3-compatible stores are also supported — see
[S3 backend](#s3-backend-aws-s3-default-vs-minio) — but this package does not
deploy a MinIO server itself).

| Component | What it is | Where it runs |
|---|---|---|
| `historyserver` | Standalone HTTP server. Serves completed/historical Ray session data (jobs, tasks, actors, logs) out of S3 to the dashboard. | 1 Deployment, cluster-wide (not per-RayCluster) |
| `collector` | Sidecar container injected into **every** Ray head/worker pod. Streams live events + logs to S3 in the layout `historyserver` expects. | 1 sidecar container per Ray pod, in every `RayCluster` you want tracked |
| `kuberay-dashboard` | Next.js UI. Talks only to `historyserver` over HTTP (`HISTORYSERVER_DOMAIN`) — it has no direct dependency on any live RayCluster. | 1 Deployment, cluster-wide |

```
Browser ──> Route (reencrypt) ──> oauth-proxy ──> kuberay-dashboard (Next.js)
                                                        │
                                          (server-side proxy, internal)
                                                        ▼
                                                  historyserver ──> S3 bucket
                                                        ^
RayCluster pods: [ray-head|ray-worker] + [collector sidecar] ─────────┘
                                   (writes events/logs to the same S3 bucket)

CLI ──> Route (reencrypt) ──> oauth-proxy ──> historyserver ──> S3 bucket
        (Bearer token via `oc whoami -t`)
```

## Directory layout

```
Repo/
├── README.md                              <- you are here
├── .env.example                           <- copy to .env, fill in, never commit .env
├── images/
│   ├── Dockerfile.historyserver           <- UBI9-based, multi-stage Go build
│   ├── Dockerfile.collector               <- same base, builds the collector binary
│   ├── Dockerfile.dashboard                <- Next.js standalone build
│   ├── dashboard-basepath.patch           <- source patch, only needed if dashboard
│   │                                          is served under a path prefix
│   └── build-and-push.sh                  <- builds + pushes all 3 images
├── manifests/
│   ├── 00-namespace.yaml.tpl
│   ├── 01-secret-s3-credentials.yaml.tpl
│   ├── 02-historyserver.yaml.tpl          <- SA + auth-delegator CRB + Deployment (+ oauth-proxy sidecar) + Service + Route
│   ├── 03-dashboard.yaml.tpl              <- SA + auth-delegator CRB + anyuid RoleBinding + Deployment (+ oauth-proxy sidecar) + Service + Route
│   ├── 04-dashboard-httproute.yaml.tpl.example  <- optional Gateway API alternative (includes ReferenceGrant for cross-namespace backendRef)
│   └── 05-raycluster-new.yaml.tpl         <- full NEW RayCluster, collector pre-wired
├── examples/
│   └── sample-workload.py                 <- Ray tasks + actors to validate the pipeline
└── scripts/
    ├── install.sh                         <- renders + applies the manifests above
    ├── patch-existing-raycluster.py       <- adds the collector to an EXISTING RayCluster
    ├── patch-existing-raycluster.sh       <- .env-driven wrapper around the above
    └── verify.sh                          <- post-install health checks
```

## Important considerations

The Ray History Server is an **upstream community feature** introduced in
[KubeRay v1.6](https://github.com/ray-project/kuberay/releases) and is
currently in **alpha** status. It is **not included in or supported by
Red Hat OpenShift AI**. Keep the following in mind:

- **Alpha API** — future KubeRay releases may include breaking changes to
  the history server API, configuration format, and storage layout.
- **Not FIPS-compliant** — the upstream Go binaries do not use FIPS-validated
  cryptographic libraries. If your environment requires FIPS compliance,
  you will need to rebuild with `go-toolset-fips` or equivalent.
- **Single-tenant by design** — the historyserver serves events from every
  cluster session in the bucket. Any authenticated user who can reach the
  Route can view data from any session. This package adds OpenShift OAuth
  authentication (see [Auth](#auth--security-context-what-actually-needs-configuring)),
  but does not add per-namespace or per-cluster authorization.
- **Event storage size** — typical sessions produce 10–50 MB of events in
  S3. Plan bucket lifecycle / retention policies accordingly for
  long-running environments.

This setup is intended for **development, testing, and evaluation** where
you need post-mortem debugging today and are comfortable with the
limitations above. For production multi-tenant environments, watch for
official Red Hat OpenShift AI integration in a future release.

## Prerequisites

1. **OpenShift cluster with the KubeRay operator installed.** This package
   assumes the Red Hat OpenShift AI 3.5 (RHOAI/ODH) build of the KubeRay operator
   (`registry.redhat.io/rhoai/odh-kuberay-operator-controller-rhel9`),
   installed via the RHOAI operator subscription with the `ray` component
   enabled in the `DataScienceCluster` CR. 
2. **An S3 bucket** (can be auto-created on first write, see below) — either
   a real AWS S3 bucket with an **IAM user or role scoped to it** (access
   key + secret, or an STS session token), or an existing MinIO/S3-compatible
   endpoint with equivalent credentials. The example AWS IAM policy is in
   `manifests/01-secret-s3-credentials.yaml.tpl`; see
   [S3 backend](#s3-backend-aws-s3-default-vs-minio) for the MinIO option.
3. `oc` (or `kubectl`), `envsubst` (GNU gettext), and `openssl` (for
   auto-generating `OAUTH_COOKIE_SECRET` — skip if you set it manually)
   always; `python3` with `pyyaml` (`pip install pyyaml`) if patching an
   existing RayCluster.

## Required permissions — who can install vs. who can use

### Installing (deploying the stack)

**`cluster-admin` is required.** A standard user — even one with the
`admin` role on the target namespace — **cannot** run `install.sh`
successfully. The manifests create three types of resource that only a
cluster administrator can create:

| Resource | Why it needs cluster-admin |
|---|---|
| **Namespace** (`00-namespace.yaml.tpl`) | Creating a Namespace (not a Project) requires the `create namespaces` cluster-level permission. On managed clusters (ROSA, OSD), the `self-provisioner` ClusterRoleBinding is typically disabled or creates Projects only. |
| **ClusterRoleBinding** to `system:auth-delegator` (`02-historyserver.yaml.tpl`, `03-dashboard.yaml.tpl`) | Both the historyserver and dashboard ServiceAccounts need a **cluster-scoped** ClusterRoleBinding so their OAuth proxy sidecars can call `TokenReview` / `SubjectAccessReview`. No namespace-scoped role can create a ClusterRoleBinding. |
| **RoleBinding** to `system:openshift:scc:anyuid` (`03-dashboard.yaml.tpl`) | The dashboard image runs as a fixed non-root UID that falls outside the namespace's auto-allocated range. Binding the `anyuid` SCC ClusterRole requires the `bind` verb on that ClusterRole, which the namespace `admin` role does **not** grant — only cluster-admin can do it. |

If someone else administers the cluster for you, ask them to run
`install.sh` (or to apply the rendered manifests). Once the stack is
deployed, day-to-day usage does **not** require cluster-admin.

### Using the deployed dashboard and historyserver

**Any authenticated OpenShift user with `view`, `edit`, or `admin` on the
namespace can access the Routes.** Both Routes are fronted by an OAuth proxy
configured with:

```
--openshift-delegate-urls={"/":{"resource":"services","verb":"get","namespace":"<NAMESPACE>"}}
```

This means the proxy performs a `SubjectAccessReview` checking whether the
caller can **`get services`** in the deployment namespace. The built-in
`view`, `edit`, and `admin` roles all include this permission, so any user
who has been granted one of these roles on the namespace is authorised.

| Scenario | Access? |
|---|---|
| Cluster-admin | ✅ Yes |
| User with `admin` role on the namespace | ✅ Yes |
| User with `edit` role on the namespace | ✅ Yes |
| User with `view` role on the namespace | ✅ Yes |
| Authenticated user with **no** role on the namespace | ❌ No (403 Forbidden) |
| Unauthenticated request | ❌ No (login redirect / 403) |

To grant a colleague access without any elevated privileges:

```bash
oc adm policy add-role-to-user view <username> -n <NAMESPACE>
```

### Patching an existing RayCluster

Running `scripts/patch-existing-raycluster.sh` only modifies the
`RayCluster` CR and its namespace-scoped resources. A user with **`edit`**
(or `admin`) on the RayCluster's namespace can run it — cluster-admin is
not required for this step alone (assuming the historyserver stack was
already deployed by an admin).

### Optional HTTPRoute (Gateway API) — cross-namespace permissions

If you enable the optional `04-dashboard-httproute.yaml.tpl.example`
manifest, be aware that it creates resources in **two** namespaces:

| Resource | Namespace | Why |
|---|---|---|
| `HTTPRoute` | `${GATEWAY_NAMESPACE}` (e.g. `openshift-ingress`) | Must be co-located with the Gateway it attaches to via `parentRefs` |
| `ReferenceGrant` | `${NAMESPACE}` (e.g. `ray-history`) | Authorises the HTTPRoute in the gateway namespace to reference the `kuberay-dashboard` Service cross-namespace |

The `ReferenceGrant` is **required by the Gateway API spec** — without it,
the Gateway controller rejects the cross-namespace `backendRef` with a
`RefNotPermitted` status and traffic will not reach the dashboard. The
grant included in the manifest is scoped narrowly: it only allows
`HTTPRoute` resources from `${GATEWAY_NAMESPACE}` to reference `Service`
resources in `${NAMESPACE}`.

The installing user therefore needs permission to create resources in
**both** namespaces (`HTTPRoute` in the gateway namespace, `ReferenceGrant`
in the application namespace). On most clusters this still requires
cluster-admin, since the gateway namespace is typically managed
infrastructure.

## Quick start — brand-new cluster, brand-new RayCluster

The `.env.example` defaults already point at pre-built images
(`quay.io/cathaloconnor/{historyserver,collector,kuberay-dashboard}`),
so no build step is required to get started:

```bash
cp .env.example .env
vi .env   # fill in NAMESPACE, S3_*, AWS_*, etc. -- image refs already set

# 1. Stand up historyserver + dashboard, and (optionally) a new RayCluster
./scripts/install.sh --with-raycluster

# 2. Verify
./scripts/verify.sh
```

Without `--with-raycluster`, step 1 only deploys `historyserver` and
`kuberay-dashboard` — use this if you're adding history-server support to
RayClusters that already exist (see next section).

### Validating the pipeline with a sample workload

Once the RayCluster is running, submit the sample workload to generate
events that flow through the collector → S3 → historyserver → dashboard:

```bash
# Copy the script into the head pod and run it:
HEAD_POD=$(oc get pods -n ${NAMESPACE} -l "ray.io/cluster=${RAYCLUSTER_NAME},ray.io/node-type=head" -o jsonpath='{.items[0].metadata.name}')
oc cp examples/sample-workload.py ${NAMESPACE}/${HEAD_POD}:/tmp/sample-workload.py -c ray-head
oc exec -n ${NAMESPACE} ${HEAD_POD} -c ray-head -- python /tmp/sample-workload.py
```

The script submits 20 remote tasks and creates a stateful actor, generating
task/actor definition and lifecycle events. These should appear in the
dashboard within ~30–60 seconds (one collector poll cycle).

### Post-mortem debugging — browsing a deleted cluster

The core value of the history server is **debugging clusters that no longer
exist**. After the sample workload completes, delete the RayCluster to
simulate the ephemeral cluster lifecycle:

```bash
oc delete raycluster ${RAYCLUSTER_NAME} -n ${NAMESPACE}
# Wait a few seconds for the collector's graceful shutdown to flush
# remaining events to S3 before the pod terminates.
```

The RayCluster and all its pods are now gone, but the events are preserved
in S3. Open the dashboard in your browser — the deleted cluster's session
still appears and you can browse its tasks, actors, jobs, and logs as if
the cluster were still running.

To re-create the cluster for further testing, re-run `install.sh --with-raycluster`.

### Browsing history via the CLI

The historyserver exposes the same Ray Dashboard API endpoints. You can
query them directly with `curl` and a bearer token. This is useful for
scripting, CI integration, or when the dashboard UI is not available.

```bash
# Shorthand
HS=https://$(oc get route historyserver -n ${NAMESPACE} -o jsonpath='{.spec.host}')
TOKEN=$(oc whoami -t)

# 1. List available cluster sessions
curl -sk -H "Authorization: Bearer $TOKEN" "$HS/clusters" | python3 -m json.tool

# 2. Enter a session (loads events into memory — first call takes a few seconds)
#    Replace <session-id> with a value from the /clusters response, e.g.
#    session_2026-10-16_16-08-42_177326_1
curl -sk -c /tmp/hs-cookies.txt \
  -H "Authorization: Bearer $TOKEN" \
  "$HS/enter_cluster/${NAMESPACE}/${RAYCLUSTER_NAME}/<session-id>"

# 3. Query tasks
curl -sk -b /tmp/hs-cookies.txt \
  -H "Authorization: Bearer $TOKEN" \
  "$HS/api/v0/tasks" | python3 -m json.tool

# 4. Query actors
curl -sk -b /tmp/hs-cookies.txt \
  -H "Authorization: Bearer $TOKEN" \
  "$HS/logical/actors" | python3 -m json.tool

# 5. View node summary
curl -sk -b /tmp/hs-cookies.txt \
  -H "Authorization: Bearer $TOKEN" \
  "$HS/nodes?view=summary" | python3 -m json.tool
```

Note: the historyserver uses a session cookie (`cluster_cookie`) to track
which cluster session you are viewing. The `-c` / `-b` flags on `curl`
save and send this cookie across requests.

## Applying history-server support to an EXISTING RayCluster

Once `historyserver` is deployed (quick start step 1, without
`--with-raycluster`), wire up each existing `RayCluster` with:

```bash
# Dry run first -- prints the patched RayCluster YAML, changes nothing:
./scripts/patch-existing-raycluster.sh <raycluster-name> <raycluster-namespace>

# Review the diff, then apply for real:
./scripts/patch-existing-raycluster.sh <raycluster-name> <raycluster-namespace> --apply
```

This script (`scripts/patch-existing-raycluster.py` under the hood):
- is **idempotent** — re-running it is always safe, it only adds what's
  missing, never duplicates or overwrites unrelated config
- adds the `odh.ray.io/secure-trusted-network: "true"` annotation
- adds the `RAY_*` event-reporting env vars to the head/worker `ray-*`
  containers
- adds a `postStart` hook that captures the raylet's node ID (warns instead
  of overwriting if the container already has one — see the script's output)
- adds the shared `ray-logs` `emptyDir` volume + mount
- appends a `collector` sidecar container (role `Head`/`Worker`) wired to
  your S3 bucket/credentials

Patching an existing RayCluster **restarts its pods** (new container =
new pod spec hash), so plan for a brief interruption to running Ray
workloads.

If you'd rather write your own merge patch instead of using the script
(e.g. for GitOps), `manifests/05-raycluster-new.yaml.tpl`'s
`headGroupSpec`/`workerGroupSpecs` are a complete reference for exactly what
needs to be present — the script and the template produce equivalent output.

## Auth / security context: what actually needs configuring

Good news — almost none of this is manual:

- **RayCluster → Ray dashboard API (port 8265) auth**: fully automatic.
  The only thing you add is the `odh.ray.io/secure-trusted-network: "true"`
  annotation on the `RayCluster`. The RHOAI KubeRay operator watches for it
  and automatically creates a dedicated `<name>-oauth-proxy-sa`
  ServiceAccount (owned by the RayCluster, cleaned up via the
  `ray.io/authentication-resources` finalizer on delete) and injects a
  `kube-rbac-proxy` sidecar that authenticates access to the dashboard port.
  **No RBAC, Role, or RoleBinding needs to be created by you for this.**
- **`historyserver` and `kuberay-dashboard` Route auth (OAuth proxy)**:
  both Routes are fronted by an OpenShift `oauth-proxy` sidecar that
  authenticates all external access. Unauthenticated requests receive a
  `403 Forbidden` (or a login-page redirect in a browser). Each manifest
  creates:
    - A **ServiceAccount** with an `oauth-redirectreference` annotation
      (registers the Route as the OAuth redirect target)
    - A **ClusterRoleBinding** to `system:auth-delegator` (lets the
      oauth-proxy validate bearer tokens via `TokenReview` and check
      authorization via `SubjectAccessReview`)
    - An **oauth-proxy sidecar** container in the Deployment, configured
      with `--openshift-delegate-urls` so that any user who can `get
      services` in the namespace is authorised

  Browser users are redirected to the OpenShift login page. CLI / API
  access works with a bearer token:
  ```bash
  curl -H "Authorization: Bearer $(oc whoami -t)" https://<route>/...
  ```
  The `OAUTH_COOKIE_SECRET` is auto-generated by `install.sh` if not set
  in `.env`. Set it explicitly and persist it in `.env` for consistency
  across re-installs.
- **`collector` ServiceAccount**: plain default ServiceAccount, no extra
  RBAC. The collector only talks to the local Ray dashboard agent and S3.
  (The historyserver binary *does* support an optional
  `--use-kubernetes-proxy` mode for proxying to live clusters' K8s-exposed
  dashboards, which does need RBAC — this package doesn't enable it, since
  it isn't required for the historical-data flow described here.)
- **`kuberay-dashboard` ServiceAccount — `anyuid` SCC**: the Next.js
  production image's Dockerfile fixes a non-root UID (`USER nextjs`, uid
  1001). OpenShift's default `restricted-v2` SCC only allows UIDs from the
  namespace's auto-allocated range, not an arbitrary fixed one, so the pod
  won't start without a grant. `manifests/03-dashboard.yaml.tpl` includes
  the necessary RoleBinding to `system:openshift:scc:anyuid`, scoped to just
  this ServiceAccount in this namespace. If your target namespace already
  permits fixed non-root UIDs under a different policy, this is harmless to
  leave in place.
- **Route TLS**: `reencrypt` termination with HTTP→HTTPS redirect. Traffic
  is encrypted all the way from the OpenShift router to the oauth-proxy
  sidecar (which serves TLS via an auto-generated service-serving cert).
  No client cert / mTLS is configured; add it at the Route/Gateway layer
  if your environment requires it.

## S3 backend: AWS S3 (default) vs. MinIO

Every template (`historyserver` Deployment, the `collector` sidecar in both
the new-RayCluster template and the patcher script) reads the same 6
variables for its storage backend: `S3_BUCKET`, `S3_REGION`, `S3_ENDPOINT`,
`S3FORCE_PATH_STYLE`, `S3DISABLE_SSL`, `SSL_CERT_FILE`, plus
`AWS_S3ID`/`AWS_S3SECRET` from the Secret. `.env.example` has both options
side by side — AWS S3 active by default, with the MinIO alternative values
provided as a commented-out block to swap in.

**This package does not deploy a MinIO server.** The MinIO option is only
for pointing at a MinIO (or other S3-compatible store) you already have
running and reachable from the cluster — e.g. if you are already running MinIO
for other workloads and want to reuse it instead of standing up AWS access.

| Setting | AWS S3 (default) | MinIO / other S3-compatible |
|---|---|---|
| `S3_ENDPOINT` | **empty** — the AWS SDK resolves the standard regional endpoint for `S3_REGION` automatically. Only set this if routing through a VPC endpoint. | `host:port` of your MinIO service, e.g. `minio.my-ns.svc:443` |
| `S3_REGION` | a real AWS region, e.g. `us-east-1` | any non-empty placeholder (MinIO mostly ignores it, but the AWS SDK requires something) |
| `S3FORCE_PATH_STYLE` | `"false"` (virtual-hosted-style; required by most current AWS regions) | `"true"` (required for MinIO) |
| `S3DISABLE_SSL` | `"false"` (always TLS against AWS) | `"false"` unless MinIO is plain HTTP internally |
| `SSL_CERT_FILE` | **empty** — AWS's publicly-trusted cert is validated by the `ca-certificates` package already in the runtime image; an empty value is ignored by Go's x509 loader, same as leaving it unset | path to a CA bundle, if MinIO's TLS cert isn't publicly trusted (e.g. an internally-signed OpenShift service-ca cert: `/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt`) |
| `AWS_S3ID` / `AWS_S3SECRET` | a real AWS IAM access key/secret (or STS token via the also-supported `AWS_S3TOKEN`) | MinIO access/secret key |

The historyserver/collector code always builds an explicit AWS session via
`credentials.NewStaticCredentials(...)` regardless of backend — it does
**not** fall back to the default AWS credential chain (no automatic EC2
instance-profile or IRSA detection). You must supply
`AWS_S3ID`/`AWS_S3SECRET` via the Secret either way.

For AWS, the configured bucket is **auto-created on first write** if it
doesn't already exist (`s3:CreateBucket` in the IAM policy) — or pre-create
it yourself and drop that permission for tighter scoping. The same applies
to MinIO as long as the credentials have bucket-create permission there too.

If you're using `scripts/patch-existing-raycluster.py` directly (not via the
`.sh` wrapper, which already reads these from `.env`), the equivalent flags
are `--s3-endpoint`, `--s3-force-path-style`, `--s3-disable-ssl`, and
`--ssl-cert-file` (all optional, default to the AWS-friendly values).

## Troubleshooting
- **Dashboard pod stuck in `CreateContainerConfigError`**: almost always the
  missing `anyuid` SCC grant — see [Auth](#auth--security-context-what-actually-needs-configuring).
- **Dashboard loads but assets 404 / API calls go to the wrong path**:
  `DASHBOARD_BASE_PATH` mismatch between the image build arg
  (`NEXT_PUBLIC_BASE_PATH`), the `HISTORYSERVER_PROXY_ENDPOINT` env var, the
  readiness/liveness probe paths, and the Route/HTTPRoute path prefix — all
  four must agree exactly. The pre-built images from `.env.example` were
  built with `NEXT_PUBLIC_BASE_PATH=/kuberay-dashboard`, so
  `DASHBOARD_BASE_PATH` must be set to `/kuberay-dashboard` when using them.
  To serve the dashboard at `/` instead, rebuild the image with
  `NEXT_PUBLIC_BASE_PATH=""` and set `DASHBOARD_BASE_PATH=""` in `.env`.
- **`collector` pod/container not showing up after patching an existing
  RayCluster**: patching a `RayCluster` spec restarts its pods — give it a
  minute, then `oc get pods -n <ns> -l ray.io/cluster=<name>`.

## Clean up

To remove everything deployed by this package:

```bash
# Source .env for variable values
source .env

# Delete the namespace (takes all namespaced resources with it)
oc delete namespace ${NAMESPACE}

# Delete the cluster-scoped ClusterRoleBindings created by the manifests
oc delete clusterrolebinding \
  ${NAMESPACE}:historyserver:auth-delegator \
  ${NAMESPACE}:kuberay-dashboard:auth-delegator
```

This does **not** delete the S3 bucket or its contents — historical events
are preserved and can be served by a future deployment pointing at the same
bucket.
