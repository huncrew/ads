#!/usr/bin/env bash
# Create a SageMaker Studio domain + private JupyterLab space on an L40S GPU running ComfyUI.
# Uses SageMaker's own GPU quotas (separate from EC2). Idempotent: re-run safely.
# Usage: ./setup.sh            (create + start)
#        ./setup.sh stop|start (stop/start the GPU app; disk is kept)
set -euo pipefail
REGION=${AWS_REGION:-us-west-2}
NAME=${NAME:-comfyui}
SPACE=$NAME-space
INSTANCE=${INSTANCE:-ml.g6e.2xlarge}
DISK_GB=${DISK_GB:-250}
IDLE_MIN=${IDLE_MIN:-120}
# AWS-owned SageMaker Distribution (GPU) image; account IDs per region:
# https://docs.aws.amazon.com/sagemaker/latest/dg/notebooks-available-images.html
declare -A IMG_ACCT=([us-west-2]=542918446943 [us-east-1]=885854791233 [us-east-2]=137914896644)
IMAGE_ARN=${IMAGE_ARN:-arn:aws:sagemaker:$REGION:${IMG_ACCT[$REGION]:-}:image/sagemaker-distribution-gpu}
DIR=$(cd "$(dirname "$0")" && pwd)
aws() { command aws --region "$REGION" "$@"; }

domain_id() { aws sagemaker list-domains --query "Domains[?DomainName=='$NAME'].DomainId | [0]" --output text; }
wait_app() { # wait until the JupyterLab app reaches $1
  while s=$(aws sagemaker describe-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default --query Status --output text 2>/dev/null) && [ "$s" != "$1" ]; do
    [ "$s" = Failed ] && [ "$1" != Deleted ] && { aws sagemaker describe-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default --query FailureReason --output text; exit 1; }
    [ "$1" = Deleted ] && [ "$s" = Deleted ] && break
    echo "  app: $s"; sleep 20
  done
}
start_app() {
  aws sagemaker create-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default \
    --resource-spec "InstanceType=$INSTANCE,SageMakerImageArn=$IMAGE_ARN,LifecycleConfigArn=$LCC_ARN" >/dev/null
  wait_app InService
}

case "${1:-create}" in
  stop)
    D=$(domain_id); aws sagemaker delete-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default
    echo "Stopping GPU app (disk kept)."; exit ;;
  start)
    D=$(domain_id)
    LCC_ARN=$(aws sagemaker describe-studio-lifecycle-config --studio-lifecycle-config-name "$NAME-lcc" --query StudioLifecycleConfigArn --output text)
    S=$(aws sagemaker describe-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default --query Status --output text 2>/dev/null || echo Deleted)
    # Failed apps are auto-deleted by SageMaker; only wait if one is still shutting down.
    case "$S" in Deleted|Failed) ;; *) wait_app Deleted ;; esac
    start_app; echo "Running."; exit ;;
esac

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true --query 'Subnets[].SubnetId' --output text)

ROLE=$NAME-sagemaker-exec
if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
  aws iam create-role --role-name "$ROLE" --assume-role-policy-document \
    '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sagemaker.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
  aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess
  sleep 10
fi
ROLE_ARN=arn:aws:iam::$ACCOUNT:role/$ROLE

LCC_ARN=$(aws sagemaker describe-studio-lifecycle-config --studio-lifecycle-config-name "$NAME-lcc" --query StudioLifecycleConfigArn --output text 2>/dev/null || true)
if [ -z "$LCC_ARN" ]; then
  LCC_ARN=$(aws sagemaker create-studio-lifecycle-config --studio-lifecycle-config-name "$NAME-lcc" \
    --studio-lifecycle-config-app-type JupyterLab \
    --studio-lifecycle-config-content "$(base64 -w0 "$DIR/lcc-comfyui.sh")" \
    --query StudioLifecycleConfigArn --output text)
fi

D=$(domain_id)
if [ "$D" = None ] || [ -z "$D" ]; then
  D=$(aws sagemaker create-domain --domain-name "$NAME" --auth-mode IAM --vpc-id "$VPC" --subnet-ids $SUBNETS \
    --app-network-access-type PublicInternetOnly \
    --default-user-settings "$(cat <<EOF
{"ExecutionRole":"$ROLE_ARN",
 "JupyterLabAppSettings":{"LifecycleConfigArns":["$LCC_ARN"],
   "AppLifecycleManagement":{"IdleSettings":{"LifecycleManagement":"ENABLED","IdleTimeoutInMinutes":$IDLE_MIN}}},
 "SpaceStorageSettings":{"DefaultEbsStorageSettings":{"DefaultEbsVolumeSizeInGb":$DISK_GB,"MaximumEbsVolumeSizeInGb":500}}}
EOF
)" --default-space-settings "{\"ExecutionRole\":\"$ROLE_ARN\"}" --query DomainArn --output text | sed 's#.*/##')
fi
until [ "$(aws sagemaker describe-domain --domain-id "$D" --query Status --output text)" = InService ]; do echo "  domain: creating"; sleep 20; done

aws sagemaker describe-user-profile --domain-id "$D" --user-profile-name "$NAME" >/dev/null 2>&1 ||
  aws sagemaker create-user-profile --domain-id "$D" --user-profile-name "$NAME" >/dev/null
until [ "$(aws sagemaker describe-user-profile --domain-id "$D" --user-profile-name "$NAME" --query Status --output text)" = InService ]; do sleep 10; done

aws sagemaker describe-space --domain-id "$D" --space-name "$SPACE" >/dev/null 2>&1 ||
  aws sagemaker create-space --domain-id "$D" --space-name "$SPACE" \
    --ownership-settings "OwnerUserProfileName=$NAME" --space-sharing-settings SharingType=Private \
    --space-settings "{\"AppType\":\"JupyterLab\",\"SpaceStorageSettings\":{\"EbsStorageSettings\":{\"EbsVolumeSizeInGb\":$DISK_GB}},
      \"JupyterLabAppSettings\":{\"DefaultResourceSpec\":{\"InstanceType\":\"$INSTANCE\",\"LifecycleConfigArn\":\"$LCC_ARN\"}}}" >/dev/null
until [ "$(aws sagemaker describe-space --domain-id "$D" --space-name "$SPACE" --query Status --output text)" = InService ]; do sleep 10; done

S=$(aws sagemaker describe-app --domain-id "$D" --space-name "$SPACE" --app-type JupyterLab --app-name default --query Status --output text 2>/dev/null || echo none)
[ "$S" = InService ] || { [ "$S" = Pending ] && wait_app InService; } || start_app

echo "Domain $D ready. Open Studio: aws sagemaker create-presigned-domain-url --region $REGION --domain-id $D --user-profile-name $NAME --space-name $SPACE"
echo "ComfyUI (after setup finishes, ~30-40 min first time): <studio-url>/jupyterlab/default/proxy/8188/"
