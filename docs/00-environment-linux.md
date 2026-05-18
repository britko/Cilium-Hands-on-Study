# Linux 환경 준비

Linux에서는 Docker Engine을 기본 런타임으로 권장합니다. Ubuntu 기준 예시는 아래와 같습니다.

## Docker Engine 설치

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"
```

`usermod`는 현재 사용자를 `docker` 그룹에 추가합니다. 이 설정은 새 로그인 세션부터 반영되므로, 가장 단순한 방법은 터미널을 완전히 닫고 새로 여는 것입니다.

터미널을 다시 열지 않고 지금 세션에 바로 반영하려면 다음 명령을 실행합니다.

```bash
newgrp docker
```

Docker daemon이 실행 중인지 확인하고, 필요하면 시작합니다.

```bash
sudo systemctl start docker
```

systemd가 없는 환경이라면 다음을 사용합니다.

```bash
sudo service docker start
```

이후 현재 사용자가 Docker API에 접근할 수 있는지 확인합니다.

```bash
id -nG
docker version
docker ps
```

`id -nG` 출력에 `docker`가 포함되어야 합니다. `docker ps`에서 `/var/run/docker.sock` 권한 오류가 나면 `newgrp docker`를 실행하거나 터미널을 새로 엽니다.

## 필수 도구

`create-kind-cluster.sh`는 `kind`, `kubectl` CLI가 없을 때 프로젝트 로컬 `tools/bin`에 자동 설치합니다.

`helm`, `cilium`, `hubble` CLI는 [01. Cilium 설치](01-cilium-install.md)에서 수동으로 설치합니다. Cilium 설치 이후 실습도 문서의 명령을 직접 실행하면서 진행합니다.

새 터미널에서 `kubectl` alias와 completion을 쓰려면 `~/.bashrc`에 로컬 도구 설정을 추가합니다.

```bash
bash scripts/use-local-tools.sh --install-bashrc
source ~/.bashrc
```

## 실습 시작

kind 클러스터만 스크립트로 생성합니다.

```bash
bash scripts/create-kind-cluster.sh
```

이후 [01. Cilium 설치](01-cilium-install.md)부터는 Helm과 Cilium CLI 명령을 직접 실행하면서 진행합니다.
