#!/bin/bash
#
# build-pbrp.sh [<pbrp-tree>]
#
# Build the PBRP recovery (vendor_boot) for S666LN.
#
# WHY A SCRIPT AND NOT THREE TYPED COMMANDS
# =========================================
# The first PBRP build silently produced an aosp_arm/goldfish target. The cause
# was `lunch omni_S666LN-eng | tail`: the pipe runs lunch in a SUBSHELL, so the
# environment it exports is discarded, and the build proceeds with whatever
# TARGET_PRODUCT was left over. It cost a full build to notice.
#
# So: lunch output is REDIRECTED, never piped, and the product is asserted
# afterwards. If the assert fails the script stops before compiling anything.
#
# The same class of bug (reading $? after a pipeline, which reports the LAST
# command's status rather than the build's) is handled with PIPESTATUS below.
# [!] NOT `set -u`. AOSP's build/envsetup.sh references unset variables all over,
# so nounset makes `source build/envsetup.sh` kill this script outright, before
# it writes any log -- which looks exactly like a silent hang.
set -o pipefail

TREE="${1:-/mnt/external_nvme/pbrp}"
PRODUCT="omni_S666LN"
LOG="${TREE}/build-pbrp.log"

cd "${TREE}" || { echo "!! no tree at ${TREE}" >&2; exit 2; }

# ---- ALLOW_MISSING_DEPENDENCIES. Mandatory here, not optional.
#
# PBRP syncs from a MINIMAL manifest: default.xml lists 1061 projects,
# remove-minimal.xml deletes 826 of them, and 252 are checked out. The projects
# that survive still REFERENCE modules from the deleted ones, so a full soong
# module scan always fails:
#     "neuralnetworks_utils_hal_aidl" depends on undefined module
#       "neuralnetworks_utils_defaults"        (NeuralNetworks removed)
#     "ConnectivityCoverageTests" depends on undefined module
#       "libnetworkstackutilsjni_deps"         (NetworkStack removed)
#     "metalava" depends on undefined module "kotlin-reflect"
# This is INHERENT to a minimal tree, not a sync fault: the checkout matches
# the manifest exactly (HEAD == remote tip, 0 commits behind).
#
# ALLOW_MISSING_DEPENDENCIES=true is AOSP's own answer (build/soong/ui/build/
# soong.go:226, build/make/core/main.mk:733). Missing deps become errors only
# if something actually BUILDS the affected module, and a recovery image builds
# none of them.
#
# [!] It was invisible until 2026-08-19 because out/.module_paths/Android.bp.list
# is cached: the cached list predated the sync that created the orphans, so
# builds kept succeeding against a stale list. Adding files under device/ forced
# a regeneration and every latent break surfaced at once. The tree had never
# actually been able to bootstrap from scratch.
#
# [!] Two dead ends, recorded so they are not retried:
#   - .find-ignore pruning CASCADES. The pruned dirs also DEFINE modules others
#     consume (packages/modules/Connectivity/tests/common defines
#     framework-connectivity-test-defaults four lines below its broken
#     reference), so each prune bought one build and created the next failure:
#     Connectivity -> telephony tests -> cts -> cts_defaults -> 14 more dirs.
#   - Stub `defaults` modules fix the first two errors and then meet
#     tools/metalava, which needs real java_imports, not empty defaults.
export ALLOW_MISSING_DEPENDENCIES=true

# ---- PLATFORM_VERSION must be 13, and it MUST be set here, not in BoardConfig.
#
# KeyMint binds every key blob to an os_version derived from
# ro.build.version.release. This PBRP tree is lineage-19.1, so the platform
# default is 12, while the ROM that created the keys is 13. A recovery claiming
# 12 against a key created under 13 is a ROLLBACK, and the TEE answers
# KM_ERROR_INVALID_KEY_BLOB (-33) instead of decrypting.
#
# [!] Setting `PLATFORM_VERSION := 13` in BoardConfig.mk does NOTHING. Guard at
# build/make/core/version_defaults.mk:130 is `ifndef PLATFORM_VERSION`, and
# version_defaults.mk is evaluated BEFORE BoardConfig.mk, so the platform
# default wins and the device assignment is dead. This was caught by reading
# ro.build.version.release back out of the built image (it was 12), not from any
# build error -- there is none.
#
# An environment variable is defined before any makefile is read, so `ifndef`
# honours it.
export PLATFORM_VERSION=13

echo "== sourcing envsetup"
source build/envsetup.sh >/dev/null 2>&1 || { echo "!! envsetup failed" >&2; exit 2; }

echo "== lunch ${PRODUCT}-eng  (redirected, NOT piped)"
lunch "${PRODUCT}-eng" > "${TREE}/lunch.log" 2>&1
rc=$?
[ "${rc}" -eq 0 ] || { echo "!! lunch exited ${rc}"; tail -20 "${TREE}/lunch.log"; exit 2; }

# ---- the guard. This is the whole point of the script.
if [ "${TARGET_PRODUCT:-}" != "${PRODUCT}" ]; then
    echo "!! TARGET_PRODUCT is '${TARGET_PRODUCT:-<unset>}', expected '${PRODUCT}'" >&2
    echo "   Refusing to build. This is the aosp_arm/goldfish failure mode." >&2
    exit 2
fi
echo "   TARGET_PRODUCT=${TARGET_PRODUCT}  TARGET_DEVICE=${TARGET_DEVICE:-?}"

echo "== mka vendorbootimage  (log: ${LOG})"
mka vendorbootimage > "${LOG}" 2>&1
rc=$?
if [ "${rc}" -ne 0 ]; then
    echo "!! build FAILED (exit ${rc}); last errors:" >&2
    grep -iE "^(FAILED|error:|ninja: build stopped)" "${LOG}" | tail -15 >&2
    tail -25 "${LOG}" >&2
    exit "${rc}"
fi

OUT="${TREE}/out/target/product/S666LN/vendor_boot.img"
[ -f "${OUT}" ] || { echo "!! build reported success but ${OUT} is missing" >&2; exit 3; }
echo "== OK  $(stat -c %s "${OUT}") bytes  ${OUT}"
