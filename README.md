# Phase 1: HA Architecture — VPC, ALB, Auto Scaling

A separate, deliberate build covering concepts the [devops-journey](https://github.com/HARSHITHA-U/devops-journey) project never touched: plain EC2 instances (no Kubernetes) behind a load balancer, with high availability and scaling handled entirely at the AWS infrastructure layer instead of the container layer.

This is Phase 1 of a 4-phase plan. Phase 2 covers Kubernetes multi-tenancy, Phase 3 a serverless event pipeline, and Phase 4 database migrations with StatefulSets.

## Architecture

```
     ![Phase 1 architecture](docs/phase1_full_architecture.svg)
```

Two independent lifecycles run through this design:

1. **Request path (per request):** internet → ALB → listener → target group → a healthy instance → back.
2. **Capacity path (background, continuous):** CloudWatch watches average CPU → scaling policy adjusts the ASG's desired count → ASG launches/terminates instances → each change is registered in the target group automatically.

## What's implemented so far

**Networking**
- VPC (`10.2.0.0/16`) built from scratch — not reusing an existing one.
- 2 public + 2 private subnets, one of each per Availability Zone (`us-east-1a`, `us-east-1b`)
- Internet Gateway for the public subnets; a single NAT Gateway (in `us-east-1a`) for outbound-only internet from the private subnets
- Separate public and private route tables, each shared across both subnets in that tier (subnets with identical routing needs don't need separate tables)

**Security**
- Two security groups instead of one shared group: an ALB SG (port 80 from the internet) and an instance SG (port 80 from the ALB SG only, never from a CIDR) — this is what actually enforces that instances are never directly reachable, on top of them having no public IP
- A least-privilege IAM policy for this phase's user.

**Compute & scaling**
- A Launch Template (Amazon Linux 2023, looked up via a `data` source rather than a hardcoded AMI ID, so it doesn't go stale) with `user_data` that installs Apache and serves a page showing the instance's own hostname
- An Auto Scaling Group (`min 2`, `max 4`, `desired 2`) spanning both private subnets, using ELB (not EC2) health checks, so an instance whose app never started gets replaced even though the VM itself is running
- A target-tracking scaling policy holding average CPU at 50%, which creates its own CloudWatch alarms

**Verified so far**
- `terraform apply` completes cleanly and both instances reach `healthy` in the target group

**Not yet done — planned for the next session**
- Confirming the load-balancing behavior itself (alternating hostnames on refresh, direct instance access blocked)
- Self-healing test: manually terminating an instance and timing the ASG's replacement
- A deliberate break: removing the ALB→instance security group rule by hand and catching the drift with `terraform plan`
- Scale-out test: driving CPU up via a `/cgi-bin/burn` endpoint and watching the CloudWatch alarm and ASG activity
- Kubernetes-side parallel: an HPA on an existing Deployment, as the direct comparison to this phase's target-tracking policy

## Repository structure

```
.
├── terraform/
│   ├── main.tf              # provider config
│   ├── network.tf           # VPC, subnets, IGW, EIP, NAT, route tables
│   ├── alb.tf                # target group, ALB, listener
│   ├── compute.tf            # AMI lookup, launch template, ASG, scaling policy
│   ├── outputs.tf            # ALB DNS name
│   ├── user_data.sh          # instance boot script (installs Apache)
│   └── .terraform.lock.hcl   # pinned provider version (state/.terraform/ excluded — see .gitignore)
├── screenshots/
└── README.md
```

## Running it

```bash
cd terraform
terraform init
terraform plan     # check state vs. reality before applying — a partial/interrupted
                    # apply can leave orphaned resources Terraform doesn't know about
terraform apply
```

Cost while running: a NAT Gateway ($0.045/hr), the ALB ($0.02/hr + usage), and two `t3.micro` instances, together roughly $0.10–0.12/hr. Check current AWS pricing for your region.

```bash
terraform destroy  # run at the end of every session
```

## Notes from building this

- A destroyed environment's state means the next `terraform plan` should show every resource as "to add" — if it instead shows "no changes," the previous destroy never actually ran, and the NAT Gateway has likely been billing since.
- `filebase64()` fails at plan time, before anything touches AWS, if the referenced file doesn't exist or is misnamed — caught an early typo (`user` instead of `user_data.sh`) this way with zero cost impact.
- `terraform apply` can fail partway through with `AccessDenied` after already creating some resources (the network layer succeeded before the ELB actions were denied) — Terraform doesn't roll back on this kind of failure, so already-created resources keep billing until the permission is fixed and `apply` is re-run.
- Rather than widen the existing devops-journey IAM policy, a new policy was created and attached separately for this phase's ELB/ASG/CloudWatch-alarm permissions — keeps the working policy from the first project untouched and makes clear what each phase actually needed.
- ALB target group health checks and ASG health check type are two different settings: the target group defines *how* a health check works (path, thresholds, interval), while the ASG's `health_check_type` decides whether the ASG trusts that check (`ELB`) or only whether the EC2 instance itself is running (`EC2`) when deciding to replace an instance.
- One route table can be (and here, is) shared by multiple subnets with identical routing needs — a second identical table would just be a copy to maintain. Per-subnet route tables become necessary once subnets need genuinely different routing, e.g. one NAT Gateway per AZ in a fully HA design.
- The single NAT Gateway is a known, accepted single point of failure for this build: if `us-east-1a` goes down, the private subnet in `us-east-1b` loses outbound internet even though its own EC2 instance is unaffected. A per-AZ NAT would remove this but doubles NAT cost.

## Roadmap

- [x] VPC, subnets, IGW, NAT Gateway, route tables — built from scratch
- [x] Security groups (ALB + instance, referencing each other rather than CIDRs)
- [x] Launch Template, Target Group, ALB + listener
- [x] Auto Scaling Group with ELB health checks
- [x] Target-tracking scaling policy (CPU 50%)
- [ ] Verified load-balancing behavior (hostname alternation, direct-access block)
- [ ] Self-healing test (manual instance termination)
- [ ] Drift test (manual security group change caught by `terraform plan`)
- [ ] Scale-out test (CPU burn endpoint, CloudWatch alarm, ASG activity)
- [ ] Kubernetes-side HPA exercise (comparison to this phase's scaling policy)
