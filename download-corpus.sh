#!/usr/bin/env bash
# download-corpus.sh — fetch + verify + extract the Tier B corpus.
#
# By default it takes the latest published release; set CORPUS_VERSION to pin
# one (and EXPECTED_SHA256 to pin its tarball's hash as well). Every download
# is checked against the release's sha256sum.txt.
#
# Idempotent: re-running when the target version is already extracted exits 0
# without re-fetching. Rollback rotation: existing ./corpus/ is moved to
# ./corpus.previous/ (one level kept).
#
# Per spec §5.5.

set -euo pipefail

# === Optional pins (environment) ===
CORPUS_VERSION="${CORPUS_VERSION:-latest}"
EXPECTED_SHA256="${EXPECTED_SHA256:-}"
RELEASE_REPO="${RELEASE_REPO:-Patchoulab/community-brain-distribution}"
# ===================================

CORPUS_DIR="./corpus"
PREVIOUS_DIR="./corpus.previous"

log() { echo "[download-corpus] $*" >&2; }

# Detect SHA tool.
sha256_of() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" | awk '{print $1}'
    else
        log "ERROR: neither sha256sum nor shasum found; install one"
        exit 2
    fi
}

# Need gh CLI for release lookups and asset downloads.
if ! command -v gh >/dev/null 2>&1; then
    log "ERROR: gh CLI is required to download release assets"
    log "  install: https://cli.github.com/"
    exit 2
fi

# Resolve "latest" to the newest published (non-draft, non-prerelease) release.
if [[ "$CORPUS_VERSION" == "latest" ]]; then
    CORPUS_VERSION=$(gh release view --repo "${RELEASE_REPO}" --json tagName --jq .tagName)
    if [[ -z "$CORPUS_VERSION" ]]; then
        log "ERROR: could not resolve the latest release of ${RELEASE_REPO}"
        exit 1
    fi
    log "latest release is ${CORPUS_VERSION}"
fi

# Idempotency short-circuit: already at target version?
if [[ -f "${CORPUS_DIR}/corpus-manifest.json" ]]; then
    if command -v jq >/dev/null 2>&1; then
        current=$(jq -r '.corpus_version' "${CORPUS_DIR}/corpus-manifest.json" 2>/dev/null || echo "")
        if [[ "$current" == "$CORPUS_VERSION" ]]; then
            log "corpus already at ${CORPUS_VERSION}; nothing to do"
            exit 0
        fi
    fi
fi

# Fetch into a tmp dir to avoid touching ./corpus until validated.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

log "fetching corpus ${CORPUS_VERSION} from ${RELEASE_REPO}"
cd "$TMP"
gh release download "${CORPUS_VERSION}" \
    --repo "${RELEASE_REPO}" \
    --pattern "corpus-${CORPUS_VERSION}.tar.gz" \
    --pattern "sha256sum.txt" \
    --pattern "corpus-manifest.json"

# Verify SHA-256 against the release's sha256sum.txt, and against the pin if set.
log "verifying SHA-256"
actual=$(sha256_of "corpus-${CORPUS_VERSION}.tar.gz")
listed=$(awk -v f="corpus-${CORPUS_VERSION}.tar.gz" '$2 == f || $2 == "*"f {print $1}' sha256sum.txt)
if [[ -z "$listed" || "$actual" != "$listed" ]]; then
    log "ERROR: SHA-256 does not match the release's sha256sum.txt"
    log "  listed: ${listed:-<missing>}"
    log "  actual: $actual"
    exit 1
fi
if [[ -n "$EXPECTED_SHA256" && "$actual" != "$EXPECTED_SHA256" ]]; then
    log "ERROR: SHA-256 mismatch with the pinned EXPECTED_SHA256"
    log "  expected: $EXPECTED_SHA256"
    log "  actual:   $actual"
    exit 1
fi
log "SHA-256 verified"

# Rollback rotation.
cd - >/dev/null
if [[ -d "$PREVIOUS_DIR" ]]; then
    log "removing old rollback at ${PREVIOUS_DIR}"
    rm -rf "$PREVIOUS_DIR"
fi
if [[ -d "$CORPUS_DIR" ]]; then
    log "rotating ${CORPUS_DIR} -> ${PREVIOUS_DIR}"
    mv "$CORPUS_DIR" "$PREVIOUS_DIR"
fi

# Extract.
mkdir -p "$CORPUS_DIR"
log "extracting tarball into ${CORPUS_DIR}"
tar -xzf "$TMP/corpus-${CORPUS_VERSION}.tar.gz" -C "$CORPUS_DIR"
cp "$TMP/corpus-manifest.json" "${CORPUS_DIR}/corpus-manifest.json"

log "corpus ${CORPUS_VERSION} ready"
log "  $(ls -lh "${CORPUS_DIR}/corpus-manifest.json" | awk '{print $5, $9}')"
log "  $(du -sh "${CORPUS_DIR}/lancedb" 2>/dev/null || true)"
