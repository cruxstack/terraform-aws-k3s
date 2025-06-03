# terraform-aws-k3s

Provision a K3s cluster on AWS using EC2. Automatically elect a control-plane
leader to initalize the cluster, install K3s, and publish the kubeconfig back to
SSM. Optional worker (agent) nodes join automatically.

## Why K3s vs EKS

* **Lower control-plane cost**
  * EKS control-plane alone costs around $300/month before any worker nodes are
    added. With K3s on EC2, you pay only for the EC2 instances you run,
    avoiding that fixed control-plane charge.
* **Simplified setup**
  * K3s requires a single server to get a fully functional cluster, making it
    ideal for personal use, small teams, test environments, or cost-sensitive
    workloads.
* **Full flexibility**
  * You manage your own nodes directly and can tailor instance types, scaling
    policies, and networking without provider-managed constraints.

## Features

* **High-availability control plane**
  * Automatically elect a leader and initialize the cluster without manual
    intervention.
* **Optional agent Auto Scaling Group**
  * Workers join the cluster once control plane is ready; supports spot or
    on-demand instances.
* **Elastic IP support (optional)**
  * Allocate and attach stable public IPs to server instances.
* **Minimal IAM footprint**
  * EC2 role grants only the necessary permissions for SSM, CloudWatch Logs, and
    EC2 Describe.

## Basic Usage

```hcl
module "k3s_cluster" {
  source  = "cruxstack/k3s/aws"
  version = "x.x.x"

  server_instances = {
    count            = 1
    assign_public_ip = 1
    vpc_subnet_ids   = ["subnet-0abcd1234efgh5678"]
  }

  k3s_admin_allowed_cidrs = ["x.x.x.x/32"]
}
```

Fetch the kubeconfig:

```bash
aws ssm get-parameter \
  --name "/prod-k3s/server/kubeconfig" \
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
| `server_instances`        | Controls number/type of K3s servers; EIP support; subnets.      | `<pre>object({<br>  count: number<br>  key\_name: string<br>  vpc\_subnet\_ids: list(string)<br>  assign\_public\_ip: bool<br>  eip\_enabled: bool<br>  types: list(object({type\:string,weight\:number}))<br>})</pre>           | `{ count=1, … }` |
| `agent_instances`         | Controls number/type of K3s agents; spot settings; subnets.     | `<pre>object({<br>  count: number<br>  key\_name: string<br>  vpc\_subnet\_ids: list(string)<br>  spot: object({enabled\:bool,allocation\_strategy\:string})<br>  types: list(object({type\:string,weight\:number}))<br>})</pre> | `{ count=0, … }` |
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

