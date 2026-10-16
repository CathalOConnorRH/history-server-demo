#!/usr/bin/env python3
"""
Idempotently patches an EXISTING RayCluster so it starts reporting history
(events + logs) to the history server, without touching anything else in the
spec. Safe to re-run: every change is "add if missing", nothing is ever
overwritten or duplicated on a second run.

What it adds:
  - metadata.annotations["odh.ray.io/secure-trusted-network"] = "true"
    (triggers the RHOAI/ODH KubeRay operator to auto-create the OAuth-proxy
    ServiceAccount + kube-rbac-proxy sidecar -- no manual RBAC needed)
  - headGroupSpec.rayStartParams.dashboard-host = "0.0.0.0"
  - on the head container and every worker-group's main ray container:
      - the RAY_* event-reporting env vars
      - a postStart lifecycle hook that captures the raylet's node_id
      - a volumeMount for the shared `ray-logs` emptyDir
  - a `ray-logs` emptyDir volume on each pod template
  - a `collector` sidecar container (role=Head / role=Worker) wired to the
    S3 bucket/region/credentials you pass in

Usage (dry run, prints the patched RayCluster YAML to stdout):
  python3 patch-existing-raycluster.py \\
    --name raycluster-prod --namespace ray-prod \\
    --s3-bucket <your-namespace>-ray-history --s3-region us-east-1 \\
    --s3-secret-name ray-history-s3-creds \\
    --collector-image quay.io/<your-namespace>/collector:v1.0.0

Usage (apply directly to the cluster via `oc apply`):
  python3 patch-existing-raycluster.py ... --apply

Requires: python3 -m pip install pyyaml  (plus `oc` or `kubectl` on PATH).
"""
import argparse
import copy
import subprocess
import sys

try:
    import yaml
except ImportError:
    sys.exit(
        "Missing dependency: PyYAML. Install it with:\n"
        "    python3 -m pip install pyyaml"
    )

EVENT_ENV_VARS = [
    {"name": "RAY_enable_ray_event", "value": "1"},
    {
        "name": "RAY_DASHBOARD_AGGREGATOR_AGENT_EVENTS_EXPORT_ADDR",
        "value": "http://localhost:8084/v1/events",
    },
    {
        "name": "RAY_DASHBOARD_AGGREGATOR_AGENT_EXPOSABLE_EVENT_TYPES",
        "value": (
            "TASK_DEFINITION_EVENT,TASK_LIFECYCLE_EVENT,ACTOR_TASK_DEFINITION_EVENT,"
            "TASK_PROFILE_EVENT,DRIVER_JOB_DEFINITION_EVENT,DRIVER_JOB_LIFECYCLE_EVENT,"
            "ACTOR_DEFINITION_EVENT,ACTOR_LIFECYCLE_EVENT,NODE_DEFINITION_EVENT,"
            "NODE_LIFECYCLE_EVENT"
        ),
    },
    {"name": "RAY_enable_core_worker_ray_event_to_aggregator", "value": "1"},
]

POST_START_COMMAND = [
    "/bin/sh",
    "-c",
    (
        "for i in $(seq 1 120); do\n"
        "  id=$(ps -ef | grep '[r]aylet' | grep -oE -- '--node_id=[0-9a-f]+' | head -1 | cut -d= -f2)\n"
        '  if [ -n "$id" ]; then echo "$id" > /tmp/ray/raylet_node_id; exit 0; fi\n'
        "  sleep 1\n"
        "done\n"
    ),
]

RAY_LOGS_VOLUME_NAME = "ray-logs"
RAY_LOGS_MOUNT_PATH = "/tmp/ray"
SECURE_TRUSTED_NETWORK_ANNOTATION = "odh.ray.io/secure-trusted-network"


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def get_kube_cli():
    for cli in ("oc", "kubectl"):
        if run(["which", cli]).returncode == 0:
            return cli
    sys.exit("Neither `oc` nor `kubectl` found on PATH.")


def fetch_raycluster(cli, name, namespace):
    result = run([cli, "get", "raycluster", name, "-n", namespace, "-o", "yaml"])
    if result.returncode != 0:
        sys.exit(f"Failed to fetch RayCluster {namespace}/{name}:\n{result.stderr}")
    return yaml.safe_load(result.stdout)


def merge_env(existing_env, new_vars):
    """Append any env var in new_vars whose name isn't already present."""
    existing_env = existing_env or []
    existing_names = {e["name"] for e in existing_env}
    for var in new_vars:
        if var["name"] not in existing_names:
            existing_env.append(copy.deepcopy(var))
    return existing_env


def is_main_ray_container(container):
    name = container.get("name", "")
    return name not in ("collector", "kube-rbac-proxy") and not name.startswith(
        "oauth-proxy"
    )


def ensure_volume(pod_spec):
    volumes = pod_spec.setdefault("volumes", [])
    if not any(v.get("name") == RAY_LOGS_VOLUME_NAME for v in volumes):
        volumes.append({"name": RAY_LOGS_VOLUME_NAME, "emptyDir": {}})


def patch_main_container(container):
    container["env"] = merge_env(container.get("env"), EVENT_ENV_VARS)

    if "lifecycle" not in container or not container["lifecycle"].get("postStart"):
        container["lifecycle"] = {
            "postStart": {"exec": {"command": copy.deepcopy(POST_START_COMMAND)}}
        }
    else:
        print(
            f"  WARNING: container '{container.get('name')}' already has a "
            "postStart lifecycle hook -- leaving it untouched. The collector "
            "needs /tmp/ray/raylet_node_id written once the raylet starts; "
            "make sure your existing hook does this too, or the collector "
            "may not tag events with the correct node ID.",
            file=sys.stderr,
        )

    mounts = container.setdefault("volumeMounts", [])
    if not any(m.get("mountPath") == RAY_LOGS_MOUNT_PATH for m in mounts):
        mounts.append({"name": RAY_LOGS_VOLUME_NAME, "mountPath": RAY_LOGS_MOUNT_PATH})


def collector_env(args):
    env = [
        {"name": "RAY_TMP_ROOT", "value": RAY_LOGS_MOUNT_PATH},
        {"name": "S3_BUCKET", "value": args.s3_bucket},
        {"name": "S3_REGION", "value": args.s3_region},
        {"name": "S3_ENDPOINT", "value": args.s3_endpoint},
        {"name": "S3FORCE_PATH_STYLE", "value": args.s3_force_path_style},
        {"name": "S3DISABLE_SSL", "value": args.s3_disable_ssl},
        {
            "name": "AWS_S3ID",
            "valueFrom": {
                "secretKeyRef": {"name": args.s3_secret_name, "key": "AWS_S3ID"}
            },
        },
        {
            "name": "AWS_S3SECRET",
            "valueFrom": {
                "secretKeyRef": {"name": args.s3_secret_name, "key": "AWS_S3SECRET"}
            },
        },
    ]
    if args.ssl_cert_file:
        env.append({"name": "SSL_CERT_FILE", "value": args.ssl_cert_file})
    return env


def build_collector_container(role, ray_cluster_name, ray_cluster_id, args):
    env = collector_env(args)
    if role == "Head":
        env.insert(
            1, {"name": "RAY_DASHBOARD_ADDRESS", "value": "http://localhost:8265"}
        )
        env.insert(2, {"name": "RAY_COLLECTOR_POLL_INTERVAL", "value": "30s"})
    return {
        "name": "collector",
        "image": args.collector_image,
        "imagePullPolicy": "Always",
        "command": ["collector"],
        "args": [
            f"--role={role}",
            "--runtime-class-name=s3",
            f"--ray-cluster-name={ray_cluster_name}",
            f"--ray-cluster-id={ray_cluster_id}",
            "--ray-root-dir=log",
            "--events-port=8084",
        ],
        "env": env,
        "volumeMounts": [
            {"name": RAY_LOGS_VOLUME_NAME, "mountPath": RAY_LOGS_MOUNT_PATH}
        ],
    }


def ensure_collector(pod_spec, role, ray_cluster_name, ray_cluster_id, args):
    containers = pod_spec.setdefault("containers", [])
    if any(c.get("name") == "collector" for c in containers):
        print(
            f"  '{role}' pod template already has a collector container, skipping.",
            file=sys.stderr,
        )
        return
    containers.append(
        build_collector_container(role, ray_cluster_name, ray_cluster_id, args)
    )


def patch_raycluster(rc, args):
    rc.setdefault("metadata", {}).setdefault("annotations", {})
    rc["metadata"]["annotations"][SECURE_TRUSTED_NETWORK_ANNOTATION] = "true"

    ray_cluster_name = rc["metadata"]["name"]
    ray_cluster_id = rc["metadata"]["namespace"]

    head = rc["spec"]["headGroupSpec"]
    head.setdefault("rayStartParams", {})["dashboard-host"] = "0.0.0.0"
    head_pod_spec = head["template"]["spec"]
    for c in head_pod_spec.get("containers", []):
        if is_main_ray_container(c):
            print(f"Patching head container '{c['name']}'...", file=sys.stderr)
            patch_main_container(c)
    ensure_volume(head_pod_spec)
    ensure_collector(head_pod_spec, "Head", ray_cluster_name, ray_cluster_id, args)

    for wg in rc["spec"].get("workerGroupSpecs", []):
        worker_pod_spec = wg["template"]["spec"]
        for c in worker_pod_spec.get("containers", []):
            if is_main_ray_container(c):
                print(
                    f"Patching worker group '{wg.get('groupName')}' "
                    f"container '{c['name']}'...",
                    file=sys.stderr,
                )
                patch_main_container(c)
        ensure_volume(worker_pod_spec)
        ensure_collector(
            worker_pod_spec, "Worker", ray_cluster_name, ray_cluster_id, args
        )

    return rc


def strip_server_fields(rc):
    """Remove fields the API server owns, so this object is valid for apply."""
    meta = rc.get("metadata", {})
    for field in (
        "creationTimestamp",
        "generation",
        "resourceVersion",
        "uid",
        "selfLink",
        "managedFields",
    ):
        meta.pop(field, None)
    # Stale copy of a *previous* apply's spec, embedded as a JSON string by
    # kubectl/oc. Harmless to leave, but it duplicates the entire old spec as
    # a wall of text in the diff/dry-run output and in `oc apply`'s 3-way
    # merge it will simply be regenerated to match the new spec anyway.
    annotations = meta.get("annotations", {})
    annotations.pop("kubectl.kubernetes.io/last-applied-configuration", None)
    rc.pop("status", None)
    return rc


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True, help="Existing RayCluster name")
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--s3-bucket", required=True)
    parser.add_argument("--s3-region", required=True)
    parser.add_argument(
        "--s3-secret-name",
        required=True,
        help="Secret with AWS_S3ID / AWS_S3SECRET keys (see manifests/01-secret-s3-credentials.yaml.tpl)",
    )
    parser.add_argument(
        "--s3-endpoint",
        default="",
        help="Leave empty for AWS S3 (SDK resolves the regional endpoint "
        "automatically). Set to e.g. https://minio.example.com:9000 for "
        "MinIO or another S3-compatible store.",
    )
    parser.add_argument(
        "--s3-force-path-style",
        choices=["true", "false"],
        default="false",
        help="'false' for AWS S3 (virtual-hosted-style). 'true' for MinIO.",
    )
    parser.add_argument(
        "--s3-disable-ssl",
        choices=["true", "false"],
        default="false",
        help="'false' to always use TLS (required for AWS S3; recommended "
        "for MinIO too unless it's plain HTTP internally).",
    )
    parser.add_argument(
        "--ssl-cert-file",
        default="",
        help="Only needed against an S3-compatible endpoint (e.g. MinIO) "
        "whose TLS cert isn't publicly trusted, e.g. "
        "/var/run/secrets/kubernetes.io/serviceaccount/service-ca.crt. "
        "Leave empty for AWS S3.",
    )
    parser.add_argument("--collector-image", required=True)
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Apply the patched RayCluster to the cluster. Without this flag, "
        "the patched YAML is only printed to stdout for review (dry run).",
    )
    args = parser.parse_args()

    cli = get_kube_cli()
    print(f"Fetching {args.namespace}/{args.name} via `{cli}`...", file=sys.stderr)
    rc = fetch_raycluster(cli, args.name, args.namespace)

    patched = patch_raycluster(rc, args)
    patched = strip_server_fields(patched)
    rendered = yaml.dump(patched, sort_keys=False)

    if args.apply:
        print(f"Applying patched RayCluster {args.namespace}/{args.name}...", file=sys.stderr)
        result = subprocess.run(
            [cli, "apply", "-f", "-"], input=rendered, text=True
        )
        sys.exit(result.returncode)
    else:
        print(rendered)
        print(
            "\n# Dry run only. Review the YAML above, then re-run with --apply "
            "to apply it, or pipe it yourself:\n"
            f"#   python3 {sys.argv[0]} ... | {cli} apply -f -",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
