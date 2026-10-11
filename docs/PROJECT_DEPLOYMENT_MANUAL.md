# Frappe application deployment manual

This document describes the custom work added to this repository for running a
Frappe/ERPNext installation locally with Docker Compose and remotely on Azure
Kubernetes Service (AKS).

It is a project-specific guide. The upstream Frappe Docker documentation in the
rest of `docs/` remains useful for general Docker and Frappe operations.

## 1. What this repository is

The repository is based on `frappe/frappe_docker`. It builds and runs a custom
Frappe image containing the following applications:

| Application | Source ref |
|---|---|
| Frappe Framework | `v16.33.0` |
| ERPNext | `v16.34.1` |
| CRM | `v1.83.0` |
| India Compliance | `v16.9.0` |
| HRMS | `v16.17.1` |
| India Payroll | `develop` |
| Insights | `version-3` |
| Print Designer | `develop` (experimental on Frappe v16) |

The application list is defined in [`apps.json`](../apps.json). It is copied
into the image build and passed to `bench init`, so the apps are present in the
image before the site is created.

There are two supported execution targets:

1. Local Docker Compose for development, testing, and troubleshooting.
2. AKS manifests for the current Azure deployment.

The current AKS image is an ARM64 image in Azure Container Registry:

```text
frappecontainers.azurecr.io/frappe-custom:16.0.1-arm64
```

Kubernetes deploys it by digest rather than by a mutable tag.

The current deployed digest is recorded in [`build.lock.json`](../build.lock.json)
and [`k8s/aks/kustomization.yaml`](../k8s/aks/kustomization.yaml).

## 2. Important project files

### Actual installation and deployment configuration

These files affect the image, site, containers, or AKS resources:

- [`apps.json`](../apps.json) — applications included in the custom image.
- [`images/layered/Containerfile`](../images/layered/Containerfile) — custom image build.
- [`docker-bake.hcl`](../docker-bake.hcl) — Buildx Bake target named `custom`.
- [`build.lock.json`](../build.lock.json) — known-good image digest and source commit record.
- [`pwd.yml`](../pwd.yml) — local single-file Compose installation.
- [`compose.local.yaml`](../compose.local.yaml) — local entry point that includes `pwd.yml`.
- [`compose.yaml`](../compose.yaml) — base multi-service Compose configuration.
- [`example.env`](../example.env) — example environment variables.
- [`k8s/aks/`](../k8s/aks/) — AKS namespace, storage, services, jobs, deployments, and ingress.
- [`resources/core/`](../resources/core/) — image entrypoint and startup scripts.

### Documentation and development-only files

- `docs/` — upstream and project documentation.
- `development/` — development examples and helper tooling.
- `devcontainer-example/` — optional VS Code devcontainer example.
- `overrides/` — upstream Compose scenario overrides.
- `tests/` — repository tests and connection checks.

The `.dockerignore` intentionally excludes documentation, tests, development
files, Compose files, and other build-irrelevant content from the custom image
build context.

## 3. Changes made in this project

### Custom image

The layered image build was changed to:

- copy the project `apps.json` into the builder image;
- install all listed Frappe applications during `bench init`;
- disable Cypress binary download with `CYPRESS_INSTALL_BINARY=0`;
- increase Yarn's network timeout;
- use the npm registry explicitly for Yarn package resolution;
- retain the normal Frappe runtime entrypoint and asset handling.

The build target is configured for `linux/arm64`, matching the current AKS
node pool and the Apple Silicon build machine. If the AKS node architecture is
changed, the image platform and Kubernetes node selectors must be changed
together.

### Local Compose

The local setup uses `custom:16` and does not pull that image from a registry.
The site creation job installs ERPNext and the additional applications on a new
site. On an existing site it attempts to install the additional apps as well.

The local setup includes:

- MariaDB;
- Redis cache;
- Redis queue;
- Frappe backend;
- frontend/Nginx;
- websocket service;
- short and long queue workers;
- scheduler;
- site creation and configuration jobs.

The local web endpoint is normally `http://localhost:8080`.

### AKS deployment

The AKS layer was added under `k8s/aks/`. It contains:

- one `frappe` namespace;
- one Redis cache Deployment;
- one Redis queue StatefulSet;
- one shared Azure Files PVC (100 GiB, premium) for Frappe sites and logs;
- one configurator Job;
- one backend Deployment and Service;
- one frontend Deployment and Service;
- one websocket Deployment and Service;
- one short worker, one long worker, and one scheduler;
- one NGINX Ingress resource (catch-all, no fixed hostname).

All Frappe application pods are pinned to ARM64 nodes. Workloads were reduced
to one replica each because the expected load is small. This is suitable for a
small test or low-traffic installation, not high availability.

**Database**: The deployment uses Azure Database for PostgreSQL Flexible Server.
Frappe v16 does not support MySQL — it only accepts MariaDB, PostgreSQL, or
SQLite for `bench new-site`. Azure MySQL Flexible Server is MySQL, not MariaDB,
and is incompatible. The PostgreSQL server is deployed inside the AKS managed
VNet (`aks-vnet-*`) so no VNet peering or additional DNS configuration is
needed.

**Multisite**: The ingress has no fixed hostname (catch-all). The frontend nginx
passes the incoming `Host` header as the `X-Frappe-Site-Name` header to the
backend (`FRAPPE_SITE_NAME_HEADER=$http_host`). Each Frappe site must be named
exactly after the hostname used to access it (e.g. `bench new-site
erp.avijeet.site`). Site creation is manual.

The NGINX ingress controller uses the Azure load balancer health probe path
`/healthz`. This was necessary because probing the application root caused the
Azure load balancer to report the service as unhealthy and produced external
timeouts.

## 4. Current Azure resources and assumptions

The deployment uses these values:

```text
Subscription:    cbf3a13d-c1d7-4876-946d-076db459bdfc
Resource group:  frappe_test
AKS cluster:     frappe  (node pool: arm64, MC RG: MC_frappe_test_frappe_centralindia)
ACR:             frappecontainers.azurecr.io
Namespace:       frappe
Ingress IP:      4.224.71.45
```

### Azure PostgreSQL Flexible Server

```text
Server name:    frappe
FQDN:           frappe.postgres.database.azure.com
Version:        PostgreSQL (latest at time of creation)
Tier:           Burstable
Public access:  Disabled (private endpoint in AKS VNet)
VNet:           aks-vnet-* (MC_frappe_test_frappe_centralindia)
Subnet:         customsubnet
Private DNS:    frappe.private.postgres.database.azure.com (linked to AKS VNet)
Admin user:     frappe
```

The server is in the AKS managed VNet. Pods can resolve the FQDN and reach port
5432 directly without additional DNS or peering configuration.

AKS has permission to pull the private ACR image through the kubelet identity's
`AcrPull` role assignment. The ACR admin account was enabled temporarily for
the image push and then disabled again.

The current cluster uses an ARM64 node pool. Do not deploy the ARM64 image to
an AMD64-only node pool. Either retain the ARM64 node selector and node pool,
or rebuild and push an AMD64 image and update the selectors.

## 5. Rebuild the image locally

From the repository root:

```bash
docker buildx bake custom \
  --set custom.tags=custom:16 \
  --set custom.platforms=linux/arm64 \
  --load
```

Verify that the image is available locally:

```bash
docker image inspect custom:16
```

For an AMD64 target, use:

```bash
docker buildx bake custom \
  --set custom.tags=frappe-custom:16-amd64 \
  --set custom.platforms=linux/amd64 \
  --push
```

The `--push` form requires a registry tag and authenticated registry access.
For a local Apple Silicon run, use the ARM64 image and `--load`.

## 6. Run locally

Build the local image first, then start the Compose stack:

```bash
docker buildx bake custom \
  --set custom.tags=custom:16 \
  --set custom.platforms=linux/arm64 \
  --load

docker compose -f compose.local.yaml up -d
```

Watch initialization:

```bash
docker compose -f compose.local.yaml ps
docker compose -f compose.local.yaml logs -f create-site
```

Open `http://localhost:8080` after site creation completes. The default demo
credentials in this project are intended for local use only; change passwords
before using any non-disposable environment.

Useful local commands:

```bash
docker compose -f compose.local.yaml logs -f backend frontend websocket
docker compose -f compose.local.yaml exec backend bench --site frontend list-apps
docker compose -f compose.local.yaml down
```

Do not delete volumes as a normal restart procedure. Volumes contain the local
MariaDB database and Frappe site data. Delete them only when intentionally
resetting the local installation and accepting data loss:

```bash
docker compose -f compose.local.yaml down -v
```

## 7. Push an image to ACR

Authenticate to Azure and attach ACR pull permission to AKS if this has not
already been done:

```bash
az login
az account set --subscription cbf3a13d-c1d7-4876-946d-076db459bdfc
az aks update \
  --resource-group frappe_test \
  --name frappe \
  --attach-acr frappecontainers
```

Build and push an ARM64 image from an ARM64 Docker host:

```bash
docker buildx bake custom \
  --set custom.tags=frappecontainers.azurecr.io/frappe-custom:16.0.1-arm64 \
  --set custom.platforms=linux/arm64 \
  --push
```

After pushing, record the resulting digest in `build.lock.json` and in
`k8s/aks/kustomization.yaml`. Deploying by digest prevents an unnoticed tag
update from changing the running application.

## 8. Deploy or update AKS

### First-time setup

Create the namespace and secret once. The secret must not be committed.

The `mariadb-root-password` key now holds the **PostgreSQL admin password**
(the key name is a historical artifact from when the deployment used MariaDB):

```bash
kubectl create namespace frappe
kubectl -n frappe create secret generic frappe-secrets \
  --from-literal=mariadb-root-password='<postgres-admin-password>' \
  --from-literal=admin-password='<frappe-admin-password>'
```

Install or update the ingress controller:

```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --values k8s/aks/ingress-nginx-values.yaml
```

Apply the project manifests:

```bash
kubectl apply -k k8s/aks
```

Wait for the configurator Job to complete (it writes `common_site_config.json`):

```bash
kubectl -n frappe wait --for=condition=complete job/frappe-configurator --timeout=120s
kubectl -n frappe exec deploy/frappe-backend -- cat sites/common_site_config.json
```

The output should show:

```json
{
  "db_host": "frappe.postgres.database.azure.com",
  "db_port": 5432,
  "db_type": "postgres",
  ...
}
```

### Create the first site

Site creation is manual. The site name must match the hostname exactly:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench new-site <hostname> \
  --db-type postgres \
  --db-root-username=frappe \
  --db-root-password='<postgres-admin-password>' \
  --admin-password='<frappe-admin-password>' \
  --install-app erpnext
```

After creating the first site, set it as the default:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench set-config -g default_site <hostname>
```

### Adding a new tenant (site)

Each tenant gets its own Frappe site named after their hostname. Point the
tenant's DNS to the ingress IP, then:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench new-site <tenant-hostname> \
  --db-type postgres \
  --db-root-username=frappe \
  --db-root-password='<postgres-admin-password>' \
  --admin-password='<tenant-admin-password>' \
  --install-app erpnext
```

No ingress changes are required — the catch-all ingress rule routes all
hostnames to the frontend, which identifies the site by the `Host` header.

### Rerunning the configurator

If the ConfigMap changes (e.g. Redis host or DB host), the configurator Job
must be deleted and reapplied to regenerate `common_site_config.json`:

```bash
kubectl -n frappe delete job frappe-configurator
kubectl apply -k k8s/aks
kubectl -n frappe wait --for=condition=complete job/frappe-configurator --timeout=120s
kubectl -n frappe rollout restart deploy
```

### Resetting the Administrator password

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site <hostname> set-admin-password 'NEW_STRONG_PASSWORD'
```

Avoid passwords containing `#` — browsers can mishandle `#` in login form
submissions, causing spurious authentication failures.

## 9. Verify the public endpoint

Check DNS and the Azure load balancer:

```bash
dig +short erp.avijeet.site
kubectl -n ingress-nginx get svc ingress-nginx-controller
kubectl get ingress -n frappe
```

Test HTTP:

```bash
curl -I --connect-timeout 10 --max-time 20 http://erp.avijeet.site/
```

A successful deployment returns `HTTP/1.1 200 OK`. The current ingress IP is
`4.224.71.45`. Treat the IP as changeable and always check the current Ingress
service before changing DNS.

For HTTPS, add a certificate and an HTTPS/TLS configuration. The current
checked-in ingress only describes HTTP and should not be considered production
TLS configuration.

## 10. Pod layout

The application workload intentionally has one pod for each of these roles:

- backend;
- frontend;
- websocket;
- short queue;
- long queue;
- scheduler;
- Redis cache;
- Redis queue.

The configurator Job remains as a completed Job pod after it finishes. It is
not continuously serving workload.

There is no in-cluster database pod. The database is Azure PostgreSQL Flexible
Server (managed service).

AKS also runs system pods in `kube-system`. Do not manually delete core pods
such as CoreDNS, kube-proxy, Azure CNI/CNS, cloud-node-manager, konnectivity,
or the disk/file CSI node drivers. They are required for cluster operation.

Optional AKS features that were reviewed during this setup included Azure
Monitor metrics, Key Vault Secrets Provider, Workload Identity, Image Cleaner,
and Retina. Azure Monitor metrics and the Key Vault Secrets Provider were
disabled after confirming they were not used by the checked-in manifests.
Workload Identity and Image Cleaner should only be disabled if no future
deployment will use their functionality. Retina was left untouched because it
is associated with AKS networking and observability behavior.

Disable optional features through Azure configuration, not by repeatedly
deleting their pods. The controller will recreate a pod while its feature is
enabled.

## 11. Troubleshooting

### Login fails with invalid credentials

Verify with curl first to distinguish a backend issue from a browser issue:

```bash
curl -s -X POST "http://erp.avijeet.site/api/method/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "usr=Administrator&pwd=<password>"
```

If curl returns `{"message":"Logged In",...}` but the browser fails, clear
browser cookies and cache or use a private/incognito window. Passwords
containing `#` can be mishandled by browser form submissions — use
`set-admin-password` to reset to an alphanumeric password.

If curl also fails, reset the password:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site set-admin-password 'NewPassword'
```

### `You are not permitted to access this resource`

This usually indicates an authorization or site-context problem. Check that the
`Host` header matches a site name exactly:

```bash
kubectl -n frappe exec deploy/frappe-backend -- bench --site erp.avijeet.site list-apps
kubectl -n frappe logs deployment/frappe-backend
```

### Site not found / blank page

The ingress routes by `Host` header. The Frappe site name must match the
hostname used to access it. If accessing by IP or port-forward, the host header
will not match any site. Use the actual hostname, or add it to `/etc/hosts`.

### External timeout

Check the ingress controller service, its external IP, DNS, and Azure health
probe path:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
kubectl -n ingress-nginx describe svc ingress-nginx-controller
dig +short erp.avijeet.site
curl -I --max-time 20 http://erp.avijeet.site/
```

The ingress service must retain the annotation from
[`ingress-nginx-values.yaml`](../k8s/aks/ingress-nginx-values.yaml).

### Pods stuck Pending

Inspect scheduling and architecture:

```bash
kubectl -n frappe describe pod <pod-name>
kubectl get nodes -L kubernetes.io/arch
kubectl -n frappe get pods -o wide
```

The current custom image is ARM64 and the Frappe workloads have an ARM64
`nodeSelector`.

### Image pull failure

Check the exact image and ACR permission:

```bash
kubectl -n frappe describe pod <pod-name>
az aks show --resource-group frappe_test --name frappe \
  --query identityProfile.kubeletidentity.objectId -o tsv
az acr show --name frappecontainers --resource-group frappe_test
```

The AKS kubelet identity needs the `AcrPull` role on the registry.

### Database connection failure

Test DNS resolution and TCP connectivity from a pod:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  getent hosts frappe.postgres.database.azure.com

kubectl -n frappe exec deploy/frappe-backend -- \
  bash -c 'timeout 5 bash -c "echo >/dev/tcp/frappe.postgres.database.azure.com/5432" && echo "PORT OPEN"'
```

If DNS fails, check that the private DNS zone
`frappe.private.postgres.database.azure.com` has a VNet link to the AKS
managed VNet (`aks-vnet-*` in the node resource group).

### Configurator Job not updating config

If `common_site_config.json` still shows old values after a ConfigMap change,
the Job has already completed and will not rerun. Delete it and reapply:

```bash
kubectl -n frappe delete job frappe-configurator
kubectl apply -k k8s/aks
kubectl -n frappe wait --for=condition=complete job/frappe-configurator --timeout=120s
```

## 12. Reproducibility and release procedure

The current running deployment is reproducible at the container level because
Kustomize pins the image by digest. `build.lock.json` records the image digest,
platform, Frappe commit, app commits, and base image digests used for the known
good image.

The source build still uses branch/tag references from `apps.json`; those
references can move or be retagged. For a fully reproducible rebuild, update
the build process to consume the exact commits recorded in `build.lock.json`,
or replace the app refs with immutable commit refs before building.

Recommended release sequence:

1. Update `apps.json` deliberately.
2. Build for the target AKS node architecture.
3. Push a unique image tag to ACR.
4. Record the pushed digest and source commits in `build.lock.json`.
5. Update the digest in `k8s/aks/kustomization.yaml`.
6. Run `kubectl kustomize k8s/aks` and review the rendered output.
7. Apply and verify Jobs, rollouts, PVCs, ingress, and the public URL.
8. Run `bench migrate` for each active site after the image update:
   ```bash
   kubectl -n frappe exec deploy/frappe-backend -- bench --site <hostname> migrate
   ```
9. Keep the previous image digest available for rollback.

## 13. Production work still required

The current AKS layer is a small, low-load starting deployment. Before calling
it production-ready, add or decide on:

- HTTPS/TLS and certificate renewal (cert-manager with wildcard cert recommended for multisite);
- backups and tested restore procedures for PostgreSQL and the Azure Files PVC;
- resource requests and limits on all pods;
- monitoring and alerting appropriate to the operating environment;
- network policies and access controls;
- secret management, preferably Azure Key Vault or another managed secret system;
- a migration/release procedure for Frappe and installed apps (see `bench migrate` above);
- availability and scaling requirements (HPA, multiple replicas, PostgreSQL HA);
- a rollback procedure based on image digests and database backups;
- managed Redis (Azure Cache for Redis) to replace in-cluster Redis StatefulSet.

The current one-replica configuration is intentionally economical and should
not be interpreted as high availability.

## 14. Day-to-day operations

### Data locations

There are two independent data stores:

| Store | What lives there | Survives cluster deletion? |
|---|---|---|
| Azure PostgreSQL | All ERPNext records, configurations, user data | **Yes** — managed service in `frappe_test` RG |
| Azure Files PVC (`frappe-sites`) | Uploaded files, site config, bench backups | **No** — file share is in the node RG (`MC_*`), deleted with the cluster unless backed up |

The `site_config.json` inside the file share is critical — it holds the
randomly-generated database name and password for each site (e.g.
`_c8167b3b48bdc293`). If it is lost, reconnecting the application to an
existing database requires manual reconstruction.

### PostgreSQL backups

Azure automatically backs up the database with 7-day point-in-time restore.
Increase retention before going live:

```bash
az postgres flexible-server update \
  --resource-group frappe_test --name frappe \
  --backup-retention 35
```

Restore to a new server (does not overwrite the running one):

```bash
az postgres flexible-server restore \
  --resource-group frappe_test \
  --name frappe-restored \
  --source-server frappe \
  --restore-time "2026-09-15T10:00:00Z"
```

After restore, update `DB_HOST` in `config.yaml`, delete the configurator job,
and reapply.

Manual dump before risky operations (image upgrades, schema changes):

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  sh -c 'PGPASSWORD=<db-password> pg_dump \
    -h frappe.postgres.database.azure.com \
    -U <db-user> <db-name> > /tmp/dump.sql'

kubectl -n frappe cp \
  frappe-backend-<pod-id>:/tmp/dump.sql ./dump-$(date +%Y%m%d).sql
```

The `db-user`, `db-name`, and `db-password` are in
`sites/erp.avijeet.site/site_config.json` inside the running pod.

### File share backups

Enable Azure Backup on the file share from the portal:

1. Create a Recovery Services Vault in `frappe_test` RG.
2. Add backup policy: Azure Files → select the storage account containing the
   `frappe-sites` share → daily snapshot, 30-day retention.

This creates daily snapshots of the file share independent of the cluster.

Alternatively, use Frappe's built-in backup (stores zip to `private/backups/`):

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site backup --with-files
```

Copy backups to Azure Blob Storage for off-cluster retention:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  sh -c 'azcopy copy \
    "sites/erp.avijeet.site/private/backups/*" \
    "https://<storage>.blob.core.windows.net/backups/<sas-token>"'
```

### Preserving site credentials

The randomly-generated `db_name`, `db_user`, and `db_password` in
`site_config.json` are the link between the file share and the PostgreSQL
database. Store them in Azure Key Vault or note them down:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  cat sites/erp.avijeet.site/site_config.json
```

Keep this output alongside your PostgreSQL admin password in a secure store.
Without it, recovering from a lost file share requires manually reconstructing
the site config.

### App and image upgrades

```bash
# 1. Take a backup
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site backup --with-files

# 2. Update image digest in k8s/aks/kustomization.yaml, then apply
kubectl apply -k k8s/aks

# 3. Run migrations for each site
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site migrate

# 4. Verify apps are healthy
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site list-apps
```

---

## 15. Disaster recovery

### Scenario: K8s cluster is gone

This covers a deleted cluster, a corrupted control plane, or any situation
where `kubectl` cannot reach the cluster and nodes cannot be recovered.

**What survives:**

| Resource | Status | Reason |
|---|---|---|
| PostgreSQL server + data | **Alive** | Managed service in `frappe_test` RG, independent of K8s |
| Azure Files share | **Gone** | Created in node RG (`MC_*`), deleted with cluster |
| Azure Files share (if Azure Backup enabled) | **Recoverable** | Daily snapshot in Recovery Services Vault |
| K8s secrets (`frappe-secrets`) | **Gone** | Stored only in etcd |
| Site `site_config.json` | **Gone with file share** | Contains DB credentials for each site |

The database is safe. The risk is losing the file share and the `site_config.json`
that maps each site to its database.

---

### Recovery path A — file share was backed up (Azure Backup or azcopy)

**Step 1: Recreate the cluster**

```bash
az aks create \
  --resource-group frappe_test \
  --name frappe \
  --node-count 1 \
  --node-vm-size Standard_D4ps_v5 \
  --node-osdisk-size 128 \
  --network-plugin azure \
  --generate-ssh-keys
```

**Step 2: Restore the file share snapshot**

From the portal: Recovery Services Vault → Azure Files → select the share →
Restore → Restore to original location (creates a new share if original is gone).

Note the restored storage account name and share name.

**Step 3: Create a static PersistentVolume pointing to the restored share**

```yaml
# pv-restore.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: frappe-sites-restored
spec:
  capacity:
    storage: 100Gi
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: azurefile-csi-premium
  csi:
    driver: file.csi.azure.com
    volumeHandle: frappe-sites-restored
    volumeAttributes:
      resourceGroup: <storage-account-rg>
      shareName: <restored-share-name>
    nodeStageSecretRef:
      name: azure-storage-secret
      namespace: frappe
```

Create the storage secret and apply the PV, then update `storage.yaml` to use
this static PV instead of dynamic provisioning.

**Step 4: Recreate the K8s secret**

```bash
kubectl create namespace frappe
kubectl -n frappe create secret generic frappe-secrets \
  --from-literal=mariadb-root-password='<postgres-admin-password>' \
  --from-literal=admin-password='<frappe-admin-password>'
```

**Step 5: Reapply manifests**

```bash
kubectl apply -k k8s/aks
```

The configurator will write `common_site_config.json`. The file share already
contains the site directories with their `site_config.json` files pointing to
the existing PostgreSQL databases. All data is intact.

**Step 6: Verify**

```bash
kubectl -n frappe get pods
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site list-apps
curl -s http://erp.avijeet.site/api/method/frappe.auth.get_logged_user
```

---

### Recovery path B — file share is gone (no backup)

The PostgreSQL database is intact but the `site_config.json` — which holds
the randomly-generated DB credentials — is lost. The database still exists
(visible as `_c8167b3b48bdc293` on the PostgreSQL server). Recovery requires
reconstructing the site config manually.

**Step 1–4: Same as Path A** (recreate cluster, secret, apply manifests).
A fresh empty PVC is provisioned.

**Step 5: Identify the existing database**

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  sh -c 'PGPASSWORD=<postgres-admin-password> psql \
    -h frappe.postgres.database.azure.com -U frappe -d postgres \
    -c "SELECT datname FROM pg_database WHERE datname LIKE '"'"'_%'"'"';"'
```

This lists the site databases (names starting with `_`). Match them to sites
by checking the tables inside each one.

**Step 6: Find or reset the DB user password**

The DB user has the same name as the database (e.g. `_c8167b3b48bdc293`).
Reset its password using the admin account:

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  sh -c 'PGPASSWORD=<postgres-admin-password> psql \
    -h frappe.postgres.database.azure.com -U frappe -d postgres \
    -c "ALTER USER \"_c8167b3b48bdc293\" PASSWORD '"'"'new-db-password'"'"';"'
```

**Step 7: Reconstruct `site_config.json`**

```bash
kubectl -n frappe exec deploy/frappe-backend -- \
  sh -c 'mkdir -p sites/erp.avijeet.site && cat > sites/erp.avijeet.site/site_config.json << EOF
{
 "db_name": "_c8167b3b48bdc293",
 "db_password": "new-db-password",
 "db_type": "postgres",
 "db_user": "_c8167b3b48bdc293"
}
EOF'
```

**Step 8: Restart and verify**

```bash
kubectl -n frappe rollout restart deploy
kubectl -n frappe exec deploy/frappe-backend -- \
  bench --site erp.avijeet.site list-apps
```

All database data (ERPNext records, CRM, users) is restored. Uploaded files
that were not backed up separately are permanently lost.

---

### Recovery priority checklist

Before going live, implement these in order:

1. **Enable Azure Backup on the file share** — makes Path A possible, avoids
   the manual credential reconstruction in Path B.
2. **Store `site_config.json` contents in Azure Key Vault** — one secret per
   site, updated when a site is created. Makes Path B fast even without the
   file share.
3. **Increase PostgreSQL backup retention to 35 days** — extends the PITR
   window for data recovery.
4. **Weekly `bench backup --with-files` to Azure Blob** — self-contained
   restore option that includes both the database dump and uploaded files,
   independent of Azure infrastructure state.
5. **Change PVC reclaim policy to `Retain`** — prevents accidental deletion of
   the file share if a PVC is deleted. Apply once after cluster creation:
   ```bash
   kubectl patch pv $(kubectl -n frappe get pvc frappe-sites \
     -o jsonpath='{.spec.volumeName}') \
     -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
   ```
