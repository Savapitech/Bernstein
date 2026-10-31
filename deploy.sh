#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="bernstein"

cd "$(dirname "$0")"

tags="$(./build-image-push.sh)"

args=()
while IFS='=' read -r app tag; do
    args+=(--set "$app.image.tag=$tag")
done <<< "$tags"

helm upgrade --install bernstein chart/bernstein --namespace "$NAMESPACE" "${args[@]}" "$@"
