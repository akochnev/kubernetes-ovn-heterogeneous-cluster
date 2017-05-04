#!/bin/bash

function usage() {
    echo "Usage: provision -p prefix -u user -z zone"
    echo
    echo "Options:"
    echo "-p | --prefix : A prefix to be prepended to GCE instance names"
    echo "-u | --user : User to create ssh keys for"
    echo "-z | --zone : GCE zone to provision instances in"
    echo "    --help             display help"
    exit 1
}


prefix=
user=sig-win
zone=

while true; do
  case "$1" in
    -p | --prefix ) prefix="$2"; shift ;;
    -u | --user   ) user="$2"; shift ;;
    -z | --zone   ) zone="$2"; shift ;;
    --help ) usage;;
    -- ) shift; break ;;
        -*) echo "ERROR: unrecognized option $1"; exit 1;;
    * ) break ;;
  esac
  shift
done

if [ -z "${prefix}" ]; then 
	echo "prefix is required parameter"
	usage
fi

#if [ -z "${user}" ]; then
#	echo "user is a required parameter"
#	usage
#fi

if [ -z "${zone}" ]; then 
	echo "zone is a required parameter"
	usage
fi


function generateSSHKey() {	

	local hostname=$1
	local user=$2

	echo "Generating SSH Key for user ${user} on instance ${hostname}"

	local connected="false"

	while [ "${connected}" == "false" ]; do
		if gcloud compute ssh ${hostname} --command="sudo mkdir -p /home/${user}/.ssh && sudo ssh-keygen -t rsa -f /home/${user}/.ssh/gce_rsa -C ${user} -q -N ''"; then
			connected="true"
		else 
			echo "Could not connect to ${hostname}...this may be expected if it was just provisioned."
			echo "Sleeping 5s..."
			sleep 5
		fi
	done

}


function getPublicKey() {

	local hostname=$1
	local user=$2
	
	echo "Pulling the public key from ${hostname}"

	gcloud compute copy-files ${hostname}:/home/${user}/.ssh/gce_rsa.pub ${hostname}.pub
}


function provision_linux() {
	
	local instance=$1
	local zone=$2
	local startupScript=$3

	echo "Provisioning instance ${instance} in zone ${zone} with startup script ${startupScript}"

	gcloud compute instances create "${instance}" \
	    --zone "${zone}" \
	    --machine-type "custom-2-2048" \
	    --can-ip-forward \
	    --tags "https-server" \
	    --image-family "ubuntu-1604-lts" \
	    --image-project "ubuntu-os-cloud" \
	    --boot-disk-size "50" \
	    --boot-disk-type "pd-ssd" \
	    --metadata-from-file startup-script="${startupScript}"


    echo "Waiting for instance start-provisioning script to complete."
#    echo "Connection errors during this step while the node reboots is normal"
    local isReady="false"

    while [ "${isReady}" == "false" ]; do
        if gcloud compute ssh -q --zone ${zone} ${instance} --command "stat /ready > /dev/null 2>&1" > /dev/null 2>&1 ; then
            	isReady="true"
        else
#        	echo "Could not connect to ${instance}...this may be expected if it was just provisioned."
#		echo "Sleeping 5s..."
        printf "."
		sleep 5
        fi
    done
    printf "done\n"
}


function modifyPublicKey() {

	local hostname=$1
	local user=$2
	local combinedPKFile=$3

	echo "Fixing format of the ${hostname} public key to match GCE expectations, and adding to ${combinedPKFile}"

	sed -i -e "s/^/${user}:/" ./${hostname}.pub
	cat ./${hostname}.pub >> ${combinedPKFile}
}


function copyConfigFile() {
	local instance=$1
	local configFile=$2

	echo "Copying config file '${configFile}' to instance ${instance}"

	gcloud compute copy-files ${configFile} ${instance}:/tmp
	gcloud compute ssh ${instance} --command "sudo mv /tmp/${configFile} /root/kubernetes-ovn-heterogeneous-cluster/${configFile}"
}

function configureNode() {
	local instance=$1
	local masterIp=$2
	local localIp=$3
	local nodeType=$4

    echo "Configuring node ${instance} as ${nodeType} node"

	gcloud compute ssh ${instance} --command "sudo chown -R ${user}:${user} /home/${user}/.ssh/"
	gcloud compute ssh ${instance} --command "sudo /root/kubernetes-ovn-heterogeneous-cluster/configure-node.sh ${masterIp} ${localIp} ${nodeType}"
}

function setupNode() {

	local instance=$1
	local user=$2
	local zone=$3
	local combinedPkFile=$4
	local configFile=$5

	echo "**Starting initial setup for ${instance}..."

	provision_linux "${instance}" "${zone}" "./provision-start-script.sh"
	sleep 10
	generateSSHKey "${instance}" "${user}"
	getPublicKey "${instance}" "${user}"
	modifyPublicKey "${instance}" "${user}" "${combinedPKFile}"
	copyConfigFile $instance $configFile
	echo "*** Completed initial setup for ${instance}."
}

cwd=$(pwd)
combinedPKFile="${cwd}/combined.pub"
configFile="sig-win.conf"

if [[ -f ${combinedPKFile} ]]; then 
	rm ${combinedPKFile}
fi

for i in "sig-windows-master" "sig-windows-worker-linux-1" "sig-windows-gw"; do
	instance="${prefix}-${i}"
	setupNode ${instance} ${user} ${zone} ${combinedPKFile} ${configFile}
done

#Configure the master node
instance="${prefix}-sig-windows-master"
masterExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)

echo "Adding public keys to authorized host of ${instance}"
#Set the metadata element from combined file
gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub

rm ${instance}.pub

configureNode ${instance} ${masterExternalIp} ${masterExternalIp} "master"

#Configure the linux worker node
instance="${prefix}-sig-windows-worker-linux-1"
workerExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)

echo "Adding public keys to authorized host of ${instance}"
#Set the metadata element from combined file
gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub

rm ${instance}.pub

configureNode ${instance} ${masterExternalIp} ${workerExternalIp} "worker/linux"

#Configure the gateway node
instance="${prefix}-sig-windows-gw"
gatewayExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)

echo "Adding public keys to authorized host of ${instance}"
#Set the metadata element from combined file
gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub

rm ${instance}.pub
configureNode ${instance} ${masterExternalIp} ${gatewayExternalIp} "gateway"

rm combined.pub
###########

#for i in "-sig-windows-master" "sig-windows-worker-linux-1" "sig-windows-gw"; do
#
#done
#
#
#instance="${prefix}-sig-windows-worker-linux-1"
#
#
#echo "**Starting work for ${instance}"
#provision_linux "${instance}" "${zone}" "./setup.sh"
#sleep 10
#generateSSHKey "${instance}" "${user}"
#getPublicKey "${instance}" "${user}"
#modifyPublicKey "${instance}" "${user}" "${combinedPKFile}"
#masterExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)
#copyConfigFile $instance $configFile
#configureNode ${instance} ${masterExternalIp} ${masterExternalIp} "master"
#echo "**Completed work for ${instance}"
#
#instance="${prefix}-sig-windows-worker-linux-1"
#
#echo "**Starting work for ${instance}"
#provision_linux "${instance}" "${zone}" "./setup.sh"
#sleep 10
#generateSSHKey "${instance}" "${user}"
#getPublicKey "${instance}" "${user}"
#modifyPublicKey "${instance}" "${user}" "${combinedPKFile}"
#workerExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)
#copyConfigFile $instance $configFile
#configureNode ${instance} ${masterExternalIp} ${workerExternalIp} "worker/linux"
#
#echo "**Completed work for ${instance}"
#
#instance="${prefix}-sig-windows-gw"
#
#echo "**Starting work for ${instance}"
#provision_linux "${instance}" "${zone}" "./setup.sh"
#sleep 10
#generateSSHKey "${instance}" "${user}"
#getPublicKey "${instance}" "${user}"
#modifyPublicKey "${instance}" "${user}" "${combinedPKFile}"
#gatewayExternalIp=$(gcloud compute instances describe ${instance} | grep networkIP)
#copyConfigFile $instance $configFile
#configureNode ${instance} ${masterExternalIp} ${gatewayExternalIp} "gateway"
#
#echo "**Completed work for ${instance}"
#
#
#instance="${prefix}-sig-windows-master"
#echo "Adding public keys to authorized host of ${instance}"
##Set the metadata element from combined file
#gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub
#
#instance="${prefix}-sig-windows-worker-linux-1"
#echo "Adding public keys to authorized host of ${instance}"
##Set the metadata element from combined file
#gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub
#
#instance="${prefix}-sig-windows-gw"
#echo "Adding public keys to authorized host of ${instance}"
##Set the metadata element from combined file
#gcloud compute instances add-metadata ${instance} --metadata-from-file ssh-keys=${cwd}/combined.pub


