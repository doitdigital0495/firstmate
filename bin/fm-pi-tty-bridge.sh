#!/usr/bin/env bash
# Give Pi a real controlling terminal when the credential broker pipes its
# output. Keep this INSIDE opr: the broker still resolves credentials and masks
# its output, while script relays Pi's interactive display back to the pane.
set -u

[ "$#" -gt 0 ] || { echo 'error: Pi terminal bridge requires a command' >&2; exit 1; }
command -v script >/dev/null 2>&1 || { echo 'error: Pi terminal bridge requires script' >&2; exit 1; }
case "$(uname -s)" in
Darwin)
  # BSD script accepts a command and arguments after the transcript path.
  exec script -q /dev/null "$@"
  ;;
Linux)
  # util-linux script takes one shell command and runs it with $SHELL -c. Bash
  # %q preserves every argument without interpreting the prompt or expanding
  # shell metacharacters again, so pin SHELL to the bash that produced it.
  printf -v command '%q ' "$@"
  SHELL=$BASH exec script -q -e -c "$command" /dev/null
  ;;
*) echo 'error: Pi terminal bridge supports only macOS and Linux' >&2; exit 1 ;;
esac
