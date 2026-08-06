#!/bin/zsh
# Install VOS runtime to ~/.vos and link ~/bin/vos — does NOT rewrite agent configs
set -euo pipefail

VOS_REPO="${VOS_REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
VOS_HOME="${VOS_HOME:-$HOME/.vos}"

echo "=== VOS install ==="
echo "repo: $VOS_REPO"
echo "home: $VOS_HOME"

mkdir -p "$VOS_HOME"/{memory,skills,state/sessions,config}
mkdir -p "$HOME/bin"

# Seed pack if missing (never clobber personalized SOUL/memory without force)
seed() {
  local src="$1" dst="$2"
  if [[ -e "$dst" && "${VOS_FORCE:-}" != "1" ]]; then
    echo "keep  $dst"
  else
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    echo "seed  $dst"
  fi
}

seed "$VOS_REPO/pack/SOUL.md" "$VOS_HOME/SOUL.md"
seed "$VOS_REPO/pack/memory/MEMORY.md" "$VOS_HOME/memory/MEMORY.md"
seed "$VOS_REPO/pack/memory/user_role.md" "$VOS_HOME/memory/user_role.md"
seed "$VOS_REPO/pack/memory/user_facts.md" "$VOS_HOME/memory/user_facts.md"
seed "$VOS_REPO/pack/memory/project_lura.md" "$VOS_HOME/memory/project_lura.md"
seed "$VOS_REPO/pack/memory/project_vos.md" "$VOS_HOME/memory/project_vos.md"
seed "$VOS_REPO/pack/memory/reference_hosts.md" "$VOS_HOME/memory/reference_hosts.md"

# Skills: always refresh from pack (skills are software; memory is personal)
for skill in recap dispatch; do
  mkdir -p "$VOS_HOME/skills/$skill"
  cp "$VOS_REPO/pack/skills/$skill/SKILL.md" "$VOS_HOME/skills/$skill/SKILL.md"
  echo "skill $skill"
done

# Example configs
if [[ ! -f "$VOS_HOME/config/policy.yaml" ]]; then
  cp "$VOS_REPO/config/policy.yaml.example" "$VOS_HOME/config/policy.yaml"
fi
if [[ ! -f "$VOS_HOME/config/workers.yaml" ]]; then
  cp "$VOS_REPO/config/workers.yaml.example" "$VOS_HOME/config/workers.yaml"
fi

# Link CLI
chmod +x "$VOS_REPO/bin/vos" "$VOS_REPO/scripts/"*.sh 2>/dev/null || true
ln -sfn "$VOS_REPO/bin/vos" "$HOME/bin/vos"
echo "link  $HOME/bin/vos → $VOS_REPO/bin/vos"

# PATH hint
if ! echo ":$PATH:" | grep -q ":$HOME/bin:"; then
  echo ""
  echo "Note: $HOME/bin is not on PATH in this shell."
  echo "Add to ~/.zshrc if needed:  export PATH=\"\$HOME/bin:\$PATH\""
fi

echo ""
echo "=== doctor ==="
"$HOME/bin/vos" status || "$VOS_REPO/bin/vos" status
echo ""
echo "Try:  vos recap"
echo "      vos ask \"what can you do\""
echo "      vos listen 15"
echo "Dock: ./scripts/make-app.sh"
echo "Done. No Claude/Codex/Grok config files were modified."
