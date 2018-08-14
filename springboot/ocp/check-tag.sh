#!/usr/bin/env bash

###################################################################
# Called from JIRA when a build is initiated
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $DIR
source ./common.sh
source ./config

USAGE="\
Error: Wrong argument(s).
Usage: `basename $0` app-name_major_minor stage ocp_token ...
Example: hello-world_1_5 sit dUmMyT0k3NV4lU3 
'_' not allowed in app name!
"

if [ ! "$1" ]; then
    echo "$USAGE"
    exit 1
fi

APP=`echo $1 | cut -d_ -f1 | tr "[A-Z]" "[a-z]"`
BUILD_PROJ=$APP-build
RELTAG=`echo $1 | cut -d_ -f2-3`
RELTAG_URL=`echo $RELTAG | tr "_" "-"`

STAGE=`echo $2 | tr "[A-Z]" "[a-z]"`
[ "$STAGE" = "sit" -o "$STAGE" = "uat" -o "$STAGE" = "stg" ] || exit 1

shift
shift

TOKEN_BUILD_CLUSTER_CICD="$1"
TOKEN_BUILD_CLUSTER_ADMIN="$2"
TOKEN_DEPLOY_CLUSTER_CICD="$3"
TOKEN_DEPLOY_CLUSTER_ADMIN="$4"

set -e
OC_CLI=$(oc_login $CLUSTER_BUILD check-tag $TOKEN_BUILD_CLUSTER_CICD)
set +e

set +x; echo -e "\n### Checking $APP:${RELTAG} exists ##########\n"; set -x

$OC_CLI get istag $APP:${RELTAG} -n $BUILD_PROJ >/dev/null
RET=$?

set +x; echo DONE $0

if [ $RET -eq 0 ]; then
	echo found
else
	echo not found
fi

exit $RET

