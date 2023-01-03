#!/bin/bash -x

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
for lb in $(openstack loadbalancer list --tags $clusterTag -f value -c id); do
    openstack loadbalancer delete --cascade $lb
done

echo "Removing Kuryr finalizers from all KuryrLoadBalancer CRs. This will trigger their deletion"
removeNamespacedFinalizers kuryrloadbalancers.openstack.org kuryr.openstack.org/kuryrloadbalancer-finalizers

echo "Removing Kuryr finalizers from all pods"
removeNamespacedFinalizers pods kuryr.openstack.org/pod-finalizer

echo "Removing Kuryr finalizers from all KuryrPort CRs. This will trigger their deletion"
removeNamespacedFinalizers kuryrports.openstack.org kuryr.openstack.org/kuryrport-finalizer

echo "Remove subports created by Kuryr from trunks"
trunks=$(python -c "import openstack; n = openstack.connect().network; print(\" \".join([x.id for x in n.trunks(any_tags=\"$clusterTag\")]))")
i=0
len=`wc -l <<< $trunks`
for trunk in $trunks; do
    i=$((i+1))
    echo "    Processing trunk $trunk, ${i}/${len}, it may take a time due to every port examinig for '$clusterTag' containing."
    subports=()
    for subport in $(python -c "import openstack; n = openstack.connect().network; print(\" \".join([x['port_id'] for x in n.get_trunk(\"$trunk\").sub_ports if \"$clusterTag\" in n.get_port(x['port_id']).tags]))"); do
        subports+=($subport)
    done

    args=()
    for sub in "${subports[@]}" ; do
        args+=("--subport $sub")
    done

    if [ ${#args[@]} -gt 0 ]; then
        openstack network trunk unset ${args[*]} $trunk
    fi
done

echo "Get all networks and subnets from KuryrNetwork CRs and remove ports, router interfaces and network itself"
mapfile -t kuryrnetworks < <(oc get kuryrnetwork -A --template='{{range $i,$p := .items}}{{ $p.status.netId }}|{{ $p.status.subnetId }}|{{ $p.status.routerId}}{{"\n"}}{{end}}')
i=0
len=${#kuryrnetworks[@]}
for kn in "${kuryrnetworks[@]}"; do
    i=$((i+1))
    IFS="|" read -a _a <<< $kn
    netID=${_a[0]}
    subnetID=${_a[1]}
    routerID=${_a[2]}
    echo "    Processing network $netID, ${i}/${len}"

    # Remove all ports from the network.
    for port in $(openstack port list --network $netID -f value -c ID); do
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

echo "Removing Kuryr service network"
openstack router remove subnet $routerID ${clusterID}-kuryr-service-network
openstack network delete ${clusterID}-kuryr-service-network

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

echo "Removing Kuryr finalizers from all Network Policies"
removeNamespacedFinalizers networkpolicy kuryr.openstack.org/networkpolicy-finalizer

echo "Removing Kuryr network policies"
#for sgid in $(openstack security group list -f value -c ID -c Description | grep 'Kuryr-Kubernetes Network Policy' | cut -f 1 -d ' '); do
#    openstack security group rule delete $(openstack security group rule list $sgid -f value -c ID | xargs)
#    openstack security group delete $sgid
#done
removeNamespacedFinalizers kuryrnetworkpolicies.openstack.org kuryr.openstack.org/networkpolicy-finalizer

# Remove finalizers from KuryrNetwork CRs.
removeNamespacedFinalizers kuryrnetworks.openstack.org kuryrnetwork.finalizers.kuryr.openstack.org

# FIXME(dulek): This has to be documented and decision to delete it has to be made by user. We have no way
#               to figure out if it CNO who created it.
# openstack delete router $routerID
