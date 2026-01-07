# Preflight Server Validation Script (Signed URL Upload)

## Overview

This repository contains a **preflight validation script** (`preflight.sh`) that is executed on each server node to collect:

- OS and kernel details  
- CPU, memory, disk information  
- Network interfaces, routing, and egress validation  
- Connectivity checks (DNS, HTTP/HTTPS)  
- Kubernetes / K3s / RKE2 detection  
- Runtime services and tooling availability  

The generated report is **uploaded directly to Google Cloud Storage (GCS)** using a **Signed URL**, so **no service account key or GCP credentials are required on the server nodes**.

---


Each node only receives a **temporary HTTPS URL** that allows uploading **one report file**.

---

## How the Flow Works

1. **Shush Team** generates a **Signed PUT URL**
2. The URL is shared with the carrier
3. On the server:
   - `preflight.sh` runs
   - Generates a report file in `/tmp`
   - Uploads it via HTTPS `PUT` to GCS
4. The Signed URL expires automatically

---

## Requirements (on server nodes)

Minimum:
- `bash`
- `curl`
- `ip`
- `ping`

Optional (auto-detected):
- `kubectl`, `k3s`, `rke2`
- `jq`, `traceroute`, `ss`
- `docker`, `containerd`, `podman`

---

## Usage on Server Nodes

### Basic run
```bash
sudo ./preflight.sh <carrier-name> --upload-url "<SIGNED_PUT_URL>"
```

### Quick mode
```bash
sudo ./preflight.sh <carrier-name> --quick --upload-url "<SIGNED_PUT_URL>"
```

### Using environment variable (recommended)
```bash
UPLOAD_URL="<SIGNED_PUT_URL>" sudo ./preflight.sh <carrier-name>
```

---

## Carrier Name Rules

- Lowercased automatically  
- Only letters, numbers, hyphens allowed  
- Used for tagging and reporting  

Examples:
```
Mint Mobile  → mint-mobile
Vodafone_UK → vodafone-uk
```

---

## Report Output

Local file:
```
/tmp/preflight_<hostname>_<YYYY-MM-DD_HHMMSS>.txt
```

Uploaded path:
```
gs://<bucket>/reports/<carrier>/<date>/preflight_<hostname>_<timestamp>.txt
```

---

## Generating a Signed Upload URL (Operator Only)

### Install dependencies
```bash
pip install google-cloud-storage google-auth
```

### Signed URL generator
```python
from datetime import timedelta
from google.cloud import storage
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--bucket", required=True)
parser.add_argument("--object", required=True)
parser.add_argument("--minutes", type=int, default=120)
args = parser.parse_args()

client = storage.Client()
bucket = client.bucket(args.bucket)
blob = bucket.blob(args.object)

url = blob.generate_signed_url(
    version="v4",
    expiration=timedelta(minutes=args.minutes),
    method="PUT",
    content_type="text/plain",
)

print(url)
```

### Generate URL
```bash
python3 make_put_signed_url.py \
  --bucket cariiername \
  --object reports/cariiername/$(date +%F)/preflight_node01.txt \
  --minutes 15
```

---

## Security Notes

- URLs are time-bound
- Only allow PUT
- No credentials stored on servers

---
