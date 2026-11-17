variable "aws_region" {
  type        = string
  description = "AWS region"
}

variable "aws_profile" {
  type        = string
  description = "AWS CLI profile"
}

variable "aws_account_id" {
  type        = string
  description = "AWS account ID"
}

variable "cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
  validation {
    condition     = length(var.cluster_name) <= 32
    error_message = "cluster_name is used as the NLB name and must be <= 32 characters."
  }
}

variable "tenant_name" {
  type        = string
  description = "TrueFoundry tenant name"
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to resources"
  default     = {}
}

variable "vpc_cidr" {
  type        = string
  description = "Primary CIDR block for the new VPC"
  default     = null
  validation {
    condition     = var.vpc_id != null || var.vpc_cidr != null
    error_message = "Set vpc_cidr, or set vpc_id to use an existing VPC."
  }
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones for the new VPC (exactly 3)"
  default     = []
  validation {
    condition     = var.vpc_id != null || length(var.availability_zones) == 3
    error_message = "Provide exactly three availability zones."
  }
}

variable "private_subnets_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the new private subnets (one per AZ)"
  default     = []
  validation {
    condition     = var.vpc_id != null || length(var.private_subnets_cidrs) > 0
    error_message = "Provide the private subnet CIDRs, or set vpc_id to use an existing VPC."
  }
}

variable "public_subnets_cidrs" {
  type        = list(string)
  description = "CIDR blocks for the new public subnets"
  default     = []
  validation {
    condition     = var.vpc_id != null || length(var.public_subnets_cidrs) >= 1
    error_message = "Provide at least one public subnet CIDR."
  }
}

variable "vpc_id" {
  type        = string
  description = "ID of an existing VPC to use instead of creating one"
  default     = null
}

variable "private_subnets_ids" {
  type        = list(string)
  description = "IDs of the existing private subnets in vpc_id"
  default     = []
  validation {
    condition     = (var.vpc_id == null) == (length(var.private_subnets_ids) == 0)
    error_message = "Set vpc_id and private_subnets_ids together to use an existing VPC."
  }
}

variable "public_subnets_ids" {
  type        = list(string)
  description = "IDs of the existing public subnets in vpc_id"
  default     = []
  validation {
    condition     = var.vpc_id == null || var.load_balancer_scheme == "internal" || length(var.public_subnets_ids) > 0
    error_message = "Set public_subnets_ids when using an existing VPC with an internet-facing load balancer."
  }
}

variable "control_plane_url" {
  type        = string
  description = "URL of the control plane, e.g. https://<hostname>"
}

variable "acm_certificate_arn" {
  type        = string
  description = "ACM certificate ARN (same region) for the control plane host"
}

variable "load_balancer_scheme" {
  type        = string
  description = "Scheme of the load balancer in front of the Istio gateway"
  default     = "internet-facing"
  validation {
    condition     = contains(["internet-facing", "internal"], var.load_balancer_scheme)
    error_message = "load_balancer_scheme must be internet-facing or internal."
  }
}

variable "argocd_chart_version" {
  type        = string
  description = "argo-cd Helm chart version"
  default     = "10.10.5"
}

variable "tfy_api_key" {
  type        = string
  description = "TrueFoundry API key"
  sensitive   = true
}

variable "truefoundry_license_jwt" {
  type        = string
  description = "TrueFoundry license JWT"
  sensitive   = true
}

variable "truefoundry_image_pull_config_json" {
  type        = string
  description = "Docker config JSON used to pull TrueFoundry images"
  sensitive   = true
}
