#!/usr/bin/env bash

###################################################################
# Called from JIRA when a production promotion is initiated
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
[ "$STAGE" == "prd" -o "$STAGE" == "dr" -o "$STAGE" == "uat" -o "$STAGE" == "sit" ] || exit 1

shift
shift

TOKEN_BUILD_CLUSTER_CICD="$1"
TOKEN_BUILD_CLUSTER_ADMIN="$2"
TOKEN_DEPLOY_CLUSTER_CICD="$3"
TOKEN_DEPLOY_CLUSTER_ADMIN="$4"

[ "$STAGE" == "prd" ] && PROJ=${APP} && CLUSTER_TARGET=$CLUSTER_PRODUCTION
[ "$STAGE" == "dr" ] && PROJ=${APP} && CLUSTER_TARGET=$CLUSTER_DR
[ "$STAGE" == "uat" -o "$STAGE" == "sit" ] && PROJ=${APP}-${STAGE} && CLUSTER_TARGET=$CLUSTER_DEPLOY

set +x
echo "######################################################"
echo HOME=$HOME
echo APP=$APP
echo STAGE=$STAGE
echo PROJ=$PROJ
echo RELTAG=$RELTAG
echo RELTAG_URL=$RELTAG_URL   # URL compatible release tag 
echo "######################################################"
echo Create project $PROJ 
echo Promote image from/to:
echo $BUILD_PROJ/$APP:$RELTAG to $BUILD_PROJ/$APP:${RELTAG}_${STAGE}
echo Image to deploy is $BUILD_PROJ/$APP:${RELTAG}_${STAGE}
echo "######################################################"
set -x 

set -e
OC_BUILD_CLI=$(oc_login $CLUSTER_BUILD build $TOKEN_BUILD_CLUSTER_CICD)
OC_DEPLOY_CLI=$(oc_login $CLUSTER_TARGET deploy $TOKEN_DEPLOY_CLUSTER_CICD)
OC_DEPLOY_ADMIN_CLI=$(oc_login $CLUSTER_TARGET admin $TOKEN_DEPLOY_CLUSTER_ADMIN)
set +e

# Note the service account (cicd) must be given the system:registry role on the on-prem (build) cluster
# to be able to pull images from aws 
#$OC_BUILD_CLUSTER_ADMIN adm policy add-role-to-user system:registry -z cicd -n default

set +x; echo -e "\n### Tagging the new image with ${RELTAG}_${STAGE} ##########\n"; set -x

# Tag/promote the image on build cluster
$OC_BUILD_CLI tag ${APP}:${RELTAG} ${APP}:${RELTAG}_${STAGE} -n $BUILD_PROJ 

set +x; echo -e "\n### Creating project $PROJ ##########\n"; set -x
if ! $OC_DEPLOY_CLI project $PROJ >/dev/null 2>&1; then
	NEW_PROJECT=$PROJ
	$OC_DEPLOY_CLI new-project $PROJ >/dev/null || exit 1
	$OC_DEPLOY_CLI project $PROJ 2>/dev/null >&2
fi


echo -e "\n### Enable external OCP to access and import images from build cluster ##########\n"

# Fetch the service account's access token. Needed to authorize pulling from the on-prem (c1) reg.
USER_TOKEN=$TOKEN_BUILD_CLUSTER_CICD

# Create or overwrite the auth secret to access the ext regisrty 
$OC_DEPLOY_CLI delete secrets/external-registry -n $PROJ 2>/dev/null

# Create the secret containing the token 
$OC_DEPLOY_CLI secrets new-dockercfg external-registry \
	--docker-username=cicd \
	--docker-password="$USER_TOKEN" \
	--docker-email=any@any.com \
	--docker-server=$EXT_REG \
	-n $PROJ 

$OC_DEPLOY_CLI secrets add sa/default secret/external-registry --for=pull -n $PROJ

# Import the remote image and create the local image stream if this is a new project
if [[ $PROJ == $NEW_PROJECT ]]; then
	MYWAIT=1
	while true
	do
		$OC_DEPLOY_CLI import-image $APP -n $PROJ \
			--insecure-skip-tls-verify \
			--from=$EXT_REG/$BUILD_PROJ/$APP:${RELTAG}_${STAGE} \
			--confirm --reference-policy=local

		$OC_DEPLOY_CLI describe is/$APP -n $PROJ | grep -qi "Import failed" || break  # IS created, sucecss!

		sleep $MYWAIT
		let MYWAIT=$MYWAIT+2
		[ $MYWAIT -gt 20 ] && echo "Giving up image import" && exit 1
	done
else
	# just retag latest
        $OC_DEPLOY_CLI tag --reference-policy=local $EXT_REG/$BUILD_PROJ/$APP:${RELTAG}_${STAGE} $APP:latest
fi

$OC_DEPLOY_CLI tag $APP:latest $APP:${RELTAG}_${STAGE} -n $PROJ 
$OC_DEPLOY_CLI tag $APP:${RELTAG}_${STAGE} $APP:deployed -n $PROJ

#set +x; echo -e "\n### Set up user permisions for $PROJ project ##########\n"; set -x
#$OC_DEPLOY_CLI policy add-role-to-user edit $ENV_USER -n $PROJ

set +x; echo -e "\n### Creating EAP's Service Account and permissions  ##########\n"; set -x
# Some apps need to allow the default SA to access the Kube API
$OC_DEPLOY_CLI policy add-role-to-user view system:serviceaccount:$PROJ:default
$OC_DEPLOY_CLI policy add-role-to-user view system:serviceaccount:$PROJ:cicd

if [[ $PROJ == $NEW_PROJECT ]]; then
	## Create admin objects if admin.yaml is present
	if [ -f $TEMPLATES_DIR/admin.yaml ]; then
		set +x; echo -e "\n### Creating admin objects for $PROJ ##########\n"; set -x

		$OC_DEPLOY_ADMIN_CLI process -f $TEMPLATES_DIR/admin.yaml -o yaml -p \
		    APP=$APP \
        	RELTAG=$RELTAG_URL \
			STAGE=$STAGE \
        	-n $PROJ | \
            	tee $LOG_DIR/${APP}-${STAGE}-${RELTAG_URL}-admin.yaml | \
            		$OC_DEPLOY_ADMIN_CLI create -f - -n $PROJ

		check_error "create admin objects from ${TEMPLATES_DIR}/admin.yaml" $?
	fi

	## Create PVs if present
	if [ -d ${PV_DIR}/${STAGE} ]; then
        for pv in $(ls ${PV_DIR}/${STAGE}/*.yaml ${PV_DIR}/${STAGE}/*.yml ); do
           	set +x; echo -e "\n### Creating pv $pv for $PROJ ##########\n"; set -x

           	$OC_DEPLOY_ADMIN_CLI process -f ${pv} -o yaml -p \
               	APP=$APP \
               	RELTAG=$RELTAG_URL \
               	STAGE=$STAGE \
               	-n $PROJ | \
                   	tee $LOG_DIR/${APP}-${STAGE}-${RELTAG_URL}-${pv} | \
                    	$OC_DEPLOY_ADMIN_CLI create -f - -n $PROJ
        done
	fi

	## Create ConfigMaps if present
	if [ -d ${CONFIG_MAP_DIR}/${STAGE} ]; then
		set +x; echo -e "\n### Creating configmaps for $PROJ ##########\n"; set -x

		$OC_DEPLOY_CLI create configmap ${APP}-config --from-file=${CONFIG_MAP_DIR}/${STAGE}/ -n $PROJ
		check_error "create configmap from ${CONFIGMAP_DIR}/${STAGE}" $?
	fi

	## Create secrets if present
	if [ -d ${SECRETS_DIR}/${STAGE} ]; then
        	set +x; echo -e "\n### Creating secrets for $PROJ ##########\n"; set -x
        	$OC_DEPLOY_CLI create secret generic ${APP}-secret --from-file=${SECRETS_DIR}/${STAGE}/ -n $PROJ
       		check_error "create secrets from ${SECRETS_DIR}/${STAGE}" $?
	fi

	## Instantiate the template 
	set +x; echo -e "\n### Creating App Environment ##########\n"; set -x
	$OC_DEPLOY_CLI process -f $TEMPLATES_DIR/deploy.yaml -o yaml -p \
		SRC_PROJ=$BUILD_PROJ \
		PROJ=$PROJ \
		APP=$APP \
		RELTAG=$RELTAG \
		STAGE=$STAGE \
		-n $PROJ | \
			tee $LOG_DIR/${APP}-${STAGE}-${RELTAG_URL}-deploy.yaml | \
				$OC_DEPLOY_CLI create -f - -n $PROJ
else
	set +x; echo "\n### Bypass app env creation for existing project ###"; set -x
fi

set +x; echo DONE $0

