#!/usr/bin/env bash

# this script is meant to be sourced from main scripts


# ----------------------------------------------------
# Helper functions

function check_error() {
    local label="$1"
    local error="$2"
    if [ ${error} -ne 0 ]; then
        echo "Aborting due to error code $error for $label"
        exit ${error}
    fi
}

function cleanup() {
    set +x +e
    oc_logout
}

function oc_login() {
    local url="$1"
    local role="$2"
    local token="$3"

    oc login --insecure-skip-tls-verify --config=${TMP_DIR}/${role}.config --token=${token} ${url} &> /dev/null
    check_error "login to ${url}" $?
    echo "oc --config=${TMP_DIR}/${role}.config $OPENSHIFT_CLI_OPTIONS"
}

function oc_logout() {
	echo -e "\n### Logging out #############\n";
	for f in $TMP_DIR/*.config; do
		oc logout --config=$f && rm -f $f
	done
}


# ----------------------------------------------------
# Main

# setup tmp and logs directories
TMP_DIR=tmp
LOG_DIR=logs
mkdir -p $TMP_DIR $LOG_DIR

# other directories
TEMPLATES_DIR=templates 
PV_DIR=${TEMPLATES_DIR}/pv 
CONFIG_MAP_DIR=${TEMPLATES_DIR}/configmap 
SECRETS_DIR=${TEMPLATES_DIR}/secret

BASENAME=${0##*/}

set -x -e
if [[ "$BASENAME" == "build.sh" ]]; then
	logfile=$LOG_DIR/$BASENAME-$1.log
else
	logfile=$LOG_DIR/$BASENAME-$1-$2.log
fi

exec > >(tee -i $logfile)
exec 2>&1

trap cleanup EXIT 

