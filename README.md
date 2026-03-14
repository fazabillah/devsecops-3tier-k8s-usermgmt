# DevSecOps 3-Tier User Management on AWS EKS

A production-grade CI/CD pipeline built around a React + Node.js + MySQL application, deployed to AWS EKS via Terraform, with security scanning gated into every stage before an image is built or pushed.

The cluster is not running — it was destroyed after validation to avoid ongoing costs. It can be reprovisioned from scratch with `terraform apply` in the `eks/` directory.

---

## Why This Pipeline Exists

A secret committed to a branch before being caught in code review can take days to rotate. GitLeaks runs on every push, against both the `client` and `api` directories, before any image is built. If it exits non-zero, the pipeline stops.

The frontend env vars are baked into the React bundle at build time — a misconfigured `REACT_APP_API_BASE_URL` means every API call in production silently fails at the browser, not the server. The Dockerfile uses a multi-stage build with `npm ci` in the builder stage, so the production domain has to be correct before the image is assembled, not patched in afterwards.

cert-manager renews the Let's Encrypt certificate automatically using ACME HTTP-01 validation through the NGINX Ingress controller. The domain resolves through Route 53, but CoreDNS needed an explicit override to forward to `8.8.8.8` — the AWS VPC resolver does not handle the `.my` TLD, and without the override every DNS lookup for `learndevops.my` from inside the cluster silently fails.

The EBS CSI driver is installed as an EKS addon and requires an IRSA-backed IAM role with OIDC federation. Getting that wired up — the OIDC provider, the trust policy with the exact `sub` condition scoped to `system:serviceaccount:kube-system:ebs-csi-controller-sa`, and the addon referencing the role ARN — was the main infrastructure blocker. The Terraform in `eks/main.tf` handles all of it end-to-end.

---

## Architecture

```
Developer
    │
    ▼
GitHub (develop branch)
    │
    ▼
Jenkins CI ──────────────────────────────────────────────┐
  1. Syntax check (node --check)                          │
  2. GitLeaks secret scan                                 │
  3. SonarQube SAST + Quality Gate                        │
  4. Trivy filesystem scan                                │
  5. Docker build (multi-stage)                           │
  6. Trivy image scan                                     │
  7. Push to DockerHub ────────────────────────────────── │
    │                                                     │
    ▼                                                     │
Manual Approval Gate                                      │
    │                                                     │
    ▼                                                     │
kubectl apply → AWS EKS (us-east-1)                       │
    │                                                     │
    ├── Namespace: prod                                   │
    │     ├── frontend (React, nginx:alpine)              │
    │     ├── backend (Node.js/Express :5000)             │
    │     └── mysql (StatefulSet, EBS 5Gi)                │
    │                                                     │
    ├── NGINX Ingress Controller (LoadBalancer)           │
    │     └── learndevops.my → frontend / /api → backend │
    │                                                     │
    ├── cert-manager (Let's Encrypt, ACME HTTP-01)        │
    │                                                     │
    └── monitoring namespace                              │
          ├── Prometheus (kube-prometheus-stack, EBS 5Gi) │
          └── Grafana                                     │
```

---

## The Pipeline

| Stage | What it does | Failure behaviour |
|---|---|---|
| Git Checkout | Clones `develop` branch | Aborts |
| Frontend Compilation | `node --check` on all `.js` files in `client/` | Aborts |
| Backend Compilation | `node --check` on all `.js` files in `api/` | Aborts |
| GitLeaks Scan | Scans `client/` and `api/` for secrets (`--exit-code 1`) | Aborts |
| SonarQube Analysis | SAST scan via sonar-scanner | Continues to Quality Gate |
| Quality Gate Check | Waits on SonarQube quality gate result (1 hr timeout) | `abortPipeline: false` — reports but continues |
| Trivy FS Scan | Scans the full working directory for CVEs; writes `fs-report.html` | Continues (report artifact preserved) |
| Build & Push Backend | Builds `api/` image, runs Trivy image scan, pushes to DockerHub | Aborts if Trivy finds critical CVEs |
| Build & Push Frontend | Builds `client/` image with multi-stage Dockerfile, runs Trivy image scan, pushes | Aborts if Trivy finds critical CVEs |
| Manual Approval | Jenkins `input` step — requires human sign-off before prod deploy | Times out after 1 hour; aborts |
| Deploy to Prod | `kubectl apply` for StorageClass, MySQL, backend, frontend, ClusterIssuer, Ingress in `prod` namespace | Aborts |
| Verify Deployment | `kubectl get pods -n prod` + `kubectl get ingress -n prod` | Reports |

The CI stages (checkout through Trivy FS) run on every push to `develop`. The image build and CD stages run on the same pipeline, gated by the manual approval.

---

## Infrastructure

All infrastructure is defined in `eks/main.tf`. A single `terraform apply` creates a VPC (`10.0.0.0/16`) with two public subnets across `us-east-1a` and `us-east-1b`, an EKS cluster named `devopsfaza-cluster`, a node group of 3× `t2.medium` instances, an OIDC provider for IRSA, and the EBS CSI driver addon wired to an IAM role scoped to its service account. Prometheus storage and MySQL data both use `ReadWriteOnce` EBS volumes via the `ebs-sc` StorageClass — which is why the CSI driver and IRSA setup have to be correct before any StatefulSet or PVC can schedule.

---

## Tech Stack

| Category | Tools |
|---|---|
| Application | React 18, Node.js 24 / Express, MySQL 8 |
| Containers | Docker (multi-stage builds), DockerHub |
| Orchestration | Kubernetes (AWS EKS), NGINX Ingress Controller |
| CI/CD | Jenkins (Declarative Pipeline), kubectl |
| Security scanning | GitLeaks, SonarQube, Trivy |
| Infrastructure as Code | Terraform |
| Observability | Prometheus, Grafana (kube-prometheus-stack Helm chart) |
| DNS / TLS | Route 53, cert-manager, Let's Encrypt (ACME HTTP-01) |

---

## Engineering Decisions

**Headless Service for MySQL.** The MySQL Service uses `clusterIP: None`. StatefulSets require a headless service to form stable DNS names — the backend connects via `mysql.prod.svc.cluster.local`, which resolves to the pod directly. A standard ClusterIP service would work for the connection but breaks StatefulSet DNS guarantees and prevents orderly pod identity management.

**React env vars baked at build time.** `REACT_APP_API_BASE_URL` is read by the React build process at `npm run build`, not at container startup. This means the production API URL has to be set in the build environment before the image is assembled. Getting this wrong produces a frontend that appears functional but sends every API request to `localhost` or an empty string — the error shows up in the browser console, not in any server log.

**CoreDNS forwarding override for `.my` TLD.** The AWS VPC resolver (`169.254.169.253`) does not resolve `.my` domains from inside the cluster. A CoreDNS ConfigMap override forwards unknown zones to `8.8.8.8` so that cert-manager's ACME HTTP-01 challenge and the Ingress domain validation both work correctly.

**`imagePullPolicy: Always` with `:latest` tags.** The pipeline pushes images tagged `:latest`. Without `imagePullPolicy: Always`, Kubernetes skips the pull if an image with that tag is already present on the node — meaning a new deployment can silently run the previous image. Always-pull ensures the node fetches from DockerHub on every rollout.

**AlertManager disabled.** `kube-prometheus-stack` ships with AlertManager enabled by default. For a single-team project where Jenkins already sends Slack notifications on build failure, running a second alerting system adds memory overhead on `t2.medium` nodes without adding coverage. The `monitoring/values.yaml` sets `alertmanager.enabled: false` explicitly.

**ELK stack excluded.** Elasticsearch alone consumes ~1.5 GB of heap at minimum. On a 3× `t2.medium` cluster that's already running Prometheus, Grafana, the EBS CSI driver, cert-manager, NGINX Ingress, and the application itself, adding Elasticsearch would cause pod evictions. Prometheus covers the observability requirement within the available memory budget.

---

## Security Model

GitLeaks runs first, before any other tool, because it's the fastest check and a leaked secret in the source is the highest-priority signal. It uses `--exit-code 1` so the pipeline hard-stops on any finding.

SonarQube performs static analysis across both the React client and the Express API. The Quality Gate step waits for the SonarQube server to return a pass/fail result — `abortPipeline: false` is set because the project is under active development and a gate failure produces a visible warning without blocking image delivery entirely. In a team environment this would be flipped to `true`.

Trivy runs twice: once as a filesystem scan across the whole working directory before any image is built, and once against each built image before it's pushed to DockerHub. The filesystem scan catches vulnerable dependencies. The image scan catches anything introduced by the base image layers — `node:22-alpine` and `nginx:alpine` in this project. Reports are saved as HTML artifacts on the Jenkins job.

TLS is handled end-to-end by cert-manager. The ClusterIssuer is configured against the Let's Encrypt production ACME endpoint. cert-manager handles certificate issuance, storage in a Kubernetes Secret, and renewal — no manual certificate management required.

---

## Local Development

The full stack runs locally with Docker Compose:

```bash
docker compose up --build
```

The React client is available at `http://localhost:3000`. The backend API runs on port `5001`. MySQL initialises the `crud_app` database and `users` table automatically from `mysql-init/`.

---

## Repository Structure

```
.
├── api/                  # Node.js/Express backend
├── client/               # React frontend (multi-stage Dockerfile)
├── eks/                  # Terraform: VPC, EKS cluster, IRSA, EBS CSI
├── k8s/                  # Kubernetes manifests: app, ingress, cert-manager
├── monitoring/           # Helm values for kube-prometheus-stack
├── mysql-init/           # SQL init scripts mounted into the MySQL container
├── tutor_sample/         # Reference Jenkinsfile from the source tutorial
├── Jenkins_CI_pipeline   # Active Jenkinsfile (CI stages)
└── docker-compose.yml    # Local development stack
```
