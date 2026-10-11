# Docker Buildx Bake build definition file
# Reference: https://github.com/docker/buildx/blob/master/docs/reference/buildx_bake.md

variable "REGISTRY_USER" {
    default = "frappe"
}

variable PYTHON_VERSION {
    default = "3.14.2"
}
variable NODE_VERSION {
    default = "24.13.0"
}

variable "FRAPPE_VERSION" {
    default = "develop"
}

variable "ERPNEXT_VERSION" {
    default = "develop"
}

variable "FRAPPE_REPO" {
    default = "https://github.com/frappe/frappe"
}

variable "ERPNEXT_REPO" {
    default = "https://github.com/frappe/erpnext"
}

variable "BENCH_REPO" {
    default = "https://github.com/frappe/bench"
}

variable "CUSTOM_IMAGE" {
    default = "custom"
}

variable "CUSTOM_TAG" {
    default = "16"
}

variable "CUSTOM_FRAPPE_VERSION" {
    default = "v16.33.0"
}

variable "CUSTOM_PLATFORMS" {
    # Native default for this Apple Silicon development machine. Override to
    # linux/amd64 when publishing for a standard AKS node pool.
    default = "linux/arm64"
}

variable "LATEST_BENCH_RELEASE" {
    default = "latest"
}

# Bench image

target "bench" {
    args = {
        GIT_REPO = "${BENCH_REPO}"
    }
    context = "images/bench"
    target = "bench"
    tags = [
        "frappe/bench:${LATEST_BENCH_RELEASE}",
        "frappe/bench:latest",
    ]
}

target "bench-test" {
    inherits = ["bench"]
    target = "bench-test"
}

# Main images
# Base for all other targets

group "default" {
    targets = ["erpnext", "base", "build"]
}

group "base-images" {
    targets = ["base", "build"]
}

function "tag" {
    params = [repo, version]
    result = [
      # Push frappe or erpnext branch as tag
      "${REGISTRY_USER}/${repo}:${version}",
      # If `version` param is develop (development build) then use tag `latest`
      "${version}" == "develop" ? "${REGISTRY_USER}/${repo}:latest" : "${REGISTRY_USER}/${repo}:${version}",
      # Make short tag for major version if possible. For example, from v13.16.0 make v13.
      can(regex("(v[0-9]+)[.]", "${version}")) ? "${REGISTRY_USER}/${repo}:${regex("(v[0-9]+)[.]", "${version}")[0]}" : "",
      # Make short tag for major version if possible. For example, from v13.16.0 make version-13.
      can(regex("(v[0-9]+)[.]", "${version}")) ? "${REGISTRY_USER}/${repo}:version-${regex("([0-9]+)[.]", "${version}")[0]}" : "",
    ]
}

target "default-args" {
    args = {
        FRAPPE_PATH = "${FRAPPE_REPO}"
        ERPNEXT_PATH = "${ERPNEXT_REPO}"
        BENCH_REPO = "${BENCH_REPO}"
        FRAPPE_BRANCH = "${FRAPPE_VERSION}"
        ERPNEXT_BRANCH = "${ERPNEXT_VERSION}"
        PYTHON_VERSION = "${PYTHON_VERSION}"
        NODE_VERSION = "${NODE_VERSION}"
    }
}

target "erpnext" {
    inherits = ["default-args"]
    context = "."
    dockerfile = "images/production/Containerfile"
    target = "erpnext"
    tags = tag("erpnext", "${ERPNEXT_VERSION}")
}

target "base" {
    inherits = ["default-args"]
    context = "."
    dockerfile = "images/production/Containerfile"
    target = "base"
    tags = tag("base", "${FRAPPE_VERSION}")
}

target "build" {
    inherits = ["default-args"]
    context = "."
    dockerfile = "images/production/Containerfile"
    target = "build"
    tags = tag("build", "${ERPNEXT_VERSION}")
}

# Custom image containing the applications listed in apps.json.
# Build locally with --load, or publish to a registry with --push.
target "custom" {
    context = "."
    dockerfile = "images/layered/Containerfile"
    args = {
        FRAPPE_PATH = "${FRAPPE_REPO}"
        FRAPPE_BRANCH = "${CUSTOM_FRAPPE_VERSION}"
    }
    platforms = ["${CUSTOM_PLATFORMS}"]
    tags = ["${CUSTOM_IMAGE}:${CUSTOM_TAG}"]
}
