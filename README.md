<p align="center">
  <img src="assets/icon.png" width="104" alt="Account Dock" />
</p>
<h1 align="center">Account Dock</h1>
<p align="center">macOS용 Codex 계정 관리자</p>
<p align="center">
  <a href="https://github.com/z8086486/account-dock/releases"><img alt="최신 프리뷰" src="https://img.shields.io/github/v/release/z8086486/account-dock?include_prereleases&label=preview&color=FF6B24" /></a>
  <img alt="macOS 14 이상" src="https://img.shields.io/badge/macOS-14%2B-ADD8E6" />
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple-Silicon-102A38" />
</p>
<p align="center">
  <a href="https://github.com/z8086486/account-dock/releases">다운로드</a> ·
  <a href="https://github.com/z8086486/account-dock/issues">버그 제보</a> ·
  <a href="ISOLATION.md">전용 창 안내</a>
</p>

![계정 관리](assets/accounts.png)

## 기능

- 계정 추가·이름 지정·macOS Keychain 저장
- 계정별 플랜, Codex 사용 한도와 크레딧 조회
- 여러 계정의 VS Code 전용 창과 같은 계정의 추가 창 열기
- 기존 VS Code의 테마·로컬 대화 연결
- 앱 안에서 업데이트 다운로드·설치·재실행

## 설치

**macOS 14 이상 · Apple Silicon · VS Code + 공식 Codex 확장 필요**

1. [최신 릴리즈](https://github.com/z8086486/account-dock/releases)에서 DMG를 다운로드합니다.
2. **Account Dock.app**을 Applications 폴더로 옮겨 실행합니다.
3. 첫 접근 안내를 완료하고 **계정 추가**에서 로그인합니다.

이후 **버전 · 업데이트 → 앱 업데이트**에서 새 버전을 설치할 수 있습니다.

VS Code는 `/Applications`에 설치되어 있어야 합니다. Python·Xcode는 필요하지 않습니다.

> 현재는 Apple 공증이 없는 프리뷰입니다. macOS 실행 확인과 첫 Keychain 접근 승인이 필요할 수 있습니다.

## 사용법

**계정 관리**에서 계정을 선택해 **전용 창 열기**를 누릅니다. 기존 VS Code 계정은 선택 목록에서 제외되고, 전용 창의 계정은 다시 선택해 창을 추가할 수 있습니다. 같은 로컬 대화를 여러 창에서 동시에 실행하지 마세요.

**저장한 계정**에서 이름과 사용량을 관리합니다. 이름이 없으면 이메일이 표시됩니다. ‘기본 Codex 계정’은 기본 인증 저장소의 계정을 뜻합니다.

![저장한 계정](assets/saved-accounts.png)

<sub>스크린샷의 계정과 사용량은 예시입니다.</sub>

## 지원 범위

| 대상 | 지원 |
| --- | --- |
| VS Code · Codex | 로컬 계정 조회, 계정별 전용 창, 테마·로컬 대화 연결 |
| Anthropic Claude | 지원 예정 |

사용량은 Codex 기준이며 API 결제 잔액이 아닙니다. 인증 정보는 로컬 Keychain에 저장하고, 온라인 사용량 조회는 **설정**에서 끌 수 있습니다.

<details>
<summary>소스 빌드</summary>

Swift 6 이상과 Xcode 또는 Command Line Tools가 필요합니다.

```sh
git clone https://github.com/z8086486/account-dock.git
cd account-dock
swift run AccountDock
swift test
```

패키징 방법은 [배포 가이드](RELEASING.md)를 참고하세요.

</details>
