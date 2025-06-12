#!/bin/bash
set -eo pipefail

# --------------------------------------------------------- terraform inputs ---

K3S_VERSION=${k3s_version}
K3S_CLUSTER_TOKEN=${k3s_cluster_token}
K3S_CLUSTER_DOMAIN=${k3s_cluster_domain}
IRSA_ENABLED=${oidc_enabled}
IRSA_BUCKET_NAME=${oidc_bucket_name}
IRSA_ISSUER_URL=${oidc_issuer_url}
SSM_PARAM_NAMESPACE=${ssm_param_namespace}

K3S_SA_PRIVATE_KEY=${k3s_sa_private_key}
K3S_SA_PUBLIC_KEY=${k3s_sa_public_key}

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

install_k3s_irsa_certs() {
  local IRSA_ISSUER_URL=$1

  { # quiet section
    K3S_SERVER_TLS_DIR=/etc/rancher/k3s/tls
    mkdir -p "$K3S_SERVER_TLS_DIR"
    pushd "$K3S_SERVER_TLS_DIR" >/dev/null
    echo "$K3S_SA_PRIVATE_KEY" | base64 -d >oidc-issuer.key
    chmod 0600 *.key
    echo "$K3S_SA_PUBLIC_KEY" | base64 -d >oidc-issuer.pub
    popd >/dev/null
  } >/dev/null 2>&1

  IRSA_ARGS=""
  IRSA_ARGS+=" --kube-apiserver-arg=api-audiences=sts.amazonaws.com"
  IRSA_ARGS+=" --kube-apiserver-arg=service-account-issuer=$IRSA_ISSUER_URL"
  IRSA_ARGS+=" --kube-apiserver-arg=service-account-key-file=$K3S_SERVER_TLS_DIR/oidc-issuer.pub"
  IRSA_ARGS+=" --kube-apiserver-arg=service-account-signing-key-file=$K3S_SERVER_TLS_DIR/oidc-issuer.key"
  IRSA_ARGS+=" --kube-apiserver-arg=service-account-issuer=k3s"
  IRSA_ARGS+=" --kube-apiserver-arg=service-account-key-file=/var/lib/rancher/k3s/server/tls/service.key"

  echo $IRSA_ARGS
}

publish_k3s_irsa_certs() {
  local IRSA_ISSUER_URL=$1
  local IRSA_BUCKET_NAME=$2

  local OIDC_TMP="/tmp/oidc"
  mkdir -p "$OIDC_TMP/.well-known"
  mkdir -p "$OIDC_TMP/openid/v1"

  local OIDC_CFG="{
    \"issuer\":\"$IRSA_ISSUER_URL\",
    \"jwks_uri\":\"$IRSA_ISSUER_URL/openid/v1/jwks\",
    \"authorization_endpoint\":\"urn:kubernetes:programmatic_authorization\",
    \"response_types_supported\":[\"id_token\"],
    \"subject_types_supported\":[\"public\"],
    \"id_token_signing_alg_values_supported\":[\"RS256\"],
    \"claims_supported\":[\"sub\",\"iss\"]
  }"
  local OIDC_JWKS
  OIDC_JWKS=$(kubectl get --raw /openid/v1/jwks | jq -c)

  echo $OIDC_CFG | jq -c >"$OIDC_TMP/.well-known/openid-configuration"
  echo $OIDC_JWKS >"$OIDC_TMP/openid/v1/jwks"
  aws s3 sync "$OIDC_TMP" "s3://$IRSA_BUCKET_NAME" --content-type "application/json" --region "$AWS_REGION"
}

publish_k3s_kubeconfig() {
  local PARAM_PATH="$1"
  local INSTANCE_ID="$2"
  local K3S_CLUSTER_HOST="$3"
  local K3S_KUBECONFIG
  local K3S_KUBECONFIG_LOCAL_PATH="/etc/rancher/k3s/k3s.yaml"

  # ensure file exists before continuing
  for _ in {1..300}; do
    [[ -f "$K3S_KUBECONFIG_LOCAL_PATH" ]] && break
    sleep 1
  done

  if [[ "$K3S_CLUSTER_HOST" == "" ]]; then
    K3S_CLUSTER_HOST=$(get_ec2_instance_ip "$INSTANCE_ID")
    [[ -z "$K3S_CLUSTER_HOST" || "$K3S_CLUSTER_HOST" == "None" ]] && {
      echo "unable to resolve leader ip" >&2
      return 1
    }
  fi

  # replace server address
  K3S_KUBECONFIG=$(sed -e "s#https://.*#https://$K3S_CLUSTER_HOST:6443#" "$K3S_KUBECONFIG_LOCAL_PATH")
  set_ssm_param "$PARAM_PATH" "$K3S_KUBECONFIG" SecureString
}

# ------------------------------------------------------------------- script ---

SETUP_WORKSPACE=/tmp/workspace

AWS_REGION=$(get_aws_region)
K3S_ROLE=$(get_ec2_instance_tag k3s-role)
K3S_CLUSTER_NAME=$(get_ec2_instance_tag k3s-cluster)
INSTANCE_ID=$(get_ec2_instance_id)
SSM_PARAM_INIT_STATUS="$SSM_PARAM_NAMESPACE/server/init-status"
SSM_PARAM_KUBECONFIG="$SSM_PARAM_NAMESPACE/server/kubeconfig"

WAIT_TIME_MAX=600 # 10 mins
WAIT_TIME_TOTAL=0

mkdir -p $SETUP_WORKSPACE
cd $SETUP_WORKSPACE

if [[ "$K3S_ROLE" == "server" ]]; then
  INSTANCE_IP=$(get_ec2_instance_ip "$INSTANCE_ID")

  K3S_TTL_SAN=$INSTANCE_IP
  if [[ "$K3S_CLUSTER_DOMAIN" != "" ]]; then
    K3S_TTL_SAN=$K3S_TTL_SAN,$INSTANCE_IP
  fi

  IRSA_ARGS=""
  if [[ "$IRSA_ENABLED" == "true" && -n "$IRSA_ISSUER_URL" ]]; then
    IRSA_ARGS=$(install_k3s_irsa_certs $IRSA_ISSUER_URL)
  fi

  if create_ssm_param "$SSM_PARAM_INIT_STATUS" "PENDING:$INSTANCE_ID"; then
    # elected as cluster leader since first to create param

    install_k3s $K3S_VERSION $K3S_CLUSTER_TOKEN "server --cluster-init --tls-san $K3S_TTL_SAN $IRSA_ARGS"
    set_ssm_param "$SSM_PARAM_INIT_STATUS" "COMPLETED:$INSTANCE_ID"
    publish_k3s_kubeconfig $SSM_PARAM_KUBECONFIG $INSTANCE_ID $K3S_CLUSTER_DOMAIN

    if [[ "$IRSA_ENABLED" == "true" && -n "$IRSA_ISSUER_URL" ]]; then
      publish_k3s_irsa_certs $IRSA_ISSUER_URL $IRSA_BUCKET_NAME
    fi

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

    install_k3s $K3S_VERSION $K3S_CLUSTER_TOKEN "server --server https://$SERVER_IP:6443 --tls-san $K3S_TTL_SAN $IRSA_ARGS"
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
