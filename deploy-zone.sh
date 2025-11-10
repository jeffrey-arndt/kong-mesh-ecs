#!/bin/bash
set -euo pipefail

# Kong Mesh ECS Zone Deployment Script
# This script automates the deployment of a Kong Mesh zone connected to Konnect

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Usage function
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Deploys a Kong Mesh zone on ECS connected to Konnect.

Required Options:
  --zone-name NAME           Name of the zone (e.g., zone1, us-east, production)
  --kds-address ADDR         Konnect KDS address (e.g., grpcs://us.mesh.sync.konghq.com:443)
  --cp-id ID                 Konnect CP ID from zone creation wizard
  --konnect-token TOKEN      Konnect authentication token

Optional Options:
  --license-file PATH       Path to Kong Mesh license.json (not needed for Konnect)
  --vpc-cidr CIDR           VPC CIDR block (default: 10.0.0.0/16)
  --subnet1-cidr CIDR       Public subnet 1 CIDR (default: 10.0.0.0/24)
  --subnet2-cidr CIDR       Public subnet 2 CIDR (default: 10.0.1.0/24)
  --region REGION           AWS region (default: us-east-2)
  --skip-demo               Skip deploying demo applications
  --skip-ingress            Skip deploying zone ingress
  -h, --help                Show this help message

Example (Konnect - no license needed):
  $0 \\
    --zone-name zone1 \\
    --kds-address grpcs://us.mesh.sync.konghq.com:443 \\
    --cp-id 61e5904f-bc3e-401e-9144-d4aa3983a921 \\
    --konnect-token spat_YOUR_TOKEN_HERE

Multi-Zone Example (second zone with different CIDR):
  $0 \\
    --zone-name zone2 \\
    --vpc-cidr 10.1.0.0/16 \\
    --subnet1-cidr 10.1.0.0/24 \\
    --subnet2-cidr 10.1.1.0/24 \\
    --kds-address grpcs://us.mesh.sync.konghq.com:443 \\
    --cp-id 61e5904f-bc3e-401e-9144-d4aa3983a921 \\
    --konnect-token spat_YOUR_TOKEN_HERE

Example with license file (standalone deployment without Konnect):
  $0 \\
    --zone-name zone1 \\
    --kds-address grpcs://us.mesh.sync.konghq.com:443 \\
    --cp-id 61e5904f-bc3e-401e-9144-d4aa3983a921 \\
    --konnect-token spat_YOUR_TOKEN_HERE \\
    --license-file ./license.json

EOF
    exit 1
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    local missing=0

    if ! command -v aws &> /dev/null; then
        log_error "aws CLI not found. Please install AWS CLI."
        missing=1
    fi

    if ! command -v kumactl &> /dev/null; then
        log_error "kumactl not found. Please install kumactl."
        missing=1
    fi

    if ! command -v jq &> /dev/null; then
        log_error "jq not found. Please install jq."
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        exit 1
    fi

    log_success "All prerequisites met"
}

# Parse command line arguments
parse_args() {
    ZONE_NAME=""
    KDS_ADDRESS=""
    CP_ID=""
    KONNECT_TOKEN=""
    LICENSE_FILE=""
    VPC_CIDR="10.0.0.0/16"
    SUBNET1_CIDR="10.0.0.0/24"
    SUBNET2_CIDR="10.0.1.0/24"
    AWS_REGION="us-east-2"
    SKIP_DEMO=false
    SKIP_INGRESS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --zone-name)
                ZONE_NAME="$2"
                shift 2
                ;;
            --kds-address)
                KDS_ADDRESS="$2"
                shift 2
                ;;
            --cp-id)
                CP_ID="$2"
                shift 2
                ;;
            --konnect-token)
                KONNECT_TOKEN="$2"
                shift 2
                ;;
            --license-file)
                LICENSE_FILE="$2"
                shift 2
                ;;
            --vpc-cidr)
                VPC_CIDR="$2"
                shift 2
                ;;
            --subnet1-cidr)
                SUBNET1_CIDR="$2"
                shift 2
                ;;
            --subnet2-cidr)
                SUBNET2_CIDR="$2"
                shift 2
                ;;
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --skip-demo)
                SKIP_DEMO=true
                shift
                ;;
            --skip-ingress)
                SKIP_INGRESS=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate required parameters
    if [ -z "$ZONE_NAME" ] || [ -z "$KDS_ADDRESS" ] || [ -z "$CP_ID" ] || \
       [ -z "$KONNECT_TOKEN" ]; then
        log_error "Missing required parameters"
        usage
    fi

    # Validate license file if provided
    if [ -n "$LICENSE_FILE" ] && [ ! -f "$LICENSE_FILE" ]; then
        log_error "License file not found: $LICENSE_FILE"
        exit 1
    fi

    export AWS_REGION
}

# Create AWS Secrets
create_secrets() {
    log_info "Creating AWS Secrets Manager secrets..."

    # License secret (optional - not needed for Konnect)
    if [ -n "$LICENSE_FILE" ]; then
        log_info "Creating license secret..."
        LICENSE_SECRET=$(aws secretsmanager create-secret \
            --name "${ZONE_NAME}/KongMeshLicense" \
            --description "Kong Mesh license for ${ZONE_NAME}" \
            --secret-string file://"${LICENSE_FILE}" \
            --region "${AWS_REGION}" \
          | jq -r .ARN)
        log_success "License secret created: ${LICENSE_SECRET}"
    else
        log_info "Skipping license secret (using Konnect licensing)"
        LICENSE_SECRET=""
    fi

    # Konnect token secret
    log_info "Creating Konnect token secret..."
    echo "${KONNECT_TOKEN}" > /tmp/konnect-cp-token-${ZONE_NAME}
    CP_TOKEN_SECRET=$(aws secretsmanager create-secret \
        --name "${ZONE_NAME}/global-cp-token" \
        --description "Konnect global control plane token for ${ZONE_NAME}" \
        --secret-string file:///tmp/konnect-cp-token-${ZONE_NAME} \
        --region "${AWS_REGION}" \
      | jq -r .ARN)
    rm /tmp/konnect-cp-token-${ZONE_NAME}
    log_success "Konnect token secret created: ${CP_TOKEN_SECRET}"
}

# Deploy VPC stack
deploy_vpc() {
    log_info "Deploying VPC stack..."

    aws cloudformation deploy \
        --capabilities CAPABILITY_IAM \
        --stack-name "${ZONE_NAME}-vpc" \
        --parameter-overrides \
          ZoneIdentifier="${ZONE_NAME}" \
          VpcCIDR="${VPC_CIDR}" \
          PublicSubnet1CIDR="${SUBNET1_CIDR}" \
          PublicSubnet2CIDR="${SUBNET2_CIDR}" \
        --template-file deploy/vpc.yaml \
        --region "${AWS_REGION}"

    log_success "VPC stack deployed"

    # Get CP address
    CP_ADDR=$(aws cloudformation describe-stacks \
        --stack-name "${ZONE_NAME}-vpc" \
        --region "${AWS_REGION}" \
      | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ExternalCPAddress") | .OutputValue')

    log_info "Control Plane address will be: ${CP_ADDR}"
}

# Generate TLS certificates
generate_tls() {
    log_info "Generating TLS certificates..."

    # Clean up any existing cert files
    rm -f key.pem cert.pem

    kumactl generate tls-certificate \
        --type=server \
        --hostname "${CP_ADDR}" \
        --hostname controlplane.kongmesh

    log_success "TLS certificates generated"

    # Store in AWS Secrets Manager
    log_info "Storing TLS certificates in AWS Secrets Manager..."

    TLS_KEY=$(aws secretsmanager create-secret \
        --name "${ZONE_NAME}/CPTLSKey" \
        --description "TLS private key for ${ZONE_NAME} control plane" \
        --secret-string file://key.pem \
        --region "${AWS_REGION}" \
      | jq -r .ARN)

    TLS_CERT=$(aws secretsmanager create-secret \
        --name "${ZONE_NAME}/CPTLSCert" \
        --description "TLS certificate for ${ZONE_NAME} control plane" \
        --secret-string file://cert.pem \
        --region "${AWS_REGION}" \
      | jq -r .ARN)

    log_success "TLS secrets created"
}

# Deploy Control Plane
deploy_control_plane() {
    log_info "Deploying Kong Mesh Control Plane (connected to Konnect)..."

    # Build parameter overrides
    local PARAM_OVERRIDES="VPCStackName=${ZONE_NAME}-vpc"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} ZoneName=${ZONE_NAME}"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} ServerKeySecret=${TLS_KEY}"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} ServerCertSecret=${TLS_CERT}"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} GlobalKDSAddress=${KDS_ADDRESS}"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} GlobalCPTokenSecret=${CP_TOKEN_SECRET}"
    PARAM_OVERRIDES="${PARAM_OVERRIDES} KonnectCPId=${CP_ID}"

    # Add license secret only if it exists
    if [ -n "$LICENSE_SECRET" ]; then
        PARAM_OVERRIDES="${PARAM_OVERRIDES} LicenseSecret=${LICENSE_SECRET}"
    fi

    aws cloudformation deploy \
        --capabilities CAPABILITY_IAM \
        --stack-name "${ZONE_NAME}-kong-mesh-cp" \
        --parameter-overrides ${PARAM_OVERRIDES} \
        --template-file deploy/controlplane.yaml \
        --region "${AWS_REGION}"

    log_success "Control Plane deployed"
    log_info "Waiting 30 seconds for control plane to stabilize..."
    sleep 30
}

# Deploy Zone Ingress
deploy_zone_ingress() {
    if [ "$SKIP_INGRESS" = true ]; then
        log_warning "Skipping zone ingress deployment"
        return
    fi

    log_info "Deploying Zone Ingress..."

    aws cloudformation deploy \
        --capabilities CAPABILITY_IAM \
        --stack-name "${ZONE_NAME}-ingress" \
        --parameter-overrides \
          VPCStackName="${ZONE_NAME}-vpc" \
          CPStackName="${ZONE_NAME}-kong-mesh-cp" \
        --template-file deploy/ingress.yaml \
        --region "${AWS_REGION}"

    log_success "Zone Ingress deployed"
}

# Deploy Demo Applications
deploy_demo_apps() {
    if [ "$SKIP_DEMO" = true ]; then
        log_warning "Skipping demo application deployment"
        return
    fi

    log_info "Deploying demo applications..."

    # Deploy Redis
    log_info "Deploying Redis..."
    aws cloudformation deploy \
        --capabilities CAPABILITY_IAM \
        --stack-name "${ZONE_NAME}-redis" \
        --parameter-overrides \
          VPCStackName="${ZONE_NAME}-vpc" \
          CPStackName="${ZONE_NAME}-kong-mesh-cp" \
        --template-file deploy/counter-demo/redis.yaml \
        --region "${AWS_REGION}"

    log_success "Redis deployed"

    # Deploy Demo App
    log_info "Deploying Demo App..."
    aws cloudformation deploy \
        --capabilities CAPABILITY_IAM \
        --stack-name "${ZONE_NAME}-demo-app" \
        --parameter-overrides \
          VPCStackName="${ZONE_NAME}-vpc" \
          CPStackName="${ZONE_NAME}-kong-mesh-cp" \
        --template-file deploy/counter-demo/demo-app.yaml \
        --region "${AWS_REGION}"

    log_success "Demo App deployed"
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    log_success "Deployment Complete!"
    echo "=========================================="
    echo ""
    echo "Zone Name:           ${ZONE_NAME}"
    echo "Region:              ${AWS_REGION}"
    echo "VPC CIDR:            ${VPC_CIDR}"
    echo "CP Address:          ${CP_ADDR}"
    echo ""
    echo "Deployed Stacks:"
    echo "  - ${ZONE_NAME}-vpc"
    echo "  - ${ZONE_NAME}-kong-mesh-cp"

    if [ "$SKIP_INGRESS" = false ]; then
        echo "  - ${ZONE_NAME}-ingress"
    fi

    if [ "$SKIP_DEMO" = false ]; then
        echo "  - ${ZONE_NAME}-redis"
        echo "  - ${ZONE_NAME}-demo-app"
        echo ""
        echo "Demo App URL:        http://${CP_ADDR}:80"
        echo ""
        echo "Test the demo app:"
        echo "  curl http://${CP_ADDR}/counter"
        echo "  curl -X POST http://${CP_ADDR}/increment"
    fi

    echo ""
    echo "Next Steps:"
    echo "  1. Check Konnect console to verify zone is connected"
    echo "  2. Verify dataplanes are registered in Konnect"
    echo "  3. Use kumactl (configured for Konnect) to manage the mesh"
    echo ""
    echo "Cleanup command:"
    echo "  ./cleanup-zone.sh --zone-name ${ZONE_NAME} --region ${AWS_REGION}"
    echo ""
}

# Main execution
main() {
    echo "=========================================="
    echo "  Kong Mesh ECS Zone Deployment"
    echo "=========================================="
    echo ""

    parse_args "$@"
    check_prerequisites
    create_secrets
    deploy_vpc
    generate_tls
    deploy_control_plane
    deploy_zone_ingress
    deploy_demo_apps
    print_summary
}

# Run main function
main "$@"
