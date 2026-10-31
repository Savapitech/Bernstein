# Bernstein

A voting application deployed on Kubernetes with a Helm chart.

| Component | Role                                       | Exposed as          |
|-----------|--------------------------------------------|---------------------|
| poll      | Web page where users vote                  | Ingress, NodePort   |
| result    | Web page showing the live results          | Ingress, NodePort   |
| worker    | Moves votes from Redis to PostgreSQL       | none                |
| redis     | Queue holding incoming votes, replicated   | ClusterIP           |
| postgres  | Database storing the votes, replicated     | ClusterIP           |

## Replication

redis and postgres each run as a StatefulSet with 2 pods. Redis replicas follow the master with `replicaof`, PostgreSQL replicas clone the primary with `pg_basebackup` on first start, then follow it with streaming replication.

Each pod has its own volume, created from the StatefulSet `volumeClaimTemplates`, and always gets the same one back after a restart (`postgres-0` uses `postgres-data-postgres-0`, ...). When the volume is local to a node, Kubernetes schedules the pod back on that node. A preferred pod anti-affinity spreads the pods of each database on different nodes.

## Autoscaling

- A HorizontalPodAutoscaler adds or removes pods to keep their CPU usage around 70% of the request. poll and result run between 2 and 6 pods, worker between 1 and 4.
- A VerticalPodAutoscaler adjusts their memory request between 128Mi and 1Gi, based on what the pods actually use. It applies a new value by recreating the pods one at a time, never going below the HPA minimum.

HPA needs metric-server and VPA need an external tool :

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server --namespace kube-system

helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm install vpa fairwinds-stable/vpa --namespace vpa --create-namespace
```

If `kubectl top nodes` fails because the kubelet certificates are self-signed, as on a default Talos cluster, add `--set args={--kubelet-insecure-tls}` to the metrics-server install.

## Prerequisites

- A Kubernetes cluster and `kubectl` configured to reach it
- Helm 3
- Traefik as ingress controller
- A StorageClass able to provision `ReadWriteOnce` volumes
- metrics-server and the Vertical Pod Autoscaler, see [Autoscaling](#autoscaling)
- Docker with buildx, to build the images
- Credentials for the registry hosting the poll, worker and result images, with read and write access

## Installation

Create the namespace:

```bash
kubectl create namespace bernstein
```

Create the secret used to pull the images from the private registry:

```bash
kubectl create secret docker-registry gitlab-registry \
  --namespace bernstein \
  --docker-server=REGISTRY_URL \
  --docker-username=REGISTRY_USERNAME \
  --docker-password=REGISTRY_PASSWORD
```

Create the secret holding the PostgreSQL password:

```bash
kubectl create secret generic postgres-secret \
  --namespace bernstein \
  --from-literal=POSTGRES_PASSWORD='change-me'
```

Log in to the registry, then build, push and deploy:

```bash
docker login registry.vyme.fr
./deploy.sh -f chart/bernstein/values-rns1-prod.yaml
```

`deploy.sh` runs `build-image-push.sh`, which builds the images of `apps/` for `linux/amd64` and pushes them. Each image is tagged with a hash of its app directory, uncommitted changes included. `deploy.sh` then runs `helm upgrade --install` with these tags. Extra arguments go to helm. The registry and the platform can be changed with the `REGISTRY` and `PLATFORM` variables.

Since an unchanged app keeps the same tag, it is neither rebuilt nor redeployed. A changed app gets a new tag, so Kubernetes always pulls the new image and runs a rolling update.

Each time the PostgreSQL primary starts, it creates the `votes` table from `chart/bernstein/files/schema.sql` if it does not exist yet. Until then, result restarts a few times, which is expected. Check that everything is running:

```bash
kubectl get pods -n bernstein
```

## Accessing the application

poll and result each get a Traefik Ingress on their own host, `poll.bernstein.local` and `result.bernstein.local` by default. Set your own hosts at install time and point their DNS records to the Traefik load balancer:

```bash
helm install bernstein chart/bernstein -n bernstein \
  --set poll.ingress.host=poll.example.com \
  --set result.ingress.host=result.example.com
```

result runs on several pods and pushes live updates over socket.io, so every browser must stay on the same pod. Traefik handles this with a sticky session cookie (`result.ingress.stickyCookie`). This only applies to traffic going through the Ingress.

The NodePort services remain available for direct access. Get their ports with `kubectl get svc poll result -n bernstein`, then open `http://<node-ip>:<node-port>`. To pin a port, set `poll.service.nodePort` or `result.service.nodePort` to a value between 30000 and 32767.

## Configuration

Every setting has a default in `chart/bernstein/values.yaml`. The most useful ones:

| Value                           | Default                                     | Description                           |
|---------------------------------|---------------------------------------------|---------------------------------------|
| `imagePullSecret`               | `gitlab-registry`                           | Secret used to pull the app images    |
| `db.host`                       | `postgres`                                  | PostgreSQL host                       |
| `db.port`                       | `5432`                                      | PostgreSQL port                       |
| `db.name`                       | `votes`                                     | Database name                         |
| `db.user`                       | `postgres`                                  | Database user                         |
| `db.passwordSecret.name`        | `postgres-secret`                           | Secret holding the password           |
| `db.passwordSecret.key`         | `POSTGRES_PASSWORD`                         | Key of the password in that secret    |
| `<app>.image.repository`        | `registry.vyme.fr/savalet/bernstein/<app>`  | Image of poll, worker or result       |
| `<app>.image.tag`               | `latest`                                    | Image tag                             |
| `<app>.replicas`                | `1` or `2`                                  | Number of pods when the HPA is disabled |
| `<app>.autoscaling.horizontal.*` | enabled, see [Autoscaling](#autoscaling)   | `enabled`, `minReplicas`, `maxReplicas`, `targetCPUUtilization` |
| `<app>.autoscaling.vertical.*`  | enabled, see [Autoscaling](#autoscaling)    | `enabled`, `minMemory`, `maxMemory`   |
| `<app>.service.type`            | `NodePort` for apps, `ClusterIP` otherwise  | Kubernetes service type               |
| `ingress.className`             | `traefik`                                   | Ingress class used by poll and result |
| `<app>.ingress.enabled`         | `true`                                      | Create the Ingress of poll or result  |
| `<app>.ingress.host`            | `<app>.bernstein.local`                     | Host served by that Ingress           |
| `result.ingress.stickyCookie`   | `result_sticky`                             | Sticky cookie name, empty to disable  |
| `redis.replicas`, `postgres.replicas` | `2`                                   | Primary plus read-only replicas       |
| `<db>.storage.size`             | `1Gi`                                       | Volume size of each redis or postgres pod |
| `<db>.storage.storageClassName` | empty (cluster default)                     | StorageClass of those volumes         |
| `<db>.affinity`                 | preferred anti-affinity per node            | Scheduling rules of redis or postgres |

If you rename a secret, use the same name in the `kubectl create secret` command and in the values.

## Upgrade and uninstall

```bash
./deploy.sh -f chart/bernstein/values-rns1-prod.yaml
helm uninstall bernstein --namespace bernstein
```

Updates roll one pod at a time without downtime: a new pod has to be ready before an old one stops, and poll and result wait 5 seconds before stopping, so Traefik stops sending them requests first.

Uninstalling keeps the redis and postgres volumes. Delete them to start from empty databases:

```bash
kubectl delete pvc -l app=postgres -n bernstein
kubectl delete pvc -l app=redis -n bernstein
```

## Security

All pods run as non-root and comply with the Kubernetes `restricted` Pod Security Standard. The settings are in `securityContext` (shared by every container) and in each component's `podSecurityContext`.
