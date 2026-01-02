#!/bin/bash
set -euo pipefail

# Configuration
POD_NAME="opendal-bench"
NAMESPACE="default"
SECRET_NAME="s3-credentials"
LOG_FILE="benchmark-results-$(date +%Y%m%d-%H%M%S).log"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 OPENDAL S3 Benchmark - Interactive Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Prerequisites check
echo "🔍 Checking prerequisites..."
echo ""

# Check kubectl
if ! command -v kubectl &> /dev/null; then
    echo "❌ ERROR: kubectl is not installed or not in PATH"
    echo ""
    echo "Please install kubectl:"
    echo "  macOS: brew install kubectl"
    echo "  Linux: https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/"
    echo "  Windows: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/"
    exit 1
fi
echo "✅ kubectl found: $(kubectl version --client --short 2>/dev/null | head -1 || echo 'installed')"

# Check Kubernetes cluster access
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ ERROR: Cannot access Kubernetes cluster"
    echo ""
    echo "Please ensure:"
    echo "  1. Kubernetes cluster is running (minikube, EKS, etc.)"
    echo "  2. kubectl is configured: kubectl config get-contexts"
    echo "  3. Context is set: kubectl config use-context <your-context>"
    exit 1
fi
echo "✅ Kubernetes cluster accessible"

# Check current context
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
echo "✅ Current context: $CURRENT_CONTEXT"

# Check if namespace exists, create if not
if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    echo "⚠️  Namespace '$NAMESPACE' does not exist, creating..."
    kubectl create namespace "$NAMESPACE"
    echo "✅ Namespace created"
fi

# Detect cluster type for tolerations
CLUSTER_TYPE="unknown"
if echo "$CURRENT_CONTEXT" | grep -qi "minikube"; then
    CLUSTER_TYPE="minikube"
elif echo "$CURRENT_CONTEXT" | grep -qi "eks" || kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "eks"; then
    CLUSTER_TYPE="eks"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Prerequisites check complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Prompt for AWS credentials
echo "📋 AWS Credentials Setup"
echo ""
echo "Please provide your AWS credentials (they will be stored as a Kubernetes secret):"
echo ""

read -p "AWS_ACCESS_KEY_ID: " AWS_ACCESS_KEY_ID
read -p "AWS_SECRET_ACCESS_KEY: " AWS_SECRET_ACCESS_KEY
read -p "AWS_SESSION_TOKEN (optional, press Enter to skip): " AWS_SESSION_TOKEN

echo ""
read -p "S3 Endpoint (default: s3.us-east-1.amazonaws.com): " S3_ENDPOINT
S3_ENDPOINT=${S3_ENDPOINT:-s3.us-east-1.amazonaws.com}

read -p "S3 Bucket: " S3_BUCKET
read -p "S3 Region (default: us-east-1): " S3_REGION
S3_REGION=${S3_REGION:-us-east-1}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Configuration Summary:"
echo "  Endpoint: $S3_ENDPOINT"
echo "  Bucket: $S3_BUCKET"
echo "  Region: $S3_REGION"
echo "  Log file: $LOG_FILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Proceed with benchmark? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "🧹 Cleaning up existing resources..."
kubectl delete pod $POD_NAME --namespace=$NAMESPACE --ignore-not-found=true
kubectl delete secret $SECRET_NAME --namespace=$NAMESPACE --ignore-not-found=true
kubectl delete configmap qps-bench-source --namespace=$NAMESPACE --ignore-not-found=true

echo ""
echo "🔐 Creating Kubernetes secret for AWS credentials..."
if [ -n "$AWS_SESSION_TOKEN" ]; then
    kubectl create secret generic $SECRET_NAME \
        --namespace=$NAMESPACE \
        --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
        --from-literal=secret_access_key="$AWS_SECRET_ACCESS_KEY" \
        --from-literal=session_token="$AWS_SESSION_TOKEN"
else
    kubectl create secret generic $SECRET_NAME \
        --namespace=$NAMESPACE \
        --from-literal=access_key_id="$AWS_ACCESS_KEY_ID" \
        --from-literal=secret_access_key="$AWS_SECRET_ACCESS_KEY"
fi

echo "✅ Secret created: $SECRET_NAME"

echo ""
echo "📦 Creating QPS benchmark source ConfigMap..."

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QPS_SOURCE_DIR="$SCRIPT_DIR/qps-bench"

# Check if QPS source files exist
if [ ! -f "$QPS_SOURCE_DIR/Cargo.toml" ] || [ ! -f "$QPS_SOURCE_DIR/src/main.rs" ]; then
    echo "❌ ERROR: QPS benchmark source files not found"
    echo "   Expected: $QPS_SOURCE_DIR/Cargo.toml"
    echo "   Expected: $QPS_SOURCE_DIR/src/main.rs"
    echo ""
    echo "Please ensure the QPS benchmark source files are in the qps-bench/ directory"
    exit 1
fi

echo "✅ Found QPS benchmark source files in: $QPS_SOURCE_DIR"

kubectl create configmap qps-bench-source \
    --namespace=$NAMESPACE \
    --from-file=Cargo.toml="$QPS_SOURCE_DIR/Cargo.toml" \
    --from-file=main.rs="$QPS_SOURCE_DIR/src/main.rs" 2>/dev/null || \
kubectl create configmap qps-bench-source \
    --namespace=$NAMESPACE \
    --from-file=Cargo.toml="$QPS_SOURCE_DIR/Cargo.toml" \
    --from-file=main.rs="$QPS_SOURCE_DIR/src/main.rs" \
    --dry-run=client -o yaml | kubectl apply -f -

echo "✅ ConfigMap created: qps-bench-source"

echo ""
echo "📦 Generating pod manifest..."

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAML_TEMPLATE="$SCRIPT_DIR/benchmark-pod.yaml.template"

# Check if YAML template exists
if [ ! -f "$YAML_TEMPLATE" ]; then
    echo "❌ ERROR: YAML template not found: $YAML_TEMPLATE"
    exit 1
fi

# Generate tolerations based on cluster type
TOLERATIONS_YAML=""
if [ "$CLUSTER_TYPE" = "eks" ]; then
    # Check if any nodes have the bench_test taint (check taint, not label)
    # Look for nodes with taint key=node_group and value=bench_test
    if kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"="}{.value}{"\n"}{end}{end}' 2>/dev/null | grep -q "node_group=bench_test"; then
        TOLERATIONS_YAML="  tolerations:
  - key: \"node_group\"
    operator: \"Equal\"
    value: \"bench_test\"
    effect: \"NoSchedule\""
        echo "ℹ️  EKS detected: Adding tolerations for bench_test node group"
    else
        echo "ℹ️  EKS detected but bench_test node group taint not found, skipping tolerations"
    fi
else
    echo "ℹ️  Minikube or other cluster: Tolerations not needed"
fi

# Substitute variables in YAML template
# Handle tolerations separately since it may contain newlines
if [ -n "$TOLERATIONS_YAML" ]; then
    # Use perl for multi-line replacement, or awk as fallback
    if command -v perl &> /dev/null; then
        perl -pe "s|{{TOLERATIONS}}|$TOLERATIONS_YAML|g" "$YAML_TEMPLATE" | \
        sed -e "s|{{POD_NAME}}|$POD_NAME|g" \
            -e "s|{{NAMESPACE}}|$NAMESPACE|g" \
            -e "s|{{SECRET_NAME}}|$SECRET_NAME|g" \
            -e "s|{{S3_ENDPOINT}}|$S3_ENDPOINT|g" \
            -e "s|{{S3_BUCKET}}|$S3_BUCKET|g" \
            -e "s|{{S3_REGION}}|$S3_REGION|g" > /tmp/opendal-bench-dynamic.yaml
    else
        # Fallback: use awk for multi-line replacement
        awk -v pod_name="$POD_NAME" \
            -v namespace="$NAMESPACE" \
            -v secret_name="$SECRET_NAME" \
            -v s3_endpoint="$S3_ENDPOINT" \
            -v s3_bucket="$S3_BUCKET" \
            -v s3_region="$S3_REGION" \
            -v tolerations="$TOLERATIONS_YAML" \
            '{gsub(/{{POD_NAME}}/, pod_name); \
              gsub(/{{NAMESPACE}}/, namespace); \
              gsub(/{{SECRET_NAME}}/, secret_name); \
              gsub(/{{S3_ENDPOINT}}/, s3_endpoint); \
              gsub(/{{S3_BUCKET}}/, s3_bucket); \
              gsub(/{{S3_REGION}}/, s3_region); \
              gsub(/{{TOLERATIONS}}/, tolerations); \
              print}' "$YAML_TEMPLATE" > /tmp/opendal-bench-dynamic.yaml
    fi
else
    # No tolerations - use simple sed and remove the placeholder line
    sed -e "s|{{POD_NAME}}|$POD_NAME|g" \
        -e "s|{{NAMESPACE}}|$NAMESPACE|g" \
        -e "s|{{SECRET_NAME}}|$SECRET_NAME|g" \
        -e "s|{{S3_ENDPOINT}}|$S3_ENDPOINT|g" \
        -e "s|{{S3_BUCKET}}|$S3_BUCKET|g" \
        -e "s|{{S3_REGION}}|$S3_REGION|g" \
        -e '/^  {{TOLERATIONS}}$/d' \
        "$YAML_TEMPLATE" > /tmp/opendal-bench-dynamic.yaml
fi

echo "✅ Manifest generated from template: $YAML_TEMPLATE"

echo ""
echo "📦 Deploying benchmark pod..."
kubectl apply -f /tmp/opendal-bench-dynamic.yaml

# Wait for init container to complete
echo ""
echo "⏳ Waiting for S3 connectivity check (init container)..."
sleep 5

# Monitor init container
for i in {1..60}; do
    INIT_STATUS=$(kubectl get pod $POD_NAME --namespace=$NAMESPACE -o jsonpath='{.status.initContainerStatuses[0].state}' 2>/dev/null || echo "")
    
    if echo "$INIT_STATUS" | grep -q "terminated"; then
        INIT_EXIT_CODE=$(kubectl get pod $POD_NAME --namespace=$NAMESPACE -o jsonpath='{.status.initContainerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")
        
        if [ "$INIT_EXIT_CODE" != "0" ]; then
            echo ""
            echo "❌ S3 connectivity check FAILED!"
            echo ""
            echo "Init container logs:"
            kubectl logs $POD_NAME --namespace=$NAMESPACE -c s3-connectivity-check | tee -a "$LOG_FILE"
            echo ""
            echo "Cleaning up..."
            kubectl delete pod $POD_NAME --namespace=$NAMESPACE
            kubectl delete secret $SECRET_NAME --namespace=$NAMESPACE
            exit 1
        else
            echo "✅ S3 connectivity check passed!"
            break
        fi
    fi
    
    if [ $i -eq 60 ]; then
        echo "❌ Timeout waiting for init container"
        kubectl logs $POD_NAME --namespace=$NAMESPACE -c s3-connectivity-check 2>&1 | tee -a "$LOG_FILE"
        kubectl delete pod $POD_NAME --namespace=$NAMESPACE
        kubectl delete secret $SECRET_NAME --namespace=$NAMESPACE
        exit 1
    fi
    
    sleep 2
done

# Save init container logs
kubectl logs $POD_NAME --namespace=$NAMESPACE -c s3-connectivity-check >> "$LOG_FILE"

# Wait for main container to start
echo ""
echo "⏳ Waiting for benchmark container to start..."
kubectl wait --for=condition=Ready pod/$POD_NAME --namespace=$NAMESPACE --timeout=120s || {
    echo "❌ Pod failed to start"
    kubectl describe pod $POD_NAME --namespace=$NAMESPACE | tee -a "$LOG_FILE"
    kubectl delete pod $POD_NAME --namespace=$NAMESPACE
    kubectl delete secret $SECRET_NAME --namespace=$NAMESPACE
    exit 1
}

echo "✅ Benchmark container started!"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Streaming benchmark logs..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Stream logs and save to file
kubectl logs -f $POD_NAME --namespace=$NAMESPACE -c opendal-bench 2>&1 | tee -a "$LOG_FILE" &
LOG_PID=$!

# Monitor pod completion
while true; do
    POD_STATUS=$(kubectl get pod $POD_NAME --namespace=$NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    
    if [ "$POD_STATUS" = "Succeeded" ] || [ "$POD_STATUS" = "Failed" ] || [ "$POD_STATUS" = "Unknown" ]; then
        sleep 5  # Give time for final logs
        kill $LOG_PID 2>/dev/null || true
        break
    fi
    
    sleep 5
done

# Capture final logs to ensure we got everything
echo ""
echo "📝 Capturing final logs..."
kubectl logs $POD_NAME --namespace=$NAMESPACE -c opendal-bench >> "$LOG_FILE" 2>&1 || true

# Check final status
POD_STATUS=$(kubectl get pod $POD_NAME --namespace=$NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
CONTAINER_EXIT_CODE=$(kubectl get pod $POD_NAME --namespace=$NAMESPACE -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Benchmark Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Pod Status: $POD_STATUS"
echo "Exit Code: ${CONTAINER_EXIT_CODE:-N/A}"
echo "Log File: $LOG_FILE"
echo ""

if [ "$POD_STATUS" = "Succeeded" ]; then
    echo "✅ Benchmark completed successfully!"
    echo ""
    echo "📊 Results Summary:"
    grep -A 2 "ops.*fastest.*slowest" "$LOG_FILE" | head -20 || echo "Results extraction in progress..."
else
    echo "⚠️  Benchmark completed with status: $POD_STATUS"
fi

echo ""
echo "Cleaning up resources..."
kubectl delete pod $POD_NAME --namespace=$NAMESPACE --ignore-not-found=true
kubectl delete secret $SECRET_NAME --namespace=$NAMESPACE --ignore-not-found=true
kubectl delete configmap qps-bench-source --namespace=$NAMESPACE --ignore-not-found=true

echo ""
echo "✅ Done! Full results saved to: $LOG_FILE"
echo ""
echo "To view complete results:"
echo "  cat $LOG_FILE | grep -A 200 'Running OPENDAL'"
