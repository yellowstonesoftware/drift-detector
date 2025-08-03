# DriftDetector

A Swift CLI tool that inspects Kubernetes contexts for service deployments and compares them against the latest release tags in corresponding GitHub repositories to identify version drift.

Example Output

![Example Output](https://github.com/yellowstonesoftware/drift-detector/blob/main/drift_output.png)

## Usage

```
USAGE: drift_detector [--context <context> ...] --namespace <namespace> [--github-token <github-token>] [--config <config>] [--log-level <log-level>]

OPTIONS:
  --context <context>     Kubernetes contexts with aliases in format 'context=alias'. Can be specified multiple times.
  --namespace <namespace> Kubernetes namespace to inspect
  --github-token <github-token>
                          GitHub Personal Access Token for API authentication (if not provided, will use GITHUB_TOKEN)
  --config <config>       Path to drift_detector YAML configuration file (default: config.yaml) (default: config.yaml)
  --log-level <log-level> Logging level (default: info) (default: info)
  --version               Show the version.
  -h, --help              Show help information.
```

Typical usage could look this:

```
./drift_detector --namespace mystuff gke_prod_us-central1_gke=Prod  --context gke_stage_us-central1_gke=Stage --log-level info --config config.yaml --context 
```

## Configuration file

```yaml
github:
  history_count: 30
  api:
    base_url: 'https://api.github.com'
    organization: 'Myorg'
    concurrency: 15
  services:
    - service-1=repo_name_github

kubernetes:
  service:
    selector:
      - role: [stable]
```

The services mapping in the `github` stanza allows one to specify a GitHub repo name for a particular app.

The `kubernetes.service.selector` is for configuring a Label Selector to match Kubernetes Deployments on when interogating the cluster. For example, the above configuration would effectively result in Drift Detector performing the same query as `kc get deployments -l role=stable`

## Authentication

### Kubernetes 

Kubernetes clusters are discovered and accessed by discovering kubeconfig either from `$HOME/.kube/config` or `$KUBECONFIG`. Credentials needs to be current, for example if kubeconfig specifies something like:

```yaml
- name: gke_stage_us-central1_gke
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      args: null
      command: gke-gcloud-auth-plugin
```

`gcloud auth login` needs to have been run before using Drift Detector to establish valid credentials. 

### GitHub

GitHub access makes use of a GH PAT (Personal Access Token) that needs to be set at `$GITHUB_TOKEN` or provided with the `--github-token` CLI parameter. 