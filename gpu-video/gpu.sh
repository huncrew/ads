#!/usr/bin/env bash
# Manage the ComfyUI GPU box. Usage: ./gpu.sh <deploy|status|tunnel|logs|stop|start|destroy> [cfn Key=Value overrides...]
set -euo pipefail
STACK=${STACK:-comfyui-video}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}
DIR=$(cd "$(dirname "$0")" && pwd)
aws() { command aws --region "$REGION" "$@"; }
out() { aws cloudformation describe-stacks --stack-name "$STACK" --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text; }

case "${1:-}" in
  deploy)
    shift
    overrides=(); [ $# -gt 0 ] && overrides=(--parameter-overrides "$@")
    aws cloudformation deploy --stack-name "$STACK" --template-file "$DIR/cloudformation.yaml" \
      --capabilities CAPABILITY_IAM ${overrides[@]+"${overrides[@]}"}
    echo "Instance $(out InstanceId) is up. Models download for ~15-30 min; check with: $0 logs" ;;
  status)
    aws ec2 describe-instances --instance-ids "$(out InstanceId)" \
      --query 'Reservations[0].Instances[0].[State.Name,InstanceType,PublicIpAddress]' --output text ;;
  tunnel)
    echo "Open http://localhost:8188 once connected (Ctrl-C to close)"
    aws ssm start-session --target "$(out InstanceId)" --document-name AWS-StartPortForwardingSession \
      --parameters portNumber=8188,localPortNumber=8188 ;;
  logs)
    aws ssm start-session --target "$(out InstanceId)" --document-name AWS-StartInteractiveCommand \
      --parameters command="tail -n 40 -f /var/log/comfyui-bootstrap.log" ;;
  stop)  aws ec2 stop-instances  --instance-ids "$(out InstanceId)" --output text ;;
  start) aws ec2 start-instances --instance-ids "$(out InstanceId)" --output text ;;
  destroy) aws cloudformation delete-stack --stack-name "$STACK" && echo "Deleting $STACK (instance + disk)" ;;
  *) sed -n 2p "$0"; exit 1 ;;
esac
