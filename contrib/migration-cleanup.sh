#!/bin/bash

clusterID=$(oc get infrastructure.config.openshift.io cluster -o=jsonpath='{.status.infrastructureName}')
clusterTag="openshiftClusterID=${clusterID}"

removeNamespacedFinalizers () {
    local resource=$1
    local finalizer=$2

    for res in $(oc get $resource -A --template='{{range $i,$p := .items}}{{ $p.metadata.name }}|{{ $p.metadata.namespace }}{{"\n"}}{{end}}'); do
        name=${res%%|*}
        ns=${res##*|}
        oc get -n $ns $resource $name -o json | \
            jq -Mcr "if .metadata.finalizers != null then del(.metadata.finalizers[] | select(. == \"${finalizer}\")) else . end" | \
            oc replace -n $ns $resource $name -f -
    done
}

echo "Removing Kuryr finalizers from all Services"
removeNamespacedFinalizers services kuryr.openstack.org/service-finalizer

echo "Removing all tagged loadbalancers from Octavia"
for lb in `openstack loadbalancer list --tags $clusterTag -f value -c id`; do
    openstack loadbalancer delete --cascade $lb
done

echo "Removing Kuryr finalizers from all KuryrLoadBalancer CRs. This will trigger their deletion"
removeNamespacedFinalizers kuryrloadbalancers.openstack.org kuryr.openstack.org/kuryrloadbalancer-finalizers

echo "Removing Kuryr service network"
openstack network delete kuryr-service-network-${clusterID}

echo "Removing Kuryr finalizers from all pods"
removeNamespacedFinalizers pods kuryr.openstack.org/pod-finalizer

echo "Removing Kuryr finalizers from all KuryrPort CRs. This will trigger their deletion"
removeNamespacedFinalizers kuryrports.openstack.org kuryr.openstack.org/kuryrport-finalizer

echo "Removing Kuryr finalizers from all Network Policies"
removeNamespacedFinalizers networkpolicy kuryr.openstack.org/networkpolicy-finalizer

echo "Removing Kuryr network policies"
for sgid in $(openstack security group list -f value -c ID -c Description | grep 'Kuryr-Kubernetes Network Policy' | cut -f 1 -d ' '); do
    openstack security group rule delete $(openstack security group rule list $sgid -f value -c ID | xargs)
    openstack security group delete $sgid
done
removeNamespacedFinalizers kuryrnetworkpolicies.openstack.org kuryr.openstack.org/networkpolicy-finalizer

echo "Remove subports created by Kuryr from trunks"
# TODO(dulek): Filtering trunks by tags - not supported by openstackclient, got to do it manually
trunks=`openstack network trunk list -f value -c ID`
i=0
len=`wc -l <<< $trunks`
for trunk in $trunks; do
    i=$((i+1))
    echo "    Processing trunk $trunk, ${i}/${len}"
    subports=()
    for subport in `openstack network subport list --trunk $trunk -f value -c Port`; do
        subports+=($subport)
    done
    # TODO(dulek): Check subports tags somehow, we don't want to remove user's subports.
    if [ ${#subports[@]} -gt 0 ]; then
        # FIXME(dulek): Something's wrong here, it expands into a single argument?
        echo openstack network trunk unset ${subports[@]/#/--subport } $trunk
    fi
done

echo "Get all networks and subnets from KuryrNetwork CRs and remove ports, router interfaces and network itself"
kuryrnetworks=`oc get kuryrnetwork -A --no-headers -o custom-columns=":status.netId,:status.subnetId,:status.routerId"`
i=0
len=`wc -l <<< $kuryrnetworks`
IFS=$'\n'
for kn in $kuryrnetworks; do
    echo "    Processing network $kn, ${i}/${len}"
    netID=`echo $kn | awk '{print $1}'`
    subnetID=`echo $kn | awk '{print $2}'`
    routerID=`echo $kn | awk '{print $3}'`

    # Remove all ports from the network.
    for port in `openstack port list --network $netID -f value -c ID`; do
        ( openstack port delete $port ) &

        # Only allow 20 jobs in parallel.
        if [[ $(jobs -r -p | wc -l) -ge 20 ]]; then
            wait -n
        fi
    done
    wait

    # Remove the subnet from the router.
    openstack router remove subnet $routerID $subnetID

    # Remove the network.
    openstack network delete $netID
done
unset IFS

# All ports are gone, we can remove the security group.
openstack security group delete kuryr-pods-security-group-${clusterID}

# Get subnetpool by tag and remove it
for subnetpool in `openstack subnet pool list --tags $clusterTag -f value -c ID`; do
    openstack subnet pool delete $subnetpool
done

# Double check that we removed all the networks based on KuryrNetwork CRs.
networks=`oc get kuryrnetwork -A --no-headers -o custom-columns=":status.netId"`
for existingNet in `openstack network list --tags $clusterTag -f value -c ID`; do
    if [[ $networks =~ $existingNet ]]; then
        echo "Network $existingNet still exists, cannot continue to remove KuryrNetwork CRs"
        exit 1
    fi
done

# Remove finalizers from KuryrNetwork CRs.
removeNamespacedFinalizers kuryrnetworks.openstack.org

# FIXME(dulek): This has to be documented and decision to delete it has to be made by user. We have no way
#               to figure out if it CNO who created it.
# openstack delete router $routerID
