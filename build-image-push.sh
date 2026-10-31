set -euo pipefail

REGISTRY="registry.vyme.fr/savalet/bernstein"
PLATFORM="linux/amd64"

cd "$(dirname "$0")"

if [ $# -gt 0 ]; then
    apps=("$@")
else
    apps=(poll result worker)
fi

content_tag() {
    local tmp
    tmp="$(mktemp -d)"
    GIT_INDEX_FILE="$tmp/index" git read-tree HEAD
    GIT_INDEX_FILE="$tmp/index" git add -A "apps/$1"
    GIT_INDEX_FILE="$tmp/index" git write-tree --prefix="apps/$1/" | cut -c1-12
    rm -rf "$tmp"
}

for app in "${apps[@]}"; do
    tag="$(content_tag "$app")"
    image="$REGISTRY/$app:$tag"

    if docker buildx imagetools inspect "$image" >/dev/null 2>&1; then
        echo "$image already in the registry, skipping the build" >&2
    else
        docker buildx build --platform "$PLATFORM" --tag "$image" --push "apps/$app" >&2
    fi

    echo "$app=$tag"
done
