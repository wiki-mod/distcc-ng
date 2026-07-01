#!/usr/bin/env bash
set -euo pipefail

readonly DEFAULT_DISTCCD_ALLOW="127.0.0.1"

normalize_allow() {
  local allow_value="${DISTCCD_ALLOW:-}"
  if [ -z "${allow_value}" ]; then
    printf '%s\n' "${DEFAULT_DISTCCD_ALLOW}"
    return 0
  fi

  case "${allow_value}" in
    *[[:space:]]*)
      printf '[distccd-entrypoint] ERROR: DISTCCD_ALLOW must not contain whitespace\n' >&2
      exit 1
      ;;
  esac

  printf '%s\n' "${allow_value}"
}

reject_conflicting_allow_args() {
  local arg
  for arg in "$@"; do
    case "${arg}" in
      --allow|--allow=*|--allow-private|--allow-private=*)
        printf '[distccd-entrypoint] ERROR: use DISTCCD_ALLOW instead of %s\n' "${arg}" >&2
        exit 1
        ;;
    esac
  done
}

main() {
  local allow_value
  allow_value="$(normalize_allow)"
  reject_conflicting_allow_args "$@"

  local -a distccd_args=()
  case "${1:-}" in
    "")
      distccd_args=(--daemon --no-detach --log-stderr)
      ;;
    distccd)
      shift
      distccd_args=("$@" --daemon --no-detach --log-stderr)
      ;;
    -*)
      distccd_args=("$@" --daemon --no-detach --log-stderr)
      ;;
    *)
      exec "$@"
      ;;
  esac

  exec distccd "${distccd_args[@]}" --allow "${allow_value}"
}

main "$@"
