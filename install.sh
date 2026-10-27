#!/usr/bin/env bash
# install.sh — symlink the wrappers into ~/.local/bin (or $PREFIX/bin).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
dest="${PREFIX:-$HOME/.local}/bin"
mkdir -p "$dest"

for f in paru-llm-diff-pager flatpak-llm-update; do
    ln -sfn "$here/bin/$f" "$dest/$f"
    echo "linked $dest/$f"
done

cat <<EOF

paru: add to ~/.config/paru/paru.conf
    [bin]
    Pager = $dest/paru-llm-diff-pager

flatpak: run \`flatpak-llm-update\` instead of \`flatpak update\`
    (optional) alias fpu=flatpak-llm-update
EOF
command -v claude >/dev/null 2>&1 || echo "warning: \`claude\` (Claude Code CLI) not found in PATH"
