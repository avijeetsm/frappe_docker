# AKS deployment

This is a starting deployment layer for the custom Frappe image. It is separate
from the local Docker Compose setup.

## Before applying

Create the secret without committing it:

```bash
kubectl create namespace frappe
kubectl -n frappe create secret generic frappe-secrets \
  --from-literal=mariadb-root-password='CHANGE_ME' \
  --from-literal=admin-password='CHANGE_ME'
```

For a real deployment, generate the values locally and save the printed
Administrator password securely:

```bash
frappe_root_pass=$(openssl rand -hex 24)
frappe_admin_pass=$(openssl rand -hex 24)

kubectl -n frappe create secret generic frappe-secrets \
  --from-literal=mariadb-root-password="$frappe_root_pass" \
  --from-literal=admin-password="$frappe_admin_pass"

printf 'Administrator password: %s\n' "$frappe_admin_pass"
```

`openssl rand -hex 24` creates 24 random bytes encoded as 48 hexadecimal
characters. The values are stored in the Kubernetes Secret and are not
committed to this repository. The site creation Job uses them for the MariaDB
root account and initial Frappe Administrator account.

To reset the Administrator password later without deleting volumes:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site frontend set-admin-password 'NEW_STRONG_PASSWORD'
```

The manifests use the ARM64 ACR image `frappecontainers.azurecr.io/frappe-custom:16.0.1-arm64`,
Azure Files for the shared Frappe sites volume, and Azure managed disks for
MariaDB and Redis queue data.

Attach ACR access to AKS once:

```bash
az aks update --resource-group frappe_test --name frappe --attach-acr frappecontainers
```

Install the NGINX ingress controller with the checked-in Azure health-probe
configuration, then validate/apply:

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values k8s/aks/ingress-nginx-values.yaml
```

The hostname is `erp.avijeet.site` in `ingress.yaml`. Validate/apply with:

```bash
kubectl kustomize k8s/aks > /tmp/frappe-aks.yaml
kubectl apply -k k8s/aks
kubectl -n frappe get pods,pvc,ingress
```

The Jobs must run after the database and shared volume are available. For a
production deployment, use a managed MariaDB-compatible database and managed
Redis instead of the in-cluster stateful services, and add TLS, backups,
resource limits, and network policies.
