#!/usr/bin/env bash
set -eo pipefail

REPO_NAME="${REPO_NAME:-garen-tech-notes}"
REPO_DESCRIPTION="${REPO_DESCRIPTION:-Garen personal technical knowledge base}"
VISIBILITY_PRIVATE=true

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN is not set."
  echo "Create a GitHub token with repo scope, then run:"
  echo "  export GITHUB_TOKEN='<your_token>'"
  echo "  ./scripts/publish-github-private.sh"
  exit 1
fi
GITHUB_TOKEN_VALUE="${GITHUB_TOKEN:-}"

command -v curl >/dev/null 2>&1 || { echo "ERROR: curl is required"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "ERROR: git is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

if [ ! -d .git ]; then
  git init -b main
fi

git add .
if ! git diff --cached --quiet; then
  git commit -m "Update tech notes"
fi

USER_JSON="$(curl -fsS -H "Authorization: token ${GITHUB_TOKEN_VALUE}" https://api.github.com/user)"
GH_USER="$(python3 -c 'import sys,json; print(json.load(sys.stdin)["login"])' <<< "$USER_JSON")"

CREATE_PAYLOAD="$(REPO_NAME="$REPO_NAME" REPO_DESCRIPTION="$REPO_DESCRIPTION" VISIBILITY_PRIVATE="$VISIBILITY_PRIVATE" python3 - <<'PY'
import json
import os
payload = {
    "name": os.environ["REPO_NAME"],
    "description": os.environ["REPO_DESCRIPTION"],
    "private": os.environ.get("VISIBILITY_PRIVATE", "true").lower() == "true",
    "auto_init": False,
}
print(json.dumps(payload, ensure_ascii=False))
PY
)"

CREATE_RESPONSE_FILE="${TMPDIR:-/tmp}/garen-tech-notes-create-repo.json"
HTTP_CODE="$(curl -sS -o "$CREATE_RESPONSE_FILE" -w '%{http_code}' \
  -X POST \
  -H "Authorization: token ${GITHUB_TOKEN_VALUE}" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/user/repos \
  -d "$CREATE_PAYLOAD")"

if [ "$HTTP_CODE" = "201" ]; then
  echo "Created private repo: ${GH_USER}/${REPO_NAME}"
elif [ "$HTTP_CODE" = "422" ]; then
  echo "Repo may already exist: ${GH_USER}/${REPO_NAME}"
else
  echo "ERROR: GitHub repo creation failed with HTTP ${HTTP_CODE}"
  cat "$CREATE_RESPONSE_FILE"
  exit 1
fi

REMOTE_URL="https://github.com/${GH_USER}/${REPO_NAME}.git"
if git remote get-url origin >/dev/null 2>&1; then
  git remote set-url origin "$REMOTE_URL"
else
  git remote add origin "$REMOTE_URL"
fi

# Use an askpass helper so the token is not stored in .git/config or shell history.
ASKPASS_FILE="$(mktemp)"
chmod 700 "$ASKPASS_FILE"
cat > "$ASKPASS_FILE" <<'EOS'
#!/usr/bin/env bash
case "$1" in
  *Username*) echo "x-access-token" ;;
  *Password*) echo "$GITHUB_TOKEN" ;;
  *) echo "" ;;
esac
EOS
trap 'rm -f "$ASKPASS_FILE" "$CREATE_RESPONSE_FILE"' EXIT

GIT_ASKPASS="$ASKPASS_FILE" GITHUB_TOKEN="$GITHUB_TOKEN_VALUE" GIT_TERMINAL_PROMPT=0 git push -u origin main

echo "Published: https://github.com/${GH_USER}/${REPO_NAME}"
