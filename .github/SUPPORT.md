# Support

This is a spare-time project. Responses are best-effort and not guaranteed.

## How to get help

- **Documentation**: start with the [README](README.md) for the quick-start flow,
  [ENVS.md](ENVS.md) for every chart value, and [chart/README.md](chart/README.md)
  for install and configuration.
- **Questions & troubleshooting**: open a [GitHub
  Discussion](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/discussions)
  or a blank issue with the `question` label.
- **Bugs**: use the [bug report
  template](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/issues/new?template=bug_report.yml).
  Include the chart version, a redacted `values.yaml`, and `helm template` output.
- **Feature requests**: use the [feature request
  template](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/issues/new?template=feature_request.yml).
- **Security vulnerabilities**: report privately through the [Security
  tab](https://github.com/hcflabs/K8s-DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks/security/advisories/new).
  See [SECURITY.md](SECURITY.md) for scope and supported versions.

## Upstream

This repository is a Kubernetes/k3s port. For issues with the TensorFold recipe,
the serving image, or the model weights themselves, please go upstream:

| Topic | Where |
| --- | --- |
| Recipe, patches, serving image | [MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks](https://github.com/MiaAI-Lab/DeepSeek-v4.1-Flash-1017-2x-DGX-Sparks) |
| Model weights and behaviour | [Mia-AiLab/DeepSeek-V4.1-Flash-1017-4bpw-TensorFold](https://huggingface.co/Mia-AiLab/DeepSeek-V4.1-Flash-1017-4bpw-TensorFold) (model card) |
| k3s ansible collection | [k3s-io/k3s-ansible](https://github.com/k3s-io/k3s-ansible) |