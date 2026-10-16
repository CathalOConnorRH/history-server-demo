# Template for a NEW RayCluster that reports to the history server from day
# one. For patching an EXISTING RayCluster instead, see
# scripts/patch-existing-raycluster.py.
#
# Required substitutions (beyond the shared .env ones): RAYCLUSTER_NAME,
# RAY_IMAGE. RAYCLUSTER_NAME is used both as metadata.name and as the
# collector's --ray-cluster-name; NAMESPACE doubles as --ray-cluster-id,
# matching the convention used by the reference deployment.
apiVersion: ray.io/v1
kind: RayCluster
metadata:
  name: ${RAYCLUSTER_NAME}
  namespace: ${NAMESPACE}
  annotations:
    # This is the ONLY auth-related setting you need to add. The KubeRay
    # operator (ODH/RHOAI build) watches this annotation and automatically:
    #   - creates a dedicated OAuth-proxy ServiceAccount
    #     (<name>-oauth-proxy-sa), owned by this RayCluster
    #   - injects a `kube-rbac-proxy` sidecar in front of the Ray dashboard
    #     port (8265), exposing it authenticated-only on 8443
    #   - adds the `ray.io/authentication-resources` finalizer to clean those
    #     resources up when the RayCluster is deleted
    # No manual RBAC/ServiceAccount/Role creation is required for this.
    # Requires the RHOAI/ODH KubeRay operator build; if you are running
    # vanilla upstream KubeRay without this controller, remove this
    # annotation (it is a no-op there) and secure dashboard access some other
    # way (e.g. NetworkPolicy + your own OAuth proxy).
    odh.ray.io/secure-trusted-network: "true"
spec:
  rayVersion: "2.55.1"
  headGroupSpec:
    enableIngress: false
    rayStartParams:
      dashboard-host: 0.0.0.0
    template:
      spec:
        containers:
          - name: ray-head
            image: ${RAY_IMAGE}
            env:
              - name: RAY_enable_ray_event
                value: "1"
              - name: RAY_DASHBOARD_AGGREGATOR_AGENT_EVENTS_EXPORT_ADDR
                value: http://localhost:8084/v1/events
              - name: RAY_DASHBOARD_AGGREGATOR_AGENT_EXPOSABLE_EVENT_TYPES
                value: TASK_DEFINITION_EVENT,TASK_LIFECYCLE_EVENT,ACTOR_TASK_DEFINITION_EVENT,TASK_PROFILE_EVENT,DRIVER_JOB_DEFINITION_EVENT,DRIVER_JOB_LIFECYCLE_EVENT,ACTOR_DEFINITION_EVENT,ACTOR_LIFECYCLE_EVENT,NODE_DEFINITION_EVENT,NODE_LIFECYCLE_EVENT
              - name: RAY_enable_core_worker_ray_event_to_aggregator
                value: "1"
            lifecycle:
              postStart:
                exec:
                  # The collector sidecar needs the raylet's node_id to tag
                  # events/logs correctly, but it isn't available until the
                  # raylet process has actually started. Poll for it and drop
                  # it on the shared emptyDir so the collector can read it.
                  command:
                    - /bin/sh
                    - -c
                    - |
                      for i in $(seq 1 120); do
                        id=$(ps -ef | grep '[r]aylet' | grep -oE -- '--node_id=[0-9a-f]+' | head -1 | cut -d= -f2)
                        if [ -n "$id" ]; then echo "$id" > /tmp/ray/raylet_node_id; exit 0; fi
                        sleep 1
                      done
            ports:
              - containerPort: 6379
                name: gcs
              - containerPort: 8265
                name: dashboard
              - containerPort: 10001
                name: client
            volumeMounts:
              - mountPath: /tmp/ray
                name: ray-logs
          - name: collector
            image: ${COLLECTOR_IMAGE}
            imagePullPolicy: Always
            command:
              - collector
            args:
              - --role=Head
              - --runtime-class-name=s3
              - --ray-cluster-name=${RAYCLUSTER_NAME}
              - --ray-cluster-id=${NAMESPACE}
              - --ray-root-dir=log
              - --events-port=8084
            env:
              - name: RAY_TMP_ROOT
                value: /tmp/ray
              - name: RAY_DASHBOARD_ADDRESS
                value: http://localhost:8265
              - name: RAY_COLLECTOR_POLL_INTERVAL
                value: 30s
              # S3 backend config -- must match the historyserver's storage
              # config exactly (same bucket/region/endpoint/credentials).
              # Values come from .env; defaults target AWS S3, see
              # .env.example's "S3 backend" section for the MinIO alternative.
              - name: S3_BUCKET
                value: "${S3_BUCKET}"
              - name: S3_REGION
                value: "${S3_REGION}"
              - name: S3_ENDPOINT
                value: "${S3_ENDPOINT}"
              - name: S3FORCE_PATH_STYLE
                value: "${S3FORCE_PATH_STYLE}"
              - name: S3DISABLE_SSL
                value: "${S3DISABLE_SSL}"
              - name: AWS_S3ID
                valueFrom:
                  secretKeyRef:
                    name: ${S3_SECRET_NAME}
                    key: AWS_S3ID
              - name: AWS_S3SECRET
                valueFrom:
                  secretKeyRef:
                    name: ${S3_SECRET_NAME}
                    key: AWS_S3SECRET
              - name: SSL_CERT_FILE
                value: "${SSL_CERT_FILE}"
            volumeMounts:
              - mountPath: /tmp/ray
                name: ray-logs
        volumes:
          - name: ray-logs
            emptyDir: {}
  workerGroupSpecs:
    - groupName: workers
      replicas: ${WORKER_REPLICAS}
      minReplicas: ${WORKER_MIN_REPLICAS}
      maxReplicas: ${WORKER_MAX_REPLICAS}
      numOfHosts: 1
      rayStartParams: {}
      template:
        spec:
          containers:
            - name: ray-worker
              image: ${RAY_IMAGE}
              env:
                - name: RAY_enable_ray_event
                  value: "1"
                - name: RAY_DASHBOARD_AGGREGATOR_AGENT_EVENTS_EXPORT_ADDR
                  value: http://localhost:8084/v1/events
                - name: RAY_DASHBOARD_AGGREGATOR_AGENT_EXPOSABLE_EVENT_TYPES
                  value: TASK_DEFINITION_EVENT,TASK_LIFECYCLE_EVENT,ACTOR_TASK_DEFINITION_EVENT,TASK_PROFILE_EVENT,DRIVER_JOB_DEFINITION_EVENT,DRIVER_JOB_LIFECYCLE_EVENT,ACTOR_DEFINITION_EVENT,ACTOR_LIFECYCLE_EVENT,NODE_DEFINITION_EVENT,NODE_LIFECYCLE_EVENT
                - name: RAY_enable_core_worker_ray_event_to_aggregator
                  value: "1"
              lifecycle:
                postStart:
                  exec:
                    command:
                      - /bin/sh
                      - -c
                      - |
                        for i in $(seq 1 120); do
                          id=$(ps -ef | grep '[r]aylet' | grep -oE -- '--node_id=[0-9a-f]+' | head -1 | cut -d= -f2)
                          if [ -n "$id" ]; then echo "$id" > /tmp/ray/raylet_node_id; exit 0; fi
                          sleep 1
                        done
              volumeMounts:
                - mountPath: /tmp/ray
                  name: ray-logs
            - name: collector
              image: ${COLLECTOR_IMAGE}
              imagePullPolicy: Always
              command:
                - collector
              args:
                - --role=Worker
                - --runtime-class-name=s3
                - --ray-cluster-name=${RAYCLUSTER_NAME}
                - --ray-cluster-id=${NAMESPACE}
                - --ray-root-dir=log
                - --events-port=8084
              env:
                - name: RAY_TMP_ROOT
                  value: /tmp/ray
                - name: S3_BUCKET
                  value: "${S3_BUCKET}"
                - name: S3_REGION
                  value: "${S3_REGION}"
                - name: S3_ENDPOINT
                  value: "${S3_ENDPOINT}"
                - name: S3FORCE_PATH_STYLE
                  value: "${S3FORCE_PATH_STYLE}"
                - name: S3DISABLE_SSL
                  value: "${S3DISABLE_SSL}"
                - name: AWS_S3ID
                  valueFrom:
                    secretKeyRef:
                      name: ${S3_SECRET_NAME}
                      key: AWS_S3ID
                - name: AWS_S3SECRET
                  valueFrom:
                    secretKeyRef:
                      name: ${S3_SECRET_NAME}
                      key: AWS_S3SECRET
                - name: SSL_CERT_FILE
                  value: "${SSL_CERT_FILE}"
              volumeMounts:
                - mountPath: /tmp/ray
                  name: ray-logs
          volumes:
            - name: ray-logs
              emptyDir: {}
