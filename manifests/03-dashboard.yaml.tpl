apiVersion: v1
kind: ServiceAccount
metadata:
  name: kuberay-dashboard
  namespace: ${NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: |
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"kuberay-dashboard"}}
---
# Allows the OAuth proxy sidecar to validate bearer tokens (TokenReview) and
# check authorization (SubjectAccessReview) for CLI/API access via
# `curl -H "Authorization: Bearer $(oc whoami -t)"`.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAMESPACE}:kuberay-dashboard:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: kuberay-dashboard
    namespace: ${NAMESPACE}
---
# REQUIRED on clusters using the default `restricted-v2` SCC (standard on
# OpenShift/ROSA/OSD since 4.11+): the dashboard image's Dockerfile sets a
# fixed, non-root UID (`USER nextjs`, uid 1001) baked into the Next.js
# standalone output. restricted-v2 only allows UIDs from the namespace's
# auto-allocated range, not an arbitrary fixed UID, so the pod will fail to
# start (CreateContainerConfigError / "unable to find user nextjs") without
# this grant. If your cluster already allows fixed non-root UIDs (e.g. a more
# permissive SCC/PSA policy), this RoleBinding is not strictly required, but
# it is harmless to apply.
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: system:openshift:scc:anyuid
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:anyuid
subjects:
  - kind: ServiceAccount
    name: kuberay-dashboard
    namespace: ${NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kuberay-dashboard
  namespace: ${NAMESPACE}
  labels:
    app: kuberay-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kuberay-dashboard
  template:
    metadata:
      labels:
        app: kuberay-dashboard
    spec:
      serviceAccountName: kuberay-dashboard
      containers:
        - name: kuberay-dashboard
          image: ${DASHBOARD_IMAGE}
          imagePullPolicy: Always
          ports:
            - containerPort: 3000
          env:
            # Server-side only: the browser never talks to this URL directly,
            # it only hits this app's own same-origin /api/historyserver/*
            # proxy, which forwards to HISTORYSERVER_DOMAIN.
            - name: HISTORYSERVER_DOMAIN
              value: "http://historyserver:30080"
            # The browser-side fetcher builds its request URL as
            # `${proxyEndpoint}${endpoint}`. Must match the basePath baked
            # into the image at build time (NEXT_PUBLIC_BASE_PATH) AND the
            # path prefix used by the Route/HTTPRoute below.
            - name: HISTORYSERVER_PROXY_ENDPOINT
              value: "${DASHBOARD_BASE_PATH}/api/historyserver"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
          readinessProbe:
            httpGet:
              # Must match the Next.js basePath baked into the image --
              # plain "/" 404s once basePath is set.
              path: ${DASHBOARD_BASE_PATH}
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: ${DASHBOARD_BASE_PATH}
              port: 3000
            initialDelaySeconds: 15
            periodSeconds: 20
        - name: oauth-proxy
          image: ${OAUTH_PROXY_IMAGE}
          args:
            - --provider=openshift
            - --https-address=:8443
            - --http-address=
            - --upstream=http://localhost:3000
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret=${OAUTH_COOKIE_SECRET}
            - --openshift-service-account=kuberay-dashboard
            - --openshift-delegate-urls={"/":{"resource":"services","verb":"get","namespace":"${NAMESPACE}"}}
            - --cookie-expire=24h
          ports:
            - containerPort: 8443
              name: oauth-proxy
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          volumeMounts:
            - mountPath: /etc/tls/private
              name: proxy-tls
              readOnly: true
      volumes:
        - name: proxy-tls
          secret:
            secretName: kuberay-dashboard-proxy-tls
---
apiVersion: v1
kind: Service
metadata:
  name: kuberay-dashboard
  namespace: ${NAMESPACE}
  labels:
    app: kuberay-dashboard
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: kuberay-dashboard-proxy-tls
spec:
  selector:
    app: kuberay-dashboard
  ports:
    - name: oauth-proxy
      port: 8443
      targetPort: 8443
    - name: http
      port: 3000
      targetPort: 3000
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: kuberay-dashboard
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: kuberay-dashboard
  port:
    targetPort: oauth-proxy
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
