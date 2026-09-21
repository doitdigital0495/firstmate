#!/usr/bin/env bash
set -u
ROOT=/home/daan/.no-mistakes/worktrees/cf62ac6bfd91/01M312BA89GBC0KZHXJZ0BBSX9
. "$ROOT/bin/fm-composer-lib.sh"
ESC=$'\033'
echo "FM_COMPOSER_CAPTURE_LINES default = $FM_COMPOSER_CAPTURE_LINES"

# tall Codex pane: idle prompt, then metadata + 20 blank rows below it
screen=''
for ((i=0;i<22;i++)); do screen+='transcript line'$'\n'; done
screen+="${ESC}[1m>${ESC}[0m ${ESC}[2mAsk Codex to do anything${ESC}[0m"$'\n\n'
screen+='  gpt-6-astra high fast'$'\n'
for ((i=0;i<20;i++)); do screen+=' '$'\n'; done
# use the real codex glyph
screen=${screen//">${ESC}[0m ${ESC}[2mAsk"/"$(printf '›')${ESC}[0m ${ESC}[2mAsk"}

caps=$(printf 'styled=1\ncursor=0\nidentity=1\nrows=%s' "$FM_COMPOSER_CAPTURE_LINES")
tall=$(printf '%s' "$screen" | tail -n "$FM_COMPOSER_CAPTURE_LINES")
echo "tall codex pane, prompt outside the ${FM_COMPOSER_CAPTURE_LINES}-row window -> $(fm_composer_classify_screen "$caps" "$tall")"

# adversarial: same idle prompt inside the window (no trailing blank flood)
near=''
for ((i=0;i<22;i++)); do near+='transcript line'$'\n'; done
near+="${ESC}[1m$(printf '›')${ESC}[0m ${ESC}[2mAsk Codex to do anything${ESC}[0m"$'\n\n'
near+='  gpt-6-astra high fast'$'\n'
nearcap=$(printf '%s' "$near" | tail -n "$FM_COMPOSER_CAPTURE_LINES")
echo "codex idle prompt inside the window -> $(fm_composer_classify_screen "$caps" "$nearcap")"

# adversarial: typed text in the composer must stay pending
typed=''
for ((i=0;i<22;i++)); do typed+='transcript line'$'\n'; done
typed+="${ESC}[1m$(printf '›')${ESC}[0m fix the flaky test"$'\n\n'
typed+='  gpt-6-astra high fast'$'\n'
typedcap=$(printf '%s' "$typed" | tail -n "$FM_COMPOSER_CAPTURE_LINES")
echo "codex composer holding typed text -> $(fm_composer_classify_screen "$caps" "$typedcap")"
