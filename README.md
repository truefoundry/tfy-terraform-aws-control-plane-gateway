# tfy-terraform-aws-control-plane-gateway

Terraform (or OpenTofu) code that installs the TrueFoundry control plane with the AI Gateway on a new Amazon EKS cluster.

It creates:

- A VPC with private and public subnets and a NAT gateway
- An EKS cluster with an initial node group and Karpenter
- IAM roles for the EBS CSI driver and the AWS Load Balancer Controller
- The control plane's RDS PostgreSQL database, S3 bucket and IAM role

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
- A VPC CIDR, three private subnet CIDRs (one per availability zone), and at least one public subnet CIDR.

**From the [installation packet](https://www.truefoundry.com/docs/platform/deploy-control-plane-and-gateway-plane#installation-packet):** `tenantName`, `tfyApiKey` and `imagePullSecret`.

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
| `control_plane_url` | `https://<hostname>` |
| `acm_certificate_arn` | ACM certificate ARN covering the hostname |
| `load_balancer_scheme` | `internet-facing` (default) or `internal` |

Optional: `tags` (extra tags on all resources) and `argocd_chart_version` (default `10.10.5`).

### 3. Export the secrets

Pass the secrets as environment variables, not in `terraform.tfvars`:

```bash
export TF_VAR_tfy_api_key='<tfyApiKey from the installation packet>'
export TF_VAR_truefoundry_image_pull_config_json='<imagePullSecret from the installation packet>'
```

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
kubectl top nodes
```

All Argo CD applications should be `Synced` and `Healthy`, and the pods in `truefoundry` should be `Running`. `kubectl top nodes` returning numbers confirms metrics-server is working. The AI Gateway's autoscaling depends on it.

### 6. Point DNS at the load balancer

Get the load balancer hostname:

```bash
kubectl -n istio-system get svc tfy-istio-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a DNS record (CNAME or alias) from the control plane hostname to this hostname. Then open `control_plane_url` in a browser and log in with the `initialAdmin` credentials from the installation packet. If `load_balancer_scheme` is `internal`, the hostname must resolve, and the load balancer must be reachable, from your network.

## Outputs

| Output | Description |
|---|---|
| `vpc_id` | VPC ID |
| `cluster_endpoint` | EKS API server endpoint |
| `truefoundry_bucket` | S3 bucket used by the control plane |
| `truefoundry_db_host` | RDS PostgreSQL hostname |
