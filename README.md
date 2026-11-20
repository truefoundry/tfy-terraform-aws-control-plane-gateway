# tfy-terraform-aws-control-plane-gateway

Terraform (or OpenTofu) code that installs the TrueFoundry control plane with the AI Gateway on a new Amazon EKS cluster.

It creates:

- A VPC with private and public subnets and a NAT gateway, unless you use an existing VPC
- An EKS cluster with an initial node group and Karpenter
- IAM roles for the EBS CSI driver and the AWS Load Balancer Controller
- The control plane's PostgreSQL database (Amazon RDS or Aurora), S3 bucket and IAM role

It then installs Argo CD and the `tfy-k8s-aws-eks-inframold` chart. Inframold uses Argo CD to deploy Istio, Karpenter, the AWS Load Balancer Controller, the EBS CSI driver, metrics-server and TrueFoundry (control plane and AI Gateway).

## Prerequisites

**Tools** on the machine that runs the install:

- Terraform >= 1.10 or OpenTofu >= 1.10
- Helm >= 3.12 (Terraform runs `helm` on this machine)
- AWS CLI v2
- kubectl

**AWS:**

- An AWS CLI profile for the target account. Its IAM permissions must cover the policy in the [TrueFoundry AWS control plane docs](https://www.truefoundry.com/docs/aws-control-plane).
- An S3 bucket with versioning turned on, for the Terraform state. The state contains secrets, so restrict access to it.
- An ACM certificate, in the same region, covering the control plane hostname.
- For a new VPC: a VPC CIDR, three private subnet CIDRs (one per availability zone), and at least one public subnet CIDR. To use an existing VPC instead, see [Use an existing VPC](#use-an-existing-vpc).

**From the [installation packet](https://www.truefoundry.com/docs/platform/deploy-control-plane-and-gateway-plane#installation-packet):** `tenantName`, `tfyApiKey`, `licenseJwt` and `imagePullSecret`.

## Usage

### 1. Configure the state backend

Fill in `backend.hcl`:

```hcl
bucket       = "<state_bucket>"
key          = "truefoundry/<tenant_name>/<aws_region>/<cluster_name>/terraform.tfstate"
region       = "<aws_region>"
profile      = "<aws_profile>"
encrypt      = true
use_lockfile = true
```

### 2. Set the inputs

Fill in `terraform.tfvars`:

| Variable | Description |
|---|---|
| `tenant_name` | `tenantName` from the installation packet |
| `cluster_name` | EKS cluster name, also used as the resource prefix and load balancer name (32 characters or fewer) |
| `aws_region` | AWS region |
| `aws_profile` | AWS CLI profile |
| `aws_account_id` | AWS account ID. Terraform refuses to run against any other account. |
| `vpc_cidr` | Primary VPC CIDR |
| `availability_zones` | Exactly three availability zones |
| `private_subnets_cidrs` | Three private subnet CIDRs, one per availability zone |
| `public_subnets_cidrs` | One or more public subnet CIDRs |
| `database_engine` | `rds` (default) for Amazon RDS for PostgreSQL, or `aurora` for Amazon Aurora PostgreSQL. Set it before the first install. Changing it later replaces the database, and the existing data is not migrated. |
| `database_instance_class` | Database instance class, for example `db.t3.medium` or `db.r6g.large`. Defaults to `db.t3.medium` for `rds` and `db.r6g.large` for `aurora`. |
| `control_plane_url` | `https://<hostname>` |
| `acm_certificate_arn` | ACM certificate ARN covering the hostname |
| `load_balancer_scheme` | `internet-facing` (default) or `internal` |
| `resource_tier` | Size of the control plane and AI Gateway: `small` (development and testing), `medium` (default, small production workloads) or `large` (large production workloads) |

Optional: `tags` (extra tags on all resources) and `argocd_chart_version` (default `10.10.5`).

#### Use an existing VPC

To install into an existing VPC, replace `vpc_cidr`, `availability_zones`, `private_subnets_cidrs` and `public_subnets_cidrs` in `terraform.tfvars` with the IDs of the VPC and its subnets:

```hcl
vpc_id              = "<vpc_id>"
private_subnets_ids = ["<private_subnet_id_1>", "<private_subnet_id_2>", "<private_subnet_id_3>"]
public_subnets_ids  = ["<public_subnet_id_1>", "<public_subnet_id_2>", "<public_subnet_id_3>"]
```

Terraform then uses these instead of creating a VPC, subnets and a NAT gateway, and takes the availability zones from the private subnets. If `load_balancer_scheme` is `internal`, `public_subnets_ids` is optional.

The VPC must have DNS hostnames and DNS resolution turned on. The private subnets must be in at least two availability zones and have outbound internet access, for example through a NAT gateway.

Tag the subnets as shown below, replacing `<cluster_name>` with your `cluster_name`. Karpenter and the AWS Load Balancer Controller find the subnets by these tags, and `terraform plan` fails if any are missing.

| Subnets | Tags |
|---|---|
| Private | `kubernetes.io/cluster/<cluster_name>`: `shared`<br>`subnet`: `private`<br>`kubernetes.io/role/internal-elb`: `1` |
| Public | `kubernetes.io/cluster/<cluster_name>`: `shared`<br>`subnet`: `public`<br>`kubernetes.io/role/elb`: `1` |

### 3. Export the secrets

Pass the secrets as environment variables, not in `terraform.tfvars`:

```bash
export TF_VAR_tfy_api_key='<tfyApiKey from the installation packet>'
export TF_VAR_truefoundry_license_jwt='<licenseJwt from the installation packet>'
export TF_VAR_truefoundry_image_pull_config_json='<imagePullSecret from the installation packet>'
```

Terraform passes `licenseJwt` to inframold, and the TrueFoundry chart stores it in the `truefoundry-creds` secret as `LICENSE_JWT`.

Use `imagePullSecret` exactly as it appears in the installation packet. It is already base64-encoded. A decoded JSON value creates an invalid image pull secret, and the TrueFoundry images fail to pull.

### 4. Install

```bash
export AWS_PROFILE=<aws_profile>

terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
terraform apply tfplan
```

With OpenTofu, replace `terraform` with `tofu`.

The apply takes a while. If the Argo CD or inframold step fails with `Unauthorized`, the EKS token expired during the apply. Run `terraform apply` again.

### 5. Verify

```bash
aws eks update-kubeconfig --name <cluster_name> --region <aws_region>

kubectl -n argocd get applications
kubectl -n truefoundry get pods
kubectl -n truefoundry describe secret truefoundry-creds
kubectl top nodes
```

All Argo CD applications should be `Synced` and `Healthy`, and the pods in `truefoundry` should be `Running`. The `Data` section of the `truefoundry-creds` secret should list `LICENSE_JWT`. `kubectl top nodes` returning numbers confirms metrics-server is working. The AI Gateway's autoscaling depends on it.

### 6. Point DNS at the load balancer

Get the load balancer hostname:

```bash
kubectl -n istio-system get svc tfy-istio-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a DNS record (CNAME or alias) from the control plane hostname to this hostname. Then open `control_plane_url` in a browser and log in with the `initialAdmin` credentials from the installation packet. If `load_balancer_scheme` is `internal`, the hostname must resolve, and the load balancer must be reachable, from your network.

## Change the resource tier

Terraform runs the inframold install only once. To change `resource_tier` later, update `terraform.tfvars` and run:

```bash
terraform apply -replace=module.truefoundry.null_resource.helm_install
```

This runs the inframold install again with the latest chart version, which can also upgrade TrueFoundry.

## Outputs

| Output | Description |
|---|---|
| `vpc_id` | VPC ID |
| `cluster_endpoint` | EKS API server endpoint |
| `truefoundry_bucket` | S3 bucket used by the control plane |
| `truefoundry_db_host` | Database hostname (the cluster endpoint for Aurora) |
