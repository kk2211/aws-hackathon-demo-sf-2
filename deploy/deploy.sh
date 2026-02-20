#!/usr/bin/env bash
#
# deploy.sh — Deploy acme-order-service to an EC2 instance with Docker Compose
#
# Designed for AWS Workshop Studio accounts with limited permissions.
# Launches an EC2 instance, installs Docker, clones the code, and runs
# docker compose with the Datadog Agent, Redis, and the Flask app.
#
# Prerequisites:
#   - AWS CLI v2 with workshop credentials exported
#   - DD_API_KEY env var (your Datadog API key)
#
# Usage:
#   ./deploy/deploy.sh          # Deploy (creates EC2 instance + everything)
#   ./deploy/deploy.sh teardown # Terminate instance + delete resources
#   ./deploy/deploy.sh status   # Show instance IP and status
#   ./deploy/deploy.sh ssh      # SSH into the instance

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
APP_NAME="acme-order-service"
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-west-2}}"
INSTANCE_TYPE="t3.medium"
KEY_NAME="${APP_NAME}-key"
SG_NAME="${APP_NAME}-sg"
TAG_KEY="Project"
TAG_VALUE="$APP_NAME"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Helpers ─────────────────────────────────────────────────────────────────
info()  { echo "→ $*"; }
ok()    { echo "✓ $*"; }
warn()  { echo "⚠ $*"; }
fail()  { echo "✗ $*" >&2; exit 1; }

get_default_vpc() {
  aws ec2 describe-vpcs \
    --filters Name=isDefault,Values=true \
    --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION"
}

get_instance_id() {
  aws ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running,pending" \
    --query "Reservations[0].Instances[0].InstanceId" --output text --region "$AWS_REGION" 2>/dev/null || echo "None"
}

get_instance_ip() {
  local instance_id="$1"
  aws ec2 describe-instances --instance-ids "$instance_id" \
    --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region "$AWS_REGION" 2>/dev/null || echo "None"
}

# Find latest Amazon Linux 2023 AMI
get_ami() {
  aws ec2 describe-images \
    --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-x86_64" "Name=state,Values=available" \
    --query "Images | sort_by(@, &CreationDate) | [-1].ImageId" \
    --output text --region "$AWS_REGION"
}

# ─── Teardown ────────────────────────────────────────────────────────────────
teardown() {
  info "Tearing down ${APP_NAME}..."

  # Terminate instances
  INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" "Name=instance-state-name,Values=running,pending,stopped" \
    --query "Reservations[*].Instances[*].InstanceId" --output text --region "$AWS_REGION" 2>/dev/null || echo "")
  if [[ -n "$INSTANCE_IDS" && "$INSTANCE_IDS" != "None" ]]; then
    aws ec2 terminate-instances --instance-ids $INSTANCE_IDS --region "$AWS_REGION" > /dev/null 2>&1 || true
    info "Waiting for instance termination..."
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_IDS --region "$AWS_REGION" 2>/dev/null || true
    ok "Instance(s) terminated"
  else
    ok "No instances found"
  fi

  # Delete key pair
  aws ec2 delete-key-pair --key-name "$KEY_NAME" --region "$AWS_REGION" 2>/dev/null || true
  rm -f "${PROJECT_DIR}/deploy/${KEY_NAME}.pem"
  ok "Key pair deleted"

  # Delete security group (may need a moment after instance termination)
  sleep 5
  VPC_ID=$(get_default_vpc)
  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || echo "None")
  if [[ "$SG_ID" != "None" && -n "$SG_ID" ]]; then
    aws ec2 delete-security-group --group-id "$SG_ID" --region "$AWS_REGION" 2>/dev/null || true
    ok "Security group deleted"
  fi

  echo ""
  ok "Teardown complete."
}

# ─── Status ──────────────────────────────────────────────────────────────────
status() {
  INSTANCE_ID=$(get_instance_id)
  if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
    info "No running instance found."
    return 0
  fi

  PUBLIC_IP=$(get_instance_ip "$INSTANCE_ID")
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Instance: ${INSTANCE_ID}"
  echo "  Public IP: ${PUBLIC_IP}"
  echo ""
  echo "  Service:   http://${PUBLIC_IP}:5000/health"
  echo "  SSH:       ./deploy/deploy.sh ssh"
  echo "═══════════════════════════════════════════════════════"
}

# ─── SSH ─────────────────────────────────────────────────────────────────────
do_ssh() {
  INSTANCE_ID=$(get_instance_id)
  if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
    fail "No running instance found."
  fi
  PUBLIC_IP=$(get_instance_ip "$INSTANCE_ID")
  KEY_FILE="${SCRIPT_DIR}/${KEY_NAME}.pem"
  if [[ ! -f "$KEY_FILE" ]]; then
    fail "Key file not found: ${KEY_FILE}"
  fi
  exec ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no ec2-user@"$PUBLIC_IP"
}

# ─── Deploy ──────────────────────────────────────────────────────────────────
deploy() {
  if [[ -z "${DD_API_KEY:-}" ]]; then
    fail "DD_API_KEY env var is not set. Export your Datadog API key."
  fi

  info "Region: ${AWS_REGION}"

  # Check if already deployed
  EXISTING_ID=$(get_instance_id)
  if [[ "$EXISTING_ID" != "None" && -n "$EXISTING_ID" ]]; then
    PUBLIC_IP=$(get_instance_ip "$EXISTING_ID")
    warn "Instance already running: ${EXISTING_ID} (${PUBLIC_IP})"
    echo "   http://${PUBLIC_IP}:5000/health"
    echo ""
    echo "   To redeploy: ./deploy/deploy.sh teardown && ./deploy/deploy.sh"
    return 0
  fi

  # ── 1. Security Group ──
  info "Setting up security group..."
  VPC_ID=$(get_default_vpc)

  SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || echo "None")

  if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
    SG_ID=$(aws ec2 create-security-group \
      --group-name "$SG_NAME" \
      --description "Allow SSH + app port for ${APP_NAME}" \
      --vpc-id "$VPC_ID" \
      --query "GroupId" --output text --region "$AWS_REGION")

    # Allow SSH
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "$AWS_REGION"
    # Allow app port
    aws ec2 authorize-security-group-ingress --group-id "$SG_ID" \
      --protocol tcp --port 5000 --cidr 0.0.0.0/0 --region "$AWS_REGION"
  fi
  ok "Security group: ${SG_ID}"

  # ── 3. Find AMI ──
  info "Looking up Amazon Linux 2023 AMI..."
  AMI_ID=$(get_ami)
  ok "AMI: ${AMI_ID}"

  # ── 4. Build user-data script ──
  # This runs on first boot: installs Docker, writes project files, starts services
  info "Preparing user-data..."

  # Create a tar of the project to embed in user-data
  PROJECT_TAR=$(cd "$PROJECT_DIR" && tar czf - \
    --exclude='.git' \
    --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.db' \
    --exclude='deploy' \
    --exclude='.env' \
    --exclude='demo_service_plan.md' \
    --exclude='.claude' \
    . | base64)

  USER_DATA=$(cat <<'USERDATA_HEADER'
#!/bin/bash
set -ex
exec > /var/log/user-data.log 2>&1

# Install Docker
dnf install -y docker git
systemctl enable docker
systemctl start docker

# Install Docker Compose plugin
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Create app directory
mkdir -p /opt/acme-order-service
cd /opt/acme-order-service

# Extract project files
USERDATA_HEADER
)

  USER_DATA+="
echo '${PROJECT_TAR}' | base64 -d | tar xzf -

# Write .env file with DD_API_KEY
cat > .env <<'ENVFILE'
DD_API_KEY=${DD_API_KEY}
ENVFILE

# Build and start
docker compose up -d --build

echo 'Deployment complete!'
"

  # ── 5. Launch Instance ──
  info "Launching EC2 instance (${INSTANCE_TYPE})..."
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$SG_ID" \
    --associate-public-ip-address \
    --user-data "$USER_DATA" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=${TAG_KEY},Value=${TAG_VALUE}},{Key=Name,Value=${APP_NAME}}]" \
    --query "Instances[0].InstanceId" --output text --region "$AWS_REGION")
  ok "Instance launched: ${INSTANCE_ID}"

  # ── 6. Wait for running state ──
  info "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$AWS_REGION"
  PUBLIC_IP=$(get_instance_ip "$INSTANCE_ID")
  ok "Instance running: ${PUBLIC_IP}"

  # ── 7. Wait for app to be ready ──
  echo ""
  info "Waiting for app to start (Docker install + build, ~2-3 min)..."

  for i in {1..40}; do
    if curl -s --connect-timeout 3 --max-time 5 "http://${PUBLIC_IP}:5000/health" > /dev/null 2>&1; then
      echo ""
      echo "═══════════════════════════════════════════════════════"
      ok "DEPLOYED! Service is running at:"
      echo ""
      echo "   http://${PUBLIC_IP}:5000/health"
      echo ""
      echo "   Load test:"
      echo "   python load_test.py --all --rps 5 --duration 120 --base-url http://${PUBLIC_IP}:5000"
      echo ""
      echo "   SSH into instance:"
      echo "   ./deploy/deploy.sh ssh"
      echo ""
      echo "   Teardown:"
      echo "   ./deploy/deploy.sh teardown"
      echo "═══════════════════════════════════════════════════════"
      return 0
    fi
    echo "   ...waiting (${i}/40)"
    sleep 10
  done

  echo ""
  warn "App not responding yet. It may still be building."
  echo "   Check manually: curl http://${PUBLIC_IP}:5000/health"
  echo "   Or SSH in:      ./deploy/deploy.sh ssh"
  echo "   Then run:        sudo tail -f /var/log/user-data.log"
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-deploy}" in
  teardown|destroy|delete)
    teardown
    ;;
  deploy|update)
    deploy
    ;;
  status)
    status
    ;;
  ssh)
    do_ssh
    ;;
  *)
    echo "Usage: $0 [deploy|update|teardown|status|ssh]"
    exit 1
    ;;
esac
