#!/usr/bin/env bash
# Pulls one image through an ECR pull through cache rule without docker, the
# way `docker pull` would: GET the manifest from the private registry's HTTP
# API, which makes ECR import it from upstream, then wait until ECR lists the
# image (ECR accepts an image only once its config and layers are stored)
# and reports every layer available.
#
# Run by terraform_data.import in main.tf with REGISTRY, REPOSITORY, DIGEST,
# and AWS_REGION set. Needs the AWS CLI, curl, and python3, plus
# ecr:GetAuthorizationToken, ecr:BatchGetImage, ecr:BatchImportUpstreamImage,
# ecr:DescribeImages, and ecr:BatchCheckLayerAvailability on the repository
# (see ../iam/private-ecr-permissions-policy.json).
set -euo pipefail

: "${REGISTRY:?}" "${REPOSITORY:?}" "${DIGEST:?}" "${AWS_REGION:?}"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT

accept="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
url="https://$REGISTRY/v2/$REPOSITORY/manifests/$DIGEST"

echo "==> import $REGISTRY/$REPOSITORY@$DIGEST through the pull through cache"
# The cache rule's service-linked role can take a moment to become usable
# right after the rule is created, so the first GET is retried.
for attempt in $(seq 1 18); do
  password="$(aws ecr get-login-password --region "$AWS_REGION")"
  code="$(curl -sS -o "$manifest" -w '%{http_code}' -u "AWS:$password" -H "Accept: $accept" "$url" || true)"
  [ "$code" = "200" ] && break
  echo "    manifest GET returned HTTP $code (attempt $attempt); retrying in 10s"
  sleep 10
done
[ "$code" = "200" ] || { echo "error: $url did not return the manifest; last response:" >&2; cat "$manifest" >&2; exit 1; }

# Content addressing: the bytes ECR serves must hash to the pinned digest, or
# the task definition would reference an image the cache does not hold.
layers="$(python3 - "$manifest" "$DIGEST" <<'PY'
import hashlib, json, sys
path, digest = sys.argv[1], sys.argv[2]
body = open(path, "rb").read()
actual = "sha256:" + hashlib.sha256(body).hexdigest()
if actual != digest:
    sys.exit(f"error: the cached manifest hashes to {actual}, not the pinned {digest}")
doc = json.loads(body)
if "layers" not in doc:
    sys.exit(f"error: {digest} is a {doc.get('mediaType')}, not a single-platform image manifest")
print(" ".join(layer["digest"] for layer in doc["layers"]))
PY
)"

count="$(wc -w <<<"$layers" | tr -d ' ')"
echo "==> wait until ECR lists the image and all $count layers are available"
for attempt in $(seq 1 30); do
  if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPOSITORY" \
       --image-ids "imageDigest=$DIGEST" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>&1; then
    # shellcheck disable=SC2086 # one argument per layer digest
    available="$(aws ecr batch-check-layer-availability --region "$AWS_REGION" --repository-name "$REPOSITORY" \
      --layer-digests $layers --query "length(layers[?layerAvailability=='AVAILABLE'])" --output text)"
    if [ "$available" = "$count" ]; then
      echo "ok: $REPOSITORY@$DIGEST is cached in the private registry"
      exit 0
    fi
  fi
  sleep 10
done
echo "error: $REPOSITORY@$DIGEST was not fully cached within 5 minutes" >&2
exit 1
