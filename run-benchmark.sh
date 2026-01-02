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
echo "📦 Generating pod manifest..."

# Generate tolerations based on cluster type
NEEDS_TOLERATIONS=false
if [ "$CLUSTER_TYPE" = "eks" ]; then
    # Check if any nodes have the bench_test taint (check taint, not label)
    # Look for nodes with taint key=node_group and value=bench_test
    if kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.taints[*]}{.key}{"="}{.value}{"\n"}{end}{end}' 2>/dev/null | grep -q "node_group=bench_test"; then
        NEEDS_TOLERATIONS=true
        echo "ℹ️  EKS detected: Adding tolerations for bench_test node group"
    else
        echo "ℹ️  EKS detected but bench_test node group taint not found, skipping tolerations"
    fi
else
    echo "ℹ️  Minikube or other cluster: Tolerations not needed"
fi

# Build YAML with conditional tolerations
cat > /tmp/opendal-bench-dynamic.yaml <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD_NAME
  namespace: $NAMESPACE
spec:
$(if [ "$NEEDS_TOLERATIONS" = "true" ]; then cat <<TOLERATIONS
  tolerations:
  - key: "node_group"
    operator: "Equal"
    value: "bench_test"
    effect: "NoSchedule"
TOLERATIONS
fi)
  initContainers:
  - name: s3-connectivity-check
    image: amazon/aws-cli:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -e
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "🔍 S3 Connectivity Pre-flight Check"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
      echo "📋 Configuration:"
      echo "  Endpoint: \$OPENDAL_S3_ENDPOINT"
      echo "  Bucket: \$OPENDAL_S3_BUCKET"
      echo "  Region: \$OPENDAL_S3_REGION"
      echo ""
      
      # Configure AWS CLI
      export AWS_ACCESS_KEY_ID="\$OPENDAL_S3_ACCESS_KEY_ID"
      export AWS_SECRET_ACCESS_KEY="\$OPENDAL_S3_SECRET_ACCESS_KEY"
      export AWS_SESSION_TOKEN="\$OPENDAL_S3_SESSION_TOKEN"
      export AWS_DEFAULT_REGION="\$OPENDAL_S3_REGION"
      
      echo "🧪 Test 1: Checking S3 endpoint connectivity..."
      if curl -s --max-time 10 "https://\$OPENDAL_S3_ENDPOINT" >/dev/null 2>&1; then
        echo "✅ Endpoint is reachable"
      else
        echo "⚠️  Direct endpoint check inconclusive, proceeding to credential test..."
      fi
      
      echo ""
      echo "🧪 Test 2: Verifying AWS credentials..."
      if aws s3 ls --endpoint-url "https://\$OPENDAL_S3_ENDPOINT" 2>&1; then
        echo "✅ Credentials are valid"
      else
        echo "❌ ERROR: Invalid or expired AWS credentials"
        echo "Please update credentials and redeploy."
        exit 1
      fi
      
      echo ""
      echo "🧪 Test 3: Checking bucket access: \$OPENDAL_S3_BUCKET"
      if aws s3 ls "s3://\$OPENDAL_S3_BUCKET" --endpoint-url "https://\$OPENDAL_S3_ENDPOINT" 2>&1; then
        echo "✅ Bucket is accessible"
      else
        echo "❌ ERROR: Cannot access bucket \$OPENDAL_S3_BUCKET"
        echo "Please verify bucket exists and credentials have proper permissions."
        exit 1
      fi
      
      echo ""
      echo "🧪 Test 4: Testing write permissions..."
      TEST_FILE="connectivity-test-\$(date +%s).txt"
      if echo "test-content" | aws s3 cp - "s3://\$OPENDAL_S3_BUCKET/\$TEST_FILE" --endpoint-url "https://\$OPENDAL_S3_ENDPOINT" 2>&1; then
        echo "✅ Write permission confirmed"
        aws s3 rm "s3://\$OPENDAL_S3_BUCKET/\$TEST_FILE" --endpoint-url "https://\$OPENDAL_S3_ENDPOINT" 2>&1 || true
      else
        echo "❌ ERROR: Cannot write to bucket \$OPENDAL_S3_BUCKET"
        echo "Please verify credentials have write permissions."
        exit 1
      fi
      
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "✅ All connectivity checks passed!"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo ""
    env:
    - name: OPENDAL_TEST
      value: "s3"
    - name: OPENDAL_S3_ENDPOINT
      value: "$S3_ENDPOINT"
    - name: OPENDAL_S3_BUCKET
      value: "$S3_BUCKET"
    - name: OPENDAL_S3_REGION
      value: "$S3_REGION"
    - name: OPENDAL_S3_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: access_key_id
    - name: OPENDAL_S3_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: secret_access_key
    - name: OPENDAL_S3_SESSION_TOKEN
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: session_token
          optional: true
  containers:
  - name: opendal-bench
    image: rust:1.75-slim
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -e
      echo "📦 Installing git and build dependencies..."
      apt-get update && apt-get install -y git curl pkg-config libssl-dev ca-certificates
      
      echo "🚀 Starting OPENDAL S3 Benchmark Setup..."
      echo "📦 Cloning opendal repository..."
      git clone https://github.com/apache/opendal.git
      cd opendal/core/benches
      
      echo "🔧 S3 Configuration:"
      echo "  Endpoint: \$OPENDAL_S3_ENDPOINT"
      echo "  Bucket: \$OPENDAL_S3_BUCKET"
      echo "  Region: \$OPENDAL_S3_REGION"
      echo "  Session Token: [SET]"
      
      echo ""
      echo "🔧 Compiling benchmark with S3 service support (this may take a few minutes)..."
      cargo bench --bench ops --features="tests,services-s3" --no-run
      
      echo ""
      echo "🚀 Running benchmark (10 samples per test, max 4 concurrent connections, 60 min timeout)..."
      
      # Run the benchmark with extended timeout (3600 seconds = 60 minutes)
      # Use --sample-count CLI arg to set 10 samples (reduced from default 100)
      # Skip high concurrency tests to avoid network errors (max 4 concurrent)
      export OPENDAL_BENCH_MAX_CONCURRENT=4
      timeout 3600 cargo bench --bench ops --features="tests,services-s3" -- --sample-count 10 --skip 'concurrent/8' --skip 'concurrent/16' --skip 'concurrent/32' 2>&1 || {
        EXIT_CODE=\$?
        if [ \$EXIT_CODE -eq 124 ]; then
          echo ""
          echo "⚠️  Benchmark timed out after 60 minutes"
          echo "This may indicate performance issues or the benchmark is taking longer than expected."
        fi
        exit \$EXIT_CODE
      }
      
      echo ""
      echo "✅ Benchmark completed!"
    env:
    - name: OPENDAL_TEST
      value: "s3"
    - name: OPENDAL_S3_ENDPOINT
      value: "$S3_ENDPOINT"
    - name: OPENDAL_S3_BUCKET
      value: "$S3_BUCKET"
    - name: OPENDAL_S3_REGION
      value: "$S3_REGION"
    - name: OPENDAL_S3_ACCESS_KEY_ID
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: access_key_id
    - name: OPENDAL_S3_SECRET_ACCESS_KEY
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: secret_access_key
    - name: OPENDAL_S3_SESSION_TOKEN
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: session_token
          optional: true
    - name: AWS_SESSION_TOKEN
      valueFrom:
        secretKeyRef:
          name: $SECRET_NAME
          key: session_token
          optional: true
    resources:
      requests:
        memory: "4Gi"
        cpu: "2"
      limits:
        memory: "8Gi"
        cpu: "4"
  restartPolicy: Never
EOF

echo "✅ Manifest generated"

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

echo ""
echo "✅ Done! Full results saved to: $LOG_FILE"
echo ""
echo "To view complete results:"
echo "  cat $LOG_FILE | grep -A 200 'Running OPENDAL'"

