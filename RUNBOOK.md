# Runbook: paid session (apply → load test → destroy)

The exact command sequence for one working session on AWS. Run from the repo root in WSL.
Budget: plan for about 3 hours. Rough on-demand cost while up: EKS control plane $0.10/h +
3 × m7i-flex.large ~$0.29/h + public IPv4 and EBS, about **$0.45/h** in total. Don't leave it running.

Rules: review every plan before applying it. Never paste command output that contains the
12-digit account ID (ECR URLs, ARNs) into the repo, README, or screenshots.

---

## 0. Preflight (free, read-only)

Each check prints `OK` or `FAIL`. Fix every FAIL before step 1.

```bash
export AWS_PROFILE=llm-eks
export AWS_REGION=us-east-2
cd ~/llm-serving-eks

# 1. Identity is the terraform-admin IAM user (not root, not another profile).
#    Prints only the user name, never the account ID.
WHO=$(aws sts get-caller-identity --query Arn --output text | awk -F/ '{print $NF}')
[ "$WHO" = "terraform-admin" ] && echo "OK identity: $WHO" || echo "FAIL identity: '$WHO'"

# 2. A cost budget exists. The account ID stays in a variable and is unset right after.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].[BudgetName,BudgetLimit.Amount,BudgetLimit.Unit]' --output text \
  | grep . && echo "OK budget" || echo "FAIL no budget"
unset ACCOUNT_ID

# 3. Your public IP is the allowed API CIDR in terraform.tfvars. If not, kubectl times out
#    after apply: update endpoint_public_access_cidrs to "<ip>/32" first.
MYIP=$(curl -s https://checkip.amazonaws.com)
grep -q "\"$MYIP/32\"" terraform/terraform.tfvars && echo "OK IP in tfvars" || echo "FAIL IP not in tfvars"

# 4. Docker is running (needed for the build in step 2).
docker info > /dev/null 2>&1 && echo "OK docker" || echo "FAIL docker not running"

# 5. Clean tree, so the image tag's git SHA matches what is committed.
[ -z "$(git status --porcelain)" ] && echo "OK git clean" || echo "FAIL uncommitted changes"

terraform -chdir=terraform init
terraform -chdir=terraform validate
```

## 1. ECR-only apply

The repo has to exist before there's anywhere to push the image. It costs pennies per month,
and the cluster isn't running yet.

```bash
terraform -chdir=terraform plan \
  -target=aws_ecr_repository.llm_server \
  -target=aws_ecr_lifecycle_policy.llm_server \
  -out=ecr.tfplan
# Expect: Plan: 2 to add, 0 to change, 0 to destroy.
terraform -chdir=terraform apply ecr.tfplan
```

## 2. Build and push the image (unique tag)

The ECR repo is IMMUTABLE, so every push needs a new tag. The tag is the llama.cpp build,
the model, the git commit, and a UTC timestamp.

```bash
ECR_URL=$(terraform -chdir=terraform output -raw ecr_repository_url)   # keep in a variable; don't echo
TAG="b11429-qwen2.5-1.5b-q4km-$(git rev-parse --short HEAD)-$(date -u +%Y%m%d%H%M)"
echo "$TAG"

aws ecr get-login-password | docker login --username AWS --password-stdin "${ECR_URL%%/*}"
docker build --platform linux/amd64 -t "$ECR_URL:$TAG" docker/   # m7i-flex nodes are x86_64
docker push "$ECR_URL:$TAG"

aws ecr describe-images --repository-name llm-serving-eks/llm-server \
  --query 'imageDetails[].imageTags' --output text                  # shows $TAG
```

## 3. Full apply (billing starts here)

```bash
terraform -chdir=terraform plan -out=full.tfplan
# Expect: about 44 to add, 0 to change, 0 to destroy (everything except the 2 ECR resources).
terraform -chdir=terraform apply full.tfplan     # ~15 min
date -u                                          # note the start time for the cost note
```

## 4. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --region us-east-2 --name llm-serving-eks

kubectl get nodes -L workload          # 3 nodes Ready, workload=llm
kubectl get pods -n kube-system        # aws-node, kube-proxy, coredns, metrics-server Running
kubectl top nodes                      # numbers (not an error) = metrics-server works; wait ~1 min if not
```

## 5. Install the monitoring stack

The release name **must** be `kube-prometheus-stack`. The llm chart's ServiceMonitor carries
that label, and the chart also provides the ServiceMonitor CRD, so install it first.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update prometheus-community

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version 91.9.0 --namespace monitoring --create-namespace \
  -f monitoring/kube-prometheus-stack-values.yaml \
  --wait --timeout 10m

kubectl get pods -n monitoring         # prometheus, grafana, operator, kube-state-metrics, node-exporter x3
```

## 6. Install the llm chart (release `llm`)

```bash
helm install llm helm/llm-server --namespace default \
  --set image.repository="$ECR_URL" \
  --set image.tag="$TAG" \
  --wait --timeout 10m                 # first pull of the ~1.5 GB image takes a few minutes

kubectl get pods,svc,hpa -l app.kubernetes.io/instance=llm
# HPA TARGETS must show a percentage, not <unknown>, before load testing.
```

Smoke test through the Service:

```bash
kubectl port-forward svc/llm-llm-server 8080:8080 >/dev/null &
PF_LLM=$!; sleep 3
curl -s localhost:8080/health
curl -s localhost:8080/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in five words."}],"max_tokens":32}'
curl -s localhost:8080/metrics | grep -E '^llamacpp:(requests_processing|requests_deferred|tokens_predicted_total)'
kill $PF_LLM
```

Confirm that Prometheus is scraping it:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null &
PF_PROM=$!; sleep 3
curl -s --get localhost:9090/api/v1/query --data-urlencode 'query=up{service="llm-llm-server"}' | python3 -m json.tool
# Expect one result per pod with value "1". Keep this port-forward open for step 9.
```

## 7. Open Grafana (before starting k6, so the whole ramp is recorded)

```bash
kubectl -n monitoring get secret kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 >/dev/null &
PF_GRAF=$!
# Browser: http://localhost:3000  user: admin
```

Dashboard panels (build them once, then export the JSON in step 9):

| Panel | PromQL |
|---|---|
| Tokens/sec (all pods) | `sum(rate(llamacpp:tokens_predicted_total[1m]))` |
| Requests processing vs deferred | `sum(llamacpp:requests_processing)` and `sum(llamacpp:requests_deferred)` |
| Pod CPU (cores) | `sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="default",container="llm-server"}[1m]))` |
| Pod memory | `sum by (pod) (container_memory_working_set_bytes{namespace="default",container="llm-server"})` |
| Pod count | `kube_deployment_status_replicas_available{deployment="llm-llm-server"}` |
| HPA desired replicas | `kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="llm-llm-server"}` |

llama-server has no latency histogram. p95 latency comes from the k6 summary.

Set the time range to "Last 30 minutes" with a 10s refresh, and start the screen recording.

## 8. Run k6

```bash
kubectl apply -f loadtest/k6-job.yaml
```

In separate terminals:

```bash
kubectl get hpa llm-llm-server -w
kubectl get pods -l app.kubernetes.io/instance=llm -o wide -w   # NODE column: one pod per node
kubectl logs -f job/k6-llm-ramp                                 # summary prints after ~10 min
```

## 9. Capture evidence

```bash
EV=evidence/$(date -u +%Y%m%d); mkdir -p "$EV"

kubectl logs job/k6-llm-ramp                              > "$EV/k6-summary.txt"   # p95, tokens/sec
kubectl describe hpa llm-llm-server                       > "$EV/hpa-describe.txt" # scale events
kubectl get pods -l app.kubernetes.io/instance=llm -o wide > "$EV/pods-wide.txt"
kubectl top pods -l app.kubernetes.io/instance=llm        > "$EV/top-pods.txt"

# Peak numbers over the test window, from Prometheus (port-forward from step 6):
q() { curl -s --get localhost:9090/api/v1/query --data-urlencode "query=$1"; echo; }
q 'max_over_time(kube_deployment_status_replicas_available{deployment="llm-llm-server"}[30m])' > "$EV/max-pods.json"
q 'max_over_time(sum(rate(llamacpp:tokens_predicted_total[1m]))[30m:15s])'                     > "$EV/peak-tokens-per-sec.json"
q 'max_over_time(sum(llamacpp:requests_deferred)[30m:15s])'                                    > "$EV/peak-deferred.json"
```

Manual captures:
- Grafana screenshots of every panel across the ramp, plus the screen recording of pods scaling.
- Dashboard JSON: Dashboard → Share → Export → turn on "Export for sharing externally" → save
  as `monitoring/grafana-llm-dashboard.json`.
- Optional: wait about 5 min after k6 ends to capture the scale-down (HPA default stabilization window).

Before committing anything in `evidence/`, make sure no account ID leaked in:

```bash
grep -rnE '[0-9]{12}' "$EV" monitoring/ || echo "clean"
```

Write the results (p95 latency, tokens/sec, max pods) into the README from these files only.
Record any failure in the troubleshooting log as symptom, cause, fix.

## 10. Tear down

Remove in-cluster resources first, so anything that created AWS resources (ENIs, any
LoadBalancer) is released while the cluster still exists. Then destroy.

```bash
kill $PF_PROM $PF_GRAF 2>/dev/null
kubectl delete -f loadtest/k6-job.yaml --ignore-not-found
helm uninstall llm -n default
helm uninstall kube-prometheus-stack -n monitoring

terraform -chdir=terraform plan -destroy -out=destroy.tfplan
# Expect: Plan: 0 to add, 0 to change, 46 to destroy.
terraform -chdir=terraform apply destroy.tfplan     # ~10-15 min; ECR force_delete removes images too
date -u                                             # end time for the cost note
```

## 11. Cleanup checks (all must be empty, 0, or "None")

```bash
R="--region us-east-2"
aws eks list-clusters $R --query 'clusters'
aws ec2 describe-instances $R \
  --filters Name=instance-state-name,Values=pending,running,stopping,stopped \
  --query 'Reservations[].Instances[].InstanceId'
aws elbv2 describe-load-balancers $R --query 'LoadBalancers[].LoadBalancerName'
aws elb describe-load-balancers $R --query 'LoadBalancerDescriptions[].LoadBalancerName'
aws ec2 describe-volumes $R --query 'Volumes[].VolumeId'
aws ec2 describe-addresses $R --query 'Addresses[].PublicIp'
aws ec2 describe-nat-gateways $R --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId'
aws ecr describe-repositories $R --query 'repositories[].repositoryName'
aws ec2 describe-vpcs $R --filters Name=tag:Project,Values=llm-serving-eks --query 'Vpcs[].VpcId'
aws resourcegroupstaggingapi get-resources $R \
  --tag-filters Key=Project,Values=llm-serving-eks --query 'length(ResourceTagMappingList)'
# The tagging API can list just-deleted resources for a while; if non-zero, re-check the
# specific services above before worrying.

terraform -chdir=terraform state list    # empty
rm -f terraform/*.tfplan
```

Check the AWS Billing console the next day to confirm the session cost.
