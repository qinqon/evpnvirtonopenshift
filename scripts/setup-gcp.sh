#!/bin/bash -xe

WORKER_SUBNET_CIDR=192.168.11.0/24

# GCP Cloud VPN Configuration variables
SHARED_SECRET="${SHARED_SECRET:-}"
ONPREM_PUBLIC_IP="${ONPREM_PUBLIC_IP:-$(curl -4 ifconfig.me)}"

# Cleanup function
cleanup_gcp_resources() {
    echo "============================================"
    echo "Cleaning up GCP VPN and Network Resources"
    echo "============================================"
    echo ""

    # Get basic configuration
    WORKER_SUBNET=$(gcloud compute instances list \
      --filter="name~worker" \
      --format="value(networkInterfaces[0].subnetwork.basename())" \
      --limit=1 2>/dev/null || true)

    if [[ -z "$WORKER_SUBNET" ]]; then
        echo "Warning: No worker subnet found, using generic cleanup..."
        echo "You may need to manually specify network resources to clean up."
        return 1
    fi

    REGION=$(gcloud compute networks subnets list \
      --filter="name=$WORKER_SUBNET" \
      --format="value(region.basename())" \
      --limit=1 2>/dev/null || true)

    NETWORK=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
      --region="$REGION" \
      --format="value(network.basename())" 2>/dev/null || true)

    if [[ -z "$NETWORK" ]]; then
        echo "Error: Could not determine network name"
        return 1
    fi

    echo "Network: $NETWORK"
    echo "Region: $REGION"
    echo ""

    VPN_GATEWAY_NAME="${NETWORK}-vpn-gateway"
    VPN_TUNNEL_NAME="${NETWORK}-tunnel-onprem"
    ROUTE_NAME="${NETWORK}-route-to-onprem-underlay"
    VTEP_ROUTE_NAME="${NETWORK}-route-to-onprem-vtep"
    L3VNI_ROUTE_NAME="${NETWORK}-route-to-onprem-l3vni"
    KIND_ROUTE_NAME="${NETWORK}-route-to-onprem-kind"

    # Step 1: Delete VPN tunnel
    echo "[1/7] Deleting VPN tunnel..."
    if gcloud compute vpn-tunnels describe $VPN_TUNNEL_NAME --region=$REGION &>/dev/null; then
        gcloud compute vpn-tunnels delete $VPN_TUNNEL_NAME --region=$REGION --quiet
        echo "  ✓ VPN tunnel deleted: $VPN_TUNNEL_NAME"
    else
        echo "  ✓ VPN tunnel not found (already deleted)"
    fi

    # Step 2: Delete routes
    echo ""
    echo "[2/7] Deleting routes..."
    if gcloud compute routes describe $ROUTE_NAME &>/dev/null; then
        gcloud compute routes delete $ROUTE_NAME --quiet
        echo "  ✓ Route deleted: $ROUTE_NAME"
    else
        echo "  ✓ Route not found (already deleted)"
    fi

    if gcloud compute routes describe $VTEP_ROUTE_NAME &>/dev/null; then
        gcloud compute routes delete $VTEP_ROUTE_NAME --quiet
        echo "  ✓ Route deleted: $VTEP_ROUTE_NAME"
    else
        echo "  ✓ VTEP route not found (already deleted)"
    fi

    if gcloud compute routes describe $L3VNI_ROUTE_NAME &>/dev/null; then
        gcloud compute routes delete $L3VNI_ROUTE_NAME --quiet
        echo "  ✓ Route deleted: $L3VNI_ROUTE_NAME"
    else
        echo "  ✓ L3VNI route not found (already deleted)"
    fi

    if gcloud compute routes describe $KIND_ROUTE_NAME &>/dev/null; then
        gcloud compute routes delete $KIND_ROUTE_NAME --quiet
        echo "  ✓ Route deleted: $KIND_ROUTE_NAME"
    else
        echo "  ✓ Kind route not found (already deleted)"
    fi

    # Step 3: Delete firewall rules
    echo ""
    echo "[3/7] Deleting firewall rules..."
    for rule in ${NETWORK}-allow-bgp-from-onprem ${NETWORK}-allow-vxlan-from-onprem ${NETWORK}-allow-icmp-from-onprem; do
        if gcloud compute firewall-rules describe $rule &>/dev/null; then
            gcloud compute firewall-rules delete $rule --quiet
            echo "  ✓ Deleted: $rule"
        else
            echo "  ✓ Not found: $rule"
        fi
    done

    # Step 4: Delete forwarding rules
    echo ""
    echo "[4/7] Deleting forwarding rules..."
    for fwd_rule in ${VPN_GATEWAY_NAME}-esp ${VPN_GATEWAY_NAME}-udp500 ${VPN_GATEWAY_NAME}-udp4500; do
        if gcloud compute forwarding-rules describe $fwd_rule --region=$REGION &>/dev/null; then
            gcloud compute forwarding-rules delete $fwd_rule --region=$REGION --quiet
            echo "  ✓ Deleted: $fwd_rule"
        else
            echo "  ✓ Not found: $fwd_rule"
        fi
    done

    # Step 5: Delete VPN gateway
    echo ""
    echo "[5/7] Deleting VPN gateway..."
    if gcloud compute target-vpn-gateways describe $VPN_GATEWAY_NAME --region=$REGION &>/dev/null; then
        gcloud compute target-vpn-gateways delete $VPN_GATEWAY_NAME --region=$REGION --quiet
        echo "  ✓ VPN gateway deleted: $VPN_GATEWAY_NAME"
    else
        echo "  ✓ VPN gateway not found (already deleted)"
    fi

    # Step 6: Delete static IP
    echo ""
    echo "[6/7] Deleting static IP..."
    IP_NAME="${VPN_GATEWAY_NAME}-ip"
    if gcloud compute addresses describe $IP_NAME --region=$REGION &>/dev/null; then
        gcloud compute addresses delete $IP_NAME --region=$REGION --quiet
        echo "  ✓ Static IP deleted: $IP_NAME"
    else
        echo "  ✓ Static IP not found (already deleted)"
    fi

    # Step 7: Remove alias IPs from worker nodes
    echo ""
    echo "[7/7] Removing alias IPs from worker nodes..."
    WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    if [[ -n "$WORKER_NODES" ]]; then
        for NODE in $WORKER_NODES; do
            INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)
            ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)

            if [[ -n "$ZONE" ]]; then
                echo "  Removing alias IP from: $INSTANCE_NAME (zone: $ZONE)"

                # Get current alias IPs
                CURRENT_ALIASES=$(gcloud compute instances describe $INSTANCE_NAME \
                    --zone=$ZONE \
                    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)' 2>/dev/null || true)

                if [[ -n "$CURRENT_ALIASES" ]]; then
                    # Filter out the openperouter alias IP (192.168.11.x)
                    KEEP_ALIASES=$(echo "$CURRENT_ALIASES" | grep -v "^192\.168\.11\." | tr '\n' ',' | sed 's/,$//' || true)

                    if [[ -n "$KEEP_ALIASES" ]]; then
                        # Update with remaining aliases
                        gcloud compute instances network-interfaces update $INSTANCE_NAME \
                            --zone=$ZONE \
                            --network-interface=nic0 \
                            --aliases="$KEEP_ALIASES"
                    else
                        # Remove all aliases if only openperouter alias existed
                        gcloud compute instances network-interfaces update $INSTANCE_NAME \
                            --zone=$ZONE \
                            --network-interface=nic0 \
                            --aliases=""
                    fi
                    echo "    ✓ Alias IP removed"
                else
                    echo "    ✓ No alias IPs found"
                fi
            fi
        done
    else
        echo "  Warning: No worker nodes found via kubectl"
    fi

    echo ""
    echo "============================================"
    echo "Cleanup Complete!"
    echo "============================================"
    echo ""
    echo "Note: The following were NOT removed (manual cleanup if needed):"
    echo "  - Secondary IP range 'openperouter-network' on subnet $WORKER_SUBNET"
    echo "  - Firewall rule: ${NETWORK}-openperouter-network"
    echo "  - VPN config file: /tmp/gcp-vpn-config.env"
    echo ""
}

# Usage function
show_usage() {
    echo "Usage: $0 [cleanup|--cleanup|help|--help]"
    echo ""
    echo "Options:"
    echo "  (no args)        Set up GCP VPN tunnel, routes, and firewall rules"
    echo "  cleanup          Remove all GCP resources created by this script"
    echo "  --cleanup        Same as cleanup"
    echo "  help             Show this help message"
    echo "  --help           Same as help"
    echo ""
    echo "Environment variables:"
    echo "  SHARED_SECRET    VPN shared secret (required for setup)"
    echo "  ONPREM_PUBLIC_IP On-prem public IP (default: auto-detected)"
    echo ""
    echo "Examples:"
    echo "  # Setup VPN"
    echo "  export SHARED_SECRET='your-secret'"
    echo "  ./setup-gcp.sh"
    echo ""
    echo "  # Cleanup"
    echo "  ./setup-gcp.sh cleanup"
}

# Check for help argument
if [[ "$1" == "help" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
    show_usage
    exit 0
fi

# Check for cleanup argument
if [[ "$1" == "cleanup" ]] || [[ "$1" == "--cleanup" ]]; then
    cleanup_gcp_resources
    exit $?
fi

WORKER_SUBNET=$(gcloud compute instances list \
  --filter="name~worker" \
  --format="value(networkInterfaces[0].subnetwork.basename())" \
  --limit=1)

if [[ -z "$WORKER_SUBNET" ]]; then
  echo "Error: No worker subnet found"
  exit 1
fi

echo "Worker subnet: $WORKER_SUBNET"

# Get region from the subnet
REGION=$(gcloud compute networks subnets list \
  --filter="name=$WORKER_SUBNET" \
  --format="value(region.basename())" \
  --limit=1)

echo "Region: $REGION"

# Check if secondary range already exists
EXISTING_RANGE=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="json" | jq -r '.secondaryIpRanges[] | select(.rangeName=="openperouter-network") | .ipCidrRange' 2>/dev/null || true)

if [[ -n "$EXISTING_RANGE" ]]; then
  echo "Secondary range 'openperouter-network' already exists with CIDR: $EXISTING_RANGE"
  if [[ "$EXISTING_RANGE" == "${WORKER_SUBNET_CIDR}" ]]; then
    echo "Range matches desired CIDR ${WORKER_SUBNET_CIDR} - nothing to do"
  else
    echo "Warning: Existing range $EXISTING_RANGE differs from desired ${WORKER_SUBNET_CIDR}"
    echo "Manual intervention required"
    exit 1
  fi
else
  echo "Adding secondary range openperouter-network=${WORKER_SUBNET_CIDR}..."
  gcloud compute networks subnets update "$WORKER_SUBNET" \
    --region="$REGION" \
    --add-secondary-ranges=openperouter-network="${WORKER_SUBNET_CIDR}"
  echo "Secondary range added successfully"
fi

# Verify final state
echo ""
echo "Final subnet configuration:"
gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="table(name,ipCidrRange,secondaryIpRanges)"

echo ""
echo "=== Configuring Firewall Rules for OpenPERouter Network ==="

# Get the network name from the subnet
NETWORK=$(gcloud compute networks subnets describe "$WORKER_SUBNET" \
  --region="$REGION" \
  --format="value(network.basename())")

echo "Network: $NETWORK"

# Check if firewall rule already exists
FIREWALL_RULE_NAME="${NETWORK}-openperouter-network"
EXISTING_FIREWALL=$(gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
  --format="value(name)" 2>/dev/null || true)

if [[ -n "$EXISTING_FIREWALL" ]]; then
  echo "Firewall rule '$FIREWALL_RULE_NAME' already exists"

  # Verify it has the correct configuration
  EXISTING_SOURCE_RANGES=$(gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
    --format="value(sourceRanges)")

  if [[ "$EXISTING_SOURCE_RANGES" == *"${WORKER_SUBNET_CIDR}"* ]]; then
    echo "Firewall rule already configured for ${WORKER_SUBNET_CIDR}"
  else
    echo "Warning: Firewall rule exists but may have incorrect source ranges"
    echo "Current source ranges: $EXISTING_SOURCE_RANGES"
  fi
else
  echo "Creating firewall rule '$FIREWALL_RULE_NAME'..."
  gcloud compute firewall-rules create "$FIREWALL_RULE_NAME" \
    --network="$NETWORK" \
    --action=ALLOW \
    --rules=icmp,tcp,udp:4789,esp \
    --source-ranges="${WORKER_SUBNET_CIDR}" \
    --description="Allow traffic from openperouter secondary subnet including VXLAN (UDP 4789)"

  echo "Firewall rule created successfully"
fi

echo ""
echo "Firewall rule status:"
gcloud compute firewall-rules describe "$FIREWALL_RULE_NAME" \
  --format="table(name,network.basename(),sourceRanges,allowed[].map().firewall_rule().list())"

echo ""
echo "=== Cleaning Up Existing Alias IPs from All Instances ==="

# Get all worker nodes
WORKER_NODES=$(kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

for NODE in $WORKER_NODES; do
  echo ""
  echo "Cleaning node: $NODE"

  # Extract GCE instance name (remove domain suffix)
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)

  # Get zone from node labels
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo "  Instance: $INSTANCE_NAME"
  echo "  Zone: $ZONE"

  # Get existing alias IPs on the instance
  EXISTING_ALIASES=$(gcloud compute instances describe $INSTANCE_NAME \
    --zone=$ZONE \
    --format='value(networkInterfaces[0].aliasIpRanges[].ipCidrRange)' 2>/dev/null || true)

  if [[ -n "$EXISTING_ALIASES" ]]; then
    echo "  Removing existing alias IPs: $EXISTING_ALIASES"
    gcloud compute instances network-interfaces update $INSTANCE_NAME \
      --zone=$ZONE \
      --network-interface=nic0 \
      --aliases=""
    echo "  ✓ Cleanup complete"
  else
    echo "  No existing alias IPs to clean up"
  fi
done

echo ""
echo "=== Adding Whereabouts IPs as Alias IPs to GCE Instances ==="

for NODE in $WORKER_NODES; do
  echo ""
  echo "Configuring node: $NODE"

  # Extract GCE instance name (remove domain suffix)
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)

  # Get zone from node labels
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo "  Instance: $INSTANCE_NAME"
  echo "  Zone: $ZONE"

  # Get router pods running on this node
  ROUTER_PODS=$(kubectl get pods -n openperouter-system \
    -l app=router \
    --field-selector spec.nodeName=$NODE \
    -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$ROUTER_PODS" ]]; then
    echo "  No router pods found on this node, skipping..."
    continue
  fi

  # Collect all whereabouts IPs from router pods on this node
  ALIAS_IPS=()
  for POD in $ROUTER_PODS; do
    echo "  Checking pod: $POD"

    # Get IP from network-status annotation (whereabouts-assigned IP)
    WHEREABOUTS_IP=$(kubectl get pod -n openperouter-system $POD \
      -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}' | \
      jq -r '.[] | select(.name=="openperouter-system/underlay") | .ips[0]' 2>/dev/null || true)

    if [[ -n "$WHEREABOUTS_IP" ]]; then
      echo "    Found whereabouts IP: $WHEREABOUTS_IP"
      ALIAS_IPS+=("openperouter-network:$WHEREABOUTS_IP/32")
    fi
  done

  if [[ ${#ALIAS_IPS[@]} -eq 0 ]]; then
    echo "  No whereabouts IPs found, skipping..."
    continue
  fi

  # Build the alias list with the whereabouts IPs
  ALIASES_PARAM="--aliases=$(IFS=,; echo "${ALIAS_IPS[*]}")"

  echo "  Adding whereabouts IPs as aliases: ${ALIAS_IPS[@]}"

  # Update the instance with the new alias IPs
  gcloud compute instances network-interfaces update $INSTANCE_NAME \
    --zone=$ZONE \
    --network-interface=nic0 \
    $ALIASES_PARAM
  echo "  ✓ Alias IPs updated successfully"
done

echo ""
echo "=== Alias IP Configuration Complete ==="
echo ""
echo "Verifying final configuration:"
for NODE in $WORKER_NODES; do
  INSTANCE_NAME=$(echo $NODE | cut -d'.' -f1)
  ZONE=$(kubectl get node $NODE -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')

  echo ""
  echo "Instance: $INSTANCE_NAME"
  gcloud compute instances describe $INSTANCE_NAME \
    --zone=$ZONE \
    --format='table(networkInterfaces[0].aliasIpRanges[].ipCidrRange)'
done

echo ""
echo "============================================"
echo "GCP Cloud VPN Setup for Containerlab"
echo "============================================"
echo ""

# Validate required VPN configuration
if [[ -z "$SHARED_SECRET" ]]; then
  echo "Error: SHARED_SECRET environment variable must be set"
  echo "Export SHARED_SECRET before running this script:"
  echo "  export SHARED_SECRET='your-vpn-shared-secret'"
  exit 1
fi

# VPN gateway and tunnel names
VPN_GATEWAY_NAME="${NETWORK}-vpn-gateway"
VPN_TUNNEL_NAME="${NETWORK}-tunnel-onprem"

echo "Network: $NETWORK"
echo "On-prem Public IP: $ONPREM_PUBLIC_IP"
echo ""

# Step 1: Check if VPN gateway exists
echo "[1/6] Checking VPN gateway..."
if gcloud compute target-vpn-gateways describe $VPN_GATEWAY_NAME --region=$REGION &>/dev/null; then
    echo "  ✓ VPN gateway $VPN_GATEWAY_NAME already exists"
    GCP_VPN_IP=$(gcloud compute forwarding-rules list --filter="name~$VPN_GATEWAY_NAME-esp" --format="get(IPAddress)" | head -1)
    echo "  Gateway IP: $GCP_VPN_IP"
else
    echo "  Creating VPN gateway..."
    # Reserve static IP
    gcloud compute addresses create $VPN_GATEWAY_NAME-ip --region=$REGION
    GCP_VPN_IP=$(gcloud compute addresses describe $VPN_GATEWAY_NAME-ip --region=$REGION --format="get(address)")

    # Create VPN gateway
    gcloud compute target-vpn-gateways create $VPN_GATEWAY_NAME \
        --network=$NETWORK \
        --region=$REGION

    # Create forwarding rules
    gcloud compute forwarding-rules create ${VPN_GATEWAY_NAME}-esp \
        --region=$REGION \
        --ip-protocol=ESP \
        --address=$GCP_VPN_IP \
        --target-vpn-gateway=$VPN_GATEWAY_NAME

    gcloud compute forwarding-rules create ${VPN_GATEWAY_NAME}-udp500 \
        --region=$REGION \
        --ip-protocol=UDP \
        --ports=500 \
        --address=$GCP_VPN_IP \
        --target-vpn-gateway=$VPN_GATEWAY_NAME

    gcloud compute forwarding-rules create ${VPN_GATEWAY_NAME}-udp4500 \
        --region=$REGION \
        --ip-protocol=UDP \
        --ports=4500 \
        --address=$GCP_VPN_IP \
        --target-vpn-gateway=$VPN_GATEWAY_NAME

    echo "  ✓ VPN gateway created with IP: $GCP_VPN_IP"
fi

# Step 2: Delete existing tunnel if it exists (to update traffic selectors)
echo ""
echo "[2/6] Configuring VPN tunnel..."
if gcloud compute vpn-tunnels describe $VPN_TUNNEL_NAME --region=$REGION &>/dev/null; then
    echo "  Deleting existing tunnel to update configuration..."
    gcloud compute vpn-tunnels delete $VPN_TUNNEL_NAME --region=$REGION --quiet
fi

# Create VPN tunnel with asymmetric traffic selectors
# GCP side: local=worker VTEPs, remote=on-prem networks
echo "  Creating VPN tunnel..."
gcloud compute vpn-tunnels create $VPN_TUNNEL_NAME \
    --region=$REGION \
    --peer-address=$ONPREM_PUBLIC_IP \
    --shared-secret=$SHARED_SECRET \
    --ike-version=2 \
    --target-vpn-gateway=$VPN_GATEWAY_NAME \
    --local-traffic-selector=${WORKER_SUBNET_CIDR} \
    --remote-traffic-selector=10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24

echo "  ✓ VPN tunnel created"

# Step 3: Configure routes
# TODO: Replace static VPC routes with dynamic BGP route learning via Cloud Router
#
# Instead of manually creating static routes, configure BGP on Cloud Router to:
# 1. Peer with leafgcp (10.250.1.3) ASN 64515
# 2. Dynamically learn routes: 10.250.1.0/24, 10.250.11.0/24, 100.65.0.0/24
# 3. Automatically install routes into VPC routing table
#
# For now, using static routes as a workaround:
echo ""
echo "[3/6] Configuring routes..."
ROUTE_NAME="${NETWORK}-route-to-onprem-underlay"

# Check if route already exists on this network
EXISTING_ROUTE=$(gcloud compute routes describe "$ROUTE_NAME" --format="value(network.basename())" 2>/dev/null || true)

if [[ -n "$EXISTING_ROUTE" ]] && [[ "$EXISTING_ROUTE" == "$NETWORK" ]]; then
    echo "  ✓ Route $ROUTE_NAME already exists on network $NETWORK"
else
    # Delete if route exists on different network or with wrong config
    if gcloud compute routes describe "$ROUTE_NAME" &>/dev/null; then
        echo "  Deleting existing route with wrong configuration..."
        gcloud compute routes delete "$ROUTE_NAME" --quiet
    fi

    # Create the route for underlay
    gcloud compute routes create "$ROUTE_NAME" \
        --network=$NETWORK \
        --destination-range=10.250.1.0/24 \
        --next-hop-vpn-tunnel=$VPN_TUNNEL_NAME \
        --next-hop-vpn-tunnel-region=$REGION \
        --priority=100
    echo "  ✓ Route created: 10.250.1.0/24 → VPN tunnel on network $NETWORK"
fi

# Create route for kind VTEP subnet
VTEP_ROUTE_NAME="${NETWORK}-route-to-onprem-vtep"
EXISTING_VTEP_ROUTE=$(gcloud compute routes describe "$VTEP_ROUTE_NAME" --format="value(network.basename())" 2>/dev/null || true)

if [[ -n "$EXISTING_VTEP_ROUTE" ]] && [[ "$EXISTING_VTEP_ROUTE" == "$NETWORK" ]]; then
    echo "  ✓ Route $VTEP_ROUTE_NAME already exists on network $NETWORK"
else
    # Delete if route exists on different network or with wrong config
    if gcloud compute routes describe "$VTEP_ROUTE_NAME" &>/dev/null; then
        echo "  Deleting existing VTEP route with wrong configuration..."
        gcloud compute routes delete "$VTEP_ROUTE_NAME" --quiet
    fi

    # Create the route for VTEP
    gcloud compute routes create "$VTEP_ROUTE_NAME" \
        --network=$NETWORK \
        --destination-range=100.65.0.0/24 \
        --next-hop-vpn-tunnel=$VPN_TUNNEL_NAME \
        --next-hop-vpn-tunnel-region=$REGION \
        --priority=100
    echo "  ✓ Route created: 100.65.0.0/24 → VPN tunnel on network $NETWORK"
fi

# Create route for L3VNI test VTEP subnet (leafl3test)
L3VNI_ROUTE_NAME="${NETWORK}-route-to-onprem-l3vni"
EXISTING_L3VNI_ROUTE=$(gcloud compute routes describe "$L3VNI_ROUTE_NAME" --format="value(network.basename())" 2>/dev/null || true)

if [[ -n "$EXISTING_L3VNI_ROUTE" ]] && [[ "$EXISTING_L3VNI_ROUTE" == "$NETWORK" ]]; then
    echo "  ✓ Route $L3VNI_ROUTE_NAME already exists on network $NETWORK"
else
    # Delete if route exists on different network or with wrong config
    if gcloud compute routes describe "$L3VNI_ROUTE_NAME" &>/dev/null; then
        echo "  Deleting existing L3VNI route with wrong configuration..."
        gcloud compute routes delete "$L3VNI_ROUTE_NAME" --quiet
    fi

    # Create the route for L3VNI VTEP
    gcloud compute routes create "$L3VNI_ROUTE_NAME" \
        --network=$NETWORK \
        --destination-range=100.64.0.0/24 \
        --next-hop-vpn-tunnel=$VPN_TUNNEL_NAME \
        --next-hop-vpn-tunnel-region=$REGION \
        --priority=100
    echo "  ✓ Route created: 100.64.0.0/24 → VPN tunnel on network $NETWORK"
fi

# Create route for kind pod network
KIND_ROUTE_NAME="${NETWORK}-route-to-onprem-kind"
EXISTING_KIND_ROUTE=$(gcloud compute routes describe "$KIND_ROUTE_NAME" --format="value(network.basename())" 2>/dev/null || true)

if [[ -n "$EXISTING_KIND_ROUTE" ]] && [[ "$EXISTING_KIND_ROUTE" == "$NETWORK" ]]; then
    echo "  ✓ Route $KIND_ROUTE_NAME already exists on network $NETWORK"
else
    # Delete if route exists on different network or with wrong config
    if gcloud compute routes describe "$KIND_ROUTE_NAME" &>/dev/null; then
        echo "  Deleting existing kind route with wrong configuration..."
        gcloud compute routes delete "$KIND_ROUTE_NAME" --quiet
    fi

    # Create the route for kind pod network
    gcloud compute routes create "$KIND_ROUTE_NAME" \
        --network=$NETWORK \
        --destination-range=10.250.11.0/24 \
        --next-hop-vpn-tunnel=$VPN_TUNNEL_NAME \
        --next-hop-vpn-tunnel-region=$REGION \
        --priority=100
    echo "  ✓ Route created: 10.250.11.0/24 → VPN tunnel on network $NETWORK"
fi

# Step 4: Configure firewall rules
echo ""
echo "[4/6] Configuring firewall rules..."

# Delete old rules if they exist
for rule in ${NETWORK}-allow-bgp-onprem ${NETWORK}-allow-icmp-onprem ${NETWORK}-allow-vxlan-onprem; do
    if gcloud compute firewall-rules describe $rule &>/dev/null; then
        echo "  Deleting old rule: $rule"
        gcloud compute firewall-rules delete $rule --quiet
    fi
done

# BGP (TCP 179)
if ! gcloud compute firewall-rules describe ${NETWORK}-allow-bgp-from-onprem &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK}-allow-bgp-from-onprem \
        --network=$NETWORK \
        --allow=tcp:179 \
        --source-ranges=10.250.1.0/24 \
        --description="Allow BGP from on-prem containerlab underlay"
    echo "  ✓ BGP firewall rule created"
else
    echo "  ✓ BGP firewall rule already exists"
fi

# VXLAN (UDP 4789)
VXLAN_SOURCE_RANGES="10.250.1.0/24,10.250.11.0/24,100.65.0.0/24,100.64.0.0/24"
if ! gcloud compute firewall-rules describe ${NETWORK}-allow-vxlan-from-onprem &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK}-allow-vxlan-from-onprem \
        --network=$NETWORK \
        --allow=udp:4789 \
        --source-ranges=${VXLAN_SOURCE_RANGES} \
        --description="Allow VXLAN from on-prem VTEPs"
    echo "  ✓ VXLAN firewall rule created"
else
    # Update existing rule to ensure correct source ranges
    gcloud compute firewall-rules update ${NETWORK}-allow-vxlan-from-onprem \
        --source-ranges=${VXLAN_SOURCE_RANGES}
    echo "  ✓ VXLAN firewall rule updated"
fi

# ICMP
if ! gcloud compute firewall-rules describe ${NETWORK}-allow-icmp-from-onprem &>/dev/null; then
    gcloud compute firewall-rules create ${NETWORK}-allow-icmp-from-onprem \
        --network=$NETWORK \
        --allow=icmp \
        --source-ranges=10.250.1.0/24,10.250.11.0/24 \
        --description="Allow ICMP from on-prem for testing"
    echo "  ✓ ICMP firewall rule created"
else
    echo "  ✓ ICMP firewall rule already exists"
fi

# Step 5: Display configuration summary
echo ""
echo "[5/6] Configuration Summary"
echo "============================================"
echo "VPN Gateway External IP: $GCP_VPN_IP"
echo "VPN Tunnel: $VPN_TUNNEL_NAME"
echo "  Peer IP: $ONPREM_PUBLIC_IP"
echo "  Shared Secret: $SHARED_SECRET"
echo "  Traffic Selectors:"
echo "    Local (GCP):     ${WORKER_SUBNET_CIDR}"
echo "    Remote (on-prem): 10.250.1.0/24, 10.250.11.0/24, 100.65.0.0/24, 100.64.0.0/24"
echo ""
echo "Routes:"
echo "  10.250.1.0/24  → VPN tunnel (underlay)"
echo "  10.250.11.0/24 → VPN tunnel (kind pods)"
echo "  100.65.0.0/24  → VPN tunnel (kind VTEPs)"
echo "  100.64.0.0/24  → VPN tunnel (L3VNI test VTEPs)"
echo ""
echo "Firewall Rules:"
echo "  BGP:   tcp:179  from 10.250.1.0/24"
echo "  VXLAN: udp:4789 from 10.250.1.0/24, 10.250.11.0/24, 100.65.0.0/24, 100.64.0.0/24"
echo "  ICMP:  icmp    from 10.250.1.0/24, 10.250.11.0/24"
echo ""

# Step 6: Save configuration for containerlab
echo "[6/6] Saving configuration for containerlab..."
cat > /tmp/gcp-vpn-config.env <<EOF
# GCP VPN Configuration for Containerlab
export GCP_VPN_IP=$GCP_VPN_IP
export ONPREM_PUBLIC_IP=$ONPREM_PUBLIC_IP
export SHARED_SECRET=$SHARED_SECRET
EOF

echo "  ✓ Configuration saved to /tmp/gcp-vpn-config.env"
echo ""
echo "============================================"
echo "GCP Cloud VPN Setup Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Use the following configuration in leafgcp container:"
echo "   - Remote VPN IP: $GCP_VPN_IP"
echo "   - Shared Secret: $SHARED_SECRET"
echo "   - Traffic Selectors: local=10.250.1.0/24, remote=${WORKER_SUBNET_CIDR}"
echo ""
echo "2. Configure containerlab with underlay network 10.250.1.0/24:"
echo "   - spine: 10.250.1.0/31, 10.250.1.2/31"
echo "   - leafkind: 10.250.1.1/31"
echo "   - leafgcp: 10.250.1.3/31 (BGP peering address for GCP workers)"
echo ""
echo "3. Update GCP workers Underlay to peer with leafgcp (10.250.1.3)"
echo ""
echo "To clean up all resources created by this script:"
echo "  ./setup-gcp.sh cleanup"
echo ""
