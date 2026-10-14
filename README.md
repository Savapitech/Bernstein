Add the Password for the postgres data base

```
kubectl create secret generic postgres-secret --namespace bernstein --from-literal=POSTGRES_PASSWORD='bernstein-test-123'
```

Check if the command works
```
kubectl get secrets -n bernstein
```
