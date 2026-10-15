<p align="center">
  <img src="assets/icon.png" width="104" alt="Account Dock" />
</p>
<h1 align="center">Account Dock</h1>
<p align="center"><strong>Codex 계정별로 VS Code를 열고, 사용량을 확인하는 macOS 앱</strong></p>
<p align="center">
  <a href="https://github.com/z8086486/account-dock/releases"><img alt="최신 버전" src="https://img.shields.io/github/v/release/z8086486/account-dock?label=release&amp;color=FF6B24&amp;cacheSeconds=300&amp;v=1" /></a>
  <img alt="macOS 14 이상" src="https://img.shields.io/badge/macOS-14%2B-ADD8E6" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple-Silicon-102A38" />
</p>
<p align="center">
  <a href="https://github.com/z8086486/account-dock/releases">다운로드</a> ·
  <a href="https://github.com/z8086486/account-dock/issues">버그 제보</a> ·
  <a href="ISOLATION.md">계정별 VS Code 안내</a>
</p>

개인 계정과 업무 계정처럼 **여러 Codex 계정을 함께 사용할 때** 계정별 로그인과 창을 관리합니다. 기존 VS Code는 그대로 두고, 등록한 다른 계정으로 별도의 VS Code를 열어 동시에 작업할 수 있습니다.

- **계정별 VS Code** — 저장한 계정을 선택해 실행하고, 같은 계정으로 창을 추가합니다. 기존 테마와 로컬 대화도 연결합니다.
- **사용 한도·크레딧** — 계정별 플랜과 남은 한도, 제공되는 크레딧 잔액을 확인합니다.
- **메뉴 막대 활동** — Codex 작업 중에는 휠이 회전합니다. 클릭하면 계정별 작업 상태와 로컬 토큰 사용 기록을 확인할 수 있습니다.

![계정 관리](assets/accounts.png)

계정은 macOS Keychain에 보관합니다. 로그인 시 자동 실행과 앱 내 업데이트를 지원합니다.

## 설치

**macOS 14 이상 · Apple Silicon · VS Code + 공식 Codex 확장 필요**

1. [최신 릴리즈](https://github.com/z8086486/account-dock/releases)에서 DMG를 다운로드합니다.
2. **Account Dock.app**을 Applications 폴더로 옮겨 실행합니다.
3. 첫 접근 안내를 완료하고 **계정 추가**에서 로그인합니다.

이후 **버전 · 업데이트 → 앱 업데이트**에서 새 버전을 설치할 수 있습니다.

VS Code는 `/Applications`에 설치되어 있어야 합니다. Python·Xcode는 필요하지 않습니다.

> Apple Developer ID 서명·공증은 적용하지 않았습니다. macOS 실행 확인과 첫 Keychain 접근 승인이 필요할 수 있습니다.

## 사용법

**계정 관리**에서 계정을 선택해 **새 창 열기**를 누릅니다. 기존 VS Code 계정은 선택 목록에서 제외되고, 계정별 VS Code에 연결된 계정은 다시 선택해 창을 추가할 수 있습니다. 계정별 VS Code 옆의 **모든 창 닫기**로 해당 인스턴스의 모든 창을 닫을 수 있습니다. 기본 VS Code는 종료하지 않습니다. 같은 로컬 대화를 여러 창에서 동시에 실행하지 마세요.

**저장한 계정**에서 이름과 사용량을 관리합니다. 이름이 없으면 이메일이 표시됩니다. ‘기본 Codex 계정’은 기본 인증 저장소의 계정을 뜻합니다.

**메뉴 막대**의 휠은 Codex 작업을 감지하면 회전합니다. 클릭하면 오늘·누적 토큰과 계정별 남은 한도를 볼 수 있습니다. **활동 기록 · API 환산**을 펼치면 잔디밭과 비용 추정액이 표시됩니다. 새로고침 버튼으로 바로 조회할 수 있으며, 패널의 휠을 누르면 메인 창이 열립니다.

<p align="center"><img src="assets/wheel-animation.gif" width="280" alt="Codex 작업 중 회전하는 휠" /></p>

<p align="center"><img src="assets/activity.png" width="370" alt="Codex 활동 패널" /></p>

### 사용량 안내

- 메뉴바의 토큰은 **이 Mac에 기록된 Codex 사용량**입니다. 저장한 계정의 사용량·한도는 Codex가 제공하는 조회 값이며, OpenAI API 청구 내역이 아닙니다.
- **API 단가 환산**은 모델과 토큰 세부 내역이 확인된 기록만 계산한 추정액입니다. 실제 청구액과 다르며, 적용 단가·환율과 환산 범위는 패널에서 확인할 수 있습니다.
- 로컬 기록으로 활동을 파악하므로 표시가 늦거나 일부 기록이 누락될 수 있습니다. 다른 계정으로 이어서 진행한 과거 대화는 실제 계정별 사용량과 차이가 날 수 있습니다.


![저장한 계정](assets/saved-accounts.png)

<sub>예시 데이터를 사용한 앱 화면과 휠 회전 예시입니다.</sub>

## 지원 범위

| 대상 | 지원 |
| --- | --- |
| VS Code · Codex | 로컬 계정 조회, 계정별 VS Code, 테마·로컬 대화 연결 |
| Anthropic Claude | 지원 예정 |

사용량은 Codex 기준이며 API 결제 잔액이 아닙니다. 인증 정보는 로컬 Keychain에 저장하고, 온라인 사용량 조회는 **설정**에서 끌 수 있습니다.

<details>
<summary>소스 빌드</summary>

macOS 26 SDK를 포함한 Xcode 26 이상 또는 해당 Command Line Tools가 필요합니다. 빌드한 앱은 macOS 14 이상에서 실행됩니다.

```sh
git clone https://github.com/z8086486/account-dock.git
cd account-dock
swift run AccountDock
swift test
```

패키징 방법은 [배포 가이드](RELEASING.md)를 참고하세요.

</details>
