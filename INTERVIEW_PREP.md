# DevSecOps Interview Prep — 3-Tier K8s User Management Project

This guide derives questions directly from the decisions, bugs, and architecture of this project. Every answer references real choices made here.

---

## Kubernetes & Container Orchestration

---

**Q1. You used a StatefulSet for MySQL instead of a Deployment. Why, and what would you change in a real production setup?**

*What they're testing:* Whether you understand stateful workload semantics, not just that StatefulSets exist.

StatefulSets give each pod a stable, predictable identity — `mysql-0`, `mysql-1` — and a stable network hostname tied to the headless service. A Deployment would spin up pods with random suffixes and no stable DNS. For MySQL, that matters because the backend connects to `mysql` (the headless service name), and the Pod needs a consistent hostname to reattach to its PersistentVolume on restart.

In this project, the StatefulSet has one replica. That's acceptable for a portfolio environment, but in production you'd want at least three MySQL pods running in a Galera cluster or with MySQL Group Replication. You'd add a `PodDisruptionBudget` to prevent more than one pod from being evicted simultaneously during node maintenance. You'd also separate the read and write paths behind different services — one headless for writes to `mysql-0`, one for reads distributed across replicas — and possibly run an operator like the MySQL Operator for Kubernetes to manage failover automatically.

The current setup also has `reclaimPolicy: Retain` on the StorageClass, which is intentional — if you delete the StatefulSet, the PVC stays. In prod you'd document the exact process for attaching that volume to a replacement pod, because guessing wrong means downtime or data loss.

---

**Q2. How does DNS resolution work for the MySQL headless service, and how did you use it in the backend?**

*What they're testing:* Actual understanding of Kubernetes DNS, not surface-level knowledge.

A headless service (`clusterIP: None`) does not get a virtual IP. Instead, DNS returns the IP addresses of the individual pods directly. For a StatefulSet pod named `mysql-0` in namespace `prod`, the full DNS name is `mysql-0.mysql.prod.svc.cluster.local`. But in this project, the backend just connects to `DB_HOST: mysql` — the service name. When there's one replica, that DNS entry resolves directly to the pod IP, so it works.

The backend uses the `mysql2` Node.js client with `mysql.createConnection()`. It reads `DB_HOST` from the environment. In the Kubernetes deployment, that's set to `mysql`, which CoreDNS resolves to the pod IP through the headless service DNS record.

This caused a real issue during deployment. The backend pods started before MySQL was ready. The connection attempt at startup threw `ENOTFOUND mysql` because the pod DNS record hadn't propagated yet — MySQL-0 wasn't running. The fix was `kubectl rollout restart deployment/backend` after MySQL was confirmed healthy. In production you'd add an init container that polls for MySQL connectivity before the main container starts, or implement retry logic with exponential backoff in the connection setup.

---

**Q3. Why did you set `imagePullPolicy: Always` on the frontend? What real bug does it prevent?**

*What they're testing:* Understanding of how Kubernetes image caching interacts with `:latest` tags.

If you use `:latest` as your image tag — which this project does for both frontend and backend — Kubernetes defaults to `IfNotPresent`. That means if the image `fazabillah/frontend:latest` is already cached on the node, it won't pull a new one even if you pushed a new build with that same tag. The pod runs the old image silently.

This caused an actual incident here. After a frontend fix was built, pushed, and the deployment was restarted, users still saw the broken login page. The node had the previous `latest` image cached. `imagePullPolicy: Always` forces a pull every time a pod starts, ensuring the node gets the actual current image from the registry.

The production answer to this problem is different: stop using `:latest`. Tag images with the git commit SHA or build number — something like `fazabillah/frontend:abc1234`. That way `IfNotPresent` is safe because each unique build has a unique tag, and you get an audit trail of exactly which build is running in which environment.

---

**Q4. Your StorageClass uses `volumeBindingMode: WaitForFirstConsumer`. What does that mean, and when does it matter?**

*What they're testing:* Multi-AZ EBS awareness and zone affinity.

EBS volumes are zone-specific — an EBS volume created in `us-east-1a` cannot be attached to a node in `us-east-1b`. If you use `Immediate` binding mode, Kubernetes provisions the PVC immediately when it's created, before any pod is scheduled. The volume gets created in whatever zone the scheduler picks, which may not match where the pod eventually lands. Result: the pod gets scheduled to a node in a different AZ, tries to mount the volume, and fails.

`WaitForFirstConsumer` delays volume provisioning until a pod using the PVC is actually scheduled to a node. At that point, the provisioner knows which AZ the node is in and creates the EBS volume in that same zone. This project uses three nodes across `us-east-1a` and `us-east-1b`, so this mode is important for avoiding cross-AZ mount failures.

---

**Q5. Walk me through RollingUpdate for the backend deployment. What are your `maxSurge` and `maxUnavailable` settings, and why?**

*What they're testing:* Zero-downtime deployment mechanics and readiness probe dependency.

The backend deployment uses `maxSurge: 1, maxUnavailable: 0`. With three replicas, a rolling update creates one new pod (bringing the total to four), waits for it to become ready, then terminates one old pod. It repeats until all old pods are replaced. At no point are there fewer than three running pods.

`maxUnavailable: 0` is the key part. It means the update cannot proceed by removing a pod first — it must add one before removing one. This depends entirely on readiness probes being correct. If a new pod passes its readiness check but is actually broken, traffic starts going to it and the old pod gets killed. The deployment reports success while users get errors.

This project removed the health probes from an earlier version because they were causing CrashLoopBackOff during initial testing — the probes were firing before the app was ready. In production, you'd bring them back with appropriate `initialDelaySeconds` configured correctly for the app's startup time, or use a `startupProbe` that gives the container more time before liveness kicks in.

---

**Q6. Explain the RBAC setup you created for Jenkins. Why did you need both a Role and a ClusterRole?**

*What they're testing:* Understanding of Kubernetes RBAC scope boundaries.

A `Role` is namespace-scoped. The Jenkins `Role` in the `webapps` namespace covers secrets, configmaps, PVCs, services, pods, deployments, replicasets, statefulsets, ingresses, and HPAs — everything Jenkins needs to apply manifests in that namespace.

But `StorageClass` and `ClusterIssuer` (for cert-manager) are cluster-scoped resources. They don't live in any namespace, so a namespaced Role cannot grant access to them. This caused a real error during Jenkins pipeline runs: `storageclasses.storage.k8s.io is forbidden: User "system:serviceaccount:webapps:jenkins" cannot list resource "storageclasses"`. The fix was adding a `ClusterRole` with permissions on `persistentvolumes`, `storageclasses`, and `clusterissuers`, then binding it to the jenkins service account via a `ClusterRoleBinding`.

The principle of least privilege applies here — the ClusterRole only grants `get, list, watch, create, update, delete` on those specific resources, not across everything.

---

**Q7. What happens when a pod exceeds its memory limit? How did you choose resource values for your deployments?**

*What they're testing:* Kubernetes scheduler and OOM behavior, and practical sizing.

When a container exceeds its memory limit, the kernel's OOM killer terminates it and Kubernetes restarts the pod — without warning or graceful shutdown. CPU limits behave differently: the container gets throttled but keeps running.

Resource requests are what the scheduler uses to place pods. A node must have enough unrequested CPU and memory to satisfy the request. If the total requests across pods on a node exceed the node's allocatable resources, new pods stay pending.

In this project, the nodes are `t2.medium` (2 vCPU, 4Gi RAM). With three nodes and the kube-prometheus-stack running, memory is genuinely constrained. AlertManager was disabled specifically because it pushed memory usage over comfortable limits. The MySQL request of 1Gi memory is the most significant — on a t2.medium with system overhead and other pods, that leaves limited headroom. In a production environment you'd size nodes based on measured usage after load testing, not estimates.

---

**Q8. You removed health probes from an earlier version of the backend. What would you put back in for production, and how would you configure them?**

*What they're testing:* Practical probe configuration, not textbook definitions.

Three probes serve different purposes. A `startupProbe` runs only during container initialization — it gives the app time to start without the liveness probe killing it prematurely. Once the startup probe passes, Kubernetes switches to the `livenessProbe` to detect deadlocks or hung processes. A `readinessProbe` signals whether the pod should receive traffic from the Service.

For the Express backend, the readiness probe would hit `GET /api/auth` or a dedicated `/healthz` endpoint with a 200 response. The startup probe would have a higher `failureThreshold` and `periodSeconds` to allow time for the MySQL connection to establish. The liveness probe would use the same endpoint but with a shorter period and fewer allowed failures, since a genuinely dead process should be restarted quickly.

The reason probes were removed here: during early development, the MySQL StatefulSet took longer to become ready than the probe's `initialDelaySeconds`. The backend would start, fail to connect to MySQL, and the liveness probe would kill it before it had a chance to retry — creating a crash loop that masked the real issue (MySQL not ready yet).

---

## CI/CD & DevSecOps Pipeline

---

**Q9. Why does GitLeaks run before SonarQube and Trivy in your pipeline?**

*What they're testing:* Shift-left security reasoning and understanding of what each tool catches.

GitLeaks runs first because its failure mode is the most catastrophic. A leaked secret in source code means a credential is already exposed — it may have already been committed to git history and pushed to a remote. Stopping the pipeline immediately limits how many downstream systems see or process that code. Running SAST or container scans after a secret is already exposed adds cost with no benefit.

There's also a practical ordering reason: GitLeaks is fast. It scans the filesystem for patterns matching API keys, tokens, and passwords. SonarQube requires uploading code to the server and waiting for analysis — it takes minutes. Fail fast on the cheapest check first.

In this pipeline, GitLeaks uses `--exit-code 1`, which hard-stops the pipeline if anything is found. This is different from `abortPipeline: false` in the SonarQube Quality Gate — that's deliberate asymmetry. A secret in code is a binary failure. A code quality violation in a dev project is a warning.

---

**Q10. Why is `abortPipeline: false` set for the SonarQube Quality Gate? How would this change in production?**

*What they're testing:* Understanding the difference between a quality gate as a blocker vs. a feedback mechanism.

`abortPipeline: false` means the pipeline continues even if SonarQube reports a Quality Gate failure. This was intentional for this project because SonarQube is configured with default rules, some of which flag patterns in the existing React and Express code that are stylistic rather than security-critical. Blocking deployment on every SonarQube flag during development would create friction without corresponding safety value.

In production, this changes. The Quality Gate should block deployment — `abortPipeline: true`. But that requires calibrating the gate first. You configure which rules are enforced, set thresholds for code coverage and duplication, and suppress known acceptable issues before turning on blocking. Turning it on without calibration means every deploy fails for reasons the team doesn't care about, which leads people to find ways around it entirely.

---

**Q11. What's the difference between `trivy fs` and `trivy image`, and why would you use both?**

*What they're testing:* Depth of understanding of what surface area each scan covers.

`trivy fs` scans the filesystem — your source code and its dependencies. In this pipeline, it runs on the checked-out repo before any Docker build. It catches CVEs in `package.json` dependencies (the `node_modules` tree) and any misconfigurations in Kubernetes manifests or Terraform files. It does not see what's in the base image layers.

`trivy image` scans a built container image, including every layer — the base OS packages, the runtime binaries pulled in by `FROM node:22-alpine`, and the application layer on top. It catches things that `trivy fs` misses: OS-level vulnerabilities in Alpine's packages, outdated system libraries in the base image.

This pipeline only runs `trivy fs`. In a complete pipeline, you'd add `trivy image` after the Docker build stage, before pushing to the registry. That way nothing with a critical CVE gets pushed to DockerHub even if the source code was clean.

---

**Q12. Walk me through the manual approval gate in your pipeline. Who approves, and what are the criteria?**

*What they're testing:* Change management process understanding, not just that the gate exists.

The pipeline includes a manual approval step before the deploy stage. In the current setup this is Jenkins' `input` step — the pipeline pauses and waits for a human to click approve in the Jenkins UI.

In a real team, the approver would be a senior engineer or team lead. The approval criteria would include: all automated gates passed (GitLeaks clean, Quality Gate met, Trivy found no criticals), the change has been reviewed in a PR, the deployment is happening in an agreed maintenance window if it's a production deploy, and there's a rollback plan documented for the specific change. For this project the approval is informal, but in an enterprise setting this maps to a change request in ServiceNow or equivalent.

---

**Q13. What's missing from your current pipeline compared to a full production DevSecOps pipeline?**

*What they're testing:* Self-awareness about portfolio limitations and production requirements.

Several things. No `trivy image` scan — only filesystem scanning, so base image vulnerabilities can slip through. No DAST (Dynamic Application Security Testing) — nothing is testing the running app for runtime vulnerabilities like injection or broken auth flows. No container signing with Cosign or Notary — there's no way to verify that the image in production is the same one that passed CI. No SBOM generation — no inventory of what's in the image. No automated rollback — if the deploy succeeds but the app is broken, the pipeline doesn't detect it and roll back automatically. And the secrets in the manifests (`JWT_SECRET`, `DB_PASSWORD`) are stored in Kubernetes Secrets encoded in base64, not encrypted at rest with something like AWS Secrets Manager or Vault.

---

**Q14. How would this pipeline change if you moved from Jenkins to GitHub Actions?**

*What they're testing:* Practical knowledge of both platforms.

The pipeline logic stays the same — the stages map directly. GitLeaks becomes a `uses: gitleaks/gitleaks-action@v2` step. SonarQube becomes a `sonarsource/sonarqube-scan-action`. Trivy becomes an `aquasecurity/trivy-action`. The declarative Jenkins syntax becomes GitHub Actions YAML jobs.

The bigger changes are operational. Jenkins requires a server to maintain — updates, plugins, disk space for build artifacts. GitHub Actions runs on GitHub-managed runners with no server overhead. But Jenkins has better support for complex approval workflows and is easier to self-host for air-gapped environments. The manual `input` step in Jenkins has no direct GitHub Actions equivalent — you'd need `environment: production` with required reviewers configured in the repo settings, which is less flexible. Jenkins also makes it easier to keep sensitive credentials out of the repository entirely using the Jenkins credentials store, whereas GitHub Actions credentials live in repo or org secrets which are managed through GitHub's UI.

---

## Tool Trade-offs

---

**Q15. Why did you choose GitLeaks over git-secrets or detect-secrets?**

*What they're testing:* Active evaluation, not just picking the first result.

`git-secrets` is Amazon's tool — it works well but requires installation and configuration on each machine. It hooks into git pre-commit, which means secrets can still slip through if developers bypass hooks or don't have it configured. `detect-secrets` creates a baseline file that auditors check against — it's better suited for workflows where you're managing a known set of accepted false positives.

GitLeaks runs in the pipeline as a standalone binary with a Docker image, making it easy to add to any CI system without developer machine setup. It scans both the working directory and git history by default. The `--exit-code 1` flag gives clean pipeline integration. It maintains a broad ruleset for common secret patterns and is actively maintained. For a CI-first workflow, it fits better than tools designed around pre-commit hooks.

---

**Q16. Why SonarQube over Snyk or Checkmarx for SAST?**

*What they're testing:* Budget-aware trade-off reasoning.

Snyk and Checkmarx are excellent tools, but they're commercial products with per-user or per-scan pricing. For a portfolio project and for self-hosted development environments, SonarQube Community Edition is free, self-hostable, and covers the most common SAST rules for JavaScript/Node.js. It integrates with Jenkins through the official SonarQube plugin and the `waitForQualityGate` step.

Snyk's strength is actually dependency scanning and its developer-friendly CLI — it's better positioned as a complement to SAST, not a replacement. Checkmarx is the enterprise choice with deeper analysis but comes with significant cost and operational overhead. The choice here was driven by what can be run on a self-hosted Jenkins server without license costs.

---

**Q17. Why Trivy over Grype, Clair, or Snyk Container?**

*What they're testing:* Practical tool comparison, not brand recognition.

Clair requires running a server and database — significant operational overhead for what this pipeline needs. Grype is solid and simple but has a smaller ecosystem and fewer CI integrations. Snyk Container is good but requires a Snyk account and has scan limits on free tier.

Trivy is a single binary, scans multiple targets (filesystem, images, IaC), and has a Docker image that works out of the box in any CI environment. It supports multiple output formats including HTML (used in this pipeline for the `fs-report.html` artifact). The active development and broad CVE database coverage made it the practical choice. For a project that also uses Terraform and Kubernetes manifests, Trivy's multi-target support is an actual advantage.

---

**Q18. You chose Prometheus and Grafana. Why not ELK, and why not Datadog?**

*What they're testing:* Understanding of what each tool actually does and the resource constraints.

ELK (Elasticsearch, Logstash, Kibana) is a log aggregation and search platform, not a metrics platform. Prometheus is a time-series metrics database. They're not alternatives to each other — they solve different problems. The reason ELK wasn't deployed here is resource cost. Elasticsearch alone needs several gigabytes of memory. On `t2.medium` nodes with the application already running, there's no headroom for it. The project explicitly disabled AlertManager from the Prometheus stack for the same reason — memory constraints.

Datadog would give you both metrics and logs with less operational complexity, but it costs money per host per month. For a portfolio deployment that runs intermittently, that cost adds up fast.

The right production answer is both: Prometheus for metrics and alerting, a dedicated log aggregation system (ELK, Loki, or a managed service like CloudWatch Logs or Datadog) for application logs. They serve different observability needs.

---

**Q19. Why NGINX Ingress Controller over AWS ALB Ingress Controller or Traefik?**

*What they're testing:* Cloud-native vs. portable tooling reasoning.

The AWS ALB Ingress Controller provisions an actual AWS Application Load Balancer per Ingress resource. That's more expensive and AWS-specific — it wouldn't work on any other cluster. NGINX Ingress runs inside the cluster and uses a single LoadBalancer Service (one ELB for the whole cluster), which is cheaper and cloud-agnostic.

Traefik is a good alternative with a similar approach, but its cert-manager integration requires more configuration, and NGINX Ingress has more community documentation. For a project already using cert-manager with Let's Encrypt, NGINX Ingress had the most straightforward integration path.

The trade-off is that NGINX Ingress is a single point of failure at the ingress layer. The AWS ALB is a managed service with AWS's availability guarantees. In a production environment where uptime is contractual, the ALB controller's managed nature may be worth the cost and vendor lock-in.

---

## AWS & Infrastructure

---

**Q20. Explain OIDC and IRSA. Why not just use the node's IAM instance role for the EBS CSI driver?**

*What they're testing:* IAM security boundaries in EKS.

The node's instance role applies to everything running on that node. If you grant it `AmazonEBSCSIDriverPolicy`, then any pod on any node in the cluster inherits those permissions — including application pods. A compromised application container could use that role to provision or delete EBS volumes.

IRSA (IAM Roles for Service Accounts) uses Kubernetes service accounts and the cluster's OIDC provider to grant IAM permissions to a specific service account only. The EBS CSI controller runs as `ebs-csi-controller-sa` in `kube-system`. The IAM role trust policy only allows that specific service account in that specific namespace to assume it. Application pods in `prod` using different service accounts cannot assume that role.

The Terraform in this project sets up the OIDC provider, creates the IAM role with the IRSA trust condition (`system:serviceaccount:kube-system:ebs-csi-controller-sa`), attaches `AmazonEBSCSIDriverPolicy`, and passes the role ARN to the EKS addon. This is the right approach regardless of the extra setup — blast radius reduction is fundamental to cloud security.

---

**Q21. Describe the EBS CSI CrashLoopBackOff you hit. How did you diagnose it?**

*What they're testing:* Real debugging methodology, not a textbook answer.

After deploying the EKS cluster and installing the EBS CSI addon, the `ebs-csi-controller` pods were in CrashLoopBackOff. `kubectl logs -n kube-system ebs-csi-controller-xxx -c csi-provisioner` showed authentication errors when trying to call AWS APIs — something like `NoCredentialProviders`.

The diagnosis path: first checked if the IRSA role ARN was correctly annotated on the service account (`kubectl get sa ebs-csi-controller-sa -n kube-system -o yaml`). The annotation was there. Next checked the OIDC provider — `aws eks describe-cluster --name devopsfaza-cluster --query "cluster.identity.oidc"`. The response showed an issuer URL, but `aws iam list-open-id-connect-providers` returned empty. The OIDC provider hadn't been created in IAM even though the cluster had an identity endpoint.

The Terraform had the OIDC provider resource defined but it was missing from the state — it had been destroyed separately. Adding it back and running `terraform apply` fixed it. The secondary issue was that EC2 instance metadata service (IMDS) hop limit on the nodes was set to 1, which prevented the IRSA token exchange from working through the container network hops. Fixed by updating the node group launch template to set `httpPutResponseHopLimit: 2`.

---

**Q22. When does flat Terraform make sense vs. modules? You used flat structure here.**

*What they're testing:* Pragmatic infrastructure thinking.

This project's Terraform is one `main.tf` in the `eks/` directory — all resources in a single file, no modules. That works fine here because there's one environment, one team (one person), and the resource count is manageable. Reading the whole infrastructure is one file read.

Modules become necessary when you're deploying the same infrastructure to multiple environments (dev, staging, prod) — you want to define the pattern once and instantiate it with different variable values. They also help when a team grows and different people own different infrastructure components — network team owns the VPC module, platform team owns the EKS module. Without modules, a single `main.tf` with dozens of resources across multiple ownership domains becomes impossible to review.

The rule of thumb: if you're copy-pasting blocks of Terraform to make a second environment, it's time for a module. If there's one environment and you understand the whole file without scrolling, flat is fine.

---

**Q23. You hit a `DependencyViolation` during `terraform destroy`. What caused it and how do you prevent it?**

*What they're testing:* Understanding of Terraform's state vs. actual cloud state, and Helm lifecycle.

`terraform destroy` tried to delete the VPC but failed because a security group was still attached to an ENI (Elastic Network Interface). Terraform didn't know about that security group — it wasn't in state. The culprit was the NGINX Ingress Controller, installed via Helm. When Helm created the LoadBalancer Service, AWS provisioned an ELB and associated security groups and ENIs. When the EKS cluster nodes were terminated, the ELB's ENIs lingered. Terraform's VPC deletion failed because AWS won't delete a VPC with attached resources.

The fix was manual: find the orphaned ELB in the EC2 console (or `aws elb describe-load-balancers`), delete it, delete its security group, then retry `terraform destroy`.

Prevention: always delete Helm releases before running `terraform destroy`. `helm uninstall ingress-nginx` triggers a graceful teardown of the LoadBalancer Service, which tells AWS to decommission the ELB. With the ELB gone, `terraform destroy` can clean up the VPC. You can encode this in documentation or a destroy script, but it requires discipline — it's a real gotcha in EKS lifecycle management.

---

## Application Architecture

---

**Q24. Why does the frontend use a multi-stage Dockerfile? What's the actual image size difference?**

*What they're testing:* Understanding of multi-stage builds, not just that they exist.

The first stage uses `node:22-alpine` and runs the full build toolchain: `npm ci` to install all dependencies (including devDependencies like react-scripts, webpack, babel), then `npm run build` to produce the static files in `/app/build`. That build stage image would be several hundred megabytes — it contains Node.js, npm, all the build tools, and the source code.

The second stage starts fresh from `nginx:alpine`. It copies only `/app/build` from the first stage — the compiled HTML, CSS, and JavaScript. The final image is just Nginx plus the static assets. The Node.js runtime, npm, and all build tools are discarded. The result is an image that's tens of megabytes instead of hundreds, with no build toolchain attack surface.

This also means REACT_APP environment variables must be set at build time, not runtime. React's build process inlines environment variables into the compiled JavaScript with `process.env.REACT_APP_*` substitution. If the variable isn't set during `npm run build`, it defaults to `undefined` in the output.

---

**Q25. You had a bug where the frontend was calling `localhost:5000`. Walk through what happened and how you fixed it.**

*What they're testing:* Real experience with React's environment variable system.

When the frontend was first built, `REACT_APP_API_BASE_URL` either wasn't set or was set to `http://localhost:5000`. The `npm run build` compiled that value directly into the JavaScript bundle. The Docker image was built and pushed with that value baked in. When the container ran in Kubernetes, the browser loaded the JavaScript, made API calls to `localhost:5000`, and those calls went to the user's local machine — not the backend service. The error showed up as a CORS failure or a "connection refused" in the browser's network tab.

The fix required setting the correct URL at build time. In the frontend `.env` file (or as a Docker build arg), `REACT_APP_API_BASE_URL` must point to the actual public domain — in production, `https://learndevops.my/api`. After rebuilding the image with the correct value and redeploying, the calls went to the right endpoint. This is also why the Docker build must happen in CI with the right environment, not on a developer's laptop where `localhost` values might slip in.

---

**Q26. Walk through the JWT authentication flow in this app. What are the security trade-offs?**

*What they're testing:* Auth implementation depth and awareness of limitations.

The backend has two auth-related routes: `POST /api/auth/register` and `POST /api/auth/login`. Registration hashes the password with bcrypt at cost factor 10 (`bcrypt.hash(password, 10)`) and stores it in MySQL. Login retrieves the user by email, runs `bcrypt.compare()` against the stored hash, and if it matches, signs a JWT with the payload `{ id, role }` and a 1-hour expiry.

The JWT is signed with `JWT_SECRET` from environment (`devopsFazaSuperSecretKey` in this project). Every protected route runs the `verifyToken` middleware, which extracts the Bearer token from the Authorization header and calls `jwt.verify()`. If valid, `req.user` is set with the decoded payload. Admin-only routes also run `isAdmin`, which checks `req.user.role === 'admin'`.

The trade-offs: no refresh token means users must log in again after an hour — acceptable for a management tool, annoying for a consumer app. There's no token revocation mechanism — if a JWT is stolen, it's valid until expiry. In production you'd add a token blocklist in Redis or use short-lived access tokens with refresh tokens stored in httpOnly cookies. The JWT secret is also stored in a Kubernetes Secret, which is base64 encoded but not encrypted at rest unless you've enabled etcd encryption — which this cluster hasn't.

---

## Real Debugging Experiences

---

**Q27. You had cert-manager fail to issue certificates because of a `.my` TLD issue. How did you diagnose and fix it?**

*What they're testing:* Real DNS debugging methodology.

cert-manager's ACME HTTP-01 challenge requires reaching Let's Encrypt's servers to validate domain ownership. cert-manager also needs to resolve DNS to find where to put the challenge token. The symptom was that the `Certificate` resource stayed in a pending state — `kubectl describe certificate app-tls-cert -n prod` showed the challenge was failing.

Running `kubectl run dns-test --image=busybox --rm -it -- nslookup learndevops.my` from inside the cluster returned a `SERVFAIL`. The cluster's CoreDNS was failing to resolve `.my` domains. The root cause: `.my` is Malaysia's ccTLD, and the CoreDNS default upstream resolver configuration was hitting a DNS server that had filtering rules for `.my` — or the resolver chain for `.my` was broken in the cluster's network environment.

The fix was adding a CoreDNS override in the CoreDNS ConfigMap to forward `.my` queries to a specific resolver (Google's `8.8.8.8` or Cloudflare's `1.1.1.1`) that handles the `.my` TLD correctly. After patching the CoreDNS ConfigMap and restarting CoreDNS pods, `nslookup learndevops.my` resolved correctly, cert-manager retried the ACME challenge, and the certificate issued.

---

**Q28. After fixing the CoreDNS issue, the certificate order was still stuck. What happened?**

*What they're testing:* cert-manager lifecycle understanding.

The ACME `Order` resource cert-manager created had already expired by the time the DNS fix was applied. cert-manager doesn't automatically retry expired orders. `kubectl get orders -n prod` showed the order in a `failed` or `invalid` state with an expiry timestamp in the past.

The fix is to delete the `CertificateRequest` resource associated with the certificate. cert-manager detects the missing CertificateRequest and creates a new Order, which triggers a fresh ACME challenge with a new expiry window. `kubectl delete certificaterequest -n prod <name>` is the command. After deletion, cert-manager reconciled within a minute, created a new order, ran the HTTP-01 challenge (which now worked since DNS was fixed), and issued the certificate.

---

**Q29. Walk through how you diagnosed the Jenkins Quality Gate getting stuck at PENDING.**

*What they're testing:* Webhook debugging and network configuration awareness.

The Quality Gate step in Jenkins uses a webhook — SonarQube sends a callback to Jenkins when analysis is complete. If the webhook never fires, Jenkins waits until the 1-hour timeout. The symptom was that every pipeline run sat on the Quality Gate step for exactly one hour, then continued (because `abortPipeline: false`).

The diagnosis: check SonarQube's webhook configuration. In the SonarQube admin panel under `Administration > Webhooks`, the webhook URL was set to the previous Jenkins IP address — the Elastic IP had been migrated but the webhook URL still pointed to the old IP. HTTP requests to that IP were timing out.

The fix was updating the webhook URL to the new Jenkins address. After updating, the next pipeline run received the webhook callback within seconds of SonarQube analysis completing, and the Quality Gate step resolved immediately instead of timing out.

---

**Q30. You had three sequential bugs in the same area — npm ci, .dockerignore, and stale cache. Walk through each one.**

*What they're testing:* Debugging discipline and ability to isolate issues systematically.

**Bug 1 — npm ci failing with lock file mismatch.** The pipeline ran `npm ci` in the Docker build stage and failed with an error about the lock file being out of sync with `package.json`. A developer had added a dependency by editing `package.json` directly without running `npm install` to update `package-lock.json`. The fix: run `npm install` locally, commit both files together, push.

**Bug 2 — .dockerignore missing.** After fixing the lock file, the Docker build succeeded locally but the image was larger than expected and contained source files that shouldn't be in the image. `node_modules` from the local machine was being `COPY`-ed into the image even though `npm ci` runs inside the container. Without a `.dockerignore` file, Docker sends the entire build context including `node_modules`. The fix: add `.dockerignore` with `node_modules`, `.git`, `.env`, and other non-essential paths.

**Bug 3 — stale cache.** After adding `.dockerignore`, the pipeline still occasionally used old dependencies. Docker layer caching was using a cached layer from before the lock file fix. Because the `COPY package.json package-lock.json` layer was cached, `npm ci` used the cache and pulled old packages. The fix: either invalidate the cache explicitly (`docker build --no-cache`) or ensure the `COPY` step comes before any RUN step that should depend on fresh dependencies — which was already the case, so the real fix was ensuring the lock file timestamp was newer than the cache layer, which happened automatically after the next commit that touched `package-lock.json`.

---

**Q31. An ImagePullBackOff showed up after a deploy. How did you find the root cause?**

*What they're testing:* Basic Kubernetes event reading and image tag discipline.

`kubectl get pods -n prod` showed a pod stuck in `ImagePullBackOff`. `kubectl describe pod <pod-name> -n prod` showed the Events section: `Failed to pull image "fazabillah/backend:v1": tag does not exist`. The deployment manifest had been updated to use `:v1` as the image tag during testing, but the image pushed to DockerHub was tagged `:latest`. The tag `:v1` didn't exist in the repository.

The fix was either push an image with the `:v1` tag to DockerHub, or update the deployment manifest to use `:latest`. The deeper lesson is the same one that makes `:latest` problematic from the other direction — when tags aren't managed carefully, manifests and registries get out of sync. Tagging images with the git commit SHA and using that same SHA in the manifest (generated by the CI pipeline) eliminates this class of bug entirely. The manifest always references the exact image that was built in the same pipeline run.

---

*38 questions total across six domains. Each answer ties directly to a real decision or incident in this repository.*
