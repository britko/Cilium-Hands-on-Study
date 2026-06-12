# 18. Mutual Auth & SPIRE

## 학습 목표

- SPIFFE/SPIRE와 Cilium mutual authentication의 역할을 이해합니다.
- network encryption, mTLS, mutual auth의 보호 계층을 구분합니다.
- beta 기능을 운영에 검토할 때 확인해야 할 항목을 정리합니다.

## 왜 별도 클러스터를 쓰는가

이 장은 전용 `cilium-mutual-auth` 클러스터에서 진행합니다. Mutual authentication은 Cilium 인증 기능과 SPIRE 구성 요소를 함께 켜므로, 15장이나 17장에서 사용한 클러스터를 재사용하면 이전 Helm values, Gateway 설정, L7 proxy 상태와 섞여 원인 분리가 어려워집니다.

이 실습에서 확인하는 것은 다음 흐름입니다.

```text
Cilium authentication 기능 활성화
  -> Cilium Helm chart가 SPIRE server/agent 설치
  -> frontend -> api 통신에 authentication: required 정책 적용
  -> 허용된 identity와 HTTP path만 통과하는지 확인
```

## 사전 조건

Cilium mutual authentication은 beta 기능이므로 버전과 기능 상태를 반드시 확인합니다. kind/local 랩에서는 SPIRE server의 persistent storage 대신 in-memory storage를 사용합니다. 클러스터를 삭제하거나 SPIRE server Pod가 재생성되면 SPIRE 데이터도 사라지는 랩 전용 설정입니다.

macOS/Linux Bash:

```bash
bash scripts/create-kind-cluster.sh \
  --cluster-name cilium-mutual-auth \
  --config labs/kind/kind-cilium-mutual-auth.yaml

kubectl config use-context kind-cilium-mutual-auth

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.19.3 \
  --namespace kube-system \
  --values labs/18-mutual-auth-spire/cilium-values.yaml

cilium status --wait
```

핵심 Helm values:

```yaml
authentication:
  enabled: true
  mutual:
    spire:
      enabled: true
      install:
        enabled: true
        server:
          dataStorage:
            enabled: false
```

- `authentication.enabled=true`: Cilium authentication framework를 켭니다.
- `authentication.mutual.spire.enabled=true`: SPIRE 기반 mutual authentication 연동을 켭니다.
- `authentication.mutual.spire.install.enabled=true`: Cilium Helm chart가 SPIRE server/agent를 함께 설치하게 합니다.
- `dataStorage.enabled=false`: kind 랩에서 PVC 의존성을 피하기 위해 SPIRE server 데이터를 in-memory로 둡니다.

## 개념

Mutual authentication을 이해하려면 먼저 "암호화", "인증", "인가"를 분리해야 합니다.

| 구분 | 질문 | 예시 |
|---|---|---|
| 암호화 | 중간 네트워크에서 내용을 볼 수 없게 하는가 | WireGuard/IPsec transparent encryption, TLS |
| 인증 | 상대가 주장하는 identity가 맞는가 | SPIFFE/SPIRE, mTLS certificate 검증 |
| 인가 | 인증된 상대가 이 요청을 해도 되는가 | NetworkPolicy, CiliumNetworkPolicy, HTTP method/path rule |

Transparent encryption은 노드 간 또는 Pod traffic의 네트워크 구간을 암호화합니다. 네트워크 중간에서 payload를 보기 어렵게 만드는 것이 목적입니다. 하지만 "이 요청을 보낸 workload가 정말 frontend인가"를 애플리케이션 identity 관점에서 검증하는 기능은 아닙니다.

NetworkPolicy와 CiliumNetworkPolicy는 인가 정책입니다. 예를 들어 `app=frontend`가 `app=api`의 TCP 8080과 `GET /get`만 호출할 수 있다고 정의합니다. 이 정책은 label, identity, port, L7 rule로 허용 범위를 정합니다.

Mutual authentication은 여기에 "허용된 상대가 맞는지 인증도 요구하라"는 조건을 더합니다. 이 장의 정책에는 다음 설정이 들어 있습니다.

```yaml
authentication:
  mode: required
```

이 설정은 `frontend -> api` ingress 경로에서 Cilium이 workload identity 인증을 요구하게 합니다. 즉 "frontend label이 붙은 endpoint에서 온 것처럼 보인다"에서 끝내지 않고, Cilium authentication framework를 통해 상대 identity를 확인하는 단계를 추가합니다.

### SPIFFE와 SPIRE

SPIFFE는 workload identity를 표현하는 표준입니다. 대표 형식은 다음과 같은 URI입니다.

```text
spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>
```

SPIRE는 SPIFFE identity를 발급하고 검증하는 구현체입니다. 운영 관점에서는 SPIRE가 workload identity CA와 registration/attestation 시스템 역할을 합니다.

이 장의 kind 실습에서 Cilium Helm chart는 SPIRE 구성 요소를 함께 설치합니다.

- SPIRE server: trust domain과 identity 발급의 중심 역할
- SPIRE agent: 각 node에서 workload attestation과 SVID 전달을 담당
- Cilium agent/operator: SPIRE와 연동해 Cilium authentication handshake에 필요한 identity 정보를 사용

### Cilium mutual authentication 경로

Cilium mutual authentication은 애플리케이션 container 안에 mTLS sidecar를 넣는 방식이 아닙니다. 애플리케이션 코드는 그대로 HTTP를 호출합니다. Cilium datapath와 agent가 정책에서 `authentication.mode: required`인 flow를 만나면, 해당 source/destination identity에 대해 authentication 상태를 확인하고 필요한 handshake를 수행합니다.

개념 흐름은 다음과 같습니다.

```text
frontend Pod
  -> api Service / api Pod
  -> Cilium policy lookup
  -> ingress rule matches fromEndpoints app=frontend
  -> authentication.mode: required
  -> Cilium/SPIRE 기반 workload identity 인증 확인
  -> L7 rule GET /get 확인
  -> api Pod로 전달
```

따라서 이 장의 실습에서 `curl http://api/get` 응답은 평소처럼 HTTP 응답입니다. 성공했다는 것은 다음 조건이 모두 맞았다는 뜻입니다.

- source endpoint가 `app=frontend`로 식별됨
- destination endpoint가 `app=api`로 식별됨
- mutual authentication 요구 조건을 만족함
- HTTP rule `GET /get`에 맞음

반대로 `POST /post`나 `/status/418` 실패는 mutual auth가 실패했다는 뜻이 아닐 수 있습니다. 이 실습 정책은 L7 rule이 `GET /get`만 허용하므로, 인증과 별개로 HTTP rule에서 차단될 수 있습니다.

### mTLS/service mesh와의 차이

Istio 같은 service mesh mTLS는 보통 sidecar 또는 ambient datapath에서 service-to-service mTLS, traffic management, retries, telemetry를 함께 제공합니다. Cilium mutual authentication은 Cilium policy와 datapath에 workload identity 인증을 결합하는 기능입니다.

| 항목 | Cilium mutual authentication | Service mesh mTLS |
|---|---|---|
| 주된 제어면 | Cilium policy/authentication | mesh control plane |
| 애플리케이션 변경 | 보통 없음 | 보통 없음, 단 proxy/mesh 가입 필요 |
| 라우팅/traffic management | Gateway API, Cilium/Envoy 기능과 조합 | mesh 기능으로 폭넓게 제공 |
| 정책 단위 | Cilium identity, endpoint, L3/L4/L7 rule | service/workload identity, route policy |
| 운영 포인트 | Cilium agent, SPIRE, CNP | mesh control plane, proxy, CA |

핵심은 기능 선택입니다. 이미 Cilium policy 중심으로 보안 경계를 설계하고 있고, workload identity 인증을 추가하고 싶다면 Cilium mutual authentication을 검토할 수 있습니다. 반대로 retries, circuit breaking, per-route telemetry, service mesh 전반의 traffic management가 필요하면 별도 service mesh 모델까지 비교해야 합니다.

## 실전 사례

Mutual authentication은 모든 서비스에 무조건 켜는 기능이라기보다, "label 기반 정책만으로는 부족하고 호출 주체의 workload identity까지 확인해야 하는 경계"에 적용하는 기능입니다.

### 사례 1: 결제 API 보호

결제 namespace에 `payment-api`가 있고, 주문 서비스만 결제 승인 endpoint를 호출해야 한다고 가정합니다.

기본 NetworkPolicy/CiliumNetworkPolicy만 사용하면 다음을 표현할 수 있습니다.

- `app=checkout`에서 `app=payment-api`의 TCP 8080으로 접근 허용
- HTTP `POST /authorize`만 허용
- 그 외 namespace와 workload는 차단

여기에 mutual authentication을 더하면 "허용된 label을 가진 endpoint에서 온 트래픽"을 넘어서, Cilium authentication framework가 확인한 workload identity에 대해서만 정책을 통과시킬 수 있습니다. 운영에서는 결제 승인, 포인트 차감, 정산 요청처럼 잘못된 호출 주체가 접근하면 금전 영향이 생기는 경계에 우선 적용하는 식으로 범위를 좁힙니다.

도입 시 같이 확인할 항목:

- 결제 호출 경로의 source/destination identity가 안정적인가
- 배포 중 label 또는 service account 변경으로 identity가 바뀌는가
- 인증 실패가 사용자 결제 실패로 보일 때 어떤 alert와 rollback을 쓸 것인가

### 사례 2: 공용 namespace 안의 민감 backend 분리

한 namespace 안에 여러 팀 workload가 있고, 공용 `internal-api` 중 일부 endpoint만 특정 batch job이 호출해야 하는 상황이 있습니다. namespace 단위 isolation만으로는 부족하고, Pod label만으로 운영자가 호출 주체를 신뢰하기도 애매할 수 있습니다.

이때 Cilium policy는 다음처럼 계층화할 수 있습니다.

- namespace baseline: 기본 deny와 DNS egress만 허용
- service policy: `batch-worker -> internal-api`의 특정 port/path만 허용
- mutual auth: 해당 ingress rule에 `authentication.mode: required` 적용

이 모델의 장점은 애플리케이션에 sidecar를 붙이지 않고도 Cilium policy 경계 안에서 "누가 호출했는지 확인"하는 단계를 추가할 수 있다는 점입니다. 다만 batch job이 짧게 생성/삭제되는 구조라면 SPIRE registration, Cilium endpoint identity 갱신, 인증 상태 전파가 실제 배포 패턴과 맞는지 staging에서 먼저 봐야 합니다.

### 사례 3: 서비스 mesh를 전면 도입하기 전의 제한적 mTLS 요구

조직에 이미 Cilium NetworkPolicy 운영 체계가 있고, 전체 service mesh를 도입하기에는 비용이 큰 경우가 있습니다. 예를 들어 대부분의 서비스는 L3/L4/L7 policy와 Hubble 관측으로 충분하지만, 몇 개의 내부 관리 API만 workload identity 인증을 추가로 요구할 수 있습니다.

이 경우 Cilium mutual authentication은 제한된 경계에 인증을 추가하는 후보가 됩니다. 반대로 다음 요구가 핵심이면 service mesh를 별도로 검토하는 편이 낫습니다.

- service-to-service retry, timeout, circuit breaking을 중앙에서 관리
- per-route traffic shifting과 fault injection이 필요
- 애플리케이션 팀이 mesh telemetry와 route policy를 직접 운영
- 클러스터 밖 workload까지 같은 mesh identity 모델로 묶어야 함

## 운영 설계 예시

실제 정책 PR에는 "mutual auth를 켰다"보다 어떤 통신 경계를 보호하는지가 먼저 보여야 합니다.

예시 PR 설명:

```text
대상: app/frontend -> app/api
목적: 조회 API GET /get만 허용하고, 호출 주체 workload identity 인증을 요구
정책: CiliumNetworkPolicy frontend-to-api-mutual-auth
허용 조건: source app=frontend, destination app=api, TCP 8080, HTTP GET /get, authentication required
검증: /get 성공, /post 실패, cilium status 정상, SPIRE server/agent Running
rollback: kubectl delete -f labs/18-mutual-auth-spire/mutual-auth-policy.yaml
```

운영 검증 루틴:

```bash
kubectl -n app get cnp frontend-to-api-mutual-auth -o yaml
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
kubectl -n app exec "$frontend_pod" -- curl -m 5 -X POST -sS http://api/post
kubectl -n cilium-spire get pods -o wide
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i auth
```

통과 기준:

- 허용된 method/path만 성공합니다.
- 인증 기능과 SPIRE 구성 요소가 Ready 상태입니다.
- 실패한 요청이 애플리케이션 오류인지, L7 policy 차단인지, authentication 문제인지 분리할 수 있습니다.

## SPIRE 상태 확인

SPIRE 구성 요소가 올라왔는지 확인합니다.

```bash
kubectl get ns cilium-spire
kubectl -n cilium-spire get pods -o wide
kubectl -n kube-system logs deploy/cilium-operator --tail=100 | grep -i spire
```

통과 기준:

- `cilium-spire` namespace가 존재합니다.
- SPIRE server와 SPIRE agent Pod가 Running 상태입니다.
- `cilium status --wait`가 성공합니다.

## 실습 흐름

샘플 앱을 배포합니다.

```bash
kubectl apply -f labs/02-ebpf-datapath/bookinfo-lite.yaml
kubectl -n app rollout status deploy/frontend --timeout=120s
kubectl -n app rollout status deploy/api --timeout=120s
```

정책 적용 전 기본 통신을 확인합니다.

```bash
frontend_pod="$(kubectl -n app get pod -l app=frontend -o jsonpath='{.items[0].metadata.name}')"
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
```

인증이 필요한 CiliumNetworkPolicy를 적용합니다.

```bash
kubectl apply -f labs/18-mutual-auth-spire/mutual-auth-policy.yaml
kubectl -n app get cnp frontend-to-api-mutual-auth
```

정책 적용 후 허용된 요청을 확인합니다.

```bash
kubectl -n app exec "$frontend_pod" -- curl -sS http://api/get
```

기대 결과:

- `GET /get`은 성공합니다.
- 이 통신은 `frontend` identity에서 `api` endpoint로 들어오며, policy의 `authentication.mode: required` 조건을 만족해야 합니다.

허용하지 않은 HTTP path나 method는 차단되는지 확인합니다.

```bash
kubectl -n app exec "$frontend_pod" -- curl -m 5 -sS http://api/status/418
kubectl -n app exec "$frontend_pod" -- curl -m 5 -X POST -sS http://api/post
```

기대 결과:

- 위 요청은 timeout, access denied, reset 등 실패 형태로 보여야 합니다.
- 실패 원인은 mutual auth 자체라기보다 CiliumNetworkPolicy의 L7 HTTP rule이 `GET /get`만 허용하기 때문입니다.

## 결과 해석

이 실습에서 중요한 것은 "SPIRE Pod가 떴다"에서 끝내지 않는 것입니다.

- SPIRE server/agent가 Running입니다.
- Cilium authentication 기능이 켜진 상태에서 Cilium agent가 Ready입니다.
- `authentication.mode: required`가 들어간 CiliumNetworkPolicy가 적용됩니다.
- 허용된 identity와 HTTP path는 성공하고, 허용하지 않은 path/method는 실패합니다.

Mutual authentication은 NetworkPolicy를 대체하지 않습니다. 정책으로 허용 범위를 정하고, mutual auth로 workload identity 인증을 추가한다고 보는 것이 정확합니다.

## 운영 관점

- mutual auth 적용 대상은 결제, 정산, 관리 API처럼 identity 인증 가치가 큰 경계부터 좁게 잡습니다.
- CA, trust domain, SPIRE server persistence, backup 전략이 필요합니다.
- kind 랩의 `dataStorage.enabled=false`는 운영 설정이 아닙니다. 운영에서는 SPIRE server 데이터 영속성과 복구 절차를 설계해야 합니다.
- 인증 실패 시 애플리케이션 장애처럼 보일 수 있으므로 Hubble과 Cilium logs를 함께 봅니다.
- Istio mTLS와 비교할 때 traffic management와 telemetry 범위가 다릅니다.
- beta 기능은 upgrade compatibility와 rollback 절차를 별도로 검증합니다.

## 실패 시 확인

```bash
cilium status
kubectl -n cilium-spire get pods -o wide
kubectl -n cilium-spire logs -l app.kubernetes.io/name=spire-server --tail=200
kubectl -n kube-system logs ds/cilium --tail=200 | grep -i auth
kubectl -n kube-system logs deploy/cilium-operator --tail=200 | grep -i spire
kubectl -n app describe cnp frontend-to-api-mutual-auth
```

문제 분리 기준:

- SPIRE Pod가 없으면 Helm values의 `authentication.mutual.spire.install.enabled`를 확인합니다.
- SPIRE server가 Pending이면 storage/PVC 문제를 확인합니다. kind 랩에서는 `dataStorage.enabled=false`를 사용합니다.
- Cilium은 Ready인데 `/get`만 실패하면 CiliumNetworkPolicy, endpoint label, L7 proxy 상태를 확인합니다.
- `/get`은 성공하고 다른 path/method만 실패하면 정책이 의도대로 동작한 것입니다.

## 참고

- Cilium Mutual Authentication: https://docs.cilium.io/en/stable/network/servicemesh/mutual-authentication/mutual-authentication/

## 정리

```bash
kubectl delete -f labs/18-mutual-auth-spire/mutual-auth-policy.yaml --ignore-not-found
kubectl delete -f labs/02-ebpf-datapath/bookinfo-lite.yaml --ignore-not-found
kind delete cluster --name cilium-mutual-auth
```
