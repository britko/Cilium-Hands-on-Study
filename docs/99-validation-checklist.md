# 99. 전체 검증 체크리스트

이 문서는 모든 랩을 순서대로 검증할 때 사용하는 체크리스트입니다.

## 1. 기본 클러스터

Windows PowerShell:

```powershell
.\scripts\create-kind-cluster.ps1
.\scripts\install-cilium.ps1
.\scripts\validate.ps1
```

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh
bash scripts/install-cilium.sh
bash scripts/validate.sh
```

통과 기준:

- `cilium status --wait` 성공
- `hubble status` 성공
- `cilium connectivity test` 성공

## 2. eBPF Datapath

Windows PowerShell:

```powershell
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
$pod = kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}'
kubectl -n app exec $pod -- curl -sS http://api/get
cilium endpoint list
cilium identity list
cilium service list
```

macOS/Linux Bash:

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$pod" -- curl -sS http://api/get
cilium endpoint list
cilium identity list
cilium service list
```

통과 기준:

- `frontend`에서 `api` 호출 성공
- `app=frontend`, `app=api` endpoint가 Cilium에 표시됨
- `api` Service가 Cilium service list에 표시됨

## 3. Hubble

```bash
kubectl apply -f labs/03-hubble/traffic-generator.yaml
hubble observe --namespace app --protocol http --last 5m
hubble observe --namespace app --protocol dns --last 5m
```

통과 기준:

- HTTP flow와 DNS flow가 표시됨
- source/destination namespace와 Pod가 기대한 값과 일치함

## 4. NetworkPolicy

Windows PowerShell:

```powershell
kubectl apply -f labs/04-network-policy/default-deny.yaml
kubectl -n app exec $pod -- curl -m 3 -sS http://api/get
kubectl apply -f labs/04-network-policy/allow-frontend-to-api.yaml
kubectl -n app exec $pod -- curl -sS http://api/get
```

macOS/Linux Bash:

```bash
kubectl apply -f labs/04-network-policy/default-deny.yaml
kubectl -n app exec "$pod" -- curl -m 3 -sS http://api/get
kubectl apply -f labs/04-network-policy/allow-frontend-to-api.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
```

통과 기준:

- default deny 이후 호출 실패
- allow 정책 적용 후 호출 성공
- Hubble에서 차단/허용 flow가 구분됨

## 5. L7 Policy

Windows PowerShell:

```powershell
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl apply -f labs/05-l7-policy/http-l7-policy.yaml
kubectl -n app exec $pod -- curl -sS http://api/get
kubectl -n app exec $pod -- curl -m 5 -X POST -sS http://api/post
hubble observe --namespace app --protocol http --last 5m
```

macOS/Linux Bash:

```bash
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl apply -f labs/05-l7-policy/http-l7-policy.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
hubble observe --namespace app --protocol http --last 5m
```

통과 기준:

- `GET /get` 허용
- `POST /post` 차단
- Hubble에서 HTTP method/path와 verdict 확인 가능

## 6. kube-proxy Replacement

Windows PowerShell:

```powershell
.\scripts\create-kind-cluster.ps1 -ClusterName cilium-study-kpr -ConfigPath labs/kind/kind-cilium-kpr.yaml
kubectl config use-context kind-cilium-study-kpr
.\scripts\install-cilium.ps1 -ValuesPath labs/01-install/cilium-kpr-values.yaml
kubectl -n kube-system get ds kube-proxy
kubectl apply -f labs/06-kube-proxy-replacement/nodeport-demo.yaml
curl http://127.0.0.1:30080/get
```

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-study-kpr --config labs/kind/kind-cilium-kpr.yaml
kubectl config use-context kind-cilium-study-kpr
bash scripts/install-cilium.sh --values labs/01-install/cilium-kpr-values.yaml
kubectl -n kube-system get ds kube-proxy
kubectl apply -f labs/06-kube-proxy-replacement/nodeport-demo.yaml
curl http://127.0.0.1:30080/get
```

통과 기준:

- kube-proxy DaemonSet이 없음
- Cilium이 Ready
- NodePort 호출 성공

## 7. Gateway API

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f labs/07-gateway-api/gateway-demo.yaml
kubectl -n gateway-demo get gateway,httproute
```

통과 기준:

- Gateway와 HTTPRoute가 Accepted 상태
- Cilium operator 로그에 CRD 누락 오류가 없음

## 8. 실전 운영 패턴

Windows PowerShell:

```powershell
kubectl config use-context kind-cilium-study
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
$pod = kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}'
kubectl apply -f labs/09-production-examples/namespace-zero-trust-baseline.yaml
kubectl -n app exec $pod -- curl -sS http://api/get
kubectl apply -f labs/09-production-examples/saas-egress-allowlist.yaml
kubectl -n app exec $pod -- curl -I https://api.github.com
kubectl -n app exec $pod -- curl -m 5 -I https://example.com
hubble observe --namespace app --verdict DROPPED --last 5m
kubectl delete -f labs/09-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
kubectl apply -f labs/09-production-examples/internal-api-l7-guardrail.yaml
kubectl -n app exec $pod -- curl -sS http://api/get
kubectl -n app exec $pod -- curl -m 5 -X POST -sS http://api/post
```

macOS/Linux Bash:

```bash
kubectl config use-context kind-cilium-study
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
pod=$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')
kubectl apply -f labs/09-production-examples/namespace-zero-trust-baseline.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl apply -f labs/09-production-examples/saas-egress-allowlist.yaml
kubectl -n app exec "$pod" -- curl -I https://api.github.com
kubectl -n app exec "$pod" -- curl -m 5 -I https://example.com
hubble observe --namespace app --verdict DROPPED --last 5m
kubectl delete -f labs/09-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
kubectl apply -f labs/09-production-examples/internal-api-l7-guardrail.yaml
kubectl -n app exec "$pod" -- curl -sS http://api/get
kubectl -n app exec "$pod" -- curl -m 5 -X POST -sS http://api/post
```

통과 기준:

- zero-trust baseline 적용 후에도 명시적으로 허용한 `frontend -> api` 호출은 성공
- `api.github.com` 호출은 성공하고 허용하지 않은 외부 FQDN 호출은 차단
- `GET /get`은 허용되고 `POST /post`는 L7 정책으로 차단
- Hubble에서 허용/차단 flow와 DNS/HTTP 근거 확인 가능

## 9. Cleanup

Windows PowerShell:

```powershell
kubectl delete -f labs/09-production-examples/internal-api-l7-guardrail.yaml --ignore-not-found
kubectl delete -f labs/09-production-examples/saas-egress-allowlist.yaml --ignore-not-found
kubectl delete -f labs/09-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
kubectl delete -f labs/07-gateway-api/gateway-demo.yaml --ignore-not-found
kubectl delete -f labs/06-kube-proxy-replacement/nodeport-demo.yaml --ignore-not-found
kubectl delete -f labs/05-l7-policy/http-l7-policy.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/03-hubble/traffic-generator.yaml --ignore-not-found
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
.\scripts\cleanup.ps1
```

macOS/Linux Bash:

```bash
kubectl delete -f labs/09-production-examples/internal-api-l7-guardrail.yaml --ignore-not-found
kubectl delete -f labs/09-production-examples/saas-egress-allowlist.yaml --ignore-not-found
kubectl delete -f labs/09-production-examples/namespace-zero-trust-baseline.yaml --ignore-not-found
kubectl delete -f labs/07-gateway-api/gateway-demo.yaml --ignore-not-found
kubectl delete -f labs/06-kube-proxy-replacement/nodeport-demo.yaml --ignore-not-found
kubectl delete -f labs/05-l7-policy/http-l7-policy.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/cilium-fqdn-egress.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/allow-frontend-to-api.yaml --ignore-not-found
kubectl delete -f labs/04-network-policy/default-deny.yaml --ignore-not-found
kubectl delete -f labs/03-hubble/traffic-generator.yaml --ignore-not-found
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
bash scripts/cleanup.sh
```

## 검증 기록 템플릿

```text
Date:
Host OS:
Docker Desktop version:
kind version:
Kubernetes version:
Cilium version:
Cilium CLI version:
Hubble CLI version:
Result:
Notes:
```
