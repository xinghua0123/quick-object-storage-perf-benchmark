// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use anyhow::Result;
use clap::Parser;
use hdrhistogram::Histogram;
use opendal::Operator;
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Semaphore;
use uuid::Uuid;

#[derive(Parser, Debug)]
#[command(name = "qps-bench")]
#[command(about = "QPS and latency microbenchmark for OpenDAL operations")]
struct Args {
    /// Service type (s3, oss, gcs, etc.)
    #[arg(long, default_value = "s3")]
    service: String,

    /// S3 endpoint URL
    #[arg(long)]
    endpoint: String,

    /// Region
    #[arg(long, default_value = "us-east-1")]
    region: String,

    /// Bucket name
    #[arg(long)]
    bucket: String,

    /// Access key ID
    #[arg(long)]
    access_key: String,

    /// Secret access key
    #[arg(long)]
    secret_key: String,

    /// Session token (optional, for temporary credentials)
    #[arg(long)]
    session_token: Option<String>,

    /// Key prefix
    #[arg(long, default_value = "bench")]
    prefix: String,

    /// Number of objects in dataset
    #[arg(long, default_value = "10000")]
    objects: usize,

    /// Object size in bytes
    #[arg(long, default_value = "1024")]
    object_size_bytes: usize,

    /// Concurrency level
    #[arg(long, default_value = "64")]
    concurrency: usize,

    /// Duration in seconds
    #[arg(long, default_value = "60")]
    duration_seconds: u64,

    /// Benchmark mode: stat, read_small, write_small, delete, list, read_write (combined)
    #[arg(long, default_value = "stat")]
    mode: String,

    /// Cleanup created objects after benchmark
    #[arg(long, default_value = "true")]
    cleanup: bool,

    /// Force path-style addressing (for S3-compatible services)
    #[arg(long, default_value = "false")]
    force_path_style: bool,
}

#[derive(Debug, Serialize, Deserialize)]
struct BenchmarkResult {
    mode: String,
    concurrency: usize,
    duration_seconds: u64,
    ok_ops: u64,
    err_ops: u64,
    qps: f64,
    latency_us_p50: u64,
    latency_us_p95: u64,
    latency_us_p99: u64,
    latency_us_mean: u64,
    backend: BackendInfo,
}

#[derive(Debug, Serialize, Deserialize)]
struct BackendInfo {
    service: String,
    endpoint: String,
    region: String,
    bucket: String,
}

struct BenchmarkState {
    op: Operator,
    keys: Arc<Vec<String>>,
    object_size: usize,
    prefix: String,
    next_key_index: Arc<std::sync::atomic::AtomicUsize>,
}

fn generate_key(prefix: &str, index: usize) -> String {
    // Use randomized distribution: prefix + <2 hex chars>/<uuid>
    let hex_part = format!("{:02x}", index % 256);
    let uuid_part = Uuid::new_v4().to_string();
    format!("{}/{}/{}", prefix, hex_part, uuid_part)
}

async fn create_dataset(op: &Operator, prefix: &str, count: usize, size: usize) -> Result<Vec<String>> {
    println!("Creating dataset: {} objects of {} bytes each...", count, size);
    let data = vec![0u8; size];
    let mut keys = Vec::with_capacity(count);
    
    for i in 0..count {
        let key = generate_key(prefix, i);
        match op.write(&key, data.clone()).await {
            Ok(_) => {
                keys.push(key);
                if (i + 1) % 1000 == 0 {
                    println!("  Created {}/{} objects...", i + 1, count);
                }
            }
            Err(e) => {
                eprintln!("Warning: Failed to create object {}: {}", i, e);
            }
        }
    }
    
    println!("Dataset created: {} objects", keys.len());
    Ok(keys)
}

async fn run_stat_benchmark(state: Arc<BenchmarkState>, duration: Duration, concurrency: usize) -> (u64, u64, Histogram<u64>) {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let start = Instant::now();
    let end_time = start + duration;
    let mut handles = Vec::new();
    
    let histogram = Arc::new(std::sync::Mutex::new(Histogram::<u64>::new(3).unwrap()));
    let ok_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let err_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    
    while Instant::now() < end_time {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let state_clone = state.clone();
        let histogram_clone = histogram.clone();
        let ok_count_clone = ok_count.clone();
        let err_count_clone = err_count.clone();
        
        let handle = tokio::spawn(async move {
            let _permit = permit;
            let index = state_clone.next_key_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % state_clone.keys.len();
            let key = &state_clone.keys[index];
            
            let op_start = Instant::now();
            match state_clone.op.stat(key).await {
                Ok(_) => {
                    let latency_us = op_start.elapsed().as_micros() as u64;
                    histogram_clone.lock().unwrap().record(latency_us).ok();
                    ok_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(_) => {
                    err_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        });
        
        handles.push(handle);
        
        // Limit number of pending tasks
        if handles.len() >= concurrency * 2 {
            handles.retain(|h| !h.is_finished());
        }
    }
    
    // Wait for remaining tasks
    for handle in handles {
        let _ = handle.await;
    }
    
    let hist = histogram.lock().unwrap().clone();
    (ok_count.load(std::sync::atomic::Ordering::Relaxed), 
     err_count.load(std::sync::atomic::Ordering::Relaxed),
     hist)
}

async fn run_read_benchmark(state: Arc<BenchmarkState>, duration: Duration, concurrency: usize) -> (u64, u64, Histogram<u64>) {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let start = Instant::now();
    let end_time = start + duration;
    let mut handles = Vec::new();
    
    let histogram = Arc::new(std::sync::Mutex::new(Histogram::<u64>::new(3).unwrap()));
    let ok_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let err_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    
    while Instant::now() < end_time {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let state_clone = state.clone();
        let histogram_clone = histogram.clone();
        let ok_count_clone = ok_count.clone();
        let err_count_clone = err_count.clone();
        
        let handle = tokio::spawn(async move {
            let _permit = permit;
            let index = state_clone.next_key_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % state_clone.keys.len();
            let key = &state_clone.keys[index];
            
            let op_start = Instant::now();
            match state_clone.op.read(key).await {
                Ok(_) => {
                    let latency_us = op_start.elapsed().as_micros() as u64;
                    histogram_clone.lock().unwrap().record(latency_us).ok();
                    ok_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(_) => {
                    err_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        });
        
        handles.push(handle);
        
        if handles.len() >= concurrency * 2 {
            handles.retain(|h| !h.is_finished());
        }
    }
    
    for handle in handles {
        let _ = handle.await;
    }
    
    let hist = histogram.lock().unwrap().clone();
    (ok_count.load(std::sync::atomic::Ordering::Relaxed), 
     err_count.load(std::sync::atomic::Ordering::Relaxed),
     hist)
}

async fn run_write_benchmark(state: Arc<BenchmarkState>, duration: Duration, concurrency: usize) -> (u64, u64, Histogram<u64>) {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let start = Instant::now();
    let end_time = start + duration;
    let mut handles = Vec::new();
    let data = vec![0u8; state.object_size];
    
    let histogram = Arc::new(std::sync::Mutex::new(Histogram::<u64>::new(3).unwrap()));
    let ok_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let err_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let key_counter = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    
    while Instant::now() < end_time {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let state_clone = state.clone();
        let histogram_clone = histogram.clone();
        let ok_count_clone = ok_count.clone();
        let err_count_clone = err_count.clone();
        let key_counter_clone = key_counter.clone();
        let data_clone = data.clone();
        
        let handle = tokio::spawn(async move {
            let _permit = permit;
            let counter = key_counter_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let key = generate_key(&state_clone.prefix, counter);
            
            let op_start = Instant::now();
            match state_clone.op.write(&key, data_clone).await {
                Ok(_) => {
                    let latency_us = op_start.elapsed().as_micros() as u64;
                    histogram_clone.lock().unwrap().record(latency_us).ok();
                    ok_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(_) => {
                    err_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        });
        
        handles.push(handle);
        
        if handles.len() >= concurrency * 2 {
            handles.retain(|h| !h.is_finished());
        }
    }
    
    for handle in handles {
        let _ = handle.await;
    }
    
    let hist = histogram.lock().unwrap().clone();
    (ok_count.load(std::sync::atomic::Ordering::Relaxed), 
     err_count.load(std::sync::atomic::Ordering::Relaxed),
     hist)
}

async fn run_delete_benchmark(state: Arc<BenchmarkState>, duration: Duration, concurrency: usize) -> (u64, u64, Histogram<u64>) {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let start = Instant::now();
    let end_time = start + duration;
    let mut handles = Vec::new();
    
    let histogram = Arc::new(std::sync::Mutex::new(Histogram::<u64>::new(3).unwrap()));
    let ok_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let err_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    
    while Instant::now() < end_time {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let state_clone = state.clone();
        let histogram_clone = histogram.clone();
        let ok_count_clone = ok_count.clone();
        let err_count_clone = err_count.clone();
        
        let handle = tokio::spawn(async move {
            let _permit = permit;
            let index = state_clone.next_key_index.fetch_add(1, std::sync::atomic::Ordering::Relaxed) % state_clone.keys.len();
            let key = &state_clone.keys[index];
            
            let op_start = Instant::now();
            match state_clone.op.delete(key).await {
                Ok(_) => {
                    let latency_us = op_start.elapsed().as_micros() as u64;
                    histogram_clone.lock().unwrap().record(latency_us).ok();
                    ok_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
                Err(_) => {
                    err_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        });
        
        handles.push(handle);
        
        if handles.len() >= concurrency * 2 {
            handles.retain(|h| !h.is_finished());
        }
    }
    
    for handle in handles {
        let _ = handle.await;
    }
    
    let hist = histogram.lock().unwrap().clone();
    (ok_count.load(std::sync::atomic::Ordering::Relaxed), 
     err_count.load(std::sync::atomic::Ordering::Relaxed),
     hist)
}

async fn run_list_benchmark(state: Arc<BenchmarkState>, duration: Duration, concurrency: usize) -> (u64, u64, Histogram<u64>) {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let start = Instant::now();
    let end_time = start + duration;
    let mut handles = Vec::new();
    
    let histogram = Arc::new(std::sync::Mutex::new(Histogram::<u64>::new(3).unwrap()));
    let ok_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    let err_count = Arc::new(std::sync::atomic::AtomicU64::new(0));
    
    while Instant::now() < end_time {
        let permit = semaphore.clone().acquire_owned().await.unwrap();
        let state_clone = state.clone();
        let histogram_clone = histogram.clone();
        let ok_count_clone = ok_count.clone();
        let err_count_clone = err_count.clone();
        
        let handle = tokio::spawn(async move {
            let _permit = permit;
            let op_start = Instant::now();
            match state_clone.op.list(&state_clone.prefix).await {
                Ok(entries) => {
                    let latency_us = op_start.elapsed().as_micros() as u64;
                    histogram_clone.lock().unwrap().record(latency_us).ok();
                    // Count entries (list returns Vec<Entry>, so we can just get len)
                    let _count = entries.len();
                    ok_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    // Note: We could track items/sec separately, but keeping it simple for now
                }
                Err(_) => {
                    err_count_clone.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                }
            }
        });
        
        handles.push(handle);
        
        if handles.len() >= concurrency * 2 {
            handles.retain(|h| !h.is_finished());
        }
    }
    
    for handle in handles {
        let _ = handle.await;
    }
    
    let hist = histogram.lock().unwrap().clone();
    (ok_count.load(std::sync::atomic::Ordering::Relaxed), 
     err_count.load(std::sync::atomic::Ordering::Relaxed),
     hist)
}

fn create_operator(args: &Args) -> Result<Operator> {
    use opendal::services::S3;
    use opendal::Operator;
    
    let mut builder = S3::default()
        .root("/")
        .bucket(&args.bucket)
        .endpoint(&args.endpoint)
        .region(&args.region)
        .access_key_id(&args.access_key)
        .secret_access_key(&args.secret_key);
    
    if let Some(token) = &args.session_token {
        builder = builder.session_token(token);
    }
    
    // Path style is default, so we don't need to do anything special
    // If force_path_style is false, we could enable virtual host style, but keeping it simple
    
    let op: Operator = Operator::new(builder)?
        .layer(opendal::layers::LoggingLayer::default())
        .finish();
    
    Ok(op)
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("🚀 OpenDAL QPS Benchmark");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("Mode: {}", args.mode);
    println!("Service: {}", args.service);
    println!("Endpoint: {}", args.endpoint);
    println!("Bucket: {}", args.bucket);
    println!("Region: {}", args.region);
    println!("Concurrency: {}", args.concurrency);
    println!("Duration: {}s", args.duration_seconds);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!();
    
    let op = create_operator(&args)?;
    
    // Generate prefix with timestamp and random
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let random: u64 = rand::random();
    let prefix = format!("{}/{}-{}/", args.prefix, timestamp, random);
    
    println!("Using prefix: {}", prefix);
    
    let duration = Duration::from_secs(args.duration_seconds);
    
    // Handle combined read_write mode
    if args.mode == "read_write" {
        println!();
        println!("Running combined READ + WRITE benchmark for {} seconds each...", args.duration_seconds);
        
        // Pre-create dataset for read operations
        println!("Creating dataset for read operations...");
        let keys = create_dataset(&op, &prefix, args.objects, args.object_size_bytes).await?;
        let read_state = Arc::new(BenchmarkState {
            op: op.clone(),
            keys: Arc::new(keys),
            object_size: args.object_size_bytes,
            prefix: prefix.clone(),
            next_key_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        });
        
        // Run read benchmark
        println!();
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("📊 Running READ Benchmark");
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        let (read_ok, read_err, read_hist) = run_read_benchmark(read_state.clone(), duration, args.concurrency).await;
        let read_qps = read_ok as f64 / args.duration_seconds as f64;
        let read_p50 = read_hist.value_at_quantile(0.5);
        let read_p95 = read_hist.value_at_quantile(0.95);
        let read_p99 = read_hist.value_at_quantile(0.99);
        let read_mean = read_hist.mean() as u64;
        
        let read_result = BenchmarkResult {
            mode: "read_small".to_string(),
            concurrency: args.concurrency,
            duration_seconds: args.duration_seconds,
            ok_ops: read_ok,
            err_ops: read_err,
            qps: read_qps,
            latency_us_p50: read_p50,
            latency_us_p95: read_p95,
            latency_us_p99: read_p99,
            latency_us_mean: read_mean,
            backend: BackendInfo {
                service: args.service.clone(),
                endpoint: args.endpoint.clone(),
                region: args.region.clone(),
                bucket: args.bucket.clone(),
            },
        };
        
        println!("{}", serde_json::to_string_pretty(&read_result)?);
        println!();
        println!("READ - QPS: {:.2}, P50: {:.2}ms, P95: {:.2}ms, P99: {:.2}ms", 
                 read_qps, read_p50 as f64 / 1000.0, read_p95 as f64 / 1000.0, read_p99 as f64 / 1000.0);
        
        // Run write benchmark
        println!();
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("📊 Running WRITE Benchmark");
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        let write_state = Arc::new(BenchmarkState {
            op: op.clone(),
            keys: Arc::new(Vec::new()), // Empty for write mode
            object_size: args.object_size_bytes,
            prefix: prefix.clone(),
            next_key_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
        });
        
        let (write_ok, write_err, write_hist) = run_write_benchmark(write_state.clone(), duration, args.concurrency).await;
        let write_qps = write_ok as f64 / args.duration_seconds as f64;
        let write_p50 = write_hist.value_at_quantile(0.5);
        let write_p95 = write_hist.value_at_quantile(0.95);
        let write_p99 = write_hist.value_at_quantile(0.99);
        let write_mean = write_hist.mean() as u64;
        
        let write_result = BenchmarkResult {
            mode: "write_small".to_string(),
            concurrency: args.concurrency,
            duration_seconds: args.duration_seconds,
            ok_ops: write_ok,
            err_ops: write_err,
            qps: write_qps,
            latency_us_p50: write_p50,
            latency_us_p95: write_p95,
            latency_us_p99: write_p99,
            latency_us_mean: write_mean,
            backend: BackendInfo {
                service: args.service.clone(),
                endpoint: args.endpoint.clone(),
                region: args.region.clone(),
                bucket: args.bucket.clone(),
            },
        };
        
        println!("{}", serde_json::to_string_pretty(&write_result)?);
        println!();
        println!("WRITE - QPS: {:.2}, P50: {:.2}ms, P95: {:.2}ms, P99: {:.2}ms", 
                 write_qps, write_p50 as f64 / 1000.0, write_p95 as f64 / 1000.0, write_p99 as f64 / 1000.0);
        
        // Print combined summary
        println!();
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("📊 Combined Results Summary");
        println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
        println!("READ Operations:");
        println!("  QPS:               {:.2}", read_qps);
        println!("  Latency P50:       {:.2} ms", read_p50 as f64 / 1000.0);
        println!("  Latency P95:       {:.2} ms", read_p95 as f64 / 1000.0);
        println!("  Latency P99:       {:.2} ms", read_p99 as f64 / 1000.0);
        println!("  Successful Ops:    {}", read_ok);
        println!("WRITE Operations:");
        println!("  QPS:               {:.2}", write_qps);
        println!("  Latency P50:       {:.2} ms", write_p50 as f64 / 1000.0);
        println!("  Latency P95:       {:.2} ms", write_p95 as f64 / 1000.0);
        println!("  Latency P99:       {:.2} ms", write_p99 as f64 / 1000.0);
        println!("  Successful Ops:    {}", write_ok);
        
        // Cleanup if requested
        if args.cleanup && !read_state.keys.is_empty() {
            println!();
            println!("🧹 Cleaning up {} objects...", read_state.keys.len());
            let mut cleaned = 0;
            for key in read_state.keys.iter() {
                if op.delete(key).await.is_ok() {
                    cleaned += 1;
                    if cleaned % 1000 == 0 {
                        println!("  Deleted {}/{} objects...", cleaned, read_state.keys.len());
                    }
                }
            }
            println!("✅ Cleaned up {} objects", cleaned);
        }
        
        return Ok(());
    }
    
    // Pre-create dataset for modes that need it
    let keys = if matches!(args.mode.as_str(), "stat" | "read_small" | "delete" | "list") {
        create_dataset(&op, &prefix, args.objects, args.object_size_bytes).await?
    } else {
        Vec::new()
    };
    
    let state = Arc::new(BenchmarkState {
        op,
        keys: Arc::new(keys),
        object_size: args.object_size_bytes,
        prefix: prefix.clone(),
        next_key_index: Arc::new(std::sync::atomic::AtomicUsize::new(0)),
    });
    
    let (ok_ops, err_ops, histogram) = match args.mode.as_str() {
        "stat" => run_stat_benchmark(state.clone(), duration, args.concurrency).await,
        "read_small" => run_read_benchmark(state.clone(), duration, args.concurrency).await,
        "write_small" => run_write_benchmark(state.clone(), duration, args.concurrency).await,
        "delete" => run_delete_benchmark(state.clone(), duration, args.concurrency).await,
        "list" => run_list_benchmark(state.clone(), duration, args.concurrency).await,
        _ => anyhow::bail!("Unknown mode: {}. Supported modes: stat, read_small, write_small, delete, list, read_write", args.mode),
    };
    
    let _total_ops = ok_ops + err_ops;
    let qps = ok_ops as f64 / args.duration_seconds as f64;
    let p50 = histogram.value_at_quantile(0.5);
    let p95 = histogram.value_at_quantile(0.95);
    let p99 = histogram.value_at_quantile(0.99);
    let mean = histogram.mean() as u64;
    
    let result = BenchmarkResult {
        mode: args.mode.clone(),
        concurrency: args.concurrency,
        duration_seconds: args.duration_seconds,
        ok_ops,
        err_ops,
        qps,
        latency_us_p50: p50,
        latency_us_p95: p95,
        latency_us_p99: p99,
        latency_us_mean: mean,
        backend: BackendInfo {
            service: args.service.clone(),
            endpoint: args.endpoint.clone(),
            region: args.region.clone(),
            bucket: args.bucket.clone(),
        },
    };
    
    // Print JSON output
    println!();
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📊 Results (JSON)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("{}", serde_json::to_string_pretty(&result)?);
    
    // Print human-readable summary
    println!();
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📊 Results (Human-readable)");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("Mode:              {}", result.mode);
    println!("Concurrency:       {}", result.concurrency);
    println!("Duration:          {}s", result.duration_seconds);
    println!("Successful Ops:     {}", result.ok_ops);
    println!("Failed Ops:        {}", result.err_ops);
    println!("QPS:               {:.2}", result.qps);
    println!("Latency P50:        {} μs ({:.2} ms)", result.latency_us_p50, result.latency_us_p50 as f64 / 1000.0);
    println!("Latency P95:        {} μs ({:.2} ms)", result.latency_us_p95, result.latency_us_p95 as f64 / 1000.0);
    println!("Latency P99:        {} μs ({:.2} ms)", result.latency_us_p99, result.latency_us_p99 as f64 / 1000.0);
    println!("Latency Mean:       {} μs ({:.2} ms)", result.latency_us_mean, result.latency_us_mean as f64 / 1000.0);
    println!("Backend:            {}://{}/{}", result.backend.service, result.backend.endpoint, result.backend.bucket);
    
    // Cleanup if requested
    if args.cleanup && !state.keys.is_empty() {
        println!();
        println!("🧹 Cleaning up {} objects...", state.keys.len());
        let mut cleaned = 0;
        for key in state.keys.iter() {
            if state.op.delete(key).await.is_ok() {
                cleaned += 1;
                if cleaned % 1000 == 0 {
                    println!("  Deleted {}/{} objects...", cleaned, state.keys.len());
                }
            }
        }
        println!("✅ Cleaned up {} objects", cleaned);
    }
    
    Ok(())
}

