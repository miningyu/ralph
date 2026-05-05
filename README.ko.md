# simple-ralph

[English](./README.md)

**하나의 프롬프트를 여러 개의 task로 자동 분리하고, 각 task를 plan → build → QA 루프로 완성하는 자율 빌드 에이전트.**

```
ralph run
  │
  ├─ Phase 1 (plan)   — 프롬프트를 분석해 task로 분리
  │                     "JWT 인증 추가, refresh token 포함"
  │                     → [T-001] JWT 전략  [T-002] refresh 엔드포인트  [T-003] 가드 ...
  │
  ├─ Phase 2 (build)  — task 하나씩 구현 (build_pass:true까지 반복)
  │
  └─ Phase 3 (qa)     — 독립 평가 에이전트가 각 task 검증 (qa_pass:true까지 반복)
               └─ 실패 시 → 실패 원인 전체를 다음 build iteration에 주입
```

> **Builder**(Opus)가 구현하고, **Evaluator**(Sonnet)가 독립적으로 검증한다.
> QA 실패 시 단순 증상 수정이 아닌 근본 원인을 context로 주입해 재구현한다.

---

## Requirements

- [Claude Code CLI](https://claude.ai/code) (`claude`)
- `bash`, `jq`, `curl`, `git`

## 설치

```bash
git clone https://github.com/miningyu/simple-ralph ~/.ralph
~/.ralph/install.sh
```

필요하면 shell profile에 추가:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 빠른 시작

```bash
cd your-project

ralph init                                   # ralph/ralph-config.json 생성
# ralph/ralph-config.json 수정

echo "JWT 인증 추가, refresh token 포함" >> ralph/tasks.raw.md
ralph run                                    # task 분리 후 루프 시작
```

개별 phase 실행:
```bash
ralph plan    # phase 1: tasks.raw.md → tasks.json 분리
ralph build   # phase 2: 구현
ralph qa      # phase 3: 검증
ralph reset   # 현재 사이클 archive 후 초기화
```

## 동작 방식

**Phase 1 — Plan**: `tasks.raw.md`의 자유형식 요구사항을 읽고, 구현 단위로 `tasks.json`에 task를 생성한다. 각 task는 scope, 수락 기준(acceptance criteria), 의존관계를 포함한다.

**Phase 2 — Build**: `build_pass:false`인 task를 하나 골라 구현한다. lint → typecheck → test → 런타임 스모크 테스트까지 통과해야 `build_pass:true`로 마킹하고 커밋한다.

**Phase 3 — QA**: Builder와 독립된 Evaluator가 각 task의 수락 기준을 검증한다. 버그 발견 시 `qa-report.json`에 상세 리포트를 기록하고, 다음 build iteration에 실패 원인 전체를 context로 주입한다.

QA에서 회귀가 발견되면 `build_pass`가 초기화되고, 모든 task가 `build_pass:true`와 `qa_pass:true`에 도달할 때까지 사이클이 반복된다.

## 설정

`ralph init`이 템플릿에서 `ralph/ralph-config.json`을 생성한다. 주요 필드:

| 필드 | 설명 |
|------|------|
| `projectName` | 로그 메시지에 사용 |
| `workspaces.apps[]` | 앱 목록 (name, path, kind, 테스트 여부) |
| `workspaces.packages[]` | 공유 라이브러리 목록 |
| `commands.*` | build/lint/test/typecheck 명령어 (`{scope}` 치환) |
| `builder.command` | Build 에이전트 Claude 명령어 (Opus 권장) |
| `evaluator.command` | QA 에이전트 Claude 명령어 (Sonnet 권장) |
| `runtime.backend` | 백엔드 포트, 헬스체크 경로, dev 명령어 |
| `runtime.frontend` | 프론트엔드 dev 명령어, preview URL |
| `guardrails[]` | 모든 에이전트 프롬프트에 주입되는 제약 규칙 |

전체 예시: `templates/ralph-config.example.json`

## 프로젝트 상태 파일

`ralph init` 후 프로젝트에 생기는 `ralph/` 디렉토리:

| 파일 | 설명 |
|------|------|
| `ralph/ralph-config.json` | 프로젝트 설정 (커밋 대상) |
| `ralph/tasks.raw.md` | 자유형식 요구사항 입력 |
| `ralph/tasks.json` | task 백로그 (build_pass / qa_pass 포함) |
| `ralph/qa-report.json` | task별 QA 시도 이력 |
| `ralph/qa-hints.json` | Builder가 Evaluator에게 남기는 힌트 |
| `.plan-complete` | Phase 1 완료 sentinel |

## 초기화

```bash
ralph reset                        # 현재 사이클 archive 후 초기화
ralph reset path/to/new-raw.md     # 초기화 + 새 요구사항 로드
ralph reset --hard                 # archive 없이 즉시 초기화
```

## License

MIT
