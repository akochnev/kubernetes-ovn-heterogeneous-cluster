#!/bin/bash

config=./sig-win.conf

if [[ ! -f  ${config} ]]; then 
	echo "Required config file '${config}' is not present'"
	exit 1
fi

set -a 
source ${config}
set +a 

MASTER_IP=$1; export MASTER_IP
LOCAL_IP=$2; export LOCAL_IP
nodeType=$3

TOKEN="\$TOKEN"; export TOKEN

HOSTNAME=`hostname`; export HOSTNAME

pathToTemplate=

if [[ ${nodeType} == "master" ]]; then
	    pathToTemplate=${ROOT_CHECKOUT_DIR}/master
elif [[ ${nodeType} == "worker/linux" ]]; then
        pathToTemplate=${ROOT_CHECKOUT_DIR}/worker/linux
elif [[ ${nodeType} == "gateway" ]]; then
        pathToTemplate=${ROOT_CHECKOUT_DIR}/gateway
else 
	echo "Invalid node type '${nodeType}', expecting 'master', 'worker/linux', or 'gateway'"
	return 1
fi

envsubst < ${pathToTemplate}/configure.sh-template > ${pathToTemplate}/configure.sh

chmod +x ${pathToTemplate}/configure.sh

${pathToTemplate}/configure.sh