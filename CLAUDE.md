# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository provides CloudFormation templates for deploying Kong Mesh (a service mesh based on Kuma) on AWS ECS with Fargate. It sets up a complete mesh infrastructure including:
- Control plane with Aurora Postgres backend
- Workload identity authentication using AWS IAM
- **Dynamic outbounds** via Route53 integration (no manual outbound configuration required)
- Multi-zone support with zone ingress for inter-zone communication
- Zone-specific resource naming for deploying multiple zones in the same account/region

## Architecture

### Stack Dependencies

The deployment consists of multiple CloudFormation stacks with strict dependencies:

1. **VPC Stack** (`deploy/vpc.yaml`) - Foundation layer
   - VPC with public subnets across 2 availability zones (configurable CIDR ranges)
   - Internet Gateway and routing
   - Network Load Balancer (NLB)
   - ECS cluster with zone-specific naming
   - Service Discovery private DNS namespace (`.kongmesh` TLD)
   - Route53 Private Hosted Zone (`mesh.<zone>.local`) for dynamic outbounds
   - **Zone identifier** parameter for multi-zone deployments

2. **Control Plane Stack** (`deploy/controlplane.yaml`) - Requires VPC stack
   - Kong Mesh control plane running in zone mode
   - Aurora Postgres backend for CP state
   - Load balancer listeners on ports 5678 (DP-to-CP) and 5682 (HTTPS API/GUI)
   - TLS configuration via AWS Secrets Manager
   - **Route53 integration enabled** for dynamic service discovery
   - Konnect integration for multizone deployments (connects multiple zones via global CP)

3. **Zone Ingress Stack** (`deploy/ingress.yaml`) - Requires VPC and CP stacks
   - Zone ingress dataplane for inter-zone communication
   - Load balancer listener on port 10001 for cross-zone traffic
   - Enables services in this zone to be accessible from other zones

4. **Application Stacks** (`deploy/counter-demo/`) - Require VPC and CP stacks
   - `redis.yaml` - Redis service with kuma-dp sidecar using `--bind-outbounds`
   - `demo-app.yaml` - Demo app frontend with kuma-dp sidecar using `--bind-outbounds`
   - Both use workload identity for authentication
   - Both use dynamic outbounds (no hard-coded outbound lists)

### Workload Identity Pattern

This repository implements AWS IAM-based authentication between dataplanes and the control plane:

- Control plane authenticates dataplanes via AWS IAM task roles (not dataplane tokens)
- CP requires `KUMA_DP_SERVER_AUTHN_DP_PROXY_TYPE=aws-iam` and `KUMA_DP_SERVER_AUTHN_ZONE_PROXY_TYPE=aws-iam`
- CP task role needs `iam:GetRole` permission on all DP task roles
- DP containers use `--auth-type=aws` flag
- Service name is encoded in task IAM role tags: `kuma.io/service=<service-name>`

### Dynamic Outbounds with Route53

This repository uses **dynamic outbounds** which eliminates manual outbound configuration:

- Control plane: Route53 integration enabled (see `controlplane.yaml` lines 390-404)
  - `KMESH_RUNTIME_AWS_ROUTE53_ENABLED=true`
  - Automatically manages DNS records in private hosted zone
  - Services accessible via `<service>.mesh.local:8080`

- Dataplanes: Use `--bind-outbounds` flag (see `redis.yaml` line 208, `demo-app.yaml` line 268)
  - Automatically discovers all services in the mesh
  - No need to pre-enumerate outbound dependencies
  - Routes cross-zone traffic through zone ingress gateways

- Dataplane Template: Only defines inbound configuration
  - **Inbound**: Service's listening port mapped to mesh external port
  - **No outbounds section** - automatically discovered via Route53

### Multi-Zone Architecture

For multi-zone deployments:
- Each zone has its own VPC (with non-overlapping CIDR ranges if inter-zone routing needed)
- Each zone has its own control plane connected to Konnect global CP
- Each zone has a zone ingress for accepting traffic from other zones
- Services communicate across zones transparently via mesh DNS
- Zone identifier parameter ensures unique resource names per zone

## Common Commands

### Deploying Stacks

```bash
# 1. Deploy VPC and cluster
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-vpc \
    --template-file deploy/vpc.yaml

# 2. Create secrets for control plane
LICENSE_SECRET=$(aws secretsmanager create-secret \
    --name ecs-demo/KongMeshLicense \
    --description "Secret containing Kong Mesh license" \
    --secret-string file://license.json | jq -r .ARN)

# Get CP address from VPC stack
CP_ADDR=$(aws cloudformation describe-stacks --stack-name ecs-demo-vpc \
  | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ExternalCPAddress") | .OutputValue')

# Generate TLS certificates
kumactl generate tls-certificate --type=server --hostname ${CP_ADDR} --hostname controlplane.kongmesh

# Store TLS secrets
TLS_KEY=$(aws secretsmanager create-secret \
  --name ecs-demo/CPTLSKey \
  --description "Secret containing TLS private key" \
  --secret-string file://key.pem | jq -r .ARN)
TLS_CERT=$(aws secretsmanager create-secret \
  --name ecs-demo/CPTLSCert \
  --description "Secret containing TLS certificate" \
  --secret-string file://cert.pem | jq -r .ARN)

# 3. Deploy control plane
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-kong-mesh-cp \
    --parameter-overrides VPCStackName=ecs-demo-vpc \
      LicenseSecret=${LICENSE_SECRET} \
      ServerKeySecret=${TLS_KEY} \
      ServerCertSecret=${TLS_CERT} \
    --template-file deploy/controlplane.yaml

# 4. Deploy demo applications
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-redis \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/counter-demo/redis.yaml

aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-demo-app \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/counter-demo/demo-app.yaml

# 5. Deploy zone ingress (for multi-zone only)
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-ingress \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/ingress.yaml
```

### Multi-Zone Deployment (Multiple ECS Zones)

To deploy multiple zones in the same account/region:

```bash
# Zone 1 - VPC with unique CIDR and zone identifier
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone1-vpc \
    --parameter-overrides ZoneIdentifier=zone1 VpcCIDR=10.0.0.0/16 PublicSubnet1CIDR=10.0.0.0/24 PublicSubnet2CIDR=10.0.1.0/24 \
    --template-file deploy/vpc.yaml

# Zone 2 - VPC with different CIDR
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone2-vpc \
    --parameter-overrides ZoneIdentifier=zone2 VpcCIDR=10.1.0.0/16 PublicSubnet1CIDR=10.1.0.0/24 PublicSubnet2CIDR=10.1.1.0/24 \
    --template-file deploy/vpc.yaml

# Deploy control planes for each zone (connected to Konnect)
# Zone 1 CP
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone1-kong-mesh-cp \
    --parameter-overrides VPCStackName=ecs-zone1-vpc \
      ZoneName=zone1 \
      LicenseSecret=${LICENSE_SECRET} \
      ServerKeySecret=${TLS_KEY_ZONE1} \
      ServerCertSecret=${TLS_CERT_ZONE1} \
      GlobalKDSAddress=${KDS_ADDR} \
      GlobalCPTokenSecret=${CP_TOKEN_SECRET} \
      KonnectCPId=${CP_ID} \
    --template-file deploy/controlplane.yaml

# Zone 2 CP
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone2-kong-mesh-cp \
    --parameter-overrides VPCStackName=ecs-zone2-vpc \
      ZoneName=zone2 \
      LicenseSecret=${LICENSE_SECRET} \
      ServerKeySecret=${TLS_KEY_ZONE2} \
      ServerCertSecret=${TLS_CERT_ZONE2} \
      GlobalKDSAddress=${KDS_ADDR} \
      GlobalCPTokenSecret=${CP_TOKEN_SECRET} \
      KonnectCPId=${CP_ID} \
    --template-file deploy/controlplane.yaml

# Deploy zone ingress for each zone (required for inter-zone communication)
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone1-ingress \
    --parameter-overrides VPCStackName=ecs-zone1-vpc CPStackName=ecs-zone1-kong-mesh-cp \
    --template-file deploy/ingress.yaml

aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone2-ingress \
    --parameter-overrides VPCStackName=ecs-zone2-vpc CPStackName=ecs-zone2-kong-mesh-cp \
    --template-file deploy/ingress.yaml

# Deploy applications to each zone using respective VPC/CP stack names
```

### Konnect Multizone Deployment

When deploying a zone connected to Konnect global control plane:

```bash
# Extract from Konnect zone creation wizard (Environment: Universal)
KDS_ADDR=<global KDS endpoint>  # e.g., grpcs://us.mesh.sync.konghq.com:443
CP_ID=<your CP ID>
echo "<auth token>" > konnect-cp-token
CP_TOKEN_SECRET=$(aws secretsmanager create-secret \
    --name ecs-demo/global-cp-token \
    --secret-string file://konnect-cp-token | jq -r .ARN)

# Add to CP deployment:
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-kong-mesh-cp \
    --parameter-overrides VPCStackName=ecs-demo-vpc \
      LicenseSecret=${LICENSE_SECRET} \
      ServerKeySecret=${TLS_KEY} \
      ServerCertSecret=${TLS_CERT} \
      ZoneName=ecs-demo \
      GlobalKDSAddress=${KDS_ADDR} \
      GlobalCPTokenSecret=${CP_TOKEN_SECRET} \
      KonnectCPId=${CP_ID} \
    --template-file deploy/controlplane.yaml
```

### Kumactl Setup

```bash
# Get admin token from CP stack
TOKEN_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name ecs-demo-kong-mesh-cp \
  | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "APITokenSecret") | .OutputValue')

TOKEN=$(aws secretsmanager get-secret-value --secret-id ${TOKEN_SECRET_ARN} | jq -r .SecretString)

# Configure kumactl
kumactl config control-planes add \
  --name=ecs --address=https://${CP_ADDR}:5682 --overwrite --auth-type=tokens \
  --auth-conf token=${TOKEN} \
  --ca-cert-file cert.pem
```

### Debugging and Access

```bash
# Access container shell via ECS Exec
aws ecs execute-command --cluster ${ECS_CLUSTER_NAME} \
    --task ${ECS_TASK_ARN} \
    --container workload \
    --interactive \
    --command "/bin/sh"

# View CloudFormation stack events
aws cloudformation describe-stack-events --stack-name <stack-name>

# Check ECS task logs
aws logs tail /aws/ecs/<stack-name> --follow
```

### Cleanup

```bash
# Delete in reverse order of creation
aws cloudformation delete-stack --stack-name ecs-demo-demo-app
aws cloudformation delete-stack --stack-name ecs-demo-redis
aws cloudformation delete-stack --stack-name ecs-demo-ingress
aws cloudformation delete-stack --stack-name ecs-demo-kong-mesh-cp
aws secretsmanager delete-secret --secret-id ${TLS_CERT}
aws secretsmanager delete-secret --secret-id ${TLS_KEY}
aws secretsmanager delete-secret --secret-id ${LICENSE_SECRET}
aws cloudformation delete-stack --stack-name ecs-demo-vpc
```

## CI/CD

The nightly workflow (`.github/workflows/nightly.yaml`) provides end-to-end testing:
- Uses OIDC authentication with AWS (no long-lived credentials)
- Stack naming uses `ecs-ci` prefix with unique run IDs
- Tests dataplane registration and demo app functionality
- **Important**: Failed runs leave orphaned `ecs-ci-*` stacks that must be manually deleted before next run

## Key Configuration Files

- `deploy/vpc.yaml`: VPC, networking, ECS cluster, Route53 hosted zone setup
  - Zone identifier parameter for multi-zone support
  - Configurable CIDR ranges for multiple VPCs
- `deploy/controlplane.yaml`: Kong Mesh CP with Aurora backend and Route53 integration
  - Route53 enabled: lines 390-394
  - Konnect multizone configuration: lines 407-435
- `deploy/ingress.yaml`: Zone ingress for inter-zone communication
  - Port 10001 for zone ingress traffic
  - Uses `--ingress` flag for kuma-dp
- `deploy/counter-demo/redis.yaml`: Redis dataplane example with `--bind-outbounds` (line 208)
- `deploy/counter-demo/demo-app.yaml`: Demo app dataplane with `--bind-outbounds` (line 268)
  - Redis accessed via `redis.mesh.local:8080` (lines 216-218)
- `policy.json`: IAM permissions required for deployment
- `.github/workflows/nightly.yaml`: Automated testing workflow

## Important Notes

- **Dynamic outbounds**: No manual outbound configuration needed - services discovered automatically via Route53
- **Multi-zone**: Deploy multiple zones by using different zone identifiers and CIDR ranges
- **Zone ingress**: Required for inter-zone communication - exposes services on port 10001
- The control plane GUI is accessible at `https://${CP_ADDR}:5682/gui` (requires accepting self-signed cert)
- Demo app is accessible at `http://${CP_ADDR}:80`
- All stacks use `CAPABILITY_IAM` due to IAM role creation
- Database deletion policy is set to `Delete` for CI purposes (change for production)
- Service Discovery uses internal TLD `.kongmesh` (configurable via VPC stack parameter)
- Mesh DNS domain is `mesh.<zone>.local` (zone-specific) for Route53 integration
