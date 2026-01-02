# Quick Object Storage Performance Benchmark

A streamlined tool to benchmark S3-compatible object storage (AWS S3, MinIO, etc.) using Apache OPENDAL's native benchmarking suite in Kubernetes.

## 📋 Prerequisites

### Required

1. **Kubernetes Cluster** (one of the following):
   - **Minikube** (recommended for local testing)
     ```bash
     # Install minikube
     brew install minikube  # macOS
     # or download from https://minikube.sigs.k8s.io/docs/start/
     
     # Start minikube
     minikube start
     ```
   - **EKS** (AWS Elastic Kubernetes Service)
   - **Any other Kubernetes cluster** (v1.20+)

2. **kubectl** (Kubernetes command-line tool)
   ```bash
   # macOS
   brew install kubectl
   
   # Linux
   curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
   sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
   
   # Verify installation
   kubectl version --client
   ```

3. **Cluster Access**
   ```bash
   # Verify cluster access
   kubectl cluster-info
   
   # Check current context
   kubectl config current-context
   
   # Switch context if needed
   kubectl config use-context <your-context>
   ```

### For AWS S3 Benchmarking

4. **AWS Credentials** with S3 access:
   - AWS Access Key ID
   - AWS Secret Access Key
   - AWS Session Token (if using temporary credentials)
   - S3 bucket with read/write permissions

### For S3-Compatible Storage (MinIO, etc.)

4. **S3-compatible credentials** - Use your storage provider's access keys

## 🚀 Quick Start

### 1. Clone the Repository

```bash
git clone <repository-url>
cd quick-object-storage-perf-benchmark
```

### 2. Make Script Executable

```bash
chmod +x run-benchmark.sh
```

### 3. Run the Benchmark

```bash
./run-benchmark.sh
```

The script will:
- ✅ Check all prerequisites automatically
- ✅ Prompt for AWS credentials (stored securely as Kubernetes secret)
- ✅ Prompt for S3 configuration (endpoint, bucket, region)
- ✅ Run pre-flight connectivity checks
- ✅ Deploy benchmark pod and run tests
- ✅ Save results to timestamped log file
- ✅ Auto-cleanup resources

## 📖 Detailed Usage

### Interactive Mode (Recommended)

```bash
./run-benchmark.sh
```

**What you'll be prompted for:**
1. **AWS_ACCESS_KEY_ID**: Your AWS access key
2. **AWS_SECRET_ACCESS_KEY**: Your AWS secret key
3. **AWS_SESSION_TOKEN**: (Optional) Session token for temporary credentials
4. **S3 Endpoint**: Default is `s3.us-east-1.amazonaws.com`
5. **S3 Bucket**: Name of your S3 bucket
6. **S3 Region**: Default is `us-east-1`

### What Happens Behind the Scenes

1. **Prerequisites Check**
   - Verifies `kubectl` is installed
   - Checks Kubernetes cluster connectivity
   - Detects cluster type (Minikube/EKS)
   - Creates namespace if needed

2. **Security Setup**
   - Creates Kubernetes secret for credentials
   - No credentials stored in pod manifests

3. **Pre-flight Checks** (Init Container)
   - Tests S3 endpoint connectivity
   - Validates AWS credentials
   - Verifies bucket access
   - Tests write permissions

4. **Benchmark Execution**
   - Clones OPENDAL repository
   - Compiles benchmark suite (~3-5 minutes)
   - Runs complete test suite (~10-15 minutes)
   - Captures all results

5. **Results & Cleanup**
   - Saves results to log file
   - Displays summary
   - Cleans up pod and secrets

## 📊 Benchmark Configuration

### Default Settings
- **Samples per test**: 10 (fast execution)
- **Max concurrent connections**: 4 (stable, avoids network errors)
- **Timeout**: 60 minutes
- **Resources**: 4 CPU / 8GB RAM
- **Test coverage**: Complete read + write operations

### Test Matrix

| Operation | File Sizes | Concurrency |
|-----------|------------|-------------|
| **Read** | 4KB, 64KB, 1MB, 16MB | Sequential, 1, 2, 4 threads |
| **Write** | 4KB, 64KB, 1MB, 16MB | Sequential, 1, 2, 4 threads |

## 📁 Results

### Results File Location

Results are saved in the current directory:
```
benchmark-results-YYYYMMDD-HHMMSS.log
```

### Viewing Results

```bash
# View complete results
cat benchmark-results-*.log

# View just performance metrics
cat benchmark-results-*.log | grep -A 200 "Running benchmark"

# View latest results
ls -lt benchmark-results-*.log | head -1 | awk '{print $NF}' | xargs tail -100
```

### Results Format

```
ops                  fastest       │ slowest       │ median        │ mean          │ samples │ iters
├─ read                            │               │               │               │         │
│  ├─ whole                        │               │               │               │         │
│  │  ├─ 1.00 MiB    20.13 ms      │ 76.74 ms      │ 29.2 ms       │ 30.11 ms      │ 10      │ 10
│  │  │              52.08 MB/s    │ 13.66 MB/s    │ 35.9 MB/s     │ 34.81 MB/s    │         │
```

**Key Metrics:**
- **Median**: Most reliable performance indicator (50th percentile)
- **Mean**: Average performance
- **Throughput**: MB/s or GB/s for each test

## 🔍 Monitoring

### During Execution

```bash
# Check pod status
kubectl get pod opendal-bench --namespace=default

# View live logs
kubectl logs -f opendal-bench --namespace=default -c opendal-bench

# Check resource usage
kubectl top pod opendal-bench --namespace=default

# View connectivity check logs
kubectl logs opendal-bench --namespace=default -c s3-connectivity-check
```

## 🧹 Cleanup

### Automatic Cleanup
The script automatically cleans up:
- Benchmark pod
- Kubernetes secrets

### Manual Cleanup

```bash
# Clean up benchmark resources
kubectl delete pod opendal-bench --namespace=default
kubectl delete secret s3-credentials --namespace=default
```

## 🐛 Troubleshooting

### Prerequisites Check Fails

**kubectl not found:**
```bash
# Install kubectl (see Prerequisites section)
# Verify: kubectl version --client
```

**Cannot access cluster:**
```bash
# Check cluster is running
minikube status  # for minikube

# Check context
kubectl config get-contexts
kubectl config use-context <your-context>
```

### Init Container Fails

**Invalid credentials:**
- Verify AWS credentials are correct and not expired
- For temporary credentials, ensure session token is provided
- Check credentials have S3 read/write permissions

**Bucket access denied:**
- Verify bucket exists: `aws s3 ls s3://your-bucket`
- Check IAM permissions include `s3:ListBucket`, `s3:GetObject`, `s3:PutObject`
- Verify bucket is in the correct region

**Network issues:**
- Check cluster can reach S3 endpoint
- Verify security groups allow outbound HTTPS (port 443)
- For EKS, check VPC routing and NAT gateway

### Benchmark Pod Issues

**Pod fails to start:**
```bash
# Check pod events
kubectl describe pod opendal-bench --namespace=default

# Check for resource constraints
kubectl top nodes
```

**OOMKilled (Out of Memory):**
- Script uses 4-8GB RAM by default
- For smaller clusters, edit script to reduce resources:
  ```yaml
  resources:
    requests:
      memory: "2Gi"  # Reduce if needed
      cpu: "1"
    limits:
      memory: "4Gi"
      cpu: "2"
  ```

**Pod pending (scheduling issues):**
- For EKS: Ensure tolerations match node group taints
- Check node resources: `kubectl get nodes`
- Verify namespace exists: `kubectl get namespace default`

### Benchmark Execution Issues

**Times out:**
- Default timeout is 60 minutes
- Increase in script: `timeout 7200` (2 hours)

**Connection errors:**
- Script limits to 4 concurrent connections
- If still seeing errors, reduce further in script

**Results show 100 samples instead of 10:**
- Ensure script uses `--sample-count 10` argument
- Check script version is up to date

## ⚙️ Advanced Configuration

### Change Sample Count

Edit `run-benchmark.sh`:
```bash
# Find this line and change 10 to desired number
--sample-count 10
```

### Adjust Resources

Edit pod manifest in script (around line 320):
```yaml
resources:
  requests:
    memory: "4Gi"  # Adjust as needed
    cpu: "2"
  limits:
    memory: "8Gi"
    cpu: "4"
```

### Change Concurrent Limits

Edit script to modify skip flags:
```bash
--skip 'concurrent/8' --skip 'concurrent/16' --skip 'concurrent/32'
```

### Use Different Namespace

Edit script configuration:
```bash
NAMESPACE="your-namespace"
```

## 📈 Expected Performance

### AWS S3 (Remote)
- **Read 16MB**: ~95-100 MB/s
- **Read 1MB**: ~35-40 MB/s
- **Write 16MB**: ~95-100 MB/s
- **Write 1MB**: ~35-40 MB/s

*Actual results vary based on cluster location, network conditions, and storage backend. Performance will differ for S3-compatible storage depending on deployment (local vs remote) and infrastructure.*

## 🔒 Security

- ✅ Credentials stored in Kubernetes secrets (encrypted at rest)
- ✅ Secrets automatically deleted after benchmark completion
- ✅ No credentials in pod manifests or log files
- ✅ Pre-flight checks validate credentials before deployment
- ⚠️  Log files contain performance data - review before sharing

## 📚 Additional Resources

- [OPENDAL Documentation](https://opendal.apache.org/)
- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Minikube Documentation](https://minikube.sigs.k8s.io/docs/)

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📄 License

[Add your license here]

## 🙋 Support

For issues or questions:
1. Check the Troubleshooting section
2. Review pod logs: `kubectl logs opendal-bench --namespace=default`
3. Open an issue on GitHub
