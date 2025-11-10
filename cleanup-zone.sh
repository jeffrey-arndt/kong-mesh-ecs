#!/bin/bash
set -euo pipefail

# Kong Mesh ECS Zone Cleanup Script
# This script removes all resources created by deploy-zone.sh

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

Cleans up all resources for a Kong Mesh zone deployment.

Required Options:
  --zone-name NAME           Name of the zone to cleanup

Optional Options:
  --region REGION           AWS region (default: us-east-2)
  --keep-secrets            Keep AWS Secrets Manager secrets
  --skip-demo               Skip demo app cleanup (if not deployed)
  --skip-ingress            Skip ingress cleanup (if not deployed)
  -h, --help                Show this help message

Example:
  $0 --zone-name zone1

Example (keep secrets for redeployment):
  $0 --zone-name zone1 --keep-secrets

EOF
    exit 1
}

# Parse command line arguments
parse_args() {
    ZONE_NAME=""
    AWS_REGION="us-east-2"
    KEEP_SECRETS=false
    SKIP_DEMO=false
    SKIP_INGRESS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --zone-name)
                ZONE_NAME="$2"
                shift 2
                ;;
            --region)
                AWS_REGION="$2"
                shift 2
                ;;
            --keep-secrets)
                KEEP_SECRETS=true
                shift
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
    if [ -z "$ZONE_NAME" ]; then
        log_error "Missing required parameter: --zone-name"
        usage
    fi

    export AWS_REGION
}

# Confirm deletion
confirm_deletion() {
    echo ""
    log_warning "This will delete the following resources for zone: ${ZONE_NAME}"
    echo ""
    echo "  CloudFormation Stacks:"
    if [ "$SKIP_DEMO" = false ]; then
        echo "    - ${ZONE_NAME}-demo-app"
        echo "    - ${ZONE_NAME}-redis"
    fi
    if [ "$SKIP_INGRESS" = false ]; then
        echo "    - ${ZONE_NAME}-ingress"
    fi
    echo "    - ${ZONE_NAME}-kong-mesh-cp"
    echo "    - ${ZONE_NAME}-vpc"
    echo ""
    if [ "$KEEP_SECRETS" = false ]; then
        echo "  AWS Secrets (if they exist):"
        echo "    - ${ZONE_NAME}/KongMeshLicense (if license was used)"
        echo "    - ${ZONE_NAME}/global-cp-token"
        echo "    - ${ZONE_NAME}/CPTLSKey"
        echo "    - ${ZONE_NAME}/CPTLSCert"
        echo ""
    fi

    read -p "Are you sure you want to proceed? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
}

# Delete CloudFormation stack and wait
delete_stack() {
    local stack_name=$1

    log_info "Deleting stack: ${stack_name}..."

    if aws cloudformation describe-stacks \
        --stack-name "${stack_name}" \
        --region "${AWS_REGION}" &>/dev/null; then

        aws cloudformation delete-stack \
            --stack-name "${stack_name}" \
            --region "${AWS_REGION}"

        log_info "Waiting for stack deletion to complete: ${stack_name}..."
        aws cloudformation wait stack-delete-complete \
            --stack-name "${stack_name}" \
            --region "${AWS_REGION}" || true

        log_success "Stack deleted: ${stack_name}"
    else
        log_warning "Stack not found (already deleted?): ${stack_name}"
    fi
}

# Delete secret
delete_secret() {
    local secret_name=$1

    log_info "Deleting secret: ${secret_name}..."

    if aws secretsmanager describe-secret \
        --secret-id "${secret_name}" \
        --region "${AWS_REGION}" &>/dev/null; then

        aws secretsmanager delete-secret \
            --secret-id "${secret_name}" \
            --force-delete-without-recovery \
            --region "${AWS_REGION}" &>/dev/null

        log_success "Secret deleted: ${secret_name}"
    else
        log_warning "Secret not found (already deleted?): ${secret_name}"
    fi
}

# Cleanup demo apps
cleanup_demo_apps() {
    if [ "$SKIP_DEMO" = true ]; then
        log_warning "Skipping demo app cleanup"
        return
    fi

    delete_stack "${ZONE_NAME}-demo-app"
    delete_stack "${ZONE_NAME}-redis"
}

# Cleanup zone ingress
cleanup_ingress() {
    if [ "$SKIP_INGRESS" = true ]; then
        log_warning "Skipping ingress cleanup"
        return
    fi

    delete_stack "${ZONE_NAME}-ingress"
}

# Cleanup control plane
cleanup_control_plane() {
    delete_stack "${ZONE_NAME}-kong-mesh-cp"
}

# Cleanup VPC
cleanup_vpc() {
    delete_stack "${ZONE_NAME}-vpc"
}

# Cleanup secrets
cleanup_secrets() {
    if [ "$KEEP_SECRETS" = true ]; then
        log_warning "Keeping AWS Secrets (--keep-secrets flag set)"
        return
    fi

    log_info "Cleaning up AWS Secrets..."

    delete_secret "${ZONE_NAME}/KongMeshLicense"
    delete_secret "${ZONE_NAME}/global-cp-token"
    delete_secret "${ZONE_NAME}/CPTLSKey"
    delete_secret "${ZONE_NAME}/CPTLSCert"
}

# Print summary
print_summary() {
    echo ""
    echo "=========================================="
    log_success "Cleanup Complete!"
    echo "=========================================="
    echo ""
    echo "Zone Name:           ${ZONE_NAME}"
    echo "Region:              ${AWS_REGION}"
    echo ""
    if [ "$KEEP_SECRETS" = true ]; then
        log_info "Secrets were preserved and can be reused for redeployment"
    else
        log_info "All resources have been deleted"
    fi
    echo ""
}

# Main execution
main() {
    echo "=========================================="
    echo "  Kong Mesh ECS Zone Cleanup"
    echo "=========================================="
    echo ""

    parse_args "$@"
    confirm_deletion

    log_info "Starting cleanup for zone: ${ZONE_NAME}"
    echo ""

    cleanup_demo_apps
    cleanup_ingress
    cleanup_control_plane
    cleanup_vpc
    cleanup_secrets

    print_summary
}

# Run main function
main "$@"
