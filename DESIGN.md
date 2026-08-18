# agent-factory — Design

ระบบ: **ไฟล์ spec 1 ไฟล์ → เว็บ Next.js ที่ deploy ขึ้นจริง** โดยไม่มีคนนั่งเฝ้า
รันบน Claude Code headless (`claude -p`) → ใช้ auth เดียวกับ Claude Pro ที่จ่ายอยู่แล้ว ไม่มีค่า API เพิ่ม

---

## 1. หลักการที่ดีไซน์นี้ยึด (พร้อมที่มา)

### 1.1 ต้องมี "เช็คที่รันได้" ไม่ใช่คำว่าเสร็จ

> "Claude stops when the work looks done. Without a check it can run, 'looks done' is the only signal available, and you become the verification loop."
> — [Claude Code best practices](https://code.claude.com/docs/en/best-practices)

เอกสารทางการระบุ 4 ระดับของ gate เรียงตาม "แน่นแค่ไหน":

| ระดับ | กลไก | ใช้ที่ไหนในดีไซน์นี้ |
|---|---|---|
| ในพรอมป์ | สั่งให้รันเช็คในข้อความเดียวกัน | ทุกเฟส (baseline) |
| ข้ามเทิร์น | `/goal` มี evaluator เช็คทุกเทิร์น | ไม่ใช้ (เป็น interactive) |
| **Stop hook** | สคริปต์บล็อกไม่ให้จบเทิร์นจนกว่าจะผ่าน | **ใช้ในเฟส — ให้ agent วนแก้เอง** |
| **subagent รีวิว** | โมเดลใหม่ context สะอาด มาหักล้างผล | **ใช้เฟส 40** |

⚠️ ข้อจำกัดจริงของ Stop hook: **Claude Code จะ override แล้วจบเทิร์นหลังโดนบล็อกติดกัน 8 ครั้ง** → Stop hook อย่างเดียวไม่พอ ต้องมี gate นอกกระบวนการซ้ำอีกชั้น

**สรุปดีไซน์: gate 2 ชั้น**
- ชั้นใน (Stop hook) — agent แก้เองในเทิร์นเดียว ไม่เปลืองการเรียกใหม่
- ชั้นนอก (bash gate หลังจบ) — ตัดสินว่าเฟสผ่านจริง ไม่เชื่อ hook

### 1.2 context ยาว = คุณภาพตก และ compaction ทำข้อมูลหาย

- "LLM accuracy drops with context length even when relevant information remains present" — *context rot*, ตกลง **13.9–85%** ([Zylos Research](https://zylos.ai/research/2026-04-21-agent-context-compaction-long-running-sessions/))
- compaction summary "optimizing for continuity while dropping compliance rules that were in the original context" ([Governance Decay, arXiv](https://arxiv.org/pdf/2606.22528))
- มี failure mode ที่ agent "treating context-internal information as externally verified" — คือ **สรุปว่าเทสต์ผ่านทั้งที่ process ถูก kill** ([Compaction as Epistemic Failure, arXiv](https://arxiv.org/html/2607.13071))

**สรุปดีไซน์:**
- **1 เฟส = 1 session ใหม่หมด** ไม่ใช้ `--continue` / `--resume` เด็ดขาด
- ความรู้ข้ามเฟสส่งผ่าน **ไฟล์บนดิสก์** (`PLAN.md`, `TASKS.md`, `NOTES.md`) ไม่ใช่ผ่าน context
- ห้ามให้ agent เป็นคนบอกว่าผ่าน — **orchestrator รันเช็คเอง** อ่าน exit code เอง

### 1.3 spec ต้องกลายเป็นแผนก่อน ไม่ใช่กระโดดเขียนโค้ด

GitHub Spec-Kit ใช้ลำดับ **specify → plan → tasks → implement** โดยหลักคือ "specifications do not serve code — code serves specifications" ([GitHub Blog](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/), [spec-kit](https://github.com/github/spec-kit))

เอกสาร Claude Code พูดตรงกัน: "The most useful specs are self-contained: they name the files and interfaces involved, state what is out of scope, and end with an end-to-end verification step"

**สรุปดีไซน์:** เพิ่ม **เฟส 00-plan** แปลง spec → `PLAN.md` + `TASKS.md` (ทุก task มีเกณฑ์ตรวจของตัวเอง) + `CLAUDE.md` ของโปรเจค → เฟสหลังอ่านไฟล์นี้เป็น ground truth

### 1.4 คนเขียนกับคนตรวจต้องคนละคน

> "A reviewer running in a fresh subagent context sees only the diff and the criteria you give it, not the reasoning that produced the change, so it evaluates the result on its own terms."

พร้อมคำเตือน: "A reviewer prompted to find gaps will usually report some, even when the work is sound... Chasing every finding leads to over-engineering"

**สรุปดีไซน์:** เฟส 40 ใช้ subagent รีวิว โดยสั่งชัดว่า **รายงานเฉพาะ gap ที่กระทบ correctness หรือข้อกำหนดใน TASKS.md** ห้ามเสนอ style/refactor

### 1.5 เลือก pattern ให้ตรงงาน — อย่าใส่ความซับซ้อนเกิน

Anthropic แบ่ง workflow เป็น 5 แบบ และเตือน "consider adding complexity *only* when it demonstrably improves outcomes" ([Building Effective Agents](https://www.anthropic.com/research/building-effective-agents))

งานนี้ใช้ 2 แบบผสม:
- **Prompt chaining** — เฟสเรียงกัน ผลเฟสก่อนเป็น input เฟสถัดไป ("best for: fixed, well-defined subtasks where accuracy matters more than speed") ← ตรงกับ pipeline สร้างเว็บ
- **Evaluator-optimizer** — วนแก้ในเฟสจนผ่าน gate ("especially useful when there are clear evaluation criteria")

**ไม่ใช้** orchestrator-workers (subtask เดาได้อยู่แล้ว ไม่ต้องให้โมเดลแตกงานเอง = เปลืองเปล่า)

### 1.6 headless ต้องคุมสิทธิ์

- `--permission-mode auto` มี classifier กันคำสั่งอันตราย และ **"for non-interactive runs with the -p flag, auto mode aborts if the classifier repeatedly blocks actions"** → ล้มเหลวแบบดัง ดีกว่าค้าง
- `--allowedTools` จำกัดว่าทำอะไรได้ — เอกสารระบุตรงๆ ว่า "matters when you're running unattended"
- "every AI-authored commit goes through the same review as a human's" ([hidekazu-konishi.com](https://hidekazu-konishi.com/entry/claude_code_cicd_and_headless_automation.html))

**สรุปดีไซน์:** `--permission-mode auto` + `--allowedTools` + **deploy จริงต้องมีคนกดยืนยัน** (เฟส 50 ขึ้น production ไม่ auto)

---

## 2. สถาปัตยกรรม

```
spec.md
   │
   ▼
┌──────────────────────────────────────────────────────────────┐
│ factory.sh (orchestrator — bash, ไม่มี state ใน LLM)          │
│                                                              │
│  for phase in 00 10 20 30 40 50:                             │
│     ├─ สร้าง prompt = SPEC + PLAN/TASKS/NOTES + phase.md      │
│     ├─ claude -p  (session ใหม่ทุกครั้ง + Stop hook วนแก้ใน)   │
│     ├─ รัน gate จริง → อ่าน exit code                          │
│     ├─ ผ่าน  → touch done-<phase> → เฟสถัดไป                  │
│     └─ ไม่ผ่าน → ป้อน error กลับ ลองใหม่ (สูงสุด 2) → หยุด      │
└──────────────────────────────────────────────────────────────┘
   │
   ▼
runs/<project>/   ← โปรเจคจริง + .factory/ (state, logs, notes)
```

**state อยู่บนไฟล์ระบบทั้งหมด** ไม่มีอะไรอยู่ใน context ของโมเดล → รันค้างกลางทาง ปิดเครื่อง เปิดมารันต่อได้ (`--from <phase>`)

---

## 3. เฟสและ gate

| # | เฟส | agent ทำอะไร | gate ตรวจอะไร (ของจริง) |
|---|---|---|---|
| 00 | **plan** | อ่าน spec → `PLAN.md`, `TASKS.md` (ทุกข้อมีเกณฑ์ตรวจ), `CLAUDE.md` | ไฟล์ครบ, ทุก task มีบรรทัด `verify:`, ไม่มี TODO/placeholder |
| 10 | **scaffold** | Next.js + Tailwind + Docker + Caddy + โครงโฟลเดอร์ตาม PLAN | `npm install` → `tsc --noEmit` → `next build` ผ่าน |
| 20 | **data** | SQLite schema + migration runner + auth + seed | รัน migrate กับ DB เปล่าจริง → ต้องมีตาราง + `PRAGMA user_version` ถูกเซ็ต → build ยังผ่าน |
| 30 | **features** | หน้า/route/API ตาม TASKS.md ทีละข้อ ติ๊ก `[x]` | ทุก task ติ๊กครบ + build ผ่าน |
| 40 | **review** | subagent context สะอาด เทียบ diff กับ TASKS.md → แก้ gap | start server จริง → `curl` ทุก route ใน TASKS → ต้องได้ 2xx และไม่มี error ใน log |
| 50 | **deploy** | `docker compose build && up` → healthcheck → (VPS: ssh push) | container ขึ้นจริง + `curl` ผ่าน Caddy ได้ 200 |

**หลักการตั้ง gate:** ทุก gate ต้องเป็น **คำสั่งที่ล้มได้จริง** ห้ามใช้ "ให้ LLM ตัดสินว่าผ่าน"
เฟส 40 เป็นข้อยกเว้นเดียวที่ใช้ LLM ตรวจ — แต่ตามด้วย smoke test ที่เป็น curl จริงเสมอ

---

## 4. ตารางเลือกโมเดล (ประหยัดโควต้า Pro)

| เฟส | โมเดล | effort | เหตุผล |
|---|---|---|---|
| 00-plan | opus | high | ผิดตรงนี้ พังทั้ง pipeline |
| 10-scaffold | sonnet | medium | งานกลไก มี template ชัด |
| 20-data | opus | high | schema ผิด = รื้อทีหลังแพง |
| 30-features | sonnet | medium | เขียนตาม TASKS ที่ล็อกไว้แล้ว |
| 40-review | opus | high | หา bug ต้องใช้ตัวแรง |
| 50-deploy | opus | high | Docker/network ผิดนิดเดียวก็ไม่ขึ้น |

ตั้งใน `pipeline/<phase>.conf` ต่อเฟส

---

## 5. อะไรที่ **ไม่** ทำ และทำไม

| ไม่ทำ | เหตุผล |
|---|---|
| ยิง `claude -p` ครั้งเดียวจบ | context rot 13.9–85% + พังกลางทางแล้วไปต่อทั้งที่พัง |
| `--continue` ข้ามเฟส | compaction ทำ compliance rule หาย (Governance Decay) |
| ให้ agent รายงานว่า "ผ่านแล้ว" | มี failure mode สรุปว่าเทสต์ผ่านทั้งที่ process ถูก kill |
| `bypassPermissions` เป็น default | ไม่มีอะไรกันคำสั่งทำลาย — ใช้ `auto` ที่มี classifier แทน |
| orchestrator-workers / subagent แตกงานเอง | subtask เดาล่วงหน้าได้แล้ว = จ่ายค่าซับซ้อนฟรี |
| auto-deploy ขึ้น production | เอกสาร CI/CD ระบุ "keep destructive operations behind approval" |

---

## 6. ขั้นตอนใช้งาน

```bash
# 1. เขียน spec
cp specs/_template.md specs/my-shop.md && $EDITOR specs/my-shop.md

# 2. รันทั้ง pipeline
./factory.sh specs/my-shop.md --name my-shop

# 3. เฟสไหนพัง → แก้มือ → รันต่อจากเฟสนั้น
./factory.sh specs/my-shop.md --name my-shop --from 30-features

# 4. รันเฟสเดียวซ้ำ
./factory.sh specs/my-shop.md --name my-shop --only 40-review

# 5. ขึ้น VPS (หลังเช่าแล้ว)
FACTORY_DEPLOY_TARGET=vps FACTORY_VPS=root@1.2.3.4 \
  ./factory.sh specs/my-shop.md --name my-shop --only 50-deploy
```

ทุกครั้งที่รัน log เก็บที่ `runs/<name>/.factory/logs/<phase>-a<attempt>.{prompt,out,gate}.txt`
→ เฟสพังแล้วย้อนดูได้ว่า agent เห็นอะไร ทำอะไร gate ด่าว่าอะไร

---

## 7. วิธีวัดว่าระบบนี้ดีพอ

รัน spec เดียวกัน 3 รอบ วัด:

1. **pass rate ต่อเฟส** — เฟสไหนต้อง retry บ่อย = prompt เฟสนั้นเขียนไม่ดี ต้องแก้ที่ prompt ไม่ใช่เพิ่ม retry
2. **เฟสที่คนต้องเข้าไปแก้มือ** — เป้าคือ 0
3. **gate ที่ผ่านทั้งที่ของพัง** (false pass) — อันตรายที่สุด เจอเมื่อไหร่ต้องเพิ่มเช็คใน gate ทันที

ปรับที่ **prompt เฟส** และ **ความเข้มของ gate** เท่านั้น อย่าปรับด้วยการเพิ่มจำนวน retry

**ทำแล้ว**: ทุก attempt เขียนแถวลง `runs/<name>/.factory/metrics.tsv`
(`started_at phase model effort attempt result seconds prompt_bytes`) และ `./measure.sh <spec> --runs 3`
รันแยกไดเรกทอรีให้ทุกรอบ (รอบเก่าค้างอยู่ = ถูก resume แล้วรายงาน pass ที่ไม่ได้ทำจริง) แล้วสรุป
attempts/passes/1st-try/avg-sec ต่อเฟส + เฟสที่แต่ละรอบหยุด. `--summary-only` อ่านของเก่าซ้ำโดยไม่รันใหม่

ข้อ 3 (false pass) อัตโนมัติไม่ได้ ต้องใช้คนดู — แต่ตารางชี้ที่ให้ดูก่อนได้: เฟสที่ผ่านฉลุยแล้วเฟสถัดไปพังกับงานของมัน

---

## Sources

- [Claude Code best practices — code.claude.com](https://code.claude.com/docs/en/best-practices)
- [Building Effective AI Agents — Anthropic](https://www.anthropic.com/research/building-effective-agents)
- [Spec-driven development with AI — GitHub Blog](https://github.blog/ai-and-ml/generative-ai/spec-driven-development-with-ai-get-started-with-a-new-open-source-toolkit/)
- [github/spec-kit](https://github.com/github/spec-kit)
- [Claude Code in CI/CD and Headless Automation — hidekazu-konishi.com](https://hidekazu-konishi.com/entry/claude_code_cicd_and_headless_automation.html)
- [Agent Context Compaction for Long-Running Sessions — Zylos Research](https://zylos.ai/research/2026-04-21-agent-context-compaction-long-running-sessions/)
- [Governance Decay: How Context Compaction Silently Erases Safety Constraints — arXiv](https://arxiv.org/pdf/2606.22528)
- [Compaction as Epistemic Failure — arXiv](https://arxiv.org/html/2607.13071)
- [Long-Running Coding Agents: The 2026 Guide — O-mega.ai](https://o-mega.ai/articles/long-running-coding-agents-the-2026-guide)
