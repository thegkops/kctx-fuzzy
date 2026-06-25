#!/usr/bin/env bash
# kctx-fuzzy — kubectl context and namespace switcher with fuzzy search
# Works standalone: no external dependencies required (fzf is optional)

set -euo pipefail

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Kubeconfig resolution ────────────────────────────────────────────────────
_kctx_kubeconfig_files() {
  local kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
  # Split colon-separated paths and return only existing files
  IFS=':' read -ra parts <<< "$kubeconfig"
  for f in "${parts[@]}"; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

_kctx_first_kubeconfig() {
  _kctx_kubeconfig_files | head -n1
}

# ── Parse kubeconfig with pure bash (no python/yq/kubectl required) ──────────
_kctx_list_contexts() {
  local kubeconfig
  while IFS= read -r kubeconfig; do
    # Extract context names from "- context:" or "- name:" blocks
    awk '
      /^contexts:/ { in_contexts=1; next }
      /^[a-z]/ && !/^  / { in_contexts=0 }
      in_contexts && /^- name:/ { print $3 }
      in_contexts && /^  - name:/ { print $4 }
    ' "$kubeconfig"
  done < <(_kctx_kubeconfig_files)
}

_kctx_current_context() {
  local kubeconfig
  kubeconfig="$(_kctx_first_kubeconfig)"
  [[ -z "$kubeconfig" ]] && { echo ""; return; }
  awk '/^current-context:/ { print $2; exit }' "$kubeconfig"
}

_kctx_get_cluster_for_context() {
  local ctx="$1"
  local kubeconfig
  while IFS= read -r kubeconfig; do
    awk -v ctx="$ctx" '
      /^contexts:/ { in_contexts=1; next }
      /^[a-z]/ && !/^  / { in_contexts=0 }
      in_contexts && /- name: / { name=$3 }
      in_contexts && name==ctx && /cluster:/ { print $2; exit }
    ' "$kubeconfig" | head -n1
  done < <(_kctx_kubeconfig_files)
}

_kctx_get_server_for_cluster() {
  local cluster="$1"
  local kubeconfig
  while IFS= read -r kubeconfig; do
    awk -v cl="$cluster" '
      /^clusters:/ { in_clusters=1; next }
      /^[a-z]/ && !/^  / { in_clusters=0 }
      in_clusters && /- name: / { name=$3 }
      in_clusters && name==cl && /server:/ { print $2; exit }
    ' "$kubeconfig" | head -n1
  done < <(_kctx_kubeconfig_files)
}

_kctx_set_context() {
  local ctx="$1"
  # Prefer kubectl if available; otherwise patch kubeconfig in-place
  if command -v kubectl &>/dev/null; then
    kubectl config use-context "$ctx" --kubeconfig="${KUBECONFIG:-$HOME/.kube/config}" &>/dev/null
  else
    local kubeconfig
    kubeconfig="$(_kctx_first_kubeconfig)"
    [[ -z "$kubeconfig" ]] && { echo -e "${RED}No kubeconfig found${RESET}" >&2; return 1; }
    # Use python3 if available for safe YAML editing
    if command -v python3 &>/dev/null; then
      python3 - "$kubeconfig" "$ctx" <<'PYEOF'
import sys, re
path, ctx = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = f.read()
data = re.sub(r'^(current-context:\s*).*$', r'\g<1>' + ctx, data, flags=re.MULTILINE)
with open(path, 'w') as f:
    f.write(data)
PYEOF
    else
      sed -i.bak "s/^current-context:.*/current-context: ${ctx}/" "$kubeconfig"
    fi
  fi
}

# ── Namespace helpers (requires kubectl or API access) ───────────────────────
_kns_list_namespaces() {
  if command -v kubectl &>/dev/null; then
    kubectl get namespaces --no-headers -o custom-columns=":metadata.name" 2>/dev/null
  else
    echo -e "${YELLOW}kubectl not found — cannot list namespaces${RESET}" >&2
    return 1
  fi
}

_kns_current_namespace() {
  local ctx kubeconfig ns
  ctx="$(_kctx_current_context)"
  [[ -z "$ctx" ]] && { echo "default"; return; }
  kubeconfig="$(_kctx_first_kubeconfig)"
  [[ -z "$kubeconfig" ]] && { echo "default"; return; }
  ns=$(awk -v ctx="$ctx" '
    /^contexts:/ { in_contexts=1; next }
    /^[a-z]/ && !/^  / { in_contexts=0 }
    in_contexts && /- name: / { name=$3 }
    in_contexts && name==ctx && /namespace:/ { print $2; exit }
  ' "$kubeconfig")
  echo "${ns:-default}"
}

_kns_set_namespace() {
  local ns="$1"
  if command -v kubectl &>/dev/null; then
    kubectl config set-context --current --namespace="$ns" &>/dev/null
  else
    echo -e "${RED}kubectl not found — cannot set namespace${RESET}" >&2
    return 1
  fi
}

# ── Fuzzy selector ────────────────────────────────────────────────────────────
_kctx_select() {
  # $1 = prompt string, stdin = newline-separated items
  local prompt="$1"
  local items
  items=$(cat)

  if command -v fzf &>/dev/null; then
    echo "$items" | fzf --ansi --prompt="$prompt " --height=40% --reverse --cycle
  else
    # Numbered fallback using bash `select`
    local arr=()
    while IFS= read -r line; do
      arr+=("$line")
    done <<< "$items"

    echo -e "${CYAN}${prompt}${RESET}" >&2
    PS3=$'\nEnter number: '
    select choice in "${arr[@]}"; do
      [[ -n "$choice" ]] && { echo "$choice"; return; }
      echo -e "${RED}Invalid selection${RESET}" >&2
    done
  fi
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_current() {
  local ctx ns
  ctx="$(_kctx_current_context)"
  ns="$(_kns_current_namespace)"
  if [[ -z "$ctx" ]]; then
    echo -e "${RED}No current context set${RESET}"
    return 1
  fi
  echo -e "${BOLD}Context  :${RESET} ${GREEN}${ctx}${RESET}"
  echo -e "${BOLD}Namespace:${RESET} ${CYAN}${ns}${RESET}"
}

cmd_list() {
  local current
  current="$(_kctx_current_context)"
  while IFS= read -r ctx; do
    local cluster server label
    cluster="$(_kctx_get_cluster_for_context "$ctx")"
    server="$(_kctx_get_server_for_cluster "$cluster")"
    if [[ "$ctx" == "$current" ]]; then
      printf "${GREEN}${BOLD}* %-40s${RESET}  ${CYAN}%s${RESET}\n" "$ctx" "${server:-<unknown>}"
    else
      printf "  %-40s  ${CYAN}%s${RESET}\n" "$ctx" "${server:-<unknown>}"
    fi
  done < <(_kctx_list_contexts)
}

cmd_switch_context() {
  local current
  current="$(_kctx_current_context)"

  # Build display list: mark current context
  local display_items=()
  while IFS= read -r ctx; do
    local cluster server
    cluster="$(_kctx_get_cluster_for_context "$ctx")"
    server="$(_kctx_get_server_for_cluster "$cluster")"
    local label
    if [[ "$ctx" == "$current" ]]; then
      label=$(printf "${GREEN}${BOLD}%-40s${RESET}  ${CYAN}%s${RESET}" "$ctx" "${server:-<unknown>}")
    else
      label=$(printf "%-40s  ${CYAN}%s${RESET}" "$ctx" "${server:-<unknown>}")
    fi
    display_items+=("$label")
  done < <(_kctx_list_contexts)

  if [[ ${#display_items[@]} -eq 0 ]]; then
    echo -e "${RED}No contexts found in kubeconfig${RESET}" >&2
    return 1
  fi

  local selected
  selected=$(printf '%s\n' "${display_items[@]}" | _kctx_select "Switch context >")
  [[ -z "$selected" ]] && { echo -e "${YELLOW}Cancelled${RESET}"; return 0; }

  # Strip ANSI codes and extract context name (first field)
  local ctx_name
  ctx_name=$(echo "$selected" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}')

  if [[ "$ctx_name" == "$current" ]]; then
    echo -e "${YELLOW}Already on context:${RESET} ${GREEN}${ctx_name}${RESET}"
    return 0
  fi

  _kctx_set_context "$ctx_name"
  echo -e "${GREEN}Switched to context:${RESET} ${BOLD}${ctx_name}${RESET}"
}

cmd_switch_namespace() {
  local current_ns
  current_ns="$(_kns_current_namespace)"

  local ns_list
  ns_list=$(_kns_list_namespaces 2>/dev/null) || return 1

  if [[ -z "$ns_list" ]]; then
    echo -e "${RED}No namespaces found (check cluster connectivity)${RESET}" >&2
    return 1
  fi

  local display_items=()
  while IFS= read -r ns; do
    if [[ "$ns" == "$current_ns" ]]; then
      display_items+=("$(printf "${GREEN}${BOLD}* %-30s${RESET}" "$ns")")
    else
      display_items+=("$(printf "  %-30s" "$ns")")
    fi
  done <<< "$ns_list"

  local selected
  selected=$(printf '%s\n' "${display_items[@]}" | _kctx_select "Switch namespace >")
  [[ -z "$selected" ]] && { echo -e "${YELLOW}Cancelled${RESET}"; return 0; }

  local ns_name
  ns_name=$(echo "$selected" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}' | sed 's/^\*//' | xargs)

  if [[ "$ns_name" == "$current_ns" ]]; then
    echo -e "${YELLOW}Already in namespace:${RESET} ${GREEN}${ns_name}${RESET}"
    return 0
  fi

  _kns_set_namespace "$ns_name"
  echo -e "${GREEN}Switched to namespace:${RESET} ${BOLD}${ns_name}${RESET}"
}

usage() {
  cat <<EOF
${BOLD}kctx-fuzzy${RESET} — kubectl context and namespace switcher with fuzzy search

${BOLD}USAGE${RESET}
  kctx-fuzzy            Fuzzy switch kubectl context
  kctx-fuzzy -n         Fuzzy switch namespace in current context
  kctx-fuzzy -c         Show current context and namespace
  kctx-fuzzy -l         List all contexts with cluster URLs
  kctx-fuzzy -h         Show this help

  When invoked as ${BOLD}kns-fuzzy${RESET}, switches namespace directly.

${BOLD}FUZZY SEARCH${RESET}
  Uses fzf if installed; falls back to a numbered menu otherwise.

${BOLD}KUBECONFIG${RESET}
  Reads \$KUBECONFIG or ~/.kube/config (colon-separated paths supported).
EOF
}

# ── Entry point ───────────────────────────────────────────────────────────────
main() {
  # If invoked as kns-fuzzy, go straight to namespace switching
  local invoked_as
  invoked_as="$(basename "$0")"
  if [[ "$invoked_as" == "kns-fuzzy" ]]; then
    cmd_switch_namespace
    return
  fi

  case "${1:-}" in
    -n|--namespace) cmd_switch_namespace ;;
    -c|--current)   cmd_current ;;
    -l|--list)      cmd_list ;;
    -h|--help)      usage ;;
    "")             cmd_switch_context ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
