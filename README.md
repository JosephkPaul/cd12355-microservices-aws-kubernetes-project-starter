# Coworking Space Service – Analytics API

The analytics service is a Flask API that reports coworking check-ins from PostgreSQL, and this repository builds it into a container image and runs it on Amazon EKS.

## Architecture

```
GitHub push ──► AWS CodeBuild (buildspec.yaml) ──► Amazon ECR  coworking:1.0.<build #>
                                                         │ image pull
                                                         ▼
Amazon EKS ─┬─ coworking Deployment ──── LoadBalancer Service :5153
            └─ postgresql Deployment ─── ClusterIP postgresql-service :5432
                       │ container stdout/stderr
                       ▼
CloudWatch Container Insights  /aws/containerinsights/coworking-cluster/application
```

| Path | Purpose |
|---|---|
| `analytics/` | Application source and its `Dockerfile` (Python 3.11 slim, non-root user) |
| `buildspec.yaml` | CodeBuild steps: ECR login, `docker build`, semantic-version tag, `docker push` |
| `deployment/` | EKS manifests: app Deployment + Service, PostgreSQL Deployment + Service + PV/PVC, ConfigMap, Secret |
| `deployment-local/` | The same app with a local image and a NodePort Service, for local clusters |
| `db/`, `scripts/seed-db.sh` | Schema and seed data, streamed into the cluster database with `kubectl exec` |
| `screenshots/` | Evidence of the running deployment: CodeBuild, ECR, `kubectl` and CloudWatch captures |

## How it works

- **Build:** A GitHub webhook starts CodeBuild on every push to `main` that touches `analytics/` or `buildspec.yaml`, and the image is tagged `MAJOR.MINOR.PATCH`, where `MAJOR.MINOR` is `VERSION_PREFIX` in `buildspec.yaml` and `PATCH` is the CodeBuild build number.
- **Configuration:** Plaintext settings (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`) live in a ConfigMap and the password lives in a Secret, and both PostgreSQL and the API read them, so the credentials always match.
- **Health:** `/health_check` drives the liveness probe, while `/readiness_check` queries the database, so a pod only receives traffic once it can serve reports.
- **Logs:** The Container Insights add-on ships container output to CloudWatch, including the probe requests every 10 seconds and the usage report the app logs every 30 seconds, and a pod annotation opts the app out of the add-on's OpenTelemetry auto-injection, which would otherwise take over Python logging.

## First-time setup

Run these once per environment; they assume `us-east-1` and an installed AWS CLI, `eksctl` and `kubectl`.

```bash
eksctl create cluster --name coworking-cluster --region us-east-1 --zones us-east-1a,us-east-1b \
  --nodegroup-name coworking-nodes --node-type t3.medium --nodes 1 --nodes-min 1 --nodes-max 2 --vpc-nat-mode Disable
aws ecr create-repository --repository-name coworking --image-scanning-configuration scanOnPush=true --region us-east-1

kubectl apply -f deployment/configmap.yaml -f deployment/secret.yaml
kubectl apply -f deployment/pv.yaml -f deployment/pvc.yaml \
  -f deployment/postgresql-deployment.yaml -f deployment/postgresql-service.yaml
./scripts/seed-db.sh

NODE_ROLE=$(aws eks describe-nodegroup --cluster-name coworking-cluster --nodegroup-name coworking-nodes \
  --region us-east-1 --query nodegroup.nodeRole --output text | awk -F/ '{print $NF}')
aws iam attach-role-policy --role-name "$NODE_ROLE" --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
aws eks create-addon --cluster-name coworking-cluster --addon-name amazon-cloudwatch-observability --region us-east-1
```

Then create a CodeBuild project for this GitHub repository with buildspec `buildspec.yaml`, a push webhook, an Amazon Linux standard image on `BUILD_GENERAL1_SMALL` in privileged mode (required for Docker builds), and the `AmazonEC2ContainerRegistryPowerUser` policy on its service role.
The first release of the API follows the same steps as every later one.

## Releasing a new build

1. Merge the application change to `main` and wait for CodeBuild to push `coworking:1.0.<N>`; bump `VERSION_PREFIX` for a feature (`1.1`) or breaking (`2.0`) release.
2. Point `deployment/coworking.yaml` at the new tag, commit the change, and apply it:
   ```bash
   ECR_URI=$(aws sts get-caller-identity --query Account --output text).dkr.ecr.us-east-1.amazonaws.com/coworking
   sed -i "s|image: .*coworking:.*|image: $ECR_URI:1.0.<N>|" deployment/coworking.yaml
   kubectl apply -f deployment/coworking.yaml && kubectl rollout status deployment/coworking
   ```
3. Kubernetes starts the new pod and stops the old one only after the new pod passes its readiness probe, so a release causes no downtime.
   If the new version misbehaves, `kubectl rollout undo deployment/coworking` restores the previous image.

Configuration changes are applied the same way, followed by `kubectl rollout restart deployment/coworking`, because environment variables are only read when a pod starts.

## Verifying a deployment

```bash
kubectl get svc
kubectl get pods
kubectl describe svc postgresql-service
kubectl describe deployment coworking
curl http://<EXTERNAL-IP>:5153/api/reports/daily_usage
curl http://<EXTERNAL-IP>:5153/api/reports/user_visits
```

`<EXTERNAL-IP>` is the load balancer hostname that `kubectl get svc` shows for `coworking`, and it can take a few minutes to start resolving.
The hostPath volume keeps this demo database on the node itself, so a production setup should use Amazon RDS or EBS volumes through the EBS CSI driver.

## Stand-out suggestions

**CPU and memory allocation.** The API requests 100m CPU / 128Mi memory and is capped at 500m / 256Mi, because a single Flask process with one background job idles well under 100Mi and only spikes briefly while a report query runs. PostgreSQL requests 250m / 256Mi with limits of 500m / 512Mi, which leaves room on the node for system pods and the CloudWatch agents.

**Instance type.** A single `t3.medium` (2 vCPU, 4 GiB) fits best: the traffic is light and bursty, which T3 CPU credits handle cheaply, and its 17-pod limit holds the app, the database, CoreDNS and the Container Insights pods, where a `t3.small`'s 11-pod limit does not. A Graviton `t4g.medium` would cost about 20% less if CodeBuild also produced an arm64 image.

**Saving costs.** The EKS control plane ($0.10/hour) costs more than the node, so delete the cluster with `eksctl delete cluster --name coworking-cluster --region us-east-1` whenever it is not in use. Spot or Graviton nodes, an ECR lifecycle policy that expires old tags, and a 7-day retention on the Container Insights log groups cut the remaining spend. In production, Amazon RDS plus scaling the API to zero outside business hours would lower idle cost further.
