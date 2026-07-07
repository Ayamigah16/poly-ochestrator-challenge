# ECS vs EKS — Deployment Comparison for Poly Orchestrator

Both platforms run the same Docker image and share the same backing services (RDS PostgreSQL, ElastiCache Redis). The difference is entirely in how the application container is scheduled, scaled, and operated.

---

## Architecture Overview

### ECS (Elastic Container Service) — Fargate

```
Internet
    │
    ▼
[ALB] ──────────────────────────────────────────────┐
    │                                               │
    ├──▶ [ECS Task: app] private subnet a           │
    └──▶ [ECS Task: app] private subnet b           │
              │                                     │
              ├──▶ [RDS PostgreSQL] private subnet  │
              └──▶ [ElastiCache Redis] private      │
                                                    │
[CloudWatch Logs] ◀── stdout from all tasks ────────┘
[Secrets Manager] ◀── task reads secrets at startup
[App Auto Scaling] ──▶ adjusts desired_count on CPU
```

**Key primitives:** Task Definition → ECS Service → ALB Target Group → Tasks (Fargate)

---

### EKS (Elastic Kubernetes Service)

```
Internet
    │
    ▼
[Nginx Ingress] ──────────────────────────────────────┐
    │                                                  │
    ├──▶ [Pod: app] node 1 (SPOT t3.medium)            │
    └──▶ [Pod: app] node 2 (SPOT t3.medium)            │
              │                                        │
              ├──▶ [RDS PostgreSQL] private subnet     │
              └──▶ [ElastiCache Redis] private         │
                                                       │
[HPA] ──▶ adjusts replica count on CPU/memory         │
[NetworkPolicy] ──▶ deny-all ingress except ingress   │
[ConfigMap + Secret] ──▶ injected as env vars         │
```

**Key primitives:** Deployment → ReplicaSet → Pods → Service → Ingress → ALB (via controller)

---

## Side-by-Side Comparison

| Dimension | ECS (Fargate) | EKS |
| --- | --- | --- |
| **Control plane** | Fully managed by AWS; no nodes to manage | Managed control plane; **you manage worker nodes** (or use Fargate for EKS) |
| **Infrastructure footprint** | Zero EC2 instances; pay per task CPU/memory | EC2 nodes (SPOT or on-demand) always running; pay whether idle or not |
| **Scaling unit** | ECS Task (container group) | Pod |
| **Horizontal scaling** | Application Auto Scaling (target tracking on CPU/memory/custom) | HPA (CPU, memory, custom metrics via KEDA) |
| **Config injection** | Env vars in Task Definition + Secrets Manager `secrets:` | ConfigMap + Kubernetes Secret (`envFrom:`) |
| **Secrets management** | AWS Secrets Manager (native integration, auto-rotated) | Kubernetes Secrets (base64 encoded, or ESO + Secrets Manager) |
| **Networking model** | `awsvpc` mode — each task gets its own ENI and private IP | Pod networking — pods share node ENI (vpc-cni plugin) |
| **Load balancing** | ALB → Target Group (IP mode) | Service → Ingress → ALB (via AWS Load Balancer Controller) |
| **Rolling updates** | ECS deployment circuit breaker; configurable min/max healthy % | RollingUpdate strategy; `maxSurge` / `maxUnavailable` |
| **Rollback** | Manual (re-deploy previous task definition revision) | `kubectl rollout undo deployment/...` |
| **Logging** | CloudWatch Logs via `awslogs` log driver | stdout → Fluent Bit / CloudWatch Container Insights (opt-in) |
| **Observability** | CloudWatch metrics (CPU, memory, request count) natively | Prometheus + Grafana (self-managed); CloudWatch Container Insights opt-in |
| **Service mesh** | AWS App Mesh (optional) | Istio / Linkerd / AWS App Mesh (optional) |
| **Multi-tenancy** | No namespaces; IAM + task roles for isolation | Kubernetes namespaces + RBAC + NetworkPolicy |
| **Custom resources** | Not applicable | CRDs — extend the API (cert-manager, ESO, KEDA, etc.) |
| **Migration job** | `aws ecs run-task` one-shot task | `kubectl apply` Job + wait for `condition=Complete` |
| **Startup time** | ~30–60s (Fargate cold start) | ~5–15s (pod on warm node) |
| **Operational complexity** | Low — AWS manages scheduling, node health | Medium-High — cluster upgrades, node groups, add-ons to maintain |
| **Learning curve** | Low (task definition JSON, ECS console) | High (kubectl, YAML, RBAC, networking, add-ons) |

---

## Cost Model

Costs below are illustrative for 2 replicas running continuously in `eu-west-1`.

### ECS Fargate (this project: 0.5 vCPU / 1 GB per task)

| Resource | Spec | Monthly est. |
| --- | --- | --- |
| Fargate tasks (2×) | 0.5 vCPU × 2 | ~$15 |
| Fargate memory (2×) | 1 GB × 2 | ~$3 |
| RDS `db.t3.micro` | Single-AZ | ~$15 |
| ElastiCache `cache.t3.micro` | Single node | ~$12 |
| ALB | 1 LCU/hr (light traffic) | ~$20 |
| NAT Gateway | 1 AZ | ~$35 |
| **Total** | | **~$100/month** |

### EKS (this project: SPOT `t3.medium`, 2 nodes min)

| Resource | Spec | Monthly est. |
| --- | --- | --- |
| EKS control plane | Managed | ~$73 |
| SPOT `t3.medium` (2 nodes) | ~70% discount | ~$20 |
| RDS `db.t3.micro` | Single-AZ | ~$15 |
| ElastiCache `cache.t3.micro` | Single node | ~$12 |
| ALB (Ingress) | 1 LCU/hr | ~$20 |
| NAT Gateway | 1 AZ | ~$35 |
| **Total** | | **~$175/month** |

> ECS Fargate is cheaper at low scale. EKS becomes cost-competitive at higher density because many pods share the same EC2 node. At ~8+ pods, EKS SPOT nodes are cheaper than equivalent Fargate tasks.

---

## Deployment Commands

### ECS

```bash
# 1. Push image to ECR
aws ecr get-login-password --region eu-west-1 \
  | docker login --username AWS --password-stdin <ecr-url>
docker tag poly-orchestrator:local <ecr-url>:latest
docker push <ecr-url>:latest

# 2. Provision infrastructure
cd infra/terraform/ecs
./scripts/terraform-apply.sh --env development --dir infra/terraform/ecs

# 3. Run database migrations (one-shot Fargate task)
aws ecs run-task \
  --cluster poly-orchestrator-development \
  --task-definition poly-orchestrator-development \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx]}" \
  --overrides '{"containerOverrides":[{"name":"app","command":["python","-m","alembic","upgrade","head"]}]}'

# 4. Deploy new image (trigger rolling update)
aws ecs update-service \
  --cluster poly-orchestrator-development \
  --service poly-orchestrator-development \
  --force-new-deployment
```

### EKS

```bash
# 1. Push image to ECR (or load into kind)
kind load docker-image poly-orchestrator:local --name devsecops-lab
# OR: push to ECR and update deployment image

# 2. Provision infrastructure
./scripts/terraform-apply.sh --env development

# 3. Deploy (applies manifests + runs migration Job + watches rollout)
./scripts/k8s-deploy.sh --image poly-orchestrator:local

# 4. Rollback if needed
./scripts/k8s-rollback.sh
```

---

## When to Choose ECS

- Team is AWS-native but not Kubernetes-familiar
- Workload is a small number of long-running services (< 20 services)
- You want zero node management overhead
- Budget is tight at low scale (< 8 replicas)
- You need tight AWS service integration without abstraction layers

## When to Choose EKS

- Team already knows Kubernetes
- You need multi-cloud portability (same manifests work on GKE, AKS, kind)
- You have many services that benefit from namespace isolation and RBAC
- You need advanced scheduling (GPU, taints, affinity, topology spread)
- You want a rich ecosystem of CNCF tools (KEDA, Argo, Flux, cert-manager)
- Workload density is high — many pods per node amortises the $73/month control plane

---

## Migration Path (ECS → EKS or vice versa)

Both platforms use the **same Docker image** and the **same backing services** (RDS, ElastiCache). Migration is straightforward:

1. Push image to ECR (works for both)
2. Provision the target platform's Terraform module
3. Point the new platform at the existing RDS endpoint
4. Run `alembic upgrade head` once on the new platform (no-op if schema is current)
5. Cut over DNS / ALB to the new platform
6. Decommission the old platform

Total migration effort: **< 1 day** for this service, since no stateful data moves.

---

## Terraform Structure

```
infra/terraform/
├── main.tf           # EKS: VPC + EKS cluster + RDS + ElastiCache
├── variables.tf
├── outputs.tf
└── ecs/
    ├── main.tf       # ECS: VPC + ECR + ECS cluster + ALB + RDS + ElastiCache + IAM
    ├── variables.tf
    └── outputs.tf
```

Both modules use an S3 backend with separate state keys:
- EKS: `prod/terraform.tfstate`
- ECS: `ecs/terraform.tfstate`
