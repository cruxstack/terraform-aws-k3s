# terraform-aws-k3s

## Overview

This module provisions a self-managed K3s cluster on AWS EC2, eliminating the
$300/month EKS control-plane fee and giving you full control over node sizing,
scaling, and networking. All nodes bootstrap themselves without external
orchestration or SSH access. In just a few lines of Terraform, you get:

- **Automated leader election**
  Server nodes automatically elect a leader to initialize the control plane.
- **Kubeconfig in SSM**
  The leader publishes its kubeconfig to SSM so you can fetch it securely and
  start using kubectl immediately.
- **Auto-joining agents**
  Worker (agent) nodes wait for the control plane to be ready, then join
  automatically without manual intervention.
- **Minimal IAM footprint**
  Nodes receive only the permissions they need—SSM parameter access, EC2
  describe, self-termination, and CloudWatch Logs.
- **Built-in CloudWatch logging**
  Every node installs the CloudWatch Agent to stream EC2 instance logs to a
  dedicated log group (does not include pod logs). Retention is configurable.
- **Optional Elastic IP support**
  If enabled, EIPs are allocated and attached to server nodes via a companion
  EIP manager module.
- **Single shared security group**
  All servers and agents share one security group. Only port 6443 is exposed
  to your admin CIDRs; intra-cluster traffic is unrestricted.

## Why use this instead of EKS?

- **Avoid fixed control plane cost**
  EKS control plane alone is $300/month. With this module, you pay only for
  the EC2 instances you launch.
- **Simplified, lean setup**
  A single EC2 instance can stand up a full K3s control plane (embedded etcd).
  Perfect for dev/staging, small teams, or cost-sensitive workloads.
- **Hands-on flexibility**
  You choose instance types, replica counts, spot vs on-demand, tagging, and
  scaling. Updates and upgrades are fully under your control.

## Basic Usage

```hcl
module "k3s_cluster" {
  source  = "cruxstack/k3s/aws"
  version = "x.x.x"

  name                    = "example"
  k3s_admin_allowed_cidrs = ["x.x.x.x/32"]

  k3s_server_instances = {
    count            = 1
    assign_public_ip = true
    vpc_subnet_ids   = ["subnet-0abcd1234efgh5678"]
  }
}
```

Fetch the kubeconfig:

```bash
aws ssm get-parameter \
  --name "/k3s-cluster/server/kubeconfig" \
  --with-decryption \
  --region us-east-1 \
  --query "Parameter.Value" --output text \
  > kubeconfig.yaml

export KUBECONFIG=./kubeconfig.yaml
kubectl get nodes
```

## Inputs

| Name                      | Description                                                     | Type                                                                                                                                                                                                                             | Default          |
| ------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| `k3s_server_instances`    | Controls number/type of K3s servers; EIP support; subnets.      | `<pre>object({<br>  count: number<br>  key\_name: string<br>  vpc\_subnet\_ids: list(string)<br>  assign\_public\_ip: bool<br>  eip\_enabled: bool<br>  types: list(object({type\:string,weight\:number}))<br>})</pre>           | `{ count=1, … }` |
| `k3s_agent_instances`     | Controls number/type of K3s agents; spot settings; subnets.     | `<pre>object({<br>  count: number<br>  key\_name: string<br>  vpc\_subnet\_ids: list(string)<br>  spot: object({enabled\:bool,allocation\_strategy\:string})<br>  types: list(object({type\:string,weight\:number}))<br>})</pre> | `{ count=0, … }` |
| `k3s_version`             | K3s version (“stable”, “latest”, or literal).                   | `string`                                                                                                                                                                                                                         | `"stable"`       |
| `k3s_admin_allowed_cidrs` | CIDRs allowed to reach API server (port 6443).                  | `list(string)`                                                                                                                                                                                                                   | `[]`             |
| `ssm_param_namespace`     | Base path for cluster SSM parameters (init-status, kubeconfig). | `string`                                                                                                                                                                                                                         | `"/k3s-cluster"` |
| `ssm_sessions`            | Enable SSM Session Manager logging and specify S3 bucket.       | `object({enabled:bool,logs_bucket_name:string})`                                                                                                                                                                                 | `{}`             |
| `logs_group_retention`    | Days to retain CloudWatch logs.                                 | `number`                                                                                                                                                                                                                         | `90`             |
| `vpc_security_group_ids`  | Extra security group IDs to attach to each node.                | `list(string)`                                                                                                                                                                                                                   | `[]`             |

*All standard `cloudposse/label/null` inputs are also accepted.*


## Outputs

| Name                          | Description                                                                       |
| ----------------------------- | --------------------------------------------------------------------------------- |
| `k3s_kubeconfg_ssm_parameter` | SSM path where kubeconfig is published (e.g. `"/k3s-cluster/server/kubeconfig"`). |
| `security_group_id`           | ID of the security group used by all K3s instances.                               |
| `security_group_name`         | Name of that security group.                                                      |

