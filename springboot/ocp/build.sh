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
Usage: `basename $0` app-name_major_minor ocp_token
Example: hello-world_1_5 dUmMyT0k3NV4lU3 
'_' not allowed in app name!
"

if [ ! "$1" ]; then
    echo "$USAGE"
    exit 1
fi

APP=`echo $1 | cut -d_ -f1 | tr "[A-Z]" "[a-z]"`
BUILD_PROJ=$APP-build
RELTAG=`echo $1 | cut -d_ -f2-3`

shift
TOKEN_BUILD_CLUSTER_CICD="$1"

startbuild() {
	# start build ...
	c=1
	while ! $OC_CLI start-build --from-dir=.. ${APP} -n $BUILD_PROJ -w 
	do
		let c=$c+1
		[ $c -gt 1 ] && echo Giving up on build ... && exit 1
	done
}

###################################################################
# main
#
role=build

set -e
OC_CLI=$(oc_login $CLUSTER_BUILD $role $TOKEN_BUILD_CLUSTER_CICD)

set +e
echo -e "\n### Change to or create project $BUILD_PROJ ##########\n"

if ! $OC_CLI project ${BUILD_PROJ} 2>/dev/null ; then
    $OC_CLI new-project $BUILD_PROJ >/dev/null
fi

set +x; echo -e "\n### Set up user permisions for $BUILD_PROJ project ##########\n"; set -x
$OC_CLI policy add-role-to-user view $ENV_USER -n $BUILD_PROJ


echo -e "\n### Create build config ##########\n"

[ -d scripts ] && rm -rf ../ocp-scripts && cp -rp scripts ../ocp-scripts
[ -d configuration ] && rm -rf ../configuration && cp -rp configuration ..
[ -d s2i ] && rm -rf ../.s2i && cp -rp s2i ../.s2i
[ -d data/repository ] && rm -rf ../.m2 && cp -rp data ../.m2

# setup .s2iignore
cat > ../.s2iignore << EOF
.svn/*
.git/*
ocp/*
target/*
EOF

# Remove old builds
$OC_CLI delete build --all -n $BUILD_PROJ 2>/dev/null

# Remove old build config
$OC_CLI delete bc --all -n $BUILD_PROJ 

# Create build config
if [ -f $TEMPLATES_DIR/build.yaml ]; then
	$OC_CLI process -f $TEMPLATES_DIR/build.yaml -o yaml -p \
		RELTAG=${RELTAG} \
		APP=${APP} \
		PROJ=${BUILD_PROJ} \
		-n $BUILD_PROJ | tee $LOG_DIR/${APP}-${RELTAG}-build.yaml | $OC_CLI create -f - -n $BUILD_PROJ
else
	echo "No build.yaml template, do nothing"
fi

set +x
if [ "$USER" = "jira" ]; then
    echo -e "\n### Starting build in the background ##########\n"
    set -x
    ( startbuild & ) &
else
    echo -e "\n### Starting build ##########\n"
    set -x
    startbuild
fi

set +x; echo DONE $0

