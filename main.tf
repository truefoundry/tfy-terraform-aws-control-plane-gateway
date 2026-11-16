provider "aws" {
  region              = var.aws_region
  profile             = var.aws_profile
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = merge({
      tenant      = var.tenant_name
      cluster     = var.cluster_name
      environment = "tfy-${var.tenant_name}"
      owner       = "truefoundry"
      terraform   = "true"
    }, var.tags)
  }
}

locals {
  control_plane_host = trimsuffix(
    replace(var.control_plane_url, "/^https?:\\/\\//", ""), "/"
  )

  eks_cluster_auth = {
    apiVersion = "v1"
    kind       = "Config"
    clusters = [{
      name = var.cluster_name
      cluster = {
        server                     = data.aws_eks_cluster.cluster.endpoint
        certificate-authority-data = data.aws_eks_cluster.cluster.certificate_authority[0].data
      }
    }]
    contexts = [{
      name = var.cluster_name
      context = {
        cluster = var.cluster_name
        user    = "aws-eks"
      }
    }]
    current-context = var.cluster_name
    users = [{
      name = "aws-eks"
      user = {
        token = data.aws_eks_cluster_auth.cluster.token
      }
    }]
  }

  kubeconfig_json = jsonencode(local.eks_cluster_auth)
}

data "aws_eks_cluster" "cluster" {
  name       = var.cluster_name
  depends_on = [module.cluster]
}

data "aws_eks_cluster_auth" "cluster" {
  name       = var.cluster_name
  depends_on = [module.cluster]
}

module "network" {
  source  = "truefoundry/truefoundry-network/aws"
  version = "0.4.4"

  aws_account_id = var.aws_account_id
  aws_region     = var.aws_region
  cluster_name   = var.cluster_name

  vpc_cidr              = var.vpc_cidr
  azs                   = var.availability_zones
  private_subnets_cidrs = var.private_subnets_cidrs
  public_subnets_cidrs  = var.public_subnets_cidrs

  flow_logs_enable = false
}

module "cluster" {
  source  = "truefoundry/truefoundry-cluster/aws"
  version = "0.8.8"

  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnets_id

  cluster_name                                  = var.cluster_name
  cluster_addons_csi_snapshot_controller_enable = true
  create_cloudwatch_log_group                   = false
  cloudwatch_log_group_retention_in_days        = 1
  cluster_endpoint_public_access                = true

  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}

module "karpenter" {
  source  = "truefoundry/truefoundry-karpenter/aws"
  version = "0.4.4"

  cluster_name                 = var.cluster_name
  controller_node_iam_role_arn = module.cluster.eks_managed_node_groups["initial"].iam_role_arn
  controller_nodegroup_name    = "initial"
}

module "csi_ebs" {
  source                = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version               = "6.4.0"
  create                = true
  use_name_prefix       = false
  name                  = "${var.cluster_name}-csi-ebs"
  policy_name           = "${var.cluster_name}-csi-ebs-policy"
  attach_ebs_csi_policy = true
  oidc_providers = {
    ebs = {
      provider_arn               = module.cluster.oidc_provider_arn
      namespace_service_accounts = ["aws-ebs-csi-driver:ebs-csi-controller-sa"]
    }
  }

  tags = {
    "terraform-module" = "csi-ebs"
    "terraform"        = "true"
    "cluster-name"     = var.cluster_name
  }
}

module "aws_load_balancer_controller" {
  source  = "truefoundry/truefoundry-load-balancer-controller/aws"
  version = "0.2.2"

  cluster_name                   = var.cluster_name
  elb_controller_use_name_prefix = false
  cluster_oidc_provider_arn      = module.cluster.oidc_provider_arn
  k8s_service_account_name       = "aws-load-balancer-controller"
  k8s_service_account_namespace  = "aws-load-balancer-controller"
}

module "tfy_control_plane" {
  source  = "truefoundry/truefoundry-control-plane/aws"
  version = "0.5.3"

  cluster_name            = var.cluster_name
  aws_account_id          = var.aws_account_id
  aws_region              = var.aws_region
  vpc_id                  = module.network.vpc_id
  cluster_oidc_issuer_url = module.cluster.cluster_oidc_issuer_url

  truefoundry_db_ingress_security_group = module.cluster.node_security_group_id
  truefoundry_db_subnet_ids             = toset(module.network.private_subnets_id)

  tags = var.tags
}

module "argocd" {
  source  = "truefoundry/truefoundry-helm/kubernetes"
  version = "0.1.5"

  depends_on = [
    module.tfy_control_plane,
    module.karpenter,
    module.csi_ebs,
    module.aws_load_balancer_controller,
  ]

  chart_name       = "argo-cd"
  repo_name        = "argo"
  repo_url         = "https://argoproj.github.io/argo-helm"
  chart_version    = var.argocd_chart_version
  create_namespace = true
  namespace        = "argocd"
  release_name     = "argocd"
  kubeconfig_json  = local.kubeconfig_json

  set_values = {
    "notifications" = { "enabled" = false }
    "dex"           = { "enabled" = false }
    "server"        = { "extraArgs" = ["--insecure", "--application-namespaces=*"] }
    "controller"    = { "extraArgs" = ["--application-namespaces=*"] }
  }
}

module "truefoundry" {
  source  = "truefoundry/truefoundry-helm/kubernetes"
  version = "0.1.5"

  depends_on = [module.argocd, module.tfy_control_plane]

  chart_name       = "tfy-k8s-aws-eks-inframold"
  release_name     = "tfy-k8s-aws-eks-inframold"
  kubeconfig_json  = local.kubeconfig_json
  create_namespace = true
  namespace        = "argocd"
  repo_name        = "truefoundry"
  repo_url         = "https://truefoundry.github.io/infra-charts"
  always_update    = false

  set_values = {
    "tenantName"      = var.tenant_name
    "controlPlaneURL" = var.control_plane_url
    "clusterName"     = var.cluster_name

    "argocd"        = { "enabled" = true }
    "metricsServer" = { "enabled" = true }

    "argoWorkflows" = { "enabled" = false }
    "argoRollouts"  = { "enabled" = false }
    "gpu"           = { "enabled" = false }
    "keda"          = { "enabled" = false }
    "kubecost"      = { "enabled" = false }
    "prometheus"    = { "enabled" = false, "config" = { "enabled" = false } }
    "tfyLogs"       = { "enabled" = false }
    "elasti"        = { "enabled" = false }

    "aws" = {
      "awsLoadBalancerController" = {
        "enabled" = true
        "roleArn" = module.aws_load_balancer_controller.elb_iam_role_arn
        "vpcId"   = module.network.vpc_id
        "region"  = var.aws_region
      }
      "karpenter" = {
        "enabled"           = true
        "clusterEndpoint"   = module.cluster.cluster_endpoint
        "instanceProfile"   = module.karpenter.karpenter_instance_profile_id
        "interruptionQueue" = module.karpenter.karpenter_sqs_name
        "defaultZones"      = var.availability_zones
      }
      "awsEbsCsiDriver" = {
        "enabled" = true
        "roleArn" = module.csi_ebs.arn
      }
      "awsEfsCsiDriver" = { "enabled" = false }
      "inferentia"      = { "enabled" = false }
    }

    "istio" = {
      "enabled" = true
      "gateway" = {
        "annotations" = {
          "service.beta.kubernetes.io/aws-load-balancer-name"                              = var.cluster_name
          "service.beta.kubernetes.io/aws-load-balancer-type"                              = "external"
          "service.beta.kubernetes.io/aws-load-balancer-scheme"                            = var.load_balancer_scheme
          "service.beta.kubernetes.io/aws-load-balancer-ssl-cert"                          = var.acm_certificate_arn
          "service.beta.kubernetes.io/aws-load-balancer-ssl-ports"                         = "https"
          "service.beta.kubernetes.io/aws-load-balancer-alpn-policy"                       = "HTTP2Preferred"
          "service.beta.kubernetes.io/aws-load-balancer-backend-protocol"                  = "tcp"
          "service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags"          = "cluster-name=${var.cluster_name},truefoundry.com/managed=true,owner=Truefoundry,application=tfy-istio-ingress"
          "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
        }
      }
      "discovery" = {
        "hub" = "gcr.io/istio-release"
      }
      "tfyGateway" = {
        "httpsRedirect" = true
      }
    }

    "truefoundry" = {
      "enabled"              = true
      "devMode"              = { "enabled" = false }
      "truefoundryBootstrap" = { "enabled" = true }

      "tfyApiKey"                      = var.tfy_api_key
      "truefoundryImagePullConfigJSON" = var.truefoundry_image_pull_config_json

      "gateway" = { "enabled" = true }

      "storageConfiguration" = {
        "awsS3BucketName" = module.tfy_control_plane.truefoundry_bucket_id
        "awsRegion"       = var.aws_region
      }
      "truefoundry_iam_role_arn_annotations" = {
        "eks.amazonaws.com/role-arn" = module.tfy_control_plane.truefoundry_iam_role_arn
      }
      "database" = {
        "host"     = module.tfy_control_plane.truefoundry_db_address
        "name"     = module.tfy_control_plane.truefoundry_db_database_name
        "username" = module.tfy_control_plane.truefoundry_db_username
        "password" = module.tfy_control_plane.truefoundry_db_password
      }
      "virtualservice" = {
        "enabled"  = true
        "hosts"    = [local.control_plane_host]
        "gateways" = ["istio-system/tfy-wildcard"]
      }
    }

    "tfyAgent" = { "enabled" = false }
  }
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "truefoundry_bucket" {
  value = module.tfy_control_plane.truefoundry_bucket_id
}

output "truefoundry_db_host" {
  value = module.tfy_control_plane.truefoundry_db_address
}
