locals {
  enabled       = module.this.enabled
  name_fallback = "k3s-cluster-${random_string.k3s_cluster_random_suffix.result}"
  name          = coalesce(module.this.name, var.name, local.name_fallback)

  aws_account_id  = one(data.aws_caller_identity.current.*.id)
  aws_region_name = one(data.aws_region.current.*.name)
  aws_partition   = one(data.aws_partition.current.*.partition)

  aws_image_id          = local.enabled ? data.aws_ssm_parameter.linux_ami[0].value : ""
  aws_instance_vpc_id   = one(data.aws_subnet.lookup.*.vpc_id)
  aws_instance_userdata = base64encode(local.enabled ? data.template_cloudinit_config.this[0].rendered : "")

  dns_enabled        = local.enabled && local.eip_enabled && var.dns.enabled
  dns_names          = var.dns.names
  dns_ttl            = var.dns.ttl
  dns_parent_zone_id = var.dns.parent_zone_id

  eip_enabled           = local.k3s_server_instances.eip_enabled
  eip_count             = local.eip_enabled ? local.k3s_server_instances.count : 0
  eip_manager_key_name  = "aws-eip-pool"
  eip_manager_key_value = module.k3s_label.id
  eip_public_ips        = aws_eip.this.*.public_ip

  irsa_enabled           = local.enabled && var.aws_irsa.enabled
  irsa_issuer_url        = module.irsa.issuer_url
  irsa_bucket_arn        = module.irsa.bucket_arn
  irsa_bucket_name       = module.irsa.bucket_name
  irsa_oidc_provider_arn = module.irsa.oidc_provider_arn
  irsa_smoke_enabled     = local.irsa_enabled

  k3s_version          = var.k3s_version
  k3s_cluster_token    = local.enabled ? random_password.k3s_cluster_token[0].result : ""
  k3s_cluster_ips      = [for x in aws_eip.this : x.public_ip]
  k3s_server_instances = var.k3s_server_instances
  k3s_agent_instances  = var.k3s_agent_instances

  ssm_param_namespace = "/${trim(coalesce(var.ssm_param_namespace, "/k3s-cluster/${local.name}"), "/")}"

  ssm_sessions = {
    enabled          = var.ssm_sessions.enabled
    logs_bucket_name = try(coalesce(var.ssm_sessions.logs_bucket_name, var.logs_bucket_name), "")
  }
}

data "aws_caller_identity" "current" {
  count = local.enabled ? 1 : 0
}

data "aws_partition" "current" {
  count = local.enabled ? 1 : 0
}

data "aws_region" "current" {
  count = local.enabled ? 1 : 0
}

# ================================================================== cluster ===

module "k3s_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  name    = local.name
  context = module.this.context
}

# only appliable if name variable was not set
resource "random_string" "k3s_cluster_random_suffix" {
  length  = 6
  special = false
  upper   = false
}

# ------------------------------------------------------------------- server ---

module "k3s_server_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["server"]
  context    = module.k3s_label.context
}

module "k3s_servers" {
  source  = "cloudposse/ec2-autoscale-group/aws"
  version = "0.41.0"

  image_id                = local.aws_image_id
  instance_type           = local.k3s_server_instances.types[0].type
  health_check_type       = "EC2"
  user_data_base64        = local.aws_instance_userdata
  force_delete            = true
  disable_api_termination = false
  update_default_version  = true
  launch_template_version = "$Latest"

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  iam_instance_profile_name               = local.enabled ? resource.aws_iam_instance_profile.this[0].id : null
  key_name                                = local.k3s_server_instances.key_name
  metadata_http_tokens_required           = true
  metadata_instance_metadata_tags_enabled = true

  autoscaling_policies_enabled      = false
  desired_capacity                  = local.k3s_server_instances.count
  min_size                          = local.k3s_server_instances.count
  max_size                          = local.k3s_server_instances.count + max(floor(local.k3s_server_instances.count * 0.25), 2)
  wait_for_capacity_timeout         = "300s"
  tag_specifications_resource_types = ["instance", "volume"]

  mixed_instances_policy = {
    instances_distribution = {
      on_demand_base_capacity                  = 100
      on_demand_percentage_above_base_capacity = 100 # spot disabled for servers
      on_demand_allocation_strategy            = "prioritized"
      spot_allocation_strategy                 = "capacity-optimized"
      spot_instance_pools                      = 0
      spot_max_price                           = ""
    }
    override = [for x in local.k3s_server_instances.types : { instance_type = x.type, weighted_capacity = x.weight }]
  }

  associate_public_ip_address = local.eip_enabled ? false : local.k3s_server_instances.assign_public_ip
  subnet_ids                  = local.k3s_server_instances.vpc_subnet_ids
  security_group_ids          = concat([module.security_group.id], var.vpc_security_group_ids)

  tags = merge(
    module.k3s_label.tags,
    { Name = module.k3s_server_label.id },
    { k3s-cluster = module.k3s_label.id },
    { k3s-role = "server" },
    local.eip_enabled ? { (local.eip_manager_key_name) = local.eip_manager_key_value } : {},
  )

  context = module.k3s_server_label.context

  depends_on = [
    aws_eip.this,
    module.eip_manager,
  ]
}

# -------------------------------------------------------------------- agent ---

module "k3s_agent_label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["agent"]
  context    = module.k3s_label.context
}

module "k3s_agents" {
  source  = "cloudposse/ec2-autoscale-group/aws"
  version = "0.41.0"

  image_id                = local.aws_image_id
  instance_type           = local.k3s_agent_instances.types[0].type
  health_check_type       = "EC2"
  user_data_base64        = local.aws_instance_userdata
  force_delete            = true
  disable_api_termination = false
  update_default_version  = true
  launch_template_version = "$Latest"

  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      min_healthy_percentage = 100
      max_healthy_percentage = 200
    }
  }

  iam_instance_profile_name               = local.enabled ? resource.aws_iam_instance_profile.this[0].id : null
  key_name                                = local.k3s_agent_instances.key_name
  metadata_http_tokens_required           = true
  metadata_instance_metadata_tags_enabled = true

  autoscaling_policies_enabled      = false
  desired_capacity                  = local.k3s_agent_instances.count
  min_size                          = local.k3s_agent_instances.count
  max_size                          = local.k3s_agent_instances.count + max(floor(local.k3s_agent_instances.count * 0.25), 2)
  max_instance_lifetime             = "604800"
  wait_for_capacity_timeout         = "300s"
  tag_specifications_resource_types = ["instance", "volume", "spot-instances-request"]

  mixed_instances_policy = {
    instances_distribution = {
      on_demand_base_capacity                  = local.k3s_agent_instances.spot.enabled ? 0 : 100
      on_demand_percentage_above_base_capacity = local.k3s_agent_instances.spot.enabled ? 0 : 100
      on_demand_allocation_strategy            = "prioritized"
      spot_allocation_strategy                 = local.k3s_agent_instances.spot.allocation_strategy
      spot_instance_pools                      = 0
      spot_max_price                           = ""
    }
    override = [for x in local.k3s_agent_instances.types : { instance_type = x.type, weighted_capacity = x.weight }]
  }

  associate_public_ip_address = false
  subnet_ids                  = coalesce(local.k3s_agent_instances.vpc_subnet_ids, local.k3s_server_instances.vpc_subnet_ids)
  security_group_ids          = concat([module.security_group.id], var.vpc_security_group_ids)

  tags = merge(
    module.k3s_agent_label.tags,
    { Name = module.k3s_agent_label.id },
    { k3s-cluster = module.k3s_label.id },
    { k3s-role = "agent" }
  )

  context = module.k3s_agent_label.context

  depends_on = [
    aws_eip.this,
    module.eip_manager,
  ]
}

# ------------------------------------------------------------------- shared ---

resource "random_password" "k3s_cluster_token" {
  count = local.enabled ? 1 : 0

  length  = 32
  special = false
}

data "template_cloudinit_config" "this" {
  count = local.enabled ? 1 : 0

  gzip          = true
  base64_encode = true

  part {
    content_type = "text/x-shellscript"
    content      = file("${path.module}/assets/provision.sh")
  }

  part {
    content_type = "text/cloud-config"
    content = templatefile("${path.module}/assets/cloud-config.yaml", {
      cloudwatch_agent_config_encoded = base64encode(templatefile("${path.module}/assets/cloudwatch-agent-config.json", {
        log_group_name = aws_cloudwatch_log_group.this[0].name
      }))
    })
  }

  part {
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/assets/userdata.sh", {
      k3s_version         = local.k3s_version
      k3s_cluster_token   = local.k3s_cluster_token
      k3s_cluster_domain  = local.dns_enabled ? local.dns_names[0] : ""
      irsa_enabled        = local.irsa_enabled
      irsa_issuer_url     = local.irsa_issuer_url
      irsa_bucket_name    = local.irsa_bucket_name
      ssm_param_namespace = local.ssm_param_namespace
      k3s_sa_private_key  = base64encode(module.irsa.key.private_key)
      k3s_sa_public_key   = base64encode(module.irsa.key.public_key)
    })
  }
}

resource "aws_cloudwatch_log_group" "this" {
  count = local.enabled ? 1 : 0

  name              = module.k3s_label.id
  retention_in_days = var.logs_group_retention
  tags              = module.k3s_label.tags
}

# =============================================================== networking ===

module "security_group" {
  source  = "cloudposse/security-group/aws"
  version = "2.2.0"

  vpc_id                     = local.aws_instance_vpc_id
  allow_all_egress           = true
  preserve_security_group_id = true

  rules = concat(
    [{
      key                      = "i-inclusion"
      description              = "allow traffic from others in security-group"
      type                     = "ingress"
      protocol                 = "-1"
      from_port                = 0
      to_port                  = 0
      cidr_blocks              = []
      source_security_group_id = null
      self                     = true
    }],
    var.vpc_security_group_managed_rules.http.enabled ? [{
      key                      = "i-web-http"
      description              = "allow web (http) traffic"
      type                     = "ingress"
      protocol                 = "TCP"
      from_port                = 80
      to_port                  = 80
      cidr_blocks              = var.vpc_security_group_managed_rules.http.cidrs
      source_security_group_id = null
      self                     = false
    }] : [],
    var.vpc_security_group_managed_rules.https.enabled ? [{
      key                      = "i-web-https"
      description              = "allow web (https) traffic"
      type                     = "ingress"
      protocol                 = "TCP"
      from_port                = 443
      to_port                  = 443
      cidr_blocks              = var.vpc_security_group_managed_rules.https.cidrs
      source_security_group_id = null
      self                     = false
    }] : [],
    length(var.k3s_admin_allowed_cidrs) > 0 ? [{
      key                      = "i-control"
      description              = "allow traffic to k8s control plane"
      type                     = "ingress"
      protocol                 = "-1"
      from_port                = 6443
      to_port                  = 6443
      cidr_blocks              = var.k3s_admin_allowed_cidrs
      source_security_group_id = null
      self                     = false
    }] : []
  )

  tags    = merge(module.k3s_label.tags, { Name = module.k3s_label.id }, {})
  context = module.k3s_label.context
}

# --------------------------------------------------------------------- eips ---

resource "aws_eip" "this" {
  count = local.eip_count

  tags = merge(
    module.k3s_label.tags,
    { "Name" = module.k3s_label.id },
    { (local.eip_manager_key_name) = local.eip_manager_key_value },
  )

  depends_on = [
    module.eip_manager
  ]
}

module "eip_manager" {
  source  = "cruxstack/eip-manager/aws"
  version = "0.3.0"

  enabled         = local.eip_enabled
  attributes      = ["eip-manager"]
  pool_tag_key    = local.eip_manager_key_name
  pool_tag_values = [local.eip_manager_key_value]

  context = module.k3s_label.context
}

# ---------------------------------------------------------------------- dns ---

resource "aws_route53_record" "this" {
  for_each = toset(local.dns_names)

  zone_id         = local.dns_parent_zone_id
  name            = each.key
  type            = "A"
  allow_overwrite = true

  ttl     = local.dns_ttl
  records = local.eip_public_ips
}

# ====================================================================== iam ===

resource "aws_iam_instance_profile" "this" {
  count = local.enabled ? 1 : 0

  name = module.k3s_label.id
  role = aws_iam_role.this[0].name
}

resource "aws_iam_role" "this" {
  count = local.enabled ? 1 : 0

  name                 = module.k3s_label.id
  description          = ""
  max_session_duration = "3600"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["ec2.amazonaws.com"] }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = module.k3s_label.tags
}

resource "aws_iam_role_policy_attachment" "this" {
  count = local.enabled ? 1 : 0

  role       = resource.aws_iam_role.this[0].name
  policy_arn = resource.aws_iam_policy.this[0].arn
}

resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  count = local.enabled ? 1 : 0

  role       = resource.aws_iam_role.this[0].name
  policy_arn = "arn:${local.aws_partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "this" {
  count  = local.enabled ? 1 : 0
  policy = data.aws_iam_policy_document.this[0].json
}

data "aws_iam_policy_document" "this" {
  count = local.enabled ? 1 : 0

  statement {
    sid    = "AllowCWAgentLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:TagResource",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.this[0].arn,
      "${aws_cloudwatch_log_group.this[0].arn}:log-stream:*",
    ]
  }

  statement {
    sid    = "AllowSsmParameterNamespaceAccess"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
    ]
    resources = [
      "arn:${local.aws_partition}:ssm:${local.aws_region_name}:${local.aws_account_id}:parameter/${trimprefix(local.ssm_param_namespace, "/")}/*",
    ]
  }

  statement {
    sid    = "AllowWriteOidcDocs"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      local.irsa_bucket_arn,
      "${local.irsa_bucket_arn}/*",
    ]
  }

  statement {
    sid    = "AllowEc2DescribeInstances"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEc2TerminateInstanceSelf"
    effect = "Allow"
    actions = [
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:InstanceId"
      values   = ["$${ec2:InstanceId}"]
    }
  }

  dynamic "statement" {
    for_each = var.ssm_sessions.enabled && var.ssm_sessions.logs_bucket_name != "" ? [true] : []

    content {
      sid    = "AllowSessionLogging"
      effect = "Allow"
      actions = [
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:PutObjectTagging",
        "s3:GetEncryptionConfiguration",
        "s3:GetBucketLocation",
      ]
      resources = [
        "arn:${local.aws_partition}:s3:::${var.ssm_sessions.logs_bucket_name}",
        "arn:${local.aws_partition}:s3:::${var.ssm_sessions.logs_bucket_name}/*",
      ]
    }
  }
}

# ==================================================================== irsa ===

module "irsa" {
  source = "./modules/irsa"

  enabled    = local.irsa_enabled
  attributes = ["oidc"]
  aws_region = local.aws_region_name

  context = module.k3s_label.context
}

module "irsa_smoke_test" {
  source = "./modules/irsa-smoke/"

  enabled           = local.irsa_smoke_enabled
  attributes        = ["smoke"]
  aws_region_name   = local.aws_region_name
  oidc_provider_arn = local.irsa_oidc_provider_arn
  issuer_url        = local.irsa_issuer_url

  context = module.this.context
}

# ================================================================== lookups ===

data "aws_subnet" "lookup" {
  count = local.enabled ? 1 : 0
  id    = local.k3s_server_instances.vpc_subnet_ids[0]
}

data "aws_ssm_parameter" "linux_ami" {
  count = local.enabled ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

