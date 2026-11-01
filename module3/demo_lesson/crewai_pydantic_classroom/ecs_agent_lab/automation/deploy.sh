#!/usr/bin/env bash

set -euo pipefail

# ==========================================
# ECS Agent Classroom - Deployment Automation
# ==========================================

echo "=================================="
echo " ECS Agent Classroom Deployment"
echo "=================================="

# Verify required tools are installed
for tool in aws docker python3; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: Required tool '$tool' is not installed."
        exit 1
    fi
done

echo "Required tools are installed."

# Verify Docker daemon is running
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running."
    exit 1
fi

echo "Docker is running."

# Configure AWS region
AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_REGION

# Verify AWS credentials
if ! AWS_ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text); then
    echo "ERROR: Unable to authenticate with AWS."
    exit 1
fi

export AWS_ACCOUNT_ID

echo "AWS authentication successful."
echo "AWS Account: $AWS_ACCOUNT_ID"
echo "AWS Region: $AWS_REGION"

echo "=================================="
echo " Preflight checks completed"
echo "=================================="