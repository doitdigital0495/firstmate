#!/usr/bin/env bash
# Run one Firstmate command against the disposable lab home, with every
# inherited fleet-path override removed. Usage: lab-run.sh <lab> <command...>
set -eu
LAB=$1
shift
exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" LAVISH_AXI_NO_OPEN=1 "$@"
