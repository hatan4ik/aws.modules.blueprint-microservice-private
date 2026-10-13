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
errfile="$(mktemp)"
trap 'rm -f "$manifest" "$errfile"' EXIT

accept="application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
url="https://$REGISTRY/v2/$REPOSITORY/manifests/$DIGEST"

echo "==> import $REGISTRY/$REPOSITORY@$DIGEST through the pull through cache"
# The cache rule's service-linked role can take a moment to become usable
# right after the rule is created, so the first GET is retried, and so is a
# failed token request. How the registry answers during that warm-up is not
# documented, so 401/403 are retried too, for about a minute (6 in a row)
# before they are taken for a real policy or repository mistake. A missing
# credential or a denied ecr:GetAuthorizationToken can never become valid by
# waiting and fails immediately.
auth_denied_limit=6
code=""
last_error=""
auth_denied=0
for attempt in $(seq 1 18); do
  if ! password="$(aws ecr get-login-password --region "$AWS_REGION" 2>"$errfile")"; then
    last_error="aws ecr get-login-password: $(cat "$errfile")"
    if grep -Eqi 'AccessDenied|UnauthorizedOperation|ExpiredToken|Unable to locate credentials|InvalidClientTokenId|could not be found' "$errfile"; then
      echo "error: $last_error" >&2
      exit 1
    fi
    echo "    get-login-password failed (attempt $attempt): $(cat "$errfile"); retrying in 10s" >&2
    code=""
    sleep 10
    continue
  fi
  # The token goes to curl on stdin (-K -), never on its command line, where
  # any local user could read it from the process list. It is base64, so it
  # needs no quoting; backslash and double quote are escaped anyway because
  # they would end the config value.
  escaped_password="${password//\\/\\\\}"
  escaped_password="${escaped_password//\"/\\\"}"
  curl_rc=0
  code="$(printf 'user = "AWS:%s"\n' "$escaped_password" |
    curl -sS --connect-timeout 10 --max-time 60 -K - -o "$manifest" -w '%{http_code}' -H "Accept: $accept" "$url")" || curl_rc=$?
  if [ "$curl_rc" -ne 0 ]; then
    # curl already printed its transport error (-S); retry like any non-200.
    last_error="curl exited $curl_rc"
    code="${code:-000}"
  fi
  [ "$code" = "200" ] && break
  case "$code" in
    401|403) auth_denied=$((auth_denied + 1)) ;;
    *) auth_denied=0 ;;
  esac
  if [ "$auth_denied" -ge "$auth_denied_limit" ]; then
    echo "error: $url returned HTTP $code $auth_denied times in a row; check the repository policy, the caller's ecr:BatchGetImage/ecr:BatchImportUpstreamImage permissions, and the repository name. Last response:" >&2
    cat "$manifest" >&2
    exit 1
  fi
  echo "    manifest GET returned HTTP $code (attempt $attempt); retrying in 10s"
  sleep 10
done
if [ "$code" != "200" ]; then
  echo "error: $url did not return the manifest (last HTTP code: ${code:-none})${last_error:+; last error: $last_error}; last response:" >&2
  cat "$manifest" >&2
  exit 1
fi

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
if [ "$count" -eq 0 ]; then
  echo "error: the manifest of $DIGEST lists no layers; nothing to wait for" >&2
  exit 1
fi
echo "==> wait until ECR lists the image and all $count layers are available"
last_error=""
for attempt in $(seq 1 30); do
  # A failure here is expected while ECR is still importing the image
  # (ImageNotFoundException), so it is retried; the last message is kept for
  # the final error.
  if aws ecr describe-images --region "$AWS_REGION" --repository-name "$REPOSITORY" \
       --image-ids "imageDigest=$DIGEST" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>"$errfile"; then
    # shellcheck disable=SC2086 # one argument per layer digest
    if available="$(aws ecr batch-check-layer-availability --region "$AWS_REGION" --repository-name "$REPOSITORY" \
      --layer-digests $layers --query "length(layers[?layerAvailability=='AVAILABLE'])" --output text 2>"$errfile")"; then
      if [ "$available" = "$count" ]; then
        echo "ok: $REPOSITORY@$DIGEST is cached in the private registry"
        exit 0
      fi
    else
      last_error="batch-check-layer-availability: $(cat "$errfile")"
      echo "    batch-check-layer-availability failed (attempt $attempt): $(cat "$errfile"); retrying in 10s" >&2
    fi
  else
    last_error="describe-images: $(cat "$errfile")"
  fi
  sleep 10
done
echo "error: $REPOSITORY@$DIGEST was not fully cached within 5 minutes${last_error:+; last error: $last_error}" >&2
exit 1
