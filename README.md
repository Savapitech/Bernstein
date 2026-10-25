Create the pull image secret with your docker registry credentials

```bash
kubectl create secret docker-registry gitlab-registry --docker-server=REGISTRY_URL --docker-username=REGISTRY_USERNAME --docker-password=REGISTRY_PASSWORD -n bernstein

```

Add the Password for the postgres data base

```bash
kubectl create secret generic postgres-secret --namespace bernstein --from-literal=POSTGRES_PASSWORD='bernstein-test-123'
```

Check if the command works
```bash
kubectl get secrets -n bernstein
```
