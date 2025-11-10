# Kong Mesh on ECS + Fargate

[![Nightly Kong Mesh on ECS](https://github.com/Kong/kong-mesh-ecs/actions/workflows/nightly.yaml/badge.svg)](https://github.com/Kong/kong-mesh-ecs/actions/workflows/nightly.yaml)

This repository provides some example CloudFormation templates for running
Kong Mesh on ECS + Fargate.

It provisions all the necessary AWS infrastructure for
running a standalone Kong Mesh zone with a postgres backend (on AWS Aurora)
and runs the [Kuma counter demo](https://github.com/kumahq/kuma-counter-demo).

## Quick Start (Automated Deployment)

The easiest way to deploy is using the included automation scripts:

### Prerequisites

- [AWS CLI](https://aws.amazon.com/cli/) configured with appropriate credentials
- [kumactl](https://docs.konghq.com/mesh/) installed
- [jq](https://stedolan.github.io/jq/) installed
- Access to a Konnect account (sign up at [konghq.com](https://konghq.com/))

### Single Zone Deployment

1. Create a zone in Konnect (Environment: **Universal**) and extract:
   - KDS address (e.g., `grpcs://us.mesh.sync.konghq.com:443`)
   - CP ID (e.g., `61e5904f-bc3e-401e-9144-d4aa3983a921`)
   - Authentication token (e.g., `spat_...`)

2. Run the deployment script:

```bash
./deploy-zone.sh \
  --zone-name zone1 \
  --kds-address grpcs://us.mesh.sync.konghq.com:443 \
  --cp-id 61e5904f-bc3e-401e-9144-d4aa3983a921 \
  --konnect-token spat_YOUR_TOKEN_HERE
```

This automatically:
- Creates AWS Secrets for TLS and Konnect credentials
- Deploys VPC, ECS cluster, and networking
- Generates and stores TLS certificates
- Deploys Kong Mesh control plane (connected to Konnect)
- Deploys zone ingress for multi-zone communication
- Deploys demo applications (Redis + counter app)

### Multi-Zone Deployment

Deploy a second zone with different CIDR ranges:

```bash
./deploy-zone.sh \
  --zone-name zone2 \
  --vpc-cidr 10.1.0.0/16 \
  --subnet1-cidr 10.1.0.0/24 \
  --subnet2-cidr 10.1.1.0/24 \
  --kds-address grpcs://us.mesh.sync.konghq.com:443 \
  --cp-id 61e5904f-bc3e-401e-9144-d4aa3983a921 \
  --konnect-token spat_YOUR_TOKEN_HERE
```

### Cleanup

Remove all deployed resources:

```bash
./cleanup-zone.sh --zone-name zone1
```

To keep secrets for faster redeployment:

```bash
./cleanup-zone.sh --zone-name zone1 --keep-secrets
```

### Script Options

#### deploy-zone.sh

**Required:**
- `--zone-name NAME` - Zone identifier (e.g., zone1, us-east, production)
- `--kds-address ADDR` - Konnect KDS endpoint
- `--cp-id ID` - Konnect CP ID
- `--konnect-token TOKEN` - Konnect authentication token

**Optional:**
- `--license-file PATH` - Kong Mesh license (not needed for Konnect)
- `--vpc-cidr CIDR` - VPC CIDR block (default: 10.0.0.0/16)
- `--subnet1-cidr CIDR` - Subnet 1 CIDR (default: 10.0.0.0/24)
- `--subnet2-cidr CIDR` - Subnet 2 CIDR (default: 10.0.1.0/24)
- `--region REGION` - AWS region (default: us-east-2)
- `--skip-demo` - Skip demo apps
- `--skip-ingress` - Skip zone ingress

#### cleanup-zone.sh

**Required:**
- `--zone-name NAME` - Zone to cleanup

**Optional:**
- `--region REGION` - AWS region (default: us-east-2)
- `--keep-secrets` - Preserve secrets for redeployment
- `--skip-demo` - Skip demo cleanup (if not deployed)
- `--skip-ingress` - Skip ingress cleanup (if not deployed)

---

## Manual Deployment

The example deployment consists of CloudFormation stacks for setting up the mesh:

- VPC & ECS cluster stack
- Kong Mesh CP stack

and two stacks for launching the demo.

### Workload identity

The `kuma-dp` container will use the identity of the ECS task to
authenticate with the Kuma control plane.

To enable this functionality, note that
[we set the following `kuma-cp` options via environment variables](./deploy/controlplane.yaml#L334-L337):

```yaml
- Name: KUMA_DP_SERVER_AUTHN_DP_PROXY_TYPE
  Value: aws-iam
- Name: KUMA_DP_SERVER_AUTHN_ZONE_PROXY_TYPE
  Value: aws-iam
- Name: KUMA_DP_SERVER_AUTHN_ENABLE_RELOADABLE_TOKENS
  Value: "true"
```

We also add the following to tell the CP to only allow identities for certain
accounts:

```yaml
- Name: KMESH_AWSIAM_AUTHORIZEDACCOUNTIDS
  Value: !Ref AWS::AccountId # this tells the CP which accounts can be used by DPs to authenticate
```

The `kuma-cp` task role also needs permissions to call `iam:GetRole` on any `kuma-dp` task roles. Add the following to your `kuma-cp` task role policy:

```yaml
- PolicyName: get-dataplane-roles
  PolicyDocument:
    Statement:
      - Effect: Allow
        Action:
          - iam:GetRole
        Resource:
          - *
```

and we [add the following option to the `kuma-dp` container command](./deploy/counter-demo/demo-app.yaml#L251):

```yaml
- --auth-type=aws
```

In these examples, the [ECS task IAM role has the `kuma.io/service` tag set](./deploy/counter-demo/demo-app.yaml#L126-L128)
to the name of the service the workload is running under:

```yaml
Tags:
  - Key: kuma.io/service
    Value: !FindInMap [Config, Workload, Name]
```

### Setup

You'll need to have the [Kong Mesh CLI (`kumactl`)
installed](https://docs.konghq.com/mesh/1.5.x/install/) as well as the [AWS
CLI](https://aws.amazon.com/cli/) setup on the machine you're deploying from.

Check the [example IAM policy in this repo](./policy.json) for permissions
sufficient to deploy everything in this repository.

### VPC

The VPC stack sets up our VPC, adds subnets, sets up routing and private DNS and creates a load balancer.
It also provisions the ECS cluster and corresponding IAM roles.

```
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-vpc \
    --template-file deploy/vpc.yaml
```

### Control Plane

The Kong Mesh CP stack launches Kong Mesh in standalone mode with an Aurora backend, fronted by an AWS Network Load Balancer.

#### License

The first step is to add your Kong Mesh license to AWS Secrets Manager. Assuming
your license file is at `license.json`:

```
LICENSE_SECRET=$(
  aws secretsmanager create-secret \
      --name ecs-demo/KongMeshLicense --description "Secret containing Kong Mesh license" \
      --secret-string file://license.json \
    | jq -r .ARN)
```

#### TLS

We need to provision TLS certificates for the control plane to use for both external
traffic (port `5682`) and proxy to control plane traffic (port `5678`), both of
which are protected by TLS.

In a production scenario, you'd have a static domain name to point to the load balancer
and a PKI or AWS Certificate Manager for managing TLS certificates.

In this walkthrough, we'll use the DNS name provisioned for the load balancer by AWS and use
`kumactl` to generate some TLS certificates.

##### CP address

The load balancer's DNS name is exported from our VPC stack and the HTTPS (`5682`) endpoints
are exposed:

```
CP_ADDR=$(aws cloudformation describe-stacks --stack-name ecs-demo-vpc \
  | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "ExternalCPAddress") | .OutputValue')
```

##### Certificates

`kumactl` provides a utility command for generating certificates. The
certificates will have two SANs. One is the DNS name of our load balancer and
the other is the internally-routable, static name we provision via ECS Service
Discovery for our data planes.

```
kumactl generate tls-certificate --type=server --hostname ${CP_ADDR} --hostname controlplane.kongmesh
```

We now have a `key.pem` and `cert.pem` and we'll save both of them as AWS secrets.

```
TLS_KEY=$(
  aws secretsmanager create-secret \
  --name ecs-demo/CPTLSKey \
  --description "Secret containing TLS private key for serving control plane traffic" \
  --secret-string file://key.pem \
  | jq -r .ARN)
TLS_CERT=$(
  aws secretsmanager create-secret \
  --name ecs-demo/CPTLSCert \
  --description "Secret containing TLS certificate for serving control plane traffic" \
  --secret-string file://cert.pem \
  | jq -r .ARN)
```

##### Konnect

If you are deploying a zone that connects to a global control plane on Konnect, please switch `Environment` to **Universal** in the zone creation wizard, extract and copy these items:

1. the KDS sync endpoint of your global control plane (from section **Connect Zone**, under field path `multizone.zone.globalAddress`)
2. the id of your global control plane  (from section **Connect Zone**, under field path `kmesh.multizone.zone.konnect.cpId`)
3. the authentication token  (from section **Save token**, line 2)

Export them to variables and files:

```
# sample value: grpcs://us.mesh.sync.konghq.com:443
KDS_ADDR=<your global KDS endpoints>

# sample value: 61e5904f-bc3e-401e-9144-d4aa3983a921
CP_ID=<your CP ID here>

# sample value: spat_7J9SN9TKaeg6Uf3fr7Ms1sCuJ9NUbF4AwXCJlfA7QXJzxM7wg
echo  "<your auth token here>" > konnect-cp-token
CP_TOKEN_SECRET=$(
  aws secretsmanager create-secret \
      --name ecs-demo/global-cp-token --description "Secret holding the global control plane token on Konnect" \
      --secret-string file://konnect-cp-token \
    | jq -r .ARN)
```

And make sure you attached the exported variables to the stack deployment command below.

#### Deploy stack

```
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-kong-mesh-cp \
    --parameter-overrides VPCStackName=ecs-demo-vpc \
      LicenseSecret=${LICENSE_SECRET} \
      ServerKeySecret=${TLS_KEY} \
      ServerCertSecret=${TLS_CERT} \
    --template-file deploy/controlplane.yaml
```

If you are deploying a zone that connects to Konnect, please also attach the following parameters:

```
      ZoneName=ecs-demo \
      GlobalKDSAddress=${KDS_ADDR} \
      GlobalCPTokenSecret=${CP_TOKEN_SECRET}  \
      KonnectCPId=${CP_ID}  \
```

The ECS task fetches an admin API token and saves it in an AWS secret.

#### kumactl

Let's fetch the admin token from that secret:

```
TOKEN_SECRET_ARN=$(aws cloudformation describe-stacks --stack-name ecs-demo-kong-mesh-cp \
  | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "APITokenSecret") | .OutputValue')
```

Using those two pieces of information we can fetch the admin token and set up `kumactl`:

```
TOKEN=$(aws secretsmanager get-secret-value --secret-id ${TOKEN_SECRET_ARN} \
  | jq -r .SecretString)
kumactl config control-planes add \
  --name=ecs --address=https://${CP_ADDR}:5682 --overwrite --auth-type=tokens \
  --auth-conf token=${TOKEN} \
  --ca-cert-file cert.pem
```

If you are deploying a zone that connects to Konnect, please follow instructions on Konnect to connect your kumactl to the global control plane.

#### GUI

We can also open the Kong Mesh GUI at `https://${CP_ADDR}:5682/gui` (you'll need to
force the browser to accept the self-signed certificate).

We now have our control plane running and can begin deploying applications!

### Demo app

We can now launch our app components and the workload identity feature will
handle authentication with the control plane.

```
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-redis \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/counter-demo/redis.yaml
```

```
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-demo-app \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/counter-demo/demo-app.yaml
```

See below under [Usage](#Usage) for more about how communcation between these
two services works and how to configure it.

The `demo-app` stack exposes the server on port `80` of the NLB so
our app is now running and accessible `http://${CP_ADDR}:80`.

### Zone Ingress (for multi-zone deployments)

For zone-to-zone communication in a multi-zone mesh, deploy the zone ingress:

```
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-demo-ingress \
    --parameter-overrides VPCStackName=ecs-demo-vpc CPStackName=ecs-demo-kong-mesh-cp \
    --template-file deploy/ingress.yaml
```

The zone ingress enables dataplanes in this zone to be accessible from other zones in the mesh.

### Deploying Multiple Zones

To deploy multiple ECS zones in the same account/region for a multi-zone mesh:

1. Each zone needs its own VPC stack with unique CIDR ranges and zone identifier:

```bash
# Zone 1
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone1-vpc \
    --parameter-overrides ZoneIdentifier=zone1 VpcCIDR=10.0.0.0/16 PublicSubnet1CIDR=10.0.0.0/24 PublicSubnet2CIDR=10.0.1.0/24 \
    --template-file deploy/vpc.yaml

# Zone 2
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone2-vpc \
    --parameter-overrides ZoneIdentifier=zone2 VpcCIDR=10.1.0.0/16 PublicSubnet1CIDR=10.1.0.0/24 PublicSubnet2CIDR=10.1.1.0/24 \
    --template-file deploy/vpc.yaml
```

2. Deploy control planes for each zone, connected to Konnect:

```bash
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
```

3. Deploy zone ingress for each zone (required for inter-zone communication):

```bash
# Zone 1 Ingress
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone1-ingress \
    --parameter-overrides VPCStackName=ecs-zone1-vpc CPStackName=ecs-zone1-kong-mesh-cp \
    --template-file deploy/ingress.yaml

# Zone 2 Ingress
aws cloudformation deploy \
    --capabilities CAPABILITY_IAM \
    --stack-name ecs-zone2-ingress \
    --parameter-overrides VPCStackName=ecs-zone2-vpc CPStackName=ecs-zone2-kong-mesh-cp \
    --template-file deploy/ingress.yaml
```

4. Deploy applications to each zone using the respective VPC and CP stack names.

### Cleanup

To cleanup the resources we created you can execute the following:

```
aws cloudformation delete-stack --stack-name ecs-demo-demo-app
aws cloudformation delete-stack --stack-name ecs-demo-redis
aws cloudformation delete-stack --stack-name ecs-demo-ingress
aws cloudformation delete-stack --stack-name ecs-demo-kong-mesh-cp
aws secretsmanager delete-secret --secret-id ${TLS_CERT}
aws secretsmanager delete-secret --secret-id ${TLS_KEY}
aws secretsmanager delete-secret --secret-id ${LICENSE_SECRET}
aws cloudformation delete-stack --stack-name ecs-demo-vpc
```

### Further steps

#### Admin token

The control plane ECS task saves the generated admin token to an AWS secret.
After we have accessed the secret, we can remove the final two containers in our control plane task.

## Usage

### Dynamic Outbounds with Route53

This repository uses **dynamic outbounds** via Route53 integration, which automatically
discovers and configures service endpoints without requiring manual outbound configuration.

The dataplanes use the `--bind-outbounds` flag (see [demo-app.yaml](./deploy/counter-demo/demo-app.yaml#L268))
which enables automatic service discovery. Services can be reached via the mesh DNS:

- `<service-name>.mesh.local:8080` - for services in the local zone
- For cross-zone communication, the mesh automatically routes through zone ingress gateways

The control plane is configured with Route53 integration (see [controlplane.yaml](./deploy/controlplane.yaml#L390-L394)):
- `KMESH_RUNTIME_AWS_ROUTE53_ENABLED=true`
- Automatic DNS record management in the private hosted zone

This eliminates the need to manually list outbound services in the Dataplane specification,
as was required in older versions of Kong Mesh on ECS.

### Service Communication Example

In the demo app, the frontend communicates with Redis simply by:
- Setting `REDIS_HOST=redis.mesh.local` and `REDIS_PORT=8080` (see [demo-app.yaml](./deploy/counter-demo/demo-app.yaml#L216-L218))
- The mesh automatically resolves and routes the traffic via Envoy sidecars
- No manual outbound configuration needed in the Dataplane template

## CI

This repository includes a [GitHub Workflow](.github/workflows/nightly.yaml)
that executes the above steps and tests that the demo works every night.

### Accessing the containers

You can use ECS exec to get a shell to one of the containers to debug issues.
Given a task ARN and a cluster name:

```
aws ecs execute-command --cluster ${ECS_CLUSTER_NAME} \
          --task ${ECS_TASK_ARN} \
          --container workload \
          --interactive \
          --command "/bin/sh"
```

### Failures

Note that if the job fails, any CloudFormation stacks created during the failed
run are not deleted. The next GH workflow run will not succeed unless all stacks
from previous runs are deleted. This means any `ecs-ci-*` stacks need to be
manually deleted in the nightly AWS account in the event of a workflow run
failure.

In case of failure, check the Events of the failed Cloudformation stack.
For example if an ECS service fails to create, you can look at the
failed/deleted ECS tasks for more information.
