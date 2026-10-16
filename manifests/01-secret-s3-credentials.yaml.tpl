# AWS S3 credentials consumed by both the historyserver Deployment and the
# `collector` sidecar injected into every RayCluster. Both read the SAME two
# keys (AWS_S3ID / AWS_S3SECRET) regardless of the fact they map to real AWS
# access keys here -- these env var names are historyserver/collector
# internals, not MinIO-specific.
#
# Recommended: create an IAM user (or an STS role assumed out-of-band) scoped
# to only this bucket, e.g.:
#   {
#     "Version": "2012-10-17",
#     "Statement": [{
#       "Effect": "Allow",
#       "Action": ["s3:GetObject","s3:PutObject","s3:ListBucket","s3:HeadBucket","s3:CreateBucket"],
#       "Resource": ["arn:aws:s3:::${S3_BUCKET}", "arn:aws:s3:::${S3_BUCKET}/*"]
#     }]
#   }
#
# Prefer creating this secret imperatively instead of committing real keys to
# git, e.g.:
#   oc create secret generic ${S3_SECRET_NAME} -n ${NAMESPACE} \
#     --from-literal=AWS_S3ID="${AWS_ACCESS_KEY_ID}" \
#     --from-literal=AWS_S3SECRET="${AWS_SECRET_ACCESS_KEY}"
# This template is provided for completeness / GitOps use only -- fill in
# real values via envsubst from a non-committed .env file, never check in the
# rendered output.
apiVersion: v1
kind: Secret
metadata:
  name: ${S3_SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  AWS_S3ID: "${AWS_ACCESS_KEY_ID}"
  AWS_S3SECRET: "${AWS_SECRET_ACCESS_KEY}"
