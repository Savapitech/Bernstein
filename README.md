# Bernstein

A voting application deployed on Kubernetes with a Helm chart.

| Component | Role                                       | Exposed as          |
|-----------|--------------------------------------------|---------------------|
| poll      | Web page where users vote                  | Ingress, NodePort   |
| result    | Web page showing the live results          | Ingress, NodePort   |
| worker    | Moves votes from Redis to PostgreSQL       | none                |
| redis     | Queue holding incoming votes, replicated   | ClusterIP           |
| postgres  | Database storing the votes, replicated     | ClusterIP           |

## Replication and failover

redis and postgres each run 2 instances: a primary that takes the writes and a read-only replica. When the node of a primary is drained or goes down, a replica is promoted and the app keeps working.

- PostgreSQL is managed by the [CloudNativePG](https://cloudnative-pg.io) operator through the `db` Cluster. The replica follows the primary with streaming replication. The operator promotes it when the primary fails, and switches the primary over before a drain evicts it. The apps connect to the `db-rw` service, which always targets the current primary. The `votes` table is created from `chart/bernstein/files/schema.sql` when the cluster is initialized.
- Redis runs as a StatefulSet watched by 3 Sentinels, which promote the replica when the master stops answering for 5 seconds. The apps connect to the `redis` service, served by 2 HAProxy pods that send the traffic to the instance answering `role:master` and cut the connections to a former master.

Each instance has its own volume and always gets the same one back after a restart. When the volume is local to a node, the instance can only run on that node, so it stays pending while the node is drained or down, and comes back as a replica afterwards. A preferred pod anti-affinity keeps the instances of each database on different nodes.

poll, result, worker, the Sentinels and HAProxy are spread over the nodes, and a PodDisruptionBudget lets a drain evict only one of their pods at a time. When a node goes down, their pods move to other nodes after 30 seconds instead of the default 5 minutes.

worker never reconnects by itself, so its liveness probe checks its Redis and PostgreSQL connections and restarts it when one of them is broken.

## Autoscaling

- A HorizontalPodAutoscaler adds or removes pods to keep their CPU usage around 70% of the request. poll and result run between 2 and 6 pods, worker between 1 and 4.
- A VerticalPodAutoscaler adjusts their memory request between 128Mi and 1Gi, based on what the pods actually use. It applies a new value by recreating the pods one at a time, never going below the HPA minimum.

The HPA needs metrics-server and the VPA needs the Vertical Pod Autoscaler, both installed in [Cluster setup](#cluster-setup).

## Prerequisites

- A Kubernetes cluster and `kubectl` configured to reach it
- Helm 3
- Traefik as ingress controller
- A StorageClass, CloudNativePG, metrics-server and the Vertical Pod Autoscaler, see [Cluster setup](#cluster-setup)
- Docker with buildx, to build the images
- Credentials for the registry hosting the poll, worker and result images, with read and write access

## Cluster setup

These steps are done once per cluster, before the first deployment.

On a Talos cluster managed by Omni, expose the local volume directory to the kubelet of the workers. Edit the cluster and machine set names in `cluster/omni-local-path-patch.yaml` first, then apply it, which restarts the kubelet of each worker:

```bash
omnictl apply -f cluster/omni-local-path-patch.yaml
```

Install the `local-path` StorageClass. Its namespace runs with the `privileged` Pod Security level, since it creates the volume directories through `hostPath`:

```bash
kubectl apply -f cluster/local-path-storage.yaml
```

Install metrics-server and the Vertical Pod Autoscaler. `--kubelet-insecure-tls` is needed when the kubelet certificates are self-signed, as on a default Talos cluster:

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server --namespace kube-system \
  --set 'args={--kubelet-insecure-tls}'

helm repo add fairwinds-stable https://charts.fairwinds.com/stable
helm install vpa fairwinds-stable/vpa --namespace vpa --create-namespace
```

Install the CloudNativePG operator and wait for its webhook, which has to answer before the chart creates the `db` Cluster:

```bash
kubectl apply --server-side -f https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v1.30.1/cnpg-1.30.1.yaml
kubectl rollout status deployment/cnpg-controller-manager -n cnpg-system
```

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

Create the secret holding the PostgreSQL user and password. CloudNativePG requires the `kubernetes.io/basic-auth` type, and `username` must match `db.user`:

```bash
kubectl create secret generic postgres-secret \
  --namespace bernstein \
  --type=kubernetes.io/basic-auth \
  --from-literal=username=app \
  --from-literal=password='change-me'
```

Log in to the registry, then build, push and deploy:

```bash
docker login registry.vyme.fr
./deploy.sh -f chart/bernstein/values-rns1-prod.yaml
```

`deploy.sh` runs `build-image-push.sh`, which builds the images of `apps/` for `linux/amd64` and pushes them. Each image is tagged with a hash of its app directory, uncommitted changes included. `deploy.sh` then runs `helm upgrade --install` with these tags. Extra arguments go to helm. The registry and the platform are set at the top of `build-image-push.sh`.

Since an unchanged app keeps the same tag, it is neither rebuilt nor redeployed. A changed app gets a new tag, so Kubernetes always pulls the new image and runs a rolling update.

Until the database is initialized, result and worker restart a few times, which is expected. Check that everything is running:

```bash
kubectl get pods -n bernstein
```

## Accessing the application

poll and result each get a Traefik Ingress on their own host, `poll.bernstein.local` and `result.bernstein.local` by default. `values-rns1-prod.yaml` sets `nip.io` hosts that resolve to the Traefik load balancer of the rns1-prod cluster. For another cluster, set your own hosts and point their DNS records to its Traefik load balancer:

```bash
./deploy.sh \
  --set redis.storage.storageClassName=local-path \
  --set postgres.storage.storageClassName=local-path \
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
| `db.host`                       | `db-rw`                                     | PostgreSQL host, the primary          |
| `db.port`                       | `5432`                                      | PostgreSQL port                       |
| `db.name`                       | `votes`                                     | Database name                         |
| `db.user`                       | `app`                                       | Database owner                        |
| `db.passwordSecret.name`        | `postgres-secret`                           | basic-auth secret of the database user |
| `db.passwordSecret.key`         | `password`                                  | Key of the password in that secret    |
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
| `redis.affinity`                | preferred anti-affinity per node            | Scheduling rules of the redis pods    |
| `redis.sentinel.*`              | 3 sentinels, quorum 2, down after 5 s       | Sentinel settings                     |
| `redis.haproxy.*`               | 2 pods                                      | HAProxy in front of the redis master  |

If you rename a secret, use the same name in the `kubectl create secret` command and in the values.

## Upgrade and uninstall

```bash
./deploy.sh -f chart/bernstein/values-rns1-prod.yaml
helm uninstall bernstein --namespace bernstein
```

Updates roll one pod at a time without downtime: a new pod has to be ready before an old one stops, and poll and result wait 5 seconds before stopping, so Traefik stops sending them requests first.

Uninstalling deletes the `db` Cluster, and CloudNativePG deletes its volumes with it, so the PostgreSQL data is lost. The redis volumes are kept, delete them to start from an empty queue:

```bash
kubectl delete pvc -l app=redis -n bernstein
```

## Security

All pods run as non-root and comply with the Kubernetes `restricted` Pod Security Standard. The settings are in `securityContext` (shared by every container) and in each component's `podSecurityContext`.
