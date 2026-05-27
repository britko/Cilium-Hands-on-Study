# 12. Cluster Mesh

## 학습 목표

- 두 개의 kind 클러스터를 Cilium Cluster Mesh로 연결합니다.
- cluster identity, global service, cross-cluster service discovery를 이해합니다.
- 멀티클러스터 장애와 failover를 검증합니다.

## 왜 필요한가

운영 환경에서 Cluster Mesh는 여러 Kubernetes 클러스터를 하나의 네트워크/서비스 경계처럼 다루기 위해 사용합니다. 다만 물리 네트워크를 더 빠르게 만들거나 리전 간 RTT를 줄여 주는 기능은 아닙니다. 다른 리전이나 데이터센터의 backend로 트래픽을 보내면 지연시간과 egress 비용은 오히려 늘 수 있습니다.

Cluster Mesh의 가치는 네트워크 성능 개선보다 멀티클러스터 운영 제어에 있습니다. 대표적인 목적은 다음과 같습니다.

- 리전, AZ, 데이터센터 단위로 클러스터를 분리하면서도 필요한 서비스 간 통신을 유지합니다.
- 애플리케이션 코드에 리전별 endpoint 분기 로직을 넣지 않고 같은 Kubernetes Service 이름으로 호출합니다.
- 클러스터 업그레이드나 장애 시 트래픽을 다른 클러스터 backend로 우회합니다.
- 같은 서비스 이름을 유지한 채 active-active 또는 active-standby 형태로 backend를 배치합니다.
- 클러스터를 장애 도메인으로 분리하면서 Cilium identity 기반 정책 모델을 멀티클러스터로 확장합니다.

이 장의 실습은 east/west 두 클러스터에 같은 `api.mesh-demo.svc.cluster.local` global service를 만들고, 한쪽 클러스터의 client가 로컬/원격 backend를 모두 호출할 수 있음을 확인합니다. 이후 한쪽 backend를 제거해도 반대편 backend로 계속 응답받는지 검증합니다.

현실적인 운영 패턴은 대개 `service.cilium.io/affinity: "local"`을 함께 사용합니다. 정상 상태에서는 로컬 클러스터 backend를 우선 사용해 원격 지연과 비용을 피하고, 로컬 backend가 사라졌을 때만 원격 클러스터로 failover합니다. Cluster Mesh는 병목을 없애는 도구가 아니라, 정상 시 로컬 경로를 유지하면서 장애 시 생존 경로를 제공하는 도구로 이해하는 편이 정확합니다.

또한 Cluster Mesh는 전체 DR 아키텍처를 대체하지 않습니다. 리전 A가 정전되어 사용자 진입점, ingress, gateway, database, queue, storage까지 함께 영향을 받는 상황에서는 리전 B로 외부 트래픽을 전환하는 DNS/GSLB/global load balancer, 데이터 복제와 승격, secret/config 동기화, failover runbook이 별도로 필요합니다. Cluster Mesh가 제공하는 것은 주로 클러스터 내부 서비스 discovery와 backend failover 경로입니다. 상태가 없거나 데이터 의존성이 외부에서 이미 해결된 backend는 DR 보조 역할을 할 수 있지만, 전체 서비스 DR을 Cluster Mesh만으로 완성할 수는 없습니다.

## 사전 조건

Cluster Mesh는 두 개 이상의 Kubernetes 클러스터를 연결하는 기능입니다. 이 장에서는 기본 실습 클러스터를 재사용하지 않고 `cilium-east`, `cilium-west` 두 클러스터를 새로 만듭니다.

이렇게 분리하는 이유는 다음과 같습니다.

- Cluster Mesh는 클러스터마다 고유한 Cilium cluster name과 cluster id가 필요합니다.
- 연결할 클러스터끼리는 PodCIDR와 ServiceCIDR가 겹치면 안 됩니다.
- 기존 `cilium-study`와 `cilium-study-kpr`는 앞 장의 실습 리소스와 Helm 설정이 남아 있을 수 있습니다.
- Cluster Mesh 설정을 기존 클러스터에 추가하면 이후 Gateway, BGP, Egress Gateway 검증 결과와 섞여 원인 분리가 어려워질 수 있습니다.

따라서 이 장은 `cilium-east`, `cilium-west`를 만들고, 실습이 끝나면 두 클러스터를 삭제하는 흐름을 기본으로 합니다.

노트북이나 소형 VM에서 실습한다면 이 장을 진행하는 동안에는 `cilium-east`, `cilium-west`만 유지합니다. 13장 이후의 BGP, Egress Gateway, encryption 실습은 별도 클러스터를 만들 수 있으므로, 12장을 마친 뒤 두 클러스터를 삭제하고 다음 장으로 넘어갑니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh --cluster-name cilium-east --config labs/kind/kind-cilium-clustermesh-east.yaml
bash scripts/create-kind-cluster.sh --cluster-name cilium-west --config labs/kind/kind-cilium-clustermesh-west.yaml
```

운영 패턴에서는 Cluster Mesh에 참여할 클러스터가 같은 Cilium CA를 신뢰하도록 설치 단계에서 맞춥니다. 실습에서는 로컬 임시 파일로 공통 CA를 만들고, 두 클러스터의 Helm 설치에 같은 CA를 주입합니다.

```bash
openssl genrsa -out /tmp/cilium-clustermesh-ca.key 4096
openssl req -new -x509 -days 3650 \
  -key /tmp/cilium-clustermesh-ca.key \
  -out /tmp/cilium-clustermesh-ca.crt \
  -subj "/CN=cilium-clustermesh-ca"

CILIUM_CA_CERT="$(base64 < /tmp/cilium-clustermesh-ca.crt | tr -d '\n')"
CILIUM_CA_KEY="$(base64 < /tmp/cilium-clustermesh-ca.key | tr -d '\n')"
```

각 클러스터에 Cilium을 설치할 때 cluster name과 id는 다르게 지정하고, CA는 같은 값을 사용합니다.

```bash
kubectl config use-context kind-cilium-east
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/12-cluster-mesh/cilium-values-east.yaml \
  --set-string tls.ca.cert="${CILIUM_CA_CERT}" \
  --set-string tls.ca.key="${CILIUM_CA_KEY}"
cilium status --wait

kubectl config use-context kind-cilium-west
helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/12-cluster-mesh/cilium-values-west.yaml \
  --set-string tls.ca.cert="${CILIUM_CA_CERT}" \
  --set-string tls.ca.key="${CILIUM_CA_KEY}"
cilium status --wait
```

두 클러스터의 CA secret이 같은지 확인합니다.

```bash
kubectl --context kind-cilium-east -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}{"\n"}' > /tmp/cilium-east-ca.txt
kubectl --context kind-cilium-west -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}{"\n"}' > /tmp/cilium-west-ca.txt
diff -u /tmp/cilium-east-ca.txt /tmp/cilium-west-ca.txt
```

출력이 없으면 두 클러스터가 같은 Cilium CA를 사용합니다. 여기서 값이 다르면 `--allow-mismatching-ca`로 우회하지 말고, Cilium 설치 전 단계로 돌아가 CA를 맞춘 뒤 다시 설치합니다. 이미 각각 다른 CA로 설치했다면 이 실습 클러스터는 삭제하고 새로 만드는 편이 가장 단순합니다.

## Cluster Mesh 연결

```bash
cilium clustermesh enable --context kind-cilium-east --service-type NodePort
cilium clustermesh enable --context kind-cilium-west --service-type NodePort
cilium clustermesh connect --context kind-cilium-east --destination-context kind-cilium-west
cilium clustermesh status --context kind-cilium-east --wait
cilium clustermesh status --context kind-cilium-west --wait
```

## Global Service 검증

```bash
kubectl --context kind-cilium-east apply -f labs/12-cluster-mesh/east-app.yaml
kubectl --context kind-cilium-west apply -f labs/12-cluster-mesh/west-app.yaml

kubectl --context kind-cilium-east -n mesh-demo get svc,pod -o wide
kubectl --context kind-cilium-west -n mesh-demo get svc,pod -o wide
```

각 클러스터의 `api` Pod는 응답 문자열을 다르게 설정합니다. global service가 정상으로 묶이면 east frontend에서 호출해도 `east-api`와 `west-api`가 모두 보이고, west frontend에서 호출해도 두 backend가 모두 보여야 합니다.

```bash
east_frontend="$(kubectl --context kind-cilium-east -n mesh-demo get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
west_frontend="$(kubectl --context kind-cilium-west -n mesh-demo get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"

kubectl --context kind-cilium-east -n mesh-demo exec "$east_frontend" -- sh -c \
  'for i in $(seq 1 20); do curl -sS http://api.mesh-demo.svc.cluster.local/; echo; done' \
  | grep -Eo '(east|west)-api' | sort | uniq -c

kubectl --context kind-cilium-west -n mesh-demo exec "$west_frontend" -- sh -c \
  'for i in $(seq 1 20); do curl -sS http://api.mesh-demo.svc.cluster.local/; echo; done' \
  | grep -Eo '(east|west)-api' | sort | uniq -c
```

두 명령 모두 `east-api`와 `west-api` 카운트를 출력하면 양방향 cross-cluster service discovery와 load balancing이 동작하는 것입니다.

## Failover 확인

로컬 backend가 사라져도 global service가 원격 클러스터 backend로 계속 응답하는지 확인합니다. 먼저 east backend를 줄이고, east frontend가 west backend만으로 응답받는지 봅니다.

```bash
kubectl --context kind-cilium-east -n mesh-demo scale deploy/api --replicas=0
kubectl --context kind-cilium-east -n mesh-demo wait --for=delete pod -l app=api,cluster=east --timeout=60s

kubectl --context kind-cilium-east -n mesh-demo exec "$east_frontend" -- sh -c \
  'for i in $(seq 1 10); do curl -m 5 -sS http://api.mesh-demo.svc.cluster.local/; echo; done' \
  | grep -Eo '(east|west)-api' | sort | uniq -c
```

결과가 `west-api`만 나오면 east 클러스터의 client가 west 클러스터 backend로 failover된 것입니다. east backend를 복구한 뒤 반대 방향도 확인합니다.

```bash
kubectl --context kind-cilium-east -n mesh-demo scale deploy/api --replicas=1
kubectl --context kind-cilium-east -n mesh-demo rollout status deploy/api --timeout=120s

kubectl --context kind-cilium-west -n mesh-demo scale deploy/api --replicas=0
kubectl --context kind-cilium-west -n mesh-demo wait --for=delete pod -l app=api,cluster=west --timeout=60s

kubectl --context kind-cilium-west -n mesh-demo exec "$west_frontend" -- sh -c \
  'for i in $(seq 1 10); do curl -m 5 -sS http://api.mesh-demo.svc.cluster.local/; echo; done' \
  | grep -Eo '(east|west)-api' | sort | uniq -c
```

결과가 `east-api`만 나오면 west 클러스터의 client도 east 클러스터 backend로 failover됩니다. 다음 실습을 위해 west backend를 복구합니다.

```bash
kubectl --context kind-cilium-west -n mesh-demo scale deploy/api --replicas=1
kubectl --context kind-cilium-west -n mesh-demo rollout status deploy/api --timeout=120s
```

## 운영 관점

- Cluster name과 cluster id는 전체 mesh에서 고유해야 합니다.
- CIDR 충돌은 연결 이후에 발견하면 복구 비용이 큽니다.
- Cluster Mesh에 참여할 클러스터의 Cilium CA는 설치 전에 정하고, 운영 비밀 저장소에서 백업과 교체 절차를 관리합니다.
- `--allow-mismatching-ca`는 이미 독립 CA로 운영 중인 클러스터를 예외적으로 연결할 때 검토하는 우회 옵션이며, 기본 운영 패턴으로 사용하지 않습니다.
- Cluster Mesh는 cross-cluster service discovery, global service load balancing, failover 경로, 멀티클러스터 identity/policy 확장을 제공합니다.
- Cluster Mesh는 물리 RTT 감소, 대역폭 병목 제거, 데이터 복제, 애플리케이션의 멀티리전 consistency 문제를 해결하지 않습니다.
- Cluster Mesh는 전체 리전 DR을 대체하지 않습니다. 외부 사용자 트래픽 전환, 데이터베이스 복제/승격, storage/queue/cache/session 처리, secret/config 동기화는 별도 DR 설계가 필요합니다.
- global service는 장애 전파 범위를 키울 수 있으므로 서비스별로 적용합니다.
- 멀티클러스터 정책은 identity, namespace, service account 모델을 먼저 표준화해야 합니다.

## 실패 시 확인

```bash
cilium clustermesh status --context kind-cilium-east
cilium clustermesh status --context kind-cilium-west
kubectl --context kind-cilium-east -n kube-system get svc,pod | grep clustermesh
kubectl --context kind-cilium-east -n kube-system logs -l k8s-app=clustermesh-apiserver --tail=200
```

## 정리

```bash
kind delete cluster --name cilium-east
kind delete cluster --name cilium-west
```

다음 장에서 BGP, Egress Gateway, encryption 같은 선택 클러스터를 만들 예정이면 이 정리를 먼저 수행합니다.

## 참고

- Cilium Cluster Mesh: https://docs.cilium.io/en/stable/network/clustermesh/
