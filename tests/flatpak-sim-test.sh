#!/usr/bin/env bash
# flatpak-sim-test.sh — offline test of flatpak-llm-update's decision logic.
# Puts fake `flatpak`, `gh` and `claude` first in PATH (no network, no model
# calls, nothing installed) and checks classification, filtering, exit codes
# and that confirmed updates are pinned to the reviewed commits.
# shellcheck disable=SC2016,SC2034  # check() evals its single-quoted test later
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
export SIM_LOG="$work/update.log"

cat > "$work/bin/flatpak" <<'EOF'
#!/usr/bin/env bash
# Fake flatpak. User installation only; the system one has no updates.
inst=; args=()
for a in "$@"; do case "$a" in --user|--system) inst=${a#--} ;; *) args+=("$a") ;; esac; done
set -- "${args[@]}"
commit_of() { printf '%064d' "${#1}"; }
case "$1" in
    remote-ls)
        [ "$inst" = user ] || exit 0
        printf '%s\t%s\n' \
            app/org.telegram.desktop/x86_64/stable flathub \
            app/org.mozilla.firefox/x86_64/stable flathub \
            runtime/org.gnome.Platform/x86_64/50 flathub \
            runtime/com.obsproject.Studio.Plugin.Foo/x86_64/stable flathub \
            app/com.evil.App/x86_64/stable evilremote \
            app/org.masked.App/x86_64/stable flathub ;;
    remotes) printf 'flathub https://dl.flathub.org/repo/\nevilremote https://evil.example/repo/\n' ;;
    mask) echo '  org.masked.*' ;;
    remote-info)
        shift; [ "$1" = --show-metadata ] && { printf '[Application]\nname=%s\n[Context]\nshared=network;\n' "$3"; exit 0; }
        id=${2%%//*}
        case "$id" in
            org.mozilla.firefox) subj="Export org.mozilla.firefox" ;;
            *) subj="Update modules (bbbbbbbbbbbb)" ;;
        esac
        printf '        Ref: x\n     Commit: %s\n    Subject: %s\n' "$(commit_of "$id")" "$subj" ;;
    info)
        shift; [ "$1" = --show-metadata ] && { printf '[Application]\nname=%s\n[Context]\nshared=network;\n' "$2"; exit 0; }
        printf '    Subject: Older (aaaaaaaaaaaa)\n' ;;
    update) shift; echo "update --$inst $*" >> "$SIM_LOG" ;;
    *) echo "fake flatpak: unhandled $*" >&2; exit 1 ;;
esac
EOF
cat > "$work/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *--jq*) echo "Commits:"; echo "  - Update modules [flathubbot]" ;;
    *) printf 'diff --git a/x.yml b/x.yml\n-tag: v1\n+tag: v2\n' ;;
esac
EOF
cat > "$work/bin/claude" <<'EOF'
#!/usr/bin/env bash
# Fake reviewer: DANGEROUS for the non-Flathub app, CLEAN otherwise.
if grep -q 'com.evil.App' -; then echo "VERDICT: DANGEROUS"; else echo "VERDICT: CLEAN"; fi
EOF
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH"

fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=1; fi; }

out="$("$here/bin/flatpak-llm-update" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
"$here/bin/flatpak-llm-update" >/dev/null 2>&1; rc=$?
check "full run exits 2 on a DANGEROUS item" '[ "$rc" -eq 2 ]'
check "overall verdict is DANGEROUS" 'grep -q "overall DANGEROUS" <<< "$out"'
check "platform runtime listed, not reviewed" 'grep -q "^    user|org.gnome.Platform//50" <<< "$out" && ! grep -q "═══ org.gnome.Platform:" <<< "$out"'
check "app extension is reviewed" 'grep -q "═══ com.obsproject.Studio.Plugin.Foo: CLEAN" <<< "$out"'
check "direct-upload app flagged" 'grep -q "No public manifest diff" <<< "$out"'
check "non-Flathub remote flagged by URL" 'grep -q "NOTE: not a Flathub remote: https://evil.example/repo/" <<< "$out"'
check "masked app skipped" 'grep -q "org.masked.App.*masked, skipped" <<< "$out"'
check "nothing updated without a TTY" '[ ! -e "$SIM_LOG" ]'

out="$("$here/bin/flatpak-llm-update" org.telegram.desktop 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
"$here/bin/flatpak-llm-update" org.telegram.desktop >/dev/null 2>&1; rc=$?
check "APP-ID filter narrows the review" '[ "$rc" -eq 0 ] && grep -q "org.telegram.desktop" <<< "$out" && ! grep -q "com.evil.App" <<< "$out"'

"$here/bin/flatpak-llm-update" --commit=abc >/dev/null 2>&1; rc=$?
check "--commit refused" '[ "$rc" -eq 64 ]'

if command -v script >/dev/null 2>&1; then
    printf 'y\n' | env FLATPAK_LLM_REAL_PAGER=cat script -qec "$here/bin/flatpak-llm-update org.telegram.desktop -y" /dev/null >/dev/null 2>&1
    check "confirmed update is pinned to the reviewed commit" \
        'grep -qx "update --user -y --commit=$(printf "%064d" 20) org.telegram.desktop//stable" "$SIM_LOG"'
fi

exit "$fail"
