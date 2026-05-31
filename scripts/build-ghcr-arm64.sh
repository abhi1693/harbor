#!/usr/bin/env bash
set -euo pipefail

source_dir="${1:?usage: build-ghcr-arm64.sh SOURCE_DIR HARBOR_TAG}"
harbor_tag="${2:?usage: build-ghcr-arm64.sh SOURCE_DIR HARBOR_TAG}"

if ! [[ "$harbor_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid Harbor tag: $harbor_tag" >&2
  exit 1
fi

: "${IMAGE_NAMESPACE:?IMAGE_NAMESPACE must be set, for example ghcr.io/abhi1693}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="${ARCH:-arm64}"
base_tag="${BASEIMAGETAG:-${harbor_tag}-${arch}-base}"
publish_latest="${PUBLISH_LATEST:-true}"

if [ "$arch" != "arm64" ]; then
  echo "This workflow only builds arm64 images, got ARCH=$arch" >&2
  exit 1
fi

make_args=(
  "ARCH=${arch}"
  "VERSIONTAG=${harbor_tag}"
  "PKGVERSIONTAG=${harbor_tag}"
  "BASEIMAGETAG=${base_tag}"
  "IMAGENAMESPACE=${IMAGE_NAMESPACE}"
  "BASEIMAGENAMESPACE=${IMAGE_NAMESPACE}"
  "BUILD_BASE=true"
  "PUSHBASEIMAGE=false"
  "PULL_BASE_FROM_DOCKERHUB=false"
  "BUILD_INSTALLER=true"
  "TRIVYFLAG=true"
  "EXPORTERFLAG=true"
  "GOBUILDTAGS=include_oss include_gcs"
)

cd "$source_dir"

trivy_version="$(sed -n 's/^TRIVYVERSION=//p' Makefile | head -n 1)"
if [ -n "$trivy_version" ]; then
  make_args+=(
    "TRIVY_DOWNLOAD_URL=https://github.com/aquasecurity/trivy/releases/download/${trivy_version}/trivy_${trivy_version#v}_Linux-ARM64.tar.gz"
  )
fi

docker build \
  --pull \
  --platform "linux/${arch}" \
  -f "${script_dir}/harbor-photon-base.Dockerfile" \
  -t goharbor/photon:5.0 \
  "${script_dir}"

echo "Building Harbor ${harbor_tag} for linux/${arch}"
make compile "${make_args[@]}"
make build "${make_args[@]}"

mapfile -t built_repositories < <(
  docker images --format '{{.Repository}} {{.Tag}}' \
    | awk -v namespace="${IMAGE_NAMESPACE}/" -v tag="$harbor_tag" \
      '$1 ~ "^" namespace && $2 == tag { print $1 }' \
    | sort -u
)

if [ "${#built_repositories[@]}" -eq 0 ]; then
  echo "No Harbor images were built with tag ${harbor_tag}" >&2
  exit 1
fi

for repository in "${built_repositories[@]}"; do
  source_image="${repository}:${harbor_tag}"
  arch_image="${repository}:${harbor_tag}-${arch}"

  docker image inspect "$source_image" >/dev/null
  docker push "$source_image"

  docker tag "$source_image" "$arch_image"
  docker push "$arch_image"

  if [ "$publish_latest" = "true" ]; then
    latest_image="${repository}:latest-${arch}"
    docker tag "$source_image" "$latest_image"
    docker push "$latest_image"
  fi
done
