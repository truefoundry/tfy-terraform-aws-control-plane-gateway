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
  description = "Primary CIDR block for the VPC"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones (exactly 3)"
  validation {
    condition     = length(var.availability_zones) == 3
    error_message = "Provide exactly three availability zones."
  }
}

variable "private_subnets_cidrs" {
  type        = list(string)
  description = "CIDR blocks for private subnets (one per AZ)"
}

variable "public_subnets_cidrs" {
  type        = list(string)
  description = "CIDR blocks for public subnets"
  validation {
    condition     = length(var.public_subnets_cidrs) >= 1
    error_message = "Provide at least one public subnet CIDR."
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

variable "database_engine" {
  type        = string
  description = "Engine of the control plane database: rds (Amazon RDS for PostgreSQL) or aurora (Amazon Aurora PostgreSQL)"
  default     = "rds"
  validation {
    condition     = contains(["rds", "aurora"], var.database_engine)
    error_message = "database_engine must be rds or aurora."
  }
}

variable "database_instance_class" {
  type        = string
  description = "Instance class of the control plane database. Defaults to db.t3.medium for rds and db.r6g.large for aurora."
  default     = null
  validation {
    condition     = var.database_instance_class == null || (startswith(coalesce(var.database_instance_class, "-"), "db.") && var.database_instance_class != "db.serverless")
    error_message = "database_instance_class must be a DB instance class such as db.t3.medium. db.serverless is not supported."
  }
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
