# ================================================================== general ===

variable "k3s_version" {
  type    = string
  default = "stable"
  validation {
    condition     = length(regex("(stable|latest|v[0-9]+\\.[0-9]+\\.[0-9]+(?:-rc[0-9]+)*\\+k3.+)", var.k3s_version)) > 0
    error_message = "version must be 'stable', 'latest', or valid literal k3s version"
  }
}

variable "k3s_admin_allowed_cidrs" {
  type        = list(string)
  description = "List of CIDR block allowed access for cluster control."
  default     = []
}

variable "k3s_oidc" {
  type = object({
    enabled             = optional(bool, false)
    test_assets_enabled = optional(bool, false)
  })
  description = "Cluster OIDC commonly used for IRSA support."
  default     = {}
}

# =========================================================== infrastructure ===

variable "k3s_agent_instances" {
  type = object({
    count          = optional(number, 0)
    key_name       = optional(string, "")
    vpc_subnet_ids = optional(list(string), [])
    spot = optional(object({
      enabled             = optional(bool, true)
      allocation_strategy = optional(string, "capacity-optimized")
    }), {})
    types = optional(list(object({
      type   = string
      weight = optional(number, 1)
    })), [{ type = "t3.small" }, { type = "t3a.small" }])
  })
  description = "Instance configuration for K3s agent instances."
  default     = {}
}

variable "k3s_server_instances" {
  type = object({
    count            = optional(number, 1)
    key_name         = optional(string, "")
    vpc_subnet_ids   = optional(list(string), [])
    assign_public_ip = optional(bool, false)
    eip_enabled      = optional(bool, false)
    types = optional(list(object({
      type   = string
      weight = optional(number, 1)
    })), [{ type = "t3.small" }, { type = "t3a.small" }])
  })
  description = "Instance configuration for K3s server instances."
  default     = {}
}

variable "logs_group_retention" {
  type        = number
  description = "Retention in day for CloudWatch Logs"
  default     = 90
}

variable "logs_bucket_name" {
  type        = string
  description = "S3 bucket for storing logs."
  default     = ""
}

variable "ssm_sessions" {
  type = object({
    enabled          = optional(bool, false)
    logs_bucket_name = optional(string, "")
  })
  description = "SSM Session Manager configuration with optional bucket for session logs."
  default     = {}
}

variable "ssm_param_namespace" {
  type    = string
  default = "/k3s-cluster"
}

# --------------------------------------------------------------- networking ---

variable "dns" {
  type = object({
    enabled          = optional(bool, false)
    parent_zone_id   = optional(string, "")
    parent_zone_name = optional(string, "")
    names            = optional(list(string), [])
    ttl              = optional(number, 300)
  })
  default = {}
}

variable "vpc_security_group_managed_rules" {
  type = object({
    http = optional(object({
      enabled = optional(bool, true)
      cidrs   = optional(list(string), ["0.0.0.0/0"])
    }), {})
    https = optional(object({
      enabled = optional(bool, true)
      cidrs   = optional(list(string), ["0.0.0.0/0"])
    }), {})
  })
  default = {}
}

variable "vpc_security_group_ids" {
  type        = list(string)
  description = "IDs of security groups to attach to the EC2 instances."
  default     = []
}

