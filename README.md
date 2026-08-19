# devbox

An ephemeral, browser-accessible development environment on AWS, built to work on the [`cubesat-platform`](https://github.com/kaiser-lord/cubesat-platform/) project from anywhere — no dependency on any specific local machine.

Spin it up from any browser with an AWS Console login, work in a full VS Code interface over HTTPS, then tear it down completely when done. No idle cost, no open inbound ports, no SSH keys to manage.

---

## Why this exists

The `cubesat-platform` project needs ongoing Terraform, Python, and IoT development work. Depending on a single home machine to do that work creates a single point of failure — if that machine is unavailable, work stops. This project solves that by making the *development environment itself* disposable infrastructure: defined as code, launched on demand, destroyed when not in use.

Two ideas anchor the design:

- **The blueprint is permanent, the building is not.** Terraform configuration and state live in version control and S3 — durable. The EC2 instance they describe is ephemeral — built fresh each session, destroyed after.
- **Stopped costs money; destroyed doesn't.** A stopped EC2 instance still bills for its attached EBS volume. This project always destroys rather than stops, so cost only accrues while the box is actively in use.

---

## Architecture

```
┌─────────────────┐         ┌──────────────────────────────────────────┐
│   AWS CloudShell │         │              EC2 Instance                 │
│  (control plane, │         │         t4g.medium · Debian 13 ARM64      │
│   browser-only)  │         │                                            │
│                  │         │  ┌──────────────┐    ┌──────────────────┐ │
│  terraform apply │────────▶│  │ SSM Agent    │    │  code-server      │ │
│  terraform       │  IAM    │  │ (registers   │    │  127.0.0.1:8080   │ │
│    destroy       │  role   │  │  instance)   │    │  password from    │ │
│                  │         │  └──────────────┘    │  Secrets Manager  │ │
└─────────────────┘         │                       └─────────┬────────┘ │
                              │                                 │          │
                              │                       ┌─────────▼────────┐ │
                              │                       │  cloudflared      │ │
                              │                       │  Quick Tunnel     │ │
                              │                       └─────────┬────────┘ │
                              └─────────────────────────────────┼──────────┘
                                                                 │
                                                    https://*.trycloudflare.com
                                                                 │
                                                                 ▼
                                                        Any browser, anywhere
```

**Key design choice — no inbound ports.** The security group has zero ingress rules. SSM Session Manager (for the terminal / bootstrapping visibility) and the Cloudflare Tunnel (for reaching code-server) both work over **outbound** connections initiated *from* the instance. There is nothing to open, nothing to scan, nothing to patch for inbound exposure.

---

## Components

| Component | Purpose |
|---|---|
| **EC2 instance** (`t4g.medium`, Debian 13, ARM64) | The actual compute — cheap, Graviton-based, enough headroom for code-server + Terraform + a Python venv |
| **IAM role** (`cubesat-devbox-role`) | Assumed by the instance via instance profile. Carries `AmazonSSMManagedInstanceCore` + `AdministratorAccess` (reused from the existing `terraform-cubesat` user's permission set — see [Known trade-offs](#known-trade-offs-and-future-hardening)) |
| **Security group** (`devbox-sg`) | No inbound rules. Outbound: all traffic allowed |
| **SSM Session Manager** | Terminal access to the instance without SSH keys or open port 22 |
| **AWS Secrets Manager** (`devbox/code-server-password`) | Stores the code-server login password. Created once, manually, outside Terraform. Persists across every instance recreation |
| **code-server** | Browser-based VS Code, bound to `127.0.0.1:8080` only |
| **cloudflared (Quick Tunnel)** | Exposes code-server via a public, random `*.trycloudflare.com` HTTPS URL — no Cloudflare account or domain required |
| **Terraform backend** | S3 bucket `spartan-tfstate-7`, key `devbox/terraform.tfstate`, lock table `terraform-locks` — same backend infrastructure as `cubesat-platform`, separate state key |

---

## Repository structure

```
devbox/
├── .gitignore              # excludes .terraform/, *.tfstate, *.tfstate.backup
├── backend.tf              # S3 backend configuration
├── provider.tf             # AWS provider, region us-east-2
├── ami.tf                  # data source: latest official Debian 13 ARM64 AMI
├── security_group.tf       # aws_security_group: no ingress, all egress
├── main.tf                 # aws_instance resource
├── bootstrap.sh             # user_data script — everything that happens on first boot
└── .terraform.lock.hcl     # committed, for provider version consistency
```

---

## Setup, from zero

### 1. IAM role (one-time, manual — not managed by Terraform)

Created via IAM console:

1. IAM → Roles → Create role → Trusted entity: **AWS service** → Use case: **EC2**
2. Attach policies:
   - `AmazonSSMManagedInstanceCore` (AWS managed — grants SSM connectivity)
   - `AdministratorAccess` (reused from the existing `terraform-cubesat` IAM user's permission set)
3. Name: `cubesat-devbox-role`
4. Create — AWS auto-creates a matching instance profile with the same name for EC2-use roles created via console

Verify the instance profile name if unsure:
```bash
aws iam list-instance-profiles-for-role --role-name cubesat-devbox-role
```

### 2. AWS Secrets Manager — code-server password (one-time)

Created directly via CLI, **not** through Terraform — deliberately, so the password value never lands in Terraform state:

```bash
aws secretsmanager create-secret \
  --name devbox/code-server-password \
  --description "Password for code-server on the ephemeral devbox" \
  --secret-string "$(openssl rand -base64 24)"
```

This password persists across every future instance destroy/recreate cycle. It only changes if manually rotated.

### 3. CloudShell — Terraform + git access

CloudShell provides pre-authenticated AWS CLI access (uses whoever is logged into the console — no profile configuration needed) but does **not** come with Terraform installed.

```bash
# Install Terraform into home directory (persists across CloudShell sessions)
TF_VERSION="1.15.8"
curl -o terraform.zip https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip
unzip terraform.zip
mkdir -p ~/bin
mv terraform ~/bin/
rm terraform.zip
echo 'export PATH=$HOME/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

Clone this repo using a GitHub Personal Access Token (fine-grained, scoped to this repo, Contents read/write):

```bash
git clone https://github.com/<username>/devbox.git
cd devbox
```

### 4. Initialize and apply

```bash
terraform init
terraform plan
terraform apply
```

First boot takes 2–4 minutes for the full bootstrap chain to finish (package installs, code-server install, secret fetch, tunnel start) — the instance shows as "running" well before this finishes, so wait before testing.

### 5. Connect

Get the running instance ID:
```bash
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=cubesat-devbox" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text
```

Confirm SSM registration:
```bash
aws ssm describe-instance-information --region us-east-2
```

Start a session and retrieve the tunnel URL:
```bash
aws ssm start-session --target <INSTANCE_ID> --region us-east-2
sudo journalctl -u cloudflared-tunnel -n 50 --no-pager
```

Look for a line containing `https://<random-words>.trycloudflare.com` — this URL is different every time the instance is recreated.

Retrieve the password (same every time):
```bash
aws secretsmanager get-secret-value \
  --secret-id devbox/code-server-password \
  --region us-east-2 --query SecretString --output text
```

Open the tunnel URL in any browser, enter the password, and you have a full VS Code environment.

### 6. Destroy when done

```bash
terraform destroy
```

Always destroy, never leave stopped — this is the entire point of the design.

---

## `bootstrap.sh` walkthrough

Runs once, automatically, as root, on first boot (`user_data`), in this order:

1. **`export HOME=/root`** — required. See [Lessons learned](#lessons-learned).
2. **Install base tools**: `curl`, `sudo`, `unzip`, `git`
3. **Install and start the SSM agent** — Debian's official AMI does not ship with it pre-installed (unlike Amazon Linux). Downloaded directly from AWS's regional S3 bucket for the Debian ARM64 build, installed via `dpkg`, enabled as a systemd service.
4. **Install AWS CLI v2** (ARM64 build) — needed so the script itself can call Secrets Manager.
5. **Install code-server** via its official install script.
6. **Fetch the password** from Secrets Manager using the instance's IAM role — no credentials, no hardcoded values.
7. **Write code-server's config**, binding to `127.0.0.1:8080` only, with the fetched password.
8. **Start code-server** as a systemd service (`code-server@root`).
9. **Install cloudflared** (ARM64 `.deb`), create a systemd service that runs `cloudflared tunnel --url http://localhost:8080`, ordered to start *after* code-server so it doesn't try to tunnel to a port that isn't listening yet.

---

## Lessons learned

- **`user_data` scripts run without `$HOME` set.** Unlike an interactive login shell, the cloud-init environment that runs `user_data` doesn't set `$HOME`. Any tool relying on it implicitly (the AWS CLI installer, in this case) fails silently or loudly depending on the tool, and — combined with `set -e` — kills the rest of the script with no obvious explanation beyond a cryptic `HOME: parameter not set` line buried in the console log. Fix: always `export HOME=/root` at the top of any root-run boot script. This mirrors the same lesson learned on the `cubesat-platform` project.

- **Debian's official AMIs don't include the SSM agent.** Amazon Linux does, by default; Debian doesn't. If SSM registration never appears (`aws ssm describe-instance-information` returns an empty list) after a reasonable wait, this is the first thing to check — not a networking or IAM problem necessarily, just a missing agent. Confirmed by checking `aws ec2 get-console-output` for the actual boot log, which is the most reliable way to see what a `user_data` script actually did, since SSM itself isn't available yet to check interactively at that point.

- **A minimal, no-inbound-rule security group is enough — if outbound-initiated tools do the work.** Both SSM and Cloudflare Tunnel connect *out* to their respective services; neither needs anything opened *in*. This is a meaningfully stronger security posture than the traditional "open port 22, restrict by IP" SSH pattern, for zero extra configuration effort.

- **AWS CloudShell has no port-forwarding or preview capability.** `aws ssm start-session --document-name AWS-StartPortForwardingSession` runs successfully inside CloudShell and reports "waiting for connections," but nothing forwards that local port to an actual browser — CloudShell's `localhost` is internal to AWS's infrastructure, not reachable externally. This was discovered through direct testing, then confirmed via research, after initially assuming a preview button simply wasn't visible in this CloudShell version. The fix was pivoting to Cloudflare Tunnel, which sidesteps the whole problem by giving code-server its own public URL directly, with no port-forwarding step required at all.

- **Package availability differs between AMI base images.** `git` was assumed present on Debian's minimal cloud image and wasn't — caught only when trying to actually clone a repo inside code-server. Now explicitly installed in `bootstrap.sh`. Worth treating "minimal" cloud images as genuinely minimal rather than assuming common CLI tools are included.

- **Destroy, don't stop, between sessions.** Reinforced through actual practice across this project: a stopped EC2 instance still bills for its EBS volume; a destroyed one costs nothing. Since Terraform state and configuration persist independently in S3 and GitHub, there is no real cost — in time or otherwise — to destroying between every session. This discipline was maintained consistently throughout building this project, including mid-build before the tunnel setup was even finished.

- **The code-server password is static across recreations; the tunnel URL is not.** The password lives in Secrets Manager, independent of the EC2 instance's lifecycle — same value every session unless manually rotated. The Cloudflare Quick Tunnel URL is regenerated by `cloudflared` every time the service starts, meaning a fresh instance always means a fresh URL, retrieved via `journalctl`. This is an accepted trade-off for avoiding the setup cost of a paid domain and named tunnel.

---

## Known trade-offs and future hardening

These were conscious, documented decisions made to prioritize momentum while learning the pattern — not oversights. Worth revisiting as this environment matures or if it's ever used for anything beyond solo personal development:

- **`AdministratorAccess` on the instance role.** Reused directly from the `terraform-cubesat` IAM user rather than scoped to only what this specific box needs (SSM, Secrets Manager read for one secret, S3/DynamoDB for the Terraform backend). Acceptable for a single-user personal account; would need tightening to least-privilege before use in any shared or production-adjacent context.

- **Cloudflare Quick Tunnel has no built-in authentication of its own.** Anyone with the generated URL and the code-server password can access the environment. The URL is long, random, and short-lived (changes every recreation), which provides reasonable practical protection, but this is not equivalent to genuine access control. A named tunnel with Cloudflare Access (identity-based auth in front of the tunnel) would close this gap if stronger guarantees are needed later.

- **No stable, memorable URL.** Every session requires an `journalctl` lookup to find the current tunnel address. Switching to a named Cloudflare Tunnel tied to a domain would trade a small amount of one-time setup for a permanent, predictable URL.

- **`dynamodb_table` backend locking parameter is deprecated** in favor of `use_lockfile`, per current Terraform versions. Not yet migrated, to keep the locking mechanism consistent with the `cubesat-platform` project's backend, which uses the same pattern. Worth a deliberate, coordinated upgrade across both projects rather than diverging one first.

---

## Quick reference

```bash
# Spin up
cd devbox && terraform apply

# Find the instance
aws ec2 describe-instances --region us-east-2 \
  --filters "Name=tag:Name,Values=cubesat-devbox" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text

# Get the tunnel URL
aws ssm start-session --target <INSTANCE_ID> --region us-east-2
sudo journalctl -u cloudflared-tunnel -n 50 --no-pager

# Get the password
aws secretsmanager get-secret-value --secret-id devbox/code-server-password \
  --region us-east-2 --query SecretString --output text

# Tear down
terraform destroy
```
