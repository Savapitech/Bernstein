# Bernstein

A voting application deployed on Kubernetes with a Helm chart.

| Component | Role                                       | Exposed as |
|-----------|--------------------------------------------|------------|
| poll      | Web page where users vote                  | NodePort   |
| result    | Web page showing the live results          | NodePort   |
| worker    | Moves votes from Redis to PostgreSQL       | none       |
| redis     | Queue holding incoming votes               | ClusterIP  |
| postgres  | Database storing the votes                 | ClusterIP  |

## Prerequisites

- A Kubernetes cluster and `kubectl` configured to reach it
- Helm 3
- Credentials for the registry hosting the poll, worker and result images

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

Install the chart:

```bash
helm install bernstein chart/bernstein --namespace bernstein
```

A post-install job creates the database schema once PostgreSQL is up. Check that everything is running:

```bash
kubectl get pods -n bernstein
```

## Accessing the application

poll and result are exposed through NodePort services. Get their ports:

```bash
kubectl get svc poll result -n bernstein
```

Then open `http://<node-ip>:<node-port>` in a browser. To pin a port instead of getting a random one, set `poll.service.nodePort` or `result.service.nodePort` to a value between 30000 and 32767.

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
| `<app>.replicas`                | `1` or `2`                                  | Number of pods                        |
| `<app>.service.type`            | `NodePort` for apps, `ClusterIP` otherwise  | Kubernetes service type               |
| `postgres.storage.size`         | `1Gi`                                       | Size of the database volume           |

If you rename a secret, use the same name in the `kubectl create secret` command and in the values.

## Upgrade and uninstall

```bash
helm upgrade bernstein ./chart/bernstein --namespace bernstein
helm uninstall bernstein --namespace bernstein
```

Uninstalling keeps the PostgreSQL volume. Delete it to start from an empty database:

```bash
kubectl delete pvc postgres-data-postgres-0 -n bernstein
```

## Security

All pods run as non-root and comply with the Kubernetes `restricted` Pod Security Standard. The settings are in `securityContext` (shared by every container) and in each component's `podSecurityContext`.
