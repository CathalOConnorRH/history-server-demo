apiVersion: v1
kind: ServiceAccount
metadata:
  name: historyserver
  namespace: ${NAMESPACE}
  annotations:
    serviceaccounts.openshift.io/oauth-redirectreference.primary: |
      {"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"historyserver"}}
---
# Allows the OAuth proxy sidecar to validate bearer tokens (TokenReview) and
# check authorization (SubjectAccessReview) for CLI/API access via
# `curl -H "Authorization: Bearer $(oc whoami -t)"`.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${NAMESPACE}:historyserver:auth-delegator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
  - kind: ServiceAccount
    name: historyserver
    namespace: ${NAMESPACE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: historyserver
  namespace: ${NAMESPACE}
  labels:
    app: historyserver
spec:
  replicas: 1
  selector:
    matchLabels:
      app: historyserver
  template:
    metadata:
      labels:
        app: historyserver
    spec:
      serviceAccountName: historyserver
      containers:
        - name: historyserver
          image: ${HISTORYSERVER_IMAGE}
          imagePullPolicy: Always
          command:
            - historyserver
          args:
            - --runtime-class-name=s3
            - --ray-root-dir=log
          ports:
            - containerPort: 8080
              protocol: TCP
          env:
            # S3 backend config -- all 4 of S3_ENDPOINT / S3FORCE_PATH_STYLE /
            # S3DISABLE_SSL / SSL_CERT_FILE come straight from .env. Defaults
            # there target AWS S3; see .env.example's "S3 backend" section for
            # the MinIO/S3-compatible alternative values (this package does
            # NOT deploy a MinIO server -- it only documents how to point at
            # one you already have running).
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
            # Only needed against an S3-compatible endpoint (e.g. MinIO) whose
            # TLS cert isn't publicly trusted. Leave SSL_CERT_FILE empty in
            # .env for AWS S3 -- an empty value is ignored by Go's x509
            # loader, identical to leaving the var unset.
            - name: SSL_CERT_FILE
              value: "${SSL_CERT_FILE}"
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /readz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /livez
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
        - name: oauth-proxy
          image: ${OAUTH_PROXY_IMAGE}
          args:
            - --provider=openshift
            - --https-address=:8443
            - --http-address=
            - --upstream=http://localhost:8080
            - --tls-cert=/etc/tls/private/tls.crt
            - --tls-key=/etc/tls/private/tls.key
            - --cookie-secret=${OAUTH_COOKIE_SECRET}
            - --openshift-service-account=historyserver
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
            secretName: historyserver-proxy-tls
---
apiVersion: v1
kind: Service
metadata:
  name: historyserver
  namespace: ${NAMESPACE}
  labels:
    app: historyserver
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: historyserver-proxy-tls
spec:
  selector:
    app: historyserver
  ports:
    - name: oauth-proxy
      port: 8443
      targetPort: 8443
    - name: http
      port: 30080
      targetPort: 8080
  type: ClusterIP
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: historyserver
  namespace: ${NAMESPACE}
spec:
  to:
    kind: Service
    name: historyserver
  port:
    targetPort: oauth-proxy
  tls:
    termination: reencrypt
    insecureEdgeTerminationPolicy: Redirect
  wildcardPolicy: None
