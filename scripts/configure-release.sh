#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
readonly SCRIPT_DIR
REPOSITORY_ROOT="$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)"
readonly REPOSITORY_ROOT
readonly DEFAULT_CONFIG_DIRECTORY="${XDG_CONFIG_HOME:-${HOME}/.config}/dacbar"
readonly RELEASE_ENVIRONMENT="release-signing"

secrets_file=""
variables_file=""
target_repository=""
validate_only=0
assume_yes=0

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [options]

Configure the GitHub Actions settings required by DACBar releases.
The protected $RELEASE_ENVIRONMENT environment must already exist; this script
does not create or change environments, reviewers, deployment policies, or rulesets.

Options:
  --secrets-file PATH    Read secret values and secure-file paths from PATH.
  --variables-file PATH  Read non-secret values from PATH.
  --repo OWNER/REPO      Configure this repository instead of the current one.
  --validate-only        Validate both local files without contacting GitHub.
  --yes                  Skip the target-repository confirmation.
  -h, --help             Show this help.

If a file option is omitted, the script uses these files when they exist:
  $DEFAULT_CONFIG_DIRECTORY/release.secrets
  $DEFAULT_CONFIG_DIRECTORY/release.variables

Otherwise the script prompts for each value and does not persist it locally.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case "$1" in
        --secrets-file)
            (($# >= 2)) || fail "--secrets-file requires a path"
            secrets_file="$2"
            shift 2
            ;;
        --variables-file)
            (($# >= 2)) || fail "--variables-file requires a path"
            variables_file="$2"
            shift 2
            ;;
        --repo)
            (($# >= 2)) || fail "--repo requires OWNER/REPO"
            target_repository="$2"
            shift 2
            ;;
        --validate-only)
            validate_only=1
            shift
            ;;
        --yes)
            assume_yes=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

default_secrets_file="$DEFAULT_CONFIG_DIRECTORY/release.secrets"
default_variables_file="$DEFAULT_CONFIG_DIRECTORY/release.variables"
if [[ -z "$secrets_file" && -f "$default_secrets_file" ]]; then
    secrets_file="$default_secrets_file"
fi
if [[ -z "$variables_file" && -f "$default_variables_file" ]]; then
    variables_file="$default_variables_file"
fi

canonical_file_path() {
    local path="$1"
    local directory
    directory="$(cd "$(dirname "$path")" && pwd -P)"
    printf '%s/%s' "$directory" "$(basename "$path")"
}

validate_config_location() {
    local path="$1"
    local sensitive="$2"
    local canonical_path

    [[ -f "$path" ]] || fail "configuration file does not exist: $path"
    [[ ! -L "$path" ]] || fail "configuration file must not be a symbolic link: $path"
    canonical_path="$(canonical_file_path "$path")"

    if [[ "$sensitive" == "yes" ]]; then
        case "$canonical_path" in
            "$REPOSITORY_ROOT"|"$REPOSITORY_ROOT"/*)
                fail "the secrets file must be stored outside the repository: $canonical_path"
                ;;
        esac

        local permissions
        permissions="$(stat -f '%Lp' "$canonical_path")"
        case "$permissions" in
            400|600) ;;
            *) fail "the secrets file permissions must be 600 or 400 (found $permissions): $canonical_path" ;;
        esac
    fi
}

validate_sensitive_file() {
    local path="$1"
    local label="$2"
    local canonical_path permissions owner

    [[ "$path" == /* ]] || fail "$label path must be absolute"
    [[ -s "$path" ]] || fail "$label file does not exist or is empty: $path"
    [[ ! -L "$path" ]] || fail "$label file must not be a symbolic link: $path"
    canonical_path="$(canonical_file_path "$path")"
    case "$canonical_path" in
        "$REPOSITORY_ROOT"|"$REPOSITORY_ROOT"/*)
            fail "$label file must be stored outside the repository: $canonical_path"
            ;;
    esac

    permissions="$(stat -f '%Lp' "$canonical_path")"
    case "$permissions" in
        400|600) ;;
        *) fail "$label file permissions must be 600 or 400 (found $permissions): $canonical_path" ;;
    esac
    owner="$(stat -f '%Su' "$canonical_path")"
    [[ "$owner" == "$(id -un)" ]] || fail "$label file must be owned by the current user: $canonical_path"
}

validate_config_keys() {
    local path="$1"
    local kind="$2"
    local line key

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *"="* ]] || fail "invalid line without '=' in $path"
        key="${line%%=*}"
        key="$(printf '%s' "$key" | awk '{$1=$1; print}')"
        case "$kind:$key" in
            secrets:BUILD_CERTIFICATE_P12|secrets:P12_PASSWORD|secrets:NOTARY_APPLE_ID|secrets:NOTARY_PASSWORD|secrets:SPARKLE_PRIVATE_KEY_FILE|secrets:DSYM_ARCHIVE_PASSWORD) ;;
            variables:DEVELOPER_ID_APPLICATION|variables:NOTARY_TEAM_ID|variables:SPARKLE_PUBLIC_ED_KEY) ;;
            *) fail "unknown $kind key '$key' in $path" ;;
        esac
    done < "$path"
}

read_config_value() {
    local path="$1"
    local requested_key="$2"
    local status

    set +e
    CONFIG_VALUE="$(awk -v requested_key="$requested_key" '
        /^[[:space:]]*($|#)/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            separator = index(line, "=")
            if (separator == 0) next
            key = substr(line, 1, separator - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == requested_key) {
                matches++
                value = substr(line, separator + 1)
            }
        }
        END {
            if (matches == 1) {
                printf "%s", value
                exit 0
            }
            exit matches > 1 ? 2 : 1
        }
    ' "$path")"
    status=$?
    set -e

    case "$status" in
        0) [[ -n "$CONFIG_VALUE" ]] || fail "empty value for $requested_key in $path" ;;
        1) fail "missing $requested_key in $path" ;;
        2) fail "duplicate $requested_key in $path" ;;
        *) fail "could not read $requested_key from $path" ;;
    esac
}

prompt_value() {
    local label="$1"
    local hidden="$2"
    printf '%s: ' "$label" >&2
    if [[ "$hidden" == "yes" ]]; then
        IFS= read -r -s PROMPT_VALUE
        printf '\n' >&2
    else
        IFS= read -r PROMPT_VALUE
    fi
    [[ -n "$PROMPT_VALUE" ]] || fail "$label must not be empty"
}

if [[ -n "$secrets_file" ]]; then
    validate_config_location "$secrets_file" yes
    validate_config_keys "$secrets_file" secrets
    read_config_value "$secrets_file" BUILD_CERTIFICATE_P12
    certificate_path="$CONFIG_VALUE"
    read_config_value "$secrets_file" P12_PASSWORD
    p12_password="$CONFIG_VALUE"
    read_config_value "$secrets_file" NOTARY_APPLE_ID
    notary_apple_id="$CONFIG_VALUE"
    read_config_value "$secrets_file" NOTARY_PASSWORD
    notary_password="$CONFIG_VALUE"
    read_config_value "$secrets_file" SPARKLE_PRIVATE_KEY_FILE
    sparkle_private_key_path="$CONFIG_VALUE"
    read_config_value "$secrets_file" DSYM_ARCHIVE_PASSWORD
    dsym_archive_password="$CONFIG_VALUE"
else
    ((validate_only == 0)) || fail "--validate-only requires --secrets-file (or the default file)"
    prompt_value "Absolute path to Developer ID .p12" no
    certificate_path="$PROMPT_VALUE"
    prompt_value "Password for the .p12" yes
    p12_password="$PROMPT_VALUE"
    prompt_value "Notarization Apple Account email" no
    notary_apple_id="$PROMPT_VALUE"
    prompt_value "Notarization app-specific password" yes
    notary_password="$PROMPT_VALUE"
    prompt_value "Absolute path to the exported Sparkle private key" no
    sparkle_private_key_path="$PROMPT_VALUE"
    prompt_value "Password for encrypted dSYM archives" yes
    dsym_archive_password="$PROMPT_VALUE"
fi

if [[ -n "$variables_file" ]]; then
    validate_config_location "$variables_file" no
    validate_config_keys "$variables_file" variables
    read_config_value "$variables_file" DEVELOPER_ID_APPLICATION
    developer_id_application="$CONFIG_VALUE"
    read_config_value "$variables_file" NOTARY_TEAM_ID
    notary_team_id="$CONFIG_VALUE"
    read_config_value "$variables_file" SPARKLE_PUBLIC_ED_KEY
    sparkle_public_key="$CONFIG_VALUE"
else
    ((validate_only == 0)) || fail "--validate-only requires --variables-file (or the default file)"
    prompt_value "Full Developer ID Application identity" no
    developer_id_application="$PROMPT_VALUE"
    prompt_value "Apple Developer Team ID" no
    notary_team_id="$PROMPT_VALUE"
    prompt_value "Sparkle Ed25519 public key" no
    sparkle_public_key="$PROMPT_VALUE"
fi

validate_sensitive_file "$certificate_path" "Developer ID .p12"
validate_sensitive_file "$sparkle_private_key_path" "Sparkle private key"
(( ${#dsym_archive_password} >= 32 )) || fail "DSYM_ARCHIVE_PASSWORD must contain at least 32 characters"
[[ "$notary_team_id" =~ ^[A-Z0-9]{10}$ ]] || fail "NOTARY_TEAM_ID must contain exactly 10 uppercase letters or digits"
[[ "$developer_id_application" == "Developer ID Application: "* \
    && "$developer_id_application" == *" ($notary_team_id)" ]] || \
    fail "DEVELOPER_ID_APPLICATION must end with the configured NOTARY_TEAM_ID"

derived_sparkle_public_key="$(swift "$REPOSITORY_ROOT/tools/sparkle-public-key.swift" < "$sparkle_private_key_path")"
[[ "$derived_sparkle_public_key" == "$sparkle_public_key" ]] || \
    fail "SPARKLE_PUBLIC_ED_KEY does not match SPARKLE_PRIVATE_KEY_FILE"

if ((validate_only == 1)); then
    printf 'Release configuration is valid; no GitHub settings were changed.\n'
    exit 0
fi

command -v gh >/dev/null || fail "GitHub CLI (gh) is required"
gh auth status >/dev/null
if [[ -z "$target_repository" ]]; then
    target_repository="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
fi
[[ "$target_repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || fail "--repo must use OWNER/REPO format"
target_repository="$(gh repo view "$target_repository" --json nameWithOwner --jq .nameWithOwner)"
gh api "repos/$target_repository/environments/$RELEASE_ENVIRONMENT" >/dev/null || \
    fail "GitHub environment '$RELEASE_ENVIRONMENT' does not exist; configure it manually first"

printf 'Target GitHub repository: %s\n' "$target_repository"
if ((assume_yes == 0)); then
    printf 'Upload 6 Secrets and 3 Variables? [y/N] '
    IFS= read -r confirmation
    case "$confirmation" in
        y|Y|yes|YES) ;;
        *) fail "cancelled; no GitHub settings were changed" ;;
    esac
fi

printf 'Setting GitHub Actions Secrets in %s...\n' "$RELEASE_ENVIRONMENT"
/usr/bin/base64 < "$certificate_path" | gh secret set BUILD_CERTIFICATE_BASE64 \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
printf '%s' "$p12_password" | gh secret set P12_PASSWORD \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
printf '%s' "$notary_apple_id" | gh secret set NOTARY_APPLE_ID \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
printf '%s' "$notary_password" | gh secret set NOTARY_PASSWORD \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
gh secret set SPARKLE_PRIVATE_KEY --repo "$target_repository" \
    --env "$RELEASE_ENVIRONMENT" < "$sparkle_private_key_path"
printf '%s' "$dsym_archive_password" | gh secret set DSYM_ARCHIVE_PASSWORD \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"

printf 'Setting GitHub Actions Variables in %s...\n' "$RELEASE_ENVIRONMENT"
printf '%s' "$developer_id_application" | gh variable set DEVELOPER_ID_APPLICATION \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
printf '%s' "$notary_team_id" | gh variable set NOTARY_TEAM_ID \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"
printf '%s' "$sparkle_public_key" | gh variable set SPARKLE_PUBLIC_ED_KEY \
    --repo "$target_repository" --env "$RELEASE_ENVIRONMENT"

secret_names="$(gh secret list --repo "$target_repository" --env "$RELEASE_ENVIRONMENT" --json name --jq '.[].name')"
variable_names="$(gh variable list --repo "$target_repository" --env "$RELEASE_ENVIRONMENT" --json name --jq '.[].name')"
for name in BUILD_CERTIFICATE_BASE64 P12_PASSWORD NOTARY_APPLE_ID NOTARY_PASSWORD SPARKLE_PRIVATE_KEY DSYM_ARCHIVE_PASSWORD; do
    grep -Fqx "$name" <<< "$secret_names" || fail "GitHub did not report Secret $name after upload"
done
for name in DEVELOPER_ID_APPLICATION NOTARY_TEAM_ID SPARKLE_PUBLIC_ED_KEY; do
    grep -Fqx "$name" <<< "$variable_names" || fail "GitHub did not report Variable $name after upload"
done

printf 'Release settings are configured for %s environment %s. The script did not display secrets or create credential copies.\n' \
    "$target_repository" "$RELEASE_ENVIRONMENT"
