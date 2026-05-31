#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  build-ghcr-arm64.sh plan SOURCE_DIR HARBOR_TAG FORCE_REBUILD PUBLISH_LATEST
  build-ghcr-arm64.sh prepare-source SOURCE_DIR HARBOR_TAG
  build-ghcr-arm64.sh build-component SOURCE_DIR HARBOR_TAG IMAGE TARGET
  build-ghcr-arm64.sh maintain-aliases HARBOR_TAG IMAGE [IMAGE...]
  build-ghcr-arm64.sh components SOURCE_DIR
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arch="${ARCH:-arm64}"
publish_latest="${PUBLISH_LATEST:-true}"

validate_tag() {
  local harbor_tag="${1:?tag required}"

  if ! [[ "$harbor_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    die "Invalid Harbor tag: $harbor_tag"
  fi
}

require_arm64() {
  if [ "$arch" != "arm64" ]; then
    die "This workflow only builds arm64 images, got ARCH=$arch"
  fi
}

require_image_namespace() {
  : "${IMAGE_NAMESPACE:?IMAGE_NAMESPACE must be set, for example ghcr.io/abhi1693}"
}

normalize_source_dir() {
  local source_dir="${1:?source directory required}"
  cd "$source_dir" >/dev/null
  pwd
}

component_rows() {
  local source_dir="${1:?source directory required}"

  cat <<'EOF'
prepare _build_prepare
harbor-log _build_log
harbor-db _build_db
harbor-portal _build_portal
harbor-core _build_core
harbor-jobservice _build_jobservice
harbor-registryctl _build_registryctl
nginx-photon _build_nginx
registry-photon _build_registry
trivy-adapter-photon _build_trivy_adapter
harbor-exporter _compile_and_build_exporter
EOF

  if [ -d "${source_dir}/make/photon/valkey" ]; then
    echo "valkey-photon _build_valkey"
  else
    echo "redis-photon _build_redis"
  fi
}

has_component() {
  local source_dir="${1:?source directory required}"
  local expected_image="${2:?image required}"
  local expected_target="${3:?target required}"
  local image
  local target

  while read -r image target; do
    if [ "$image" = "$expected_image" ] && [ "$target" = "$expected_target" ]; then
      return 0
    fi
  done < <(component_rows "$source_dir")

  return 1
}

has_arm64_manifest() {
  local image_ref="${1:?image reference required}"

  docker manifest inspect -v "$image_ref" 2>/dev/null | jq -e '
    if type == "array" then
      any(.[]; .Descriptor.platform.os == "linux" and .Descriptor.platform.architecture == "arm64")
    else
      .Descriptor.platform.os == "linux" and .Descriptor.platform.architecture == "arm64"
    end
  ' >/dev/null
}

make_args=()

init_make_args() {
  local source_dir="${1:?source directory required}"
  local harbor_tag="${2:?tag required}"
  local base_tag="${BASEIMAGETAG:-${harbor_tag}-${arch}-base}"
  local trivy_version
  local git_commit="${GIT_COMMIT:-}"

  validate_tag "$harbor_tag"
  require_image_namespace
  require_arm64

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

  trivy_version="$(sed -n 's/^TRIVYVERSION=//p' "${source_dir}/Makefile" | head -n 1)"
  if [ -n "$trivy_version" ]; then
    make_args+=(
      "TRIVY_DOWNLOAD_URL=https://github.com/aquasecurity/trivy/releases/download/${trivy_version}/trivy_${trivy_version#v}_Linux-ARM64.tar.gz"
    )
  fi

  if [ -z "$git_commit" ] && git -C "$source_dir" rev-parse --short=8 HEAD >/dev/null 2>&1; then
    git_commit="$(git -C "$source_dir" rev-parse --short=8 HEAD)"
  fi

  if [ -n "$git_commit" ]; then
    make_args+=("GITCOMMIT=${git_commit}")
  fi
}

build_photon_base() {
  docker build \
    --pull \
    --platform "linux/${arch}" \
    -f "${script_dir}/harbor-photon-base.Dockerfile" \
    -t goharbor/photon:5.0 \
    "${script_dir}"
}

plan_images() {
  local source_dir="${1:?source directory required}"
  local harbor_tag="${2:?tag required}"
  local force_rebuild="${3:?force_rebuild required}"
  local publish_latest_arg="${4:?publish_latest required}"
  local build_matrix='[]'
  local alias_images='[]'
  local all_images='[]'
  local image
  local target

  validate_tag "$harbor_tag"
  require_image_namespace

  while read -r image target; do
    local exact="${IMAGE_NAMESPACE}/${image}:${harbor_tag}"
    local arch_alias="${IMAGE_NAMESPACE}/${image}:${harbor_tag}-${arch}"
    local latest_alias="${IMAGE_NAMESPACE}/${image}:latest-${arch}"

    all_images="$(jq -c --arg image "$image" '. + [$image]' <<<"$all_images")"

    if [ "$force_rebuild" = "true" ] || ! has_arm64_manifest "$exact"; then
      echo "Will build ${exact}" >&2
      build_matrix="$(
        jq -c --arg image "$image" --arg target "$target" \
          '. + [{image: $image, target: $target}]' <<<"$build_matrix"
      )"
      continue
    fi

    if ! has_arm64_manifest "$arch_alias"; then
      echo "Will create alias ${arch_alias}" >&2
      alias_images="$(jq -c --arg image "$image" '. + [$image]' <<<"$alias_images")"
      continue
    fi

    if [ "$publish_latest_arg" = "true" ] && ! has_arm64_manifest "$latest_alias"; then
      echo "Will create alias ${latest_alias}" >&2
      alias_images="$(jq -c --arg image "$image" '. + [$image]' <<<"$alias_images")"
    fi
  done < <(component_rows "$source_dir")

  jq -cn \
    --argjson build_matrix "$build_matrix" \
    --argjson alias_images "$alias_images" \
    --argjson all_images "$all_images" \
    '{
      build_matrix: $build_matrix,
      alias_images: $alias_images,
      all_images: $all_images,
      build: (($build_matrix | length) > 0),
      alias_missing: (($alias_images | length) > 0)
    }'
}

prepare_source() {
  local source_dir="${1:?source directory required}"
  local harbor_tag="${2:?tag required}"

  init_make_args "$source_dir" "$harbor_tag"

  echo "Compiling Harbor ${harbor_tag} for linux/${arch}"
  cd "$source_dir"
  make compile "${make_args[@]}"
}

push_component_image() {
  local harbor_tag="${1:?tag required}"
  local image="${2:?image required}"
  local source_image="${IMAGE_NAMESPACE}/${image}:${harbor_tag}"
  local arch_image="${IMAGE_NAMESPACE}/${image}:${harbor_tag}-${arch}"
  local latest_image="${IMAGE_NAMESPACE}/${image}:latest-${arch}"

  docker image inspect "$source_image" >/dev/null

  docker push "$source_image"

  docker tag "$source_image" "$arch_image"
  docker push "$arch_image"

  if [ "$publish_latest" = "true" ]; then
    docker tag "$source_image" "$latest_image"
    docker push "$latest_image"
  fi
}

build_component() {
  local source_dir="${1:?source directory required}"
  local harbor_tag="${2:?tag required}"
  local image="${3:?image required}"
  local target="${4:?target required}"

  if ! has_component "$source_dir" "$image" "$target"; then
    die "Unknown Harbor component mapping: ${image} ${target}"
  fi

  init_make_args "$source_dir" "$harbor_tag"
  build_photon_base

  echo "Building ${IMAGE_NAMESPACE}/${image}:${harbor_tag} with ${target}"
  cd "$source_dir"
  make build "BUILDTARGET=${target}" "${make_args[@]}"

  push_component_image "$harbor_tag" "$image"
}

maintain_aliases() {
  local harbor_tag="${1:?tag required}"
  shift
  local image

  validate_tag "$harbor_tag"
  require_image_namespace
  require_arm64

  for image in "$@"; do
    local exact="${IMAGE_NAMESPACE}/${image}:${harbor_tag}"
    local arch_alias="${IMAGE_NAMESPACE}/${image}:${harbor_tag}-${arch}"
    local latest_alias="${IMAGE_NAMESPACE}/${image}:latest-${arch}"

    if ! has_arm64_manifest "$exact"; then
      die "Cannot maintain aliases because ${exact} is missing an ARM64 manifest"
    fi

    if ! has_arm64_manifest "$arch_alias"; then
      docker buildx imagetools create -t "$arch_alias" "$exact"
    fi

    if [ "$publish_latest" = "true" ] && ! has_arm64_manifest "$latest_alias"; then
      docker buildx imagetools create -t "$latest_alias" "$exact"
    fi
  done
}

main() {
  local command="${1:-}"
  shift || true

  case "$command" in
    plan)
      [ "$#" -eq 4 ] || { usage; exit 2; }
      plan_images "$(normalize_source_dir "$1")" "$2" "$3" "$4"
      ;;
    prepare-source)
      [ "$#" -eq 2 ] || { usage; exit 2; }
      prepare_source "$(normalize_source_dir "$1")" "$2"
      ;;
    build-component)
      [ "$#" -eq 4 ] || { usage; exit 2; }
      build_component "$(normalize_source_dir "$1")" "$2" "$3" "$4"
      ;;
    maintain-aliases)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      maintain_aliases "$@"
      ;;
    components)
      [ "$#" -eq 1 ] || { usage; exit 2; }
      component_rows "$(normalize_source_dir "$1")"
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
