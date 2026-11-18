#!/usr/bin/env bash
# Lists the files in the home folder whose NAME looks like a key, a token or a sign-in, and
# says for each whether the recall pod could see it with the mounts in this folder's
# deployment.yaml. It looks at names only: it never opens a file and never prints what is in one.
#
#   bash apps/recall/scan-home.sh             every hit, marked VISIBLE or hidden
#   bash apps/recall/scan-home.sh --visible   only the hits the pod could see
#   bash apps/recall/scan-home.sh --summary   counts per folder right under the home, no paths
#
# Exit code: 0 when the pod could see none of them, 1 when it could see at least one,
# 2 when the manifests disagree with each other or the home folder is not the one they mount.
#
# A name is only a hint: a key saved as notes.txt is not found, and a hit may be harmless.
# Folders called node_modules and .git are not looked into.
set -euo pipefail

mode="${1:-all}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
deployment="$here/deployment.yaml"
check="$here/check.yaml"
home_dir="/home/develop" # the path the manifests mount, the same on the host and in the pod

if [[ "$HOME" != "$home_dir" ]]; then
  echo "This scan is for $home_dir (the folder the manifests mount); HOME is $HOME." >&2
  exit 2
fi

# What the pod mounts, read from deployment.yaml: the covers (volumes "hidden" and
# "claude-cover") and every other mount under the home folder.
covers=()
others=()
while IFS=$'\t' read -r name path; do
  [[ "$path" == "$home_dir"/* ]] || continue
  if [[ "$name" == hidden || "$name" == claude-cover ]]; then covers+=("$path"); else others+=("$path"); fi
done < <(awk '
  /^ *- name: / { sub(/^ *- name: */, ""); name = $0; next }
  /^ *mountPath: / && name != "" { sub(/^ *mountPath: */, ""); print name "\t" $0; name = "" }
' "$deployment")

# The liveness check keeps its own list of the covered folders (check.yaml); it must be the same.
listed="$(awk '/^  hidden: \|/ { on = 1; next } on && /^    / { sub(/^ +/, ""); print; next } on { exit }' "$check" | sort)"
mounted="$(printf '%s\n' "${covers[@]}" | grep -v -x "$home_dir/.claude" | sort)"
if [[ "$listed" != "$mounted" ]]; then
  echo "check.yaml (hidden) and the covers in deployment.yaml differ:" >&2
  diff <(echo "$listed") <(echo "$mounted") >&2 || true
  exit 2
fi

# Mounted back inside a cover (the sessions folder): visible again.
backs=()
for path in "${others[@]}"; do
  for cover in "${covers[@]}"; do
    [[ "$path" == "$cover"/* ]] && backs+=("$path")
  done
done

visible_path() {
  local file="$1" cover back
  for back in "${backs[@]}"; do [[ "$file" == "$back"/* ]] && return 0; done
  for cover in "${covers[@]}"; do [[ "$file" == "$cover"/* ]] && return 1; done
  return 0
}

# Names that look like a secret wherever they are.
exact=(
  -iname 'id_rsa' -o -iname 'id_rsa.*' -o -iname 'id_dsa' -o -iname 'id_dsa.*'
  -o -iname 'id_ecdsa' -o -iname 'id_ecdsa_sk' -o -iname 'id_ed25519' -o -iname 'id_ed25519_sk'
  -o -iname '*.pem' -o -iname '*.key' -o -iname '*.p12' -o -iname '*.pfx' -o -iname '*.p8'
  -o -iname '*.jks' -o -iname '*.keystore' -o -iname '*.kdbx' -o -iname '*.ppk' -o -iname '*.agekey'
  -o -iname '*.ovpn' -o -iname '*.gpg' -o -iname '*.pgp' -o -iname '*.tfstate' -o -iname '*.tfstate.*'
  -o -iname '*.tfrc.json' -o -iname '*.keychain' -o -iname '*.keychain-db'
  -o -iname '.env' -o -iname '.env.*' -o -iname '*.env'
  -o -name '.netrc' -o -name '.git-credentials' -o -name '.npmrc' -o -name '.pypirc' -o -name '.yarnrc.yml'
  -o -name '.htpasswd' -o -name '.pgpass' -o -name '.my.cnf' -o -name '.s3cfg' -o -name '.boto' -o -name '.dockercfg'
  -o -iname 'kubeconfig' -o -iname '*.kubeconfig' -o -name 'k3s.yaml'
  -o -name 'keys.txt' -o -name 'hosts.yml' -o -name 'auth.json' -o -name 'credentials' -o -name 'credentials.json'
  -o -name '.credentials' -o -name '.credentials.json' -o -name '.credentials_rsaparams' -o -name '.claude.json'
  -o -name '.claude.json.*' -o -iname 'service-account*.json' -o -name 'dump.pm2'
  -o -name 'Cookies' -o -name 'Login Data' -o -name 'cookies.sqlite' -o -name 'logins.json' -o -name 'key4.db'
  -o -name '.bash_history' -o -name '.zsh_history' -o -name '.node_repl_history' -o -name '.python_history'
  -o -name '.psql_history' -o -name '.mysql_history' -o -name '.sqlite_history'
)
# Words in a name that suggest a secret, unless the file is plainly code, text or a picture.
words=(
  -iname '*secret*' -o -iname '*token*' -o -iname '*credential*' -o -iname '*password*' -o -iname '*passwd*'
  -o -iname '*apikey*' -o -iname '*api_key*' -o -iname '*api-key*' -o -iname '*oauth*' -o -iname '*private*key*'
)
not_code=(
  ! -iname '*.ts' ! -iname '*.tsx' ! -iname '*.js' ! -iname '*.jsx' ! -iname '*.mjs' ! -iname '*.cjs' ! -iname '*.mts'
  ! -iname '*.cts' ! -iname '*.go' ! -iname '*.py' ! -iname '*.pyc' ! -iname '*.rb' ! -iname '*.rs' ! -iname '*.java'
  ! -iname '*.class' ! -iname '*.kt' ! -iname '*.swift' ! -iname '*.c' ! -iname '*.h' ! -iname '*.cc' ! -iname '*.cpp'
  ! -iname '*.hpp' ! -iname '*.cs' ! -iname '*.php' ! -iname '*.md' ! -iname '*.mdx' ! -iname '*.html' ! -iname '*.css'
  ! -iname '*.scss' ! -iname '*.map' ! -iname '*.snap' ! -iname '*.svg' ! -iname '*.png' ! -iname '*.jpg'
  ! -iname '*.gif' ! -iname '*.webp' ! -iname '*.ico' ! -iname '*.woff*' ! -iname '*.ttf' ! -iname '*.lock'
  ! -iname '*.sum' ! -iname '*.mod' ! -iname '*.d.ts' ! -iname '*.sh' ! -iname '*.so' ! -iname '*.wasm'
)
# Examples and public halves are not secrets.
not_example=(
  ! -iname '*.pub' ! -iname '*example*' ! -iname '*sample*' ! -iname '*template*' ! -iname '*.dist'
  ! -iname '*.defaults'
)

visible=0
hidden=0
declare -A per_folder=()
while IFS= read -r -d '' file; do
  top="${file#"$home_dir"/}"
  top="${top%%/*}"
  if visible_path "$file"; then
    visible=$((visible + 1))
    per_folder["$top"]=$((${per_folder["$top"]:-0} + 1))
    [[ "$mode" == --summary ]] || printf 'VISIBLE  %s\n' "$file"
  else
    hidden=$((hidden + 1))
    [[ "$mode" == --summary || "$mode" == --visible ]] || printf 'hidden   %s\n' "$file"
  fi
done < <(find "$home_dir" \( -name node_modules -o -name .git \) -prune -o \
  -type f "${not_example[@]}" \( \( "${exact[@]}" \) -o \( \( "${words[@]}" \) "${not_code[@]}" \) \) \
  -print0 2>/dev/null || true)

if [[ "$mode" == --summary ]]; then
  for top in "${!per_folder[@]}"; do printf '%6d  %s\n' "${per_folder[$top]}" "$top"; done | sort -k2
fi
echo "Looked at names under $home_dir: $visible the pod could see, $hidden covered."
[[ "$visible" -eq 0 ]]
