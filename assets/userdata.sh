#!/bin/bash
set -eo pipefail

# --------------------------------------------------------- terraform inputs ---

K3S_VERSION=${k3s_version}
K3S_CLUSTER_TOKEN=${k3s_cluster_token}
SSM_PARAM_NAMESPACE=${ssm_param_namespace}

# ---------------------------------------------------------------------- fns ---

get_ec2_metadata_token() {
  local TOKEN_TTL="$1"
  [[ -z "$TOKEN_TTL" ]] && TOKEN_TTL=900
  curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: $TOKEN_TTL"
}

get_imds() {
  local IMDS_PATH="$1"
  local IMDS_TOKEN
  IMDS_TOKEN=$(get_ec2_metadata_token)
  curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    "http://169.254.169.254/latest/$IMDS_PATH"
}

get_ec2_instance_tag() {
  get_imds "meta-data/tags/instance/$1"
}

get_ec2_instance_id() {
  get_imds "meta-data/instance-id"
}

get_aws_region() {
  get_imds "dynamic/instance-identity/document" | grep -oP '"region"\s*:\s*"\K[^"]+'
}

get_ssm_param() {
  local PARAM_NAME="$1"
  aws ssm get-parameter --name "$PARAM_NAME" \
    --query 'Parameter.Value' --output text --region "$AWS_REGION" 2>/dev/null || true
}

create_ssm_param() {
  local PARAM_NAME="$1"
  local PARAM_VALUE="$2"
  local PARAM_TYPE="$3"
  [[ -z "$PARAM_TYPE" ]] && PARAM_TYPE=String
  aws ssm put-parameter --name "$PARAM_NAME" --type $PARAM_TYPE --value "$PARAM_VALUE" \
    --region "$AWS_REGION" 2>/dev/null
}

set_ssm_param() {
  local PARAM_NAME="$1"
  local PARAM_VALUE="$2"
  local PARAM_TYPE="$3"
  [[ -z "$PARAM_TYPE" ]] && PARAM_TYPE=String
  aws ssm put-parameter --name "$PARAM_NAME" --type $PARAM_TYPE --value "$PARAM_VALUE" \
    --region "$AWS_REGION" --overwrite 2>/dev/null
}

get_ec2_instance_private_ip() {
  local INSTANCE_ID="$1"
  aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text \
    --region "$AWS_REGION" 2>/dev/null
}

get_ec2_instance_public_ip() {
  local INSTANCE_ID="$1"
  aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text \
    --region "$AWS_REGION" 2>/dev/null
}

get_ec2_instance_ip() {
  local INSTANCE_ID=$1
  local INSTANCE_IP
  INSTANCE_IP=$(get_ec2_instance_public_ip "$INSTANCE_ID")
  if [[ -z "$INSTANCE_IP" || "$INSTANCE_IP" == "None" ]]; then
    INSTANCE_IP=$(get_ec2_instance_private_ip "$INSTANCE_ID")
  fi
  echo "$INSTANCE_IP"
}

terminate_ec2_instance() {
  INSTANCE_ID="$1"
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID \
    --region "$AWS_REGION"
}

get_k3s_server_private_ip() {
  aws ec2 describe-instances \
    --filters \
    "Name=tag:k3s-cluster,Values=$K3S_CLUSTER_NAME" \
    "Name=tag:k3s-role,Values=server" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[?InstanceId!=`'"$INSTANCE_ID"'`].PrivateIpAddress' \
    --output text --region "$AWS_REGION" 2>/dev/null | head -n 1
}

install_k3s() {
  local K3S_VERSION=$1
  local K3S_CLUSTER_TOKEN=$2
  local K3S_INSTALL_ARGS=$3

  # translate channel keywords
  local K3S_CHANNEL=""
  if [[ "$K3S_VERSION" == "stable" || "$K3S_VERSION" == "latest" ]]; then
    K3S_CHANNEL="$K3S_VERSION"
    K3S_VERSION=""
  fi

  curl -sfL https://get.k3s.io |
    INSTALL_K3S_CHANNEL="$K3S_CHANNEL" INSTALL_K3S_VERSION="$K3S_VERSION" K3S_TOKEN="$K3S_CLUSTER_TOKEN" \
      sh -s - $K3S_INSTALL_ARGS
}

publish_k3s_kubeconfig() {
  local PARAM_PATH="$1"
  local INSTANCE_ID="$2"
  local INSTANCE_IP
  local K3S_KUBECONFIG
  local K3S_KUBECONFIG_LOCAL_PATH="/etc/rancher/k3s/k3s.yaml"

  # ensure file exists before continuing
  for _ in {1..60}; do
    [[ -f "$K3S_KUBECONFIG_LOCAL_PATH" ]] && break
    sleep 1
  done

  INSTANCE_IP=$(get_ec2_instance_ip "$INSTANCE_ID")
  [[ -z "$INSTANCE_IP" || "$INSTANCE_IP" == "None" ]] && {
    echo "unable to resolve leader ip" >&2
    return 1
  }

  # replace server address
  K3S_KUBECONFIG=$(sed -e "s#https://.*#https://$INSTANCE_IP:6443#" "$K3S_KUBECONFIG_LOCAL_PATH")
  set_ssm_param "$PARAM_PATH" "$K3S_KUBECONFIG" SecureString
}

# ------------------------------------------------------------------- script ---

AWS_REGION=$(get_aws_region)
K3S_ROLE=$(get_ec2_instance_tag k3s-role)
K3S_CLUSTER_NAME=$(get_ec2_instance_tag k3s-cluster)
INSTANCE_ID=$(get_ec2_instance_id)
SSM_PARAM_INIT_STATUS="$SSM_PARAM_NAMESPACE/server/init-status"
SSM_PARAM_KUBECONFIG="$SSM_PARAM_NAMESPACE/server/kubeconfig"

WAIT_TIME_MAX=600 # 10 mins
WAIT_TIME_TOTAL=0

if [[ "$K3S_ROLE" == "server" ]]; then
  INSTANCE_IP=$(get_ec2_instance_ip "$INSTANCE_ID")

  if create_ssm_param "$SSM_PARAM_INIT_STATUS" "PENDING:$INSTANCE_ID"; then
    # elected as cluster leader since first to create param
    install_k3s $K3S_VERSION $K3S_CLUSTER_TOKEN "server --cluster-init --tls-san $INSTANCE_IP"
    set_ssm_param "$SSM_PARAM_INIT_STATUS" "COMPLETED:$INSTANCE_ID"
    publish_k3s_kubeconfig $SSM_PARAM_KUBECONFIG $INSTANCE_ID || true
  else
    # wait for cluster leader to complete k3s server init
    while true; do
      LEADER_STATUS_VALUE=$(get_ssm_param "$SSM_PARAM_INIT_STATUS")
      LEADER_STATUS=$(echo $LEADER_STATUS_VALUE | cut -d':' -f1)
      LEADER_INSTANCE_ID=$(echo $LEADER_STATUS_VALUE | cut -d':' -f2)
      [[ "$LEADER_STATUS" == "COMPLETED" ]] && break
      [[ "$WAIT_TIME_TOTAL" -ge "$WAIT_TIME_MAX" ]] && {
        echo "timeout waiting for cluster init" >&2
        sleep 5 # allow time to flush logs to cloudwatch
        terminate_ec2_instance $INSTANCE_ID
      }
      sleep 5
      WAIT_TIME_TOTAL=$((WAIT_TIME_TOTAL + 5))
    done

    SERVER_IP=$(get_ec2_instance_private_ip "$LEADER_INSTANCE_ID")
    [[ -z "$SERVER_IP" || "$SERVER_IP" == "None" ]] && SERVER_IP=$(get_k3s_server_private_ip)
    [[ -z "$SERVER_IP" ]] && {
      echo "server ip not found" >&2
      sleep 5 # allow time to flush logs to cloudwatch
      terminate_ec2_instance $INSTANCE_ID
    }

    install_k3s $K3S_VERSION $K3S_CLUSTER_TOKEN "server --server https://$SERVER_IP:6443 --tls-san $INSTANCE_IP"
  fi
else
  # agent logic
  while true; do
    LEADER_STATUS_VALUE=$(get_ssm_param "$SSM_PARAM_INIT_STATUS")
    LEADER_STATUS=$(echo $LEADER_STATUS_VALUE | cut -d':' -f1)
    LEADER_INSTANCE_ID=$(echo $LEADER_STATUS_VALUE | cut -d':' -f2)
    if [[ "$LEADER_STATUS" == "COMPLETED" ]]; then
      SERVER_IP=$(get_ec2_instance_private_ip "$LEADER_INSTANCE_ID")
      [[ -z "$SERVER_IP" || "$SERVER_IP" == "None" ]] && SERVER_IP=$(get_k3s_server_private_ip)
      [[ -n "$SERVER_IP" ]] && break
    fi
    [[ "$WAIT_TIME_TOTAL" -ge "$WAIT_TIME_MAX" ]] && {
      echo "timeout waiting for server ip" >&2
      sleep 5 # allow time to flush logs to cloudwatch
      terminate_ec2_instance $INSTANCE_ID
    }
    sleep 5
    WAIT_TIME_TOTAL=$((WAIT_TIME_TOTAL + 5))
  done

  install_k3s $K3S_VERSION $K3S_CLUSTER_TOKEN "agent --server https://$SERVER_IP:6443"
fi

if [[ ! -f /usr/local/bin/k3s ]]; then
  terminate_ec2_instance $INSTANCE_ID
fi
