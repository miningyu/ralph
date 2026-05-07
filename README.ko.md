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
  ├─ Phase 2 (build)  — 같은 scope의 작은 task batch 구현 (build_pass:true까지 반복)
  │
  └─ Phase 3 (qa)     — 독립 평가 에이전트가 각 task 검증 (qa_pass:true까지 반복)
               └─ 실패 시 → 실패 원인 전체를 다음 build iteration에 주입
```

> **Builder**(Claude)가 구현하고, **Evaluator**(Codex)가 독립적으로 검증한다.
> 각 phase의 CLI는 설정으로 교체 가능 — 기본값은 plan/build가 `claude`, QA가 `codex`로
> 빌더와 평가자를 서로 다른 모델 계열에서 운용한다. 프롬프트를 positional 인자로 받는
> CLI라면 무엇이든 사용 가능하므로(`claude` 둘 다, `codex` 둘 다도 OK),
> `ralph/ralph-config.json`의 `builder.command` / `evaluator.command`만 바꾸면 된다.
> QA 실패 시 단순 증상 수정이 아닌 근본 원인을 context로 주입해 재구현한다.

---

## Requirements

- [Claude Code CLI](https://claude.ai/code) (`claude`) — 기본값에서 Phase 1(plan), Phase 2(build) 담당
- [OpenAI Codex CLI](https://github.com/openai/codex) (`codex`) — 기본값에서 Phase 3(QA) 담당. 최초 1회 `codex login` 실행 필요
- `bash`, `jq`, `curl`, `git`

> `ralph/ralph-config.json`에 실제로 설정한 CLI만 설치되어 있으면 된다. 두 명령어를 모두
> `claude` (또는 모두 `codex`) 로 두면 한 쪽 CLI만 있으면 충분하다.

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

**Phase 2 — Build**: 첫 번째 `build_pass:false` task를 기준으로 같은 scope의 준비된 task를 `builder.batchSize`개까지 묶어 구현한다. `commands.quick`이 있으면 batch 단위로 빠른 검증을 실행하고, 완료한 task를 `build_pass:true`로 마킹한 뒤 한 번 커밋한다.

모든 build task가 통과하면 watchdog이 QA 전에 `commands.final`을 scope별로 한 번 실행한다. `validation.runtimeSmoke`가 `"final"`이면 백엔드/프론트엔드 런타임 스모크도 매 build iteration이 아니라 이 final gate에서 한 번 실행한다.

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
| `commands.quick` | 선택 사항. build iteration에서 사용할 빠른 검증 명령 |
| `commands.final` | 선택 사항. QA 전에 scope별로 한 번 실행할 최종 검증 명령 |
| `builder.command` | plan + build 에이전트 CLI (기본: `claude` Opus) |
| `builder.batchSize` | 한 agent 호출에서 처리할 같은 scope의 준비된 task 최대 개수 |
| `evaluator.command` | QA 에이전트 CLI (기본: `codex exec`). builder와 다른 CLI를 권장 — 새 시각으로 검증하기 위함 |
| `validation.runtimeSmoke` | `"perTask"`는 기존처럼 build 중 스모크, `"final"`은 QA 전 한 번만 스모크 |
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
| `ralph/.plan-complete` | Phase 1 완료 sentinel |

## 초기화

```bash
ralph reset                        # 현재 사이클 archive 후 초기화
ralph reset path/to/new-raw.md     # 초기화 + 새 요구사항 로드
ralph reset --hard                 # archive 없이 즉시 초기화
```

## License

MIT
