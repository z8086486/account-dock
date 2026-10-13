# Account Dock 배포와 버전 관리

현재는 개발 프리뷰입니다. GitHub에는 소스 코드를 공개하며, 일반 사용자용 DMG/APP 릴리즈는 인증 연동과 배포 경로를 검증한 뒤 공개합니다. macOS 앱 바이너리는 GitHub Releases로 배포하고, GitHub Packages는 사용하지 않습니다.

정식 배포 전 완료 조건은 [RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)를 확인하세요.

## 버전의 기준

`Sources/AccountDock/Resources/release.json`을 버전 정보의 원본으로 사용합니다.

- `version`: Account Dock의 SemVer 버전. 현재 `0.6.0`.
- `build`: 배포 후보마다 증가하는 정수. Sparkle의 업데이트 비교에 사용하는 `CFBundleVersion`으로 전달됩니다. 같은 빌드 번호를 재사용하지 않습니다.
- `channel`: 현재 `preview`. 공개 안정판은 출시 검증 후 변경합니다.
- `minimumMacOS`: 지원 macOS 하한.
- `compatibility`: 서비스별 확인한 버전과 검증 범위. 단순 설치 감지를 인증 기능 전체 검증으로 표시하지 않습니다.

ChatGPT와 Codex는 자체 버전 체계를 유지합니다. 설치 버전이 호환 목록에 없으면 ‘재확인 필요’로 표시합니다. 버전 번호만 같다고 전체 기능이 호환된다고 보장하지 않습니다. VS Code 확장 정보는 기본 로컬 설치 인덱스를 기준으로 하며, 원격 SSH·WSL·별도 프로필 및 실행 중인 확장 버전은 별도 검증 대상입니다.

연동 대상이 업데이트되면 다음 순서로 대응합니다.

1. 기존 버전과 새 버전에서 조회, 로그인, 로그아웃, 취소 및 저장한 계정 복원을 검증합니다.
2. API·인증 저장소 변경이 있으면 해당 연동 코드를 수정합니다.
3. 실제로 통과한 기능 범위만 `compatibility`에 기록하고 테스트를 보강합니다.
4. Account Dock 버전과 빌드 번호를 올리고 새 릴리즈를 준비합니다.

## 로컬 APP / DMG 만들기

Swift 6 이상, Python 3 및 macOS 패키징 도구가 필요합니다.

```sh
swift test
python3 -m unittest discover -s tests -v
python3 scripts/package_app.py --dmg
```

출력은 `dist/<version>-<architecture>/`에 생성됩니다.

- `Account Dock.app`
- `AccountDock-<version>-<architecture>-preview.zip`
- `AccountDock-<version>-<architecture>-preview.dmg`
- `SHA256SUMS`

앱에는 Sparkle 프레임워크와 설정 리소스만 포함합니다. 사용자 계정, 인증 파일, 저장한 계정, 작업 기록은 포함하지 않습니다. 빌드한 Mac의 아키텍처용으로 생성하며 현재 universal 배포가 아닙니다.

프리뷰는 로컬 실행을 위한 ad-hoc 서명입니다. Developer ID 서명·공증을 받은 정식 배포본이 아니며, 앱 자체 업데이트도 비활성화됩니다. **0.6.0부터 실행 대상 Mac에는 Python이 필요하지 않습니다.** 공식 ChatGPT 앱 또는 Codex 확장에 포함된 실행 파일은 필요합니다. Python·Xcode 없는 깨끗한 Mac 설치는 별도 검증해야 합니다.

동일한 버전의 출력 폴더가 이미 있으면 덮어쓰지 않고 중단합니다. 이전 산출물을 다른 위치로 보관한 뒤 다시 빌드하세요.

## GitHub Actions

Actions의 **Build macOS preview**를 수동 실행하면 테스트 후 ZIP/DMG와 해시를 Actions Artifact로 보관합니다. 자동 태그, GitHub Release 생성 또는 공개는 수행하지 않습니다. 소스의 `.github/workflows/preview.yml`이 이 동작을 정의합니다. 호스팅 러너에서의 최초 실행은 별도 검증해야 합니다.

## 서명된 앱과 자체 업데이트

Account Dock에는 Sparkle 2.10.0이 연결되어 있습니다. 앱 번들에 HTTPS 피드 주소와 올바른 Ed25519 공개 키가 포함된 빌드에서만 업데이트 컨트롤러를 시작합니다. 현재 프리뷰에는 이 키가 없으므로 앱 내 설치 버튼이 비활성화됩니다.

정식 배포 전에 준비할 항목:

- Apple Developer ID Application 인증서와 서명용 Keychain
- `notarytool`에서 사용할 공증 자격 증명 프로필
- Sparkle `generate_keys`로 만든 Ed25519 서명 키. 개인 키는 Keychain에 유지하고 공개 키만 앱에 포함합니다.
- 깨끗한 Mac 설치 및 실제 두 계정 전환 검증

키를 준비한 뒤의 빌드 명령 형태:

```sh
python3 scripts/package_app.py --dmg \
  --signing-identity 'Developer ID Application: Your Name (TEAMID)' \
  --notary-profile 'account-dock-notary' \
  --sparkle-public-key 'YOUR_BASE64_PUBLIC_KEY'
```

위 세 옵션은 함께 제공해야 합니다. 스크립트는 서명, 공증 요청, 티켓 첨부를 수행한 뒤 ZIP/DMG를 생성합니다. 이 경로는 실제 배포 자격 증명으로 검증해야 하며, 현재 확인한 것은 로컬 프리뷰 패키징 경로입니다.

Sparkle 피드 주소는 다음으로 고정합니다.

```text
https://github.com/z8086486/account-dock/releases/latest/download/appcast.xml
```

릴리즈 준비 순서:

1. 서명·공증된 산출물만 별도 업데이트 폴더에 복사합니다.
2. Sparkle `generate_appcast`로 아카이브의 Ed25519 서명과 `appcast.xml`을 생성합니다. 다운로드 URL은 해당 `v<version>` 태그의 고정된 GitHub Release asset URL을 사용합니다.
3. GitHub에 **Draft Release**를 만들고 서명된 ZIP/DMG, `SHA256SUMS`, `appcast.xml`을 첨부합니다. 앱 바이너리를 Git 소스 이력에 커밋하지 않습니다.
4. 이전 버전 → 새 버전의 다운로드, 서명 검증, 설치, 재실행, Keychain 저장한 계정 유지 및 실패 복구를 검증합니다.
5. 확인이 끝난 뒤 안정 릴리즈로 공개합니다. `releases/latest`는 안정 릴리즈 경로이므로 prerelease와 혼용하지 않습니다. 프리뷰 자동 배포가 필요해지면 별도 피드를 만듭니다.

현재 자동 다운로드·자동 설치는 기본으로 켜지 않습니다. 사용자가 앱 안에서 업데이트를 확인하고 설치하는 흐름부터 제공합니다. Sparkle가 다운로드 및 서명 검증·앱 교체를 담당합니다. 최초 서명 배포본과 후속 배포본 사이의 실제 업데이트는 아직 검증하지 않았습니다.

## 외부 앱 업데이트

- Codex: 공식 Marketplace의 안정 버전을 조회하고, 업데이트 버튼을 누르면 버전을 다시 확인한 후 VS Code 공식 CLI로 `openai.chatgpt@<version>`만 설치합니다. 설치 후 버전을 재조회합니다. 원격 환경이나 다른 확장을 업데이트하지 않습니다.
- ChatGPT: 설치된 앱의 버전을 표시하고 현재 앱 번들에서 확인한 공식 업데이트 피드를 조회합니다. 접근 제한이나 응답 형식 변경은 ‘확인할 수 없음’으로 표시합니다. 설치는 공식 ChatGPT 앱의 업데이트 기능 또는 공식 다운로드 경로에서 진행합니다. Account Dock이 ChatGPT 앱 번들을 교체하지 않습니다.
- Account Dock: GitHub Releases의 최신 안정판을 조회합니다. 첫 릴리즈 전의 404는 ‘첫 릴리즈 준비 중’으로 표시합니다.

버전 조회에는 계정 이메일·토큰을 전송하지 않습니다. 계정별 사용량 조회는 별개로 OpenAI 인증을 사용합니다. 버전 확인을 위한 GitHub, OpenAI 업데이트 서버, VS Code Marketplace 요청만 사용합니다.

## 참고

- [Sparkle 배포 및 업데이트 문서](https://sparkle-project.org/documentation/)
- [VS Code 공식 CLI](https://code.visualstudio.com/docs/configure/command-line)

## 로컬 설치 하나만 유지

```sh
python3 scripts/package_app.py --dmg --install
```

`~/Applications/Account Dock.app`을 고정 경로로 사용합니다. 새 번들의 서명을 검증하고 기존 Account Dock 프로세스만 종료한 뒤 앱을 교체합니다. 교체 검증이 실패하면 이전 설치를 복원합니다. 이전 빌드보다 낮은 빌드는 설치하지 않습니다. 확인된 `/Applications/Account Dock.app`과 이 프로젝트 `.local/`, `dist/`의 과거 앱 번들은 정리하고 ZIP/DMG는 유지합니다. 로그인 파일, Keychain, 앱 설정은 삭제하지 않습니다. 임의로 복사한 다른 경로까지 검색·삭제하지는 않습니다.

## 서명 준비 확인

```sh
python3 scripts/release_preflight.py --app "$HOME/Applications/Account Dock.app"
```

인증서 이름이나 인증 토큰을 출력하지 않고 Developer ID 존재 여부, 실제 서명, Gatekeeper, 공증 티켓과 업데이트 설정을 검사합니다. 성공하더라도 실제 두 계정·깨끗한 Mac·업데이트 검증을 대신하지 않습니다.

유효한 인증서가 없다는 결과만으로 Developer Program 미가입이라고 판단할 수 없습니다. [Apple Developer 계정](https://developer.apple.com/account/)에 로그인해 Membership details에서 가입 상태와 팀을 확인한 후 [Developer ID 인증서 안내](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)에 따라 준비합니다. 비밀번호·인증서 개인 키는 소스나 작업 기록에 남기지 않습니다.
