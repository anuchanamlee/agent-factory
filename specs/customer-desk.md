# customer-desk

เว็บหลังบ้านของฟรีแลนซ์คนเดียว (เจ้าของ) ใช้ดูแลลูกค้าที่ทักมาทาง Fastwork: ใครรอเราตอบอยู่ ดีลไหนค้าง ต้องตามใครวันไหน
เปิดดูแชทเต็มของลูกค้าแต่ละคน แก้สถานะงาน และวางแชทใหม่เข้าไปได้
ตัวเว็บ **ไม่ร่างข้อความเอง และไม่แตะ Fastwork** งานร่าง/ส่งทำโดยบอทแยกต่างหาก (ไม่อยู่ในโปรเจกต์นี้) ที่เขียน event ลงไฟล์ `CUSTOMERS_DIR/_desk/events.jsonl` เว็บมีหน้าที่อ่านไฟล์ทั้งหมดมาแสดง ค้นหา และทำรายงานตัวเลข

---

## 1. [บังคับ] เว็บนี้คืออะไร ใครใช้

เจ้าของคนเดียวใช้บนเครื่องตัวเอง (localhost) ทุกเช้าเปิดหน้า `/` เพื่อดูว่าวันนี้ต้องตอบใคร ตามใคร
ข้อมูลลูกค้าต้นทางคือโฟลเดอร์ไฟล์ markdown ใน vault (ตัวแปร `CUSTOMERS_DIR`) ซึ่ง Claude Code อ่านและเขียนอยู่แล้ว
เว็บ import โฟลเดอร์นั้นเข้า SQLite เพื่อค้นหา กรอง และคำนวณ แล้วเขียนกลับไปที่ไฟล์เฉพาะบางจุดที่กำหนดในข้อ 3

## 2. [บังคับ] หน้าเว็บทั้งหมด

| path | สาธารณะ/ต้องล็อกอิน | เนื้อหา |
|---|---|---|
| `/login` | สาธารณะ | ฟอร์มอีเมล+รหัสผ่าน สำเร็จแล้วเด้งไป `/` ผิดให้ขึ้นข้อความ error ในหน้าเดิม |
| `/` | ต้องล็อกอิน | **วันนี้**: 3 กล่อง (1) **รอเราตอบ** = ลูกค้าที่ข้อความล่าสุด (ไม่นับ SYS) มาจาก `C` หรือ `PASTE` และ pipeline ไม่ใช่ `lost` เรียงจากรอนานสุด แต่ละแถวแสดงชื่อ ข้อความล่าสุดตัดไม่เกิน 140 ตัวอักษร และรอมากี่ชั่วโมง/วัน (2) **ถึงวันตาม** = `follow_up` ≤ วันนี้ และ pipeline ไม่ใช่ `lost`/`delivered` (3) **ดีลที่เปิดอยู่** = pipeline `talking`/`quoted`/`won` พร้อม `deal_value` รวม · มุมบนมีเวลา import ล่าสุด ปุ่ม "นำเข้าจาก vault อีกครั้ง" และปุ่มคัดลอกคำสั่ง `/fastwork-sync` |
| `/customers` | ต้องล็อกอิน | ตารางลูกค้าทั้งหมด: ชื่อ, pipeline (ป้ายสี + ข้อความไทย), ความต้องการ (บรรทัดแรกของ Scope ใน facts), คุยล่าสุด, next_action, follow_up, deal_value · กรองด้วย query `?pipeline=<ค่า>` และค้นด้วย `?q=<คำ>` (ค้นในชื่อ, slug, facts) · เรียง last_contact ใหม่สุดก่อน |
| `/customers/[slug]` | ต้องล็อกอิน | ซ้าย: แชททั้งหมดเรียงเก่า→ใหม่ แบบฟองแชท (C ซ้าย, ME ขวา, SYS/PASTE ตรงกลางสีจาง) มีหัววันที่คั่น เลื่อนลงล่างสุดอัตโนมัติ · ขวา: ฟอร์มแก้ pipeline / next_action / follow_up / deal_value / paid, ลิงก์เปิดห้อง Fastwork (`fastwork_room`), ปุ่มคัดลอกคำสั่ง 4 ปุ่ม (`/reply <slug>`, `/client-brief <slug>`, `/client-plan <slug>`, `/customer-capture <slug>`), เนื้อหา facts แสดงเป็น markdown, กล่อง "วางแชทใหม่" (textarea + เลือกว่าเป็นข้อความจาก ลูกค้า/เรา/วางทั้งก้อน) · slug ไม่มีจริง → 404 |
| `/customers/new` | ต้องล็อกอิน | ฟอร์มเพิ่มลูกค้าใหม่: ชื่อ (บังคับ), ลิงก์ห้อง Fastwork (ไม่บังคับ), แชทแรก (ไม่บังคับ) → สร้างโฟลเดอร์ใน `CUSTOMERS_DIR` + import → เด้งไป `/customers/<slug>` |
| `/reports` | ต้องล็อกอิน | รายงานแยกแท็บ (`?range=day|week|month`, default `week`): **ขาย** (ลูกค้าใหม่ → ได้ราคา (`quoted` ขึ้นไป) → จ่ายเงิน (`won`/`delivered`) แยกตามการ์ด `card` ใน facts, เหตุผลที่หลุดจาก `lost_reason`) · **เงิน** (รายได้สุทธิ = `paid` × 0.82, มูลค่าดีลที่เปิดอยู่, เทียบเป้า `MONTHLY_GOAL`) · **เวลาตอบ** (median นาทีจาก C แรกของวันถึง ME แรกหลังจากนั้น, จำนวนครั้งที่เกิน 60 นาที) · **ร่างของบอท** (จาก events: ส่งเลย/แก้แล้วส่ง/ไม่ส่ง นับแยก) · **ชั่วโมงทำงาน** (จาก `TIME_DIR`, ชั่วโมงต่อลูกค้าและ ฿/ชั่วโมง = paid × 0.82 ÷ ชั่วโมง; ไม่มีไฟล์/ไม่มีแถว = แสดง "ไม่มีข้อมูล" ห้ามประมาณ) · **หน้าร้าน** (snapshot ล่าสุดจาก events `storefront`) — ทุกตัวเลขมีปุ่ม "ดูที่มา" แสดงแถวข้อมูลที่ใช้คำนวณ |
| `/drafts` | ต้องล็อกอิน | ประวัติร่างจาก events เรียงใหม่สุดก่อน: ลูกค้า, เวลา, สถานะ (`pending` `sent` `edited_sent` `discarded` `ack_sent`), ร่างเดิม และข้อความที่ส่งจริง (แสดงส่วนต่างถ้าแก้) · กรอง `?status=` |
| `/insights` | ต้องล็อกอิน | ภาพรวม: จำนวนลูกค้าต่อ pipeline (แท่งแนวนอน), ลูกค้าใหม่ต่อเดือนจาก `first_contact` (แท่งแนวตั้ง 12 เดือนล่าสุด), เงินที่ได้จริง = ผลรวม `paid`, มัธยฐานเวลาที่เราตอบครั้งแรก (นาที, จากข้อความ C แรกถึง ME แรกหลังจากนั้น ไม่นับข้อความที่ขึ้นต้น `[ข้อความอัตโนมัติ`) |

## 3. [บังคับ] ข้อมูลที่ต้องเก็บ

### ต้นทาง: โฟลเดอร์ `CUSTOMERS_DIR` (ไม่ใช่ DB — อ่านรูปแบบนี้ให้ตรงเป๊ะ)

```
CUSTOMERS_DIR/
  <slug>/                         slug = [a-z0-9-]+ เท่านั้น โฟลเดอร์อื่นข้าม (เช่น _fastwork)
    <slug>-facts.md               ไม่มีไฟล์นี้ = ข้ามโฟลเดอร์
    chats/YYYY-MM-DD*.md          หลายไฟล์ อ่านเรียงตามชื่อไฟล์
```

**facts** ขึ้นต้นด้วย frontmatter แบบ `key: value` บรรทัดละคู่ (ไม่มี nested) ค่าอาจอยู่ใน `"..."` แบบ JSON string
key ที่ใช้: `stage`, `fastwork_room`, `first_contact`, `last_contact`, `pipeline`, `next_action`, `follow_up`, `deal_value`, `paid`, `client_note` (ไม่มี key = ค่าว่าง/0)
ในเนื้อหา: ชื่อลูกค้าคือบรรทัด `# <ชื่อ> — facts` · สรุปผลคือบรรทัด `**Outcome:** <ข้อความ>` · หัวข้อ `## Scope & prices quoted` บรรทัด `- ` แรกใต้หัวข้อ = "ความต้องการ"

**chats** แต่ละไฟล์:
- บรรทัดก่อน `## ` แรกเป็นหัวไฟล์ ข้ามได้
- `## YYYY-MM-DD` = เปลี่ยนวันที่ของข้อความถัดไป
- `HH:MM C: ข้อความ` / `HH:MM ME: ...` / `HH:MM SYS: ...` = ข้อความใหม่ · บรรทัดถัดไปที่ไม่ตรงรูปแบบใดเลย = ต่อท้ายข้อความเดิม (ข้อความหลายบรรทัด)
- `## HH:MM paste` = ก้อนแชทที่วางมาทั้งก้อน sender = `PASTE` วันที่ = 10 ตัวแรกของชื่อไฟล์ เนื้อหาคือทุกบรรทัดจนถึง `## ` ถัดไป

### customers
| ฟิลด์ | ชนิด | บังคับ | หมายเหตุ |
|---|---|---|---|
| id | int | ✓ | auto |
| slug | text | ✓ | unique |
| name | text | ✓ | |
| stage | text | | lead / client / past |
| pipeline | text | ✓ | `new` `talking` `quoted` `won` `delivered` `lost` · ค่าอื่น/ว่าง = `new` · ป้ายไทย: ใหม่, กำลังคุย, เสนอราคาแล้ว, ได้งาน/กำลังทำ, ส่งงานแล้ว, ไม่ได้งาน |
| next_action | text | | |
| follow_up | text | | YYYY-MM-DD |
| deal_value | int | | บาท |
| paid | int | | บาท |
| fastwork_room | text | | URL |
| first_contact | text | | YYYY-MM-DD |
| last_contact | text | | YYYY-MM-DD |
| need | text | | จาก Scope บรรทัดแรก |
| outcome | text | | |
| facts_md | text | ✓ | เนื้อหา facts ทั้งหมด (ไม่รวม frontmatter) |
| imported_at | text | ✓ | ISO 8601 |

### messages
| ฟิลด์ | ชนิด | บังคับ | หมายเหตุ |
|---|---|---|---|
| id | int | ✓ | auto |
| customer_id | int | ✓ | FK customers, ลบลูกค้า = ลบข้อความ |
| seq | int | ✓ | ลำดับในลูกค้าคนนั้น เริ่ม 1 |
| date | text | ✓ | YYYY-MM-DD |
| time | text | | HH:MM |
| sender | text | ✓ | `C` `ME` `SYS` `PASTE` |
| body | text | ✓ | |
| source_file | text | ✓ | ชื่อไฟล์ใน chats/ |

### events (import จาก `CUSTOMERS_DIR/_desk/events.jsonl` — บอทเขียน เว็บอ่านอย่างเดียว)
| ฟิลด์ | ชนิด | บังคับ | หมายเหตุ |
|---|---|---|---|
| id | int | ✓ | auto |
| ts | text | ✓ | ISO 8601 |
| type | text | ✓ | `draft` `decision` `ack_sent` `storefront` · ชนิดอื่น = เก็บแต่ไม่ใช้ |
| slug | text | | ลูกค้า (ว่างได้สำหรับ `storefront`) |
| draft_id | text | | ผูก `draft` กับ `decision` |
| payload | text | ✓ | JSON ทั้งบรรทัด |
- 1 บรรทัด = 1 JSON · บรรทัดที่ parse ไม่ได้ = ข้ามและนับจำนวนแสดงใน `/reports` (ห้ามล้ม)
- `draft` payload: `{draft_id, slug, text}` · `decision` payload: `{draft_id, action: sent|edited_sent|discarded, sent_text?}` · `storefront` payload: `{views, chats, rating, reviews, response_time_text, fee_pct}`
- import events แบบลบทั้งหมดแล้วใส่ใหม่ เหมือน messages (ไฟล์เป็นต้นทาง)
- fixtures: `fixtures/customers/_desk/events.jsonl` มี draft 3 อัน: 1 sent, 1 edited_sent (ข้อความต่าง), 1 ยังไม่มี decision (= pending) + storefront 1 อัน + 1 บรรทัดเสีย

### เวลาทำงาน (อ่านอย่างเดียวจาก `TIME_DIR/YYYY-MM.md`)
แถวรูปแบบ `| YYYY-MM-DD | [[slug]] | ชั่วโมง | งาน | #billable |` · บรรทัดอื่นข้าม · fixtures: `fixtures/time/2026-09.md` มี 2 แถวของ `fixture-won` รวม 10 ชั่วโมง

### facts key เพิ่ม (อ่านจาก frontmatter, ไม่บังคับ)
`card` (การ์ด Fastwork ที่ลูกค้าเข้ามา), `lost_reason` (ข้อความสั้น) — fixtures: `fixture-won` card `line-oa`, `fixture-quoted` card `discovery`

### imports
| ฟิลด์ | ชนิด | บังคับ | หมายเหตุ |
|---|---|---|---|
| id | int | ✓ | auto |
| ran_at | text | ✓ | ISO 8601 |
| customers | int | ✓ | จำนวนที่ import |
| messages | int | ✓ | |

### users
| ฟิลด์ | ชนิด | บังคับ | หมายเหตุ |
|---|---|---|---|
| id | int | ✓ | auto |
| email | text | ✓ | unique |
| password_hash | text | ✓ | bcryptjs |
| created_at | text | ✓ | ISO 8601 |

### กติกา import / เขียนกลับ (สำคัญ)
- `npm run import` และปุ่ม "นำเข้าจาก vault อีกครั้ง" ทำงานเดียวกัน: อ่าน `CUSTOMERS_DIR` ทั้งหมด upsert customers ตาม slug, **ลบ messages ของลูกค้านั้นแล้วใส่ใหม่ทั้งชุด** (รันซ้ำกี่ครั้งจำนวนต้องเท่าเดิม), บันทึก 1 แถวใน imports · ทำใน transaction เดียว
- ลูกค้าที่โฟลเดอร์หายไปแล้ว → ลบจาก DB
- เว็บเขียนไฟล์ได้ **3 กรณีเท่านั้น** และห้ามแตะไฟล์อื่น:
  1. บันทึกฟอร์ม pipeline → แก้ **เฉพาะ 5 key** `pipeline next_action follow_up deal_value paid` ใน frontmatter ของ facts (เพิ่ม key ถ้ายังไม่มี) เนื้อหาส่วนอื่นของไฟล์ต้องเหมือนเดิมทุกไบต์ แล้ว import ลูกค้าคนนั้นใหม่
  2. วางแชท → append ต่อท้าย `chats/<วันนี้>.md` (ไม่มีไฟล์ = สร้างพร้อมหัว `# <slug> — <วันนี้>`) · เลือก "ลูกค้า"/"เรา" = เขียน `## <วันนี้>` แล้ว `HH:MM C: ...` หรือ `HH:MM ME: ...` · เลือก "วางทั้งก้อน" = เขียน `## HH:MM paste` ตามด้วยข้อความ · อัปเดต `last_contact` ใน frontmatter ถ้าวันนี้ใหม่กว่า · แล้ว import ลูกค้าคนนั้นใหม่
  3. ลูกค้าใหม่ → สร้าง `<slug>/`, `chats/`, `docs/`, และ facts ที่มี frontmatter ครบ key ในข้อ 3 (`stage: lead`, `pipeline: new`, `next_action: ตอบข้อความแรก`, `follow_up: <วันนี้>`) และหัวข้อ `## Who` `## Scope & prices quoted` `## We promised` `## They owe us` `## Deadlines` `## Preferences & tone` `## Out of scope / refused` `## Open questions` · slug ทำจากชื่อ (a-z0-9 ขีดกลาง) ถ้าชื่อเป็นไทยล้วนใช้ `lead-<ตัวเลขเวลา>` ถ้าซ้ำต่อท้าย `-2`, `-3`
- **ปิดรหัสก่อนเขียนไฟล์และก่อนเก็บ DB**: ข้อความที่วาง ถ้ามี `password:` / `pass:` / `รหัสผ่าน:` ตามด้วยค่า → ค่ากลายเป็น `***` · สตริง `AIza` + 30 ตัวขึ้นไป → `***` · base32 ตัวใหญ่ 32 ตัว → `***` · บรรทัดที่มีช่องคั่นด้วย tab และมีค่าไม่ว่าง ≥ 3 ช่อง → ทั้งบรรทัดเป็น `***`
- slug ที่รับจาก URL/ฟอร์มต้องผ่าน regex `^[a-z0-9][a-z0-9-]{0,60}$` ก่อนต่อ path ทุกครั้ง (กัน path traversal)

### fixtures (ข้อมูลทดสอบ — gate ใช้ชุดนี้)
สร้าง `fixtures/customers/` ในโปรเจกต์ มี 3 ลูกค้าตามรูปแบบข้างบน ถ้าไม่ได้ตั้ง `CUSTOMERS_DIR` ให้ใช้โฟลเดอร์นี้ · `npm run seed` = สร้าง admin + import
- `fixture-waiting`: ชื่อ `ลูกค้ารอตอบ`, pipeline `talking`, follow_up `2020-01-01`, deal_value 5000 · แชท 1 ไฟล์ `2026-09-01.md` มี 3 ข้อความ C → ME → C (ข้อความสุดท้ายคือ `C: ราคาเท่าไหร่ครับ`) · Scope บรรทัดแรก `- ระบบจองคิว LINE OA`
- `fixture-quoted`: ชื่อ `ลูกค้าเสนอราคา`, pipeline `quoted`, deal_value 12000, first_contact `2026-08-10` · แชท C → ME (ข้อความสุดท้ายจาก ME)
- `fixture-won`: ชื่อ `ลูกค้าได้งาน`, pipeline `delivered`, paid 20000, first_contact `2026-05-01` · แชทมีข้อความ 3 บรรทัดต่อกัน (multi-line) 1 ข้อความ และมี `## 10:00 paste` 1 ก้อน

## 4. [บังคับ] ใครล็อกอินได้ ทำอะไรได้

เจ้าของคนเดียว ไม่มีหน้าสมัคร บัญชีสร้างจาก `npm run seed` เท่านั้น: `owner@desk.local` / `desk-local-1234`
(ใช้จริงให้ตั้ง `ADMIN_EMAIL` / `ADMIN_PASSWORD` ใน `.env` แล้ว seed ใหม่ — ค่าในนี้ไว้ให้ gate ทดสอบ)
ทุก path ยกเว้น `/login` และ asset ของ Next ต้องถูก protect ที่ middleware (`proxy.ts`) ไม่ใช่เช็คทีละหน้า
server action / route ที่เขียนข้อมูลต้องเช็ค session ซ้ำอีกชั้น

## 5. [บังคับ] "เสร็จ" คือทำอะไรได้บ้าง

1. เปิด `/` หรือ `/customers` โดยไม่ล็อกอิน → ถูกเด้งไป `/login`
2. ล็อกอิน `owner@desk.local` / `desk-local-1234` → เข้า `/` เห็นกล่อง "รอเราตอบ" มี `ลูกค้ารอตอบ` พร้อมข้อความ `ราคาเท่าไหร่ครับ` และ **ไม่มี** `ลูกค้าเสนอราคา` · กล่อง "ถึงวันตาม" มี `ลูกค้ารอตอบ`
3. `/customers` เห็นลูกค้า 3 ราย · `/customers?pipeline=quoted` เห็นแค่ `ลูกค้าเสนอราคา` · `/customers?q=จองคิว` เห็นแค่ `ลูกค้ารอตอบ`
4. `/customers/fixture-won` เห็นข้อความ multi-line ครบ 3 บรรทัด ก้อน paste และข้อความเรียงตามเวลา · มีปุ่มคัดลอก `/reply fixture-won` · `/customers/does-not-exist` → 404 · `/customers/..%2F..%2Fetc` → 404 ไม่ใช่ 500
5. แก้ฟอร์มของ `fixture-quoted` เป็น pipeline `won` next_action `เก็บมัดจำ` → หน้าแสดงค่าใหม่ และไฟล์ `fixture-quoted-facts.md` มี `pipeline: won` แต่ทุกบรรทัดหลัง frontmatter เหมือนเดิม
6. วางแชท "ลูกค้า" ข้อความ `Password: abc123 ส่งแล้วครับ` ที่ `fixture-quoted` → timeline แสดง `Password: *** ส่งแล้วครับ` ไฟล์ `chats/<วันนี้>.md` มีบรรทัดนั้นแบบปิดรหัสแล้ว และ `ลูกค้าเสนอราคา` ขึ้นในกล่อง "รอเราตอบ" ที่ `/`
7. `/customers/new` สร้าง `Test Lead` → เด้งไป `/customers/test-lead` · มีโฟลเดอร์ `test-lead/` พร้อม facts · ขึ้นใน `/customers`
8. `/insights` แสดงเงินที่ได้จริง `20,000` และจำนวนต่อ pipeline ตรงกับ fixtures
9. รัน `npm run import` 2 ครั้งติดกัน → จำนวนแถวใน messages และ events เท่ากันทั้ง 2 ครั้ง
10. `/drafts` เห็นร่าง 3 อัน สถานะ sent / edited_sent / pending · `/drafts?status=pending` เห็น 1 อัน · อันที่ edited_sent แสดงทั้งร่างเดิมและข้อความที่ส่งจริง
11. `/reports?range=month` แท็บเงินแสดงรายได้สุทธิ `16,400` (20,000 × 0.82) · ชั่วโมงทำงานของ `fixture-won` = 10 และ ฿/ชั่วโมง = `1,640` · แท็บร่างของบอทแสดง ส่งเลย 1 / แก้แล้วส่ง 1 / ไม่ส่ง 0 · แสดง "ข้ามบรรทัดเสีย 1" · ตั้ง `TIME_DIR` ไปโฟลเดอร์ว่าง → ช่องชั่วโมงแสดง "ไม่มีข้อมูล" ไม่ใช่ 0

## 6. หน้าตา / แบรนด์

- สีหลัก: น้ำเงิน `#2a78d6` · พื้นเทาอุ่นอ่อน · ป้ายสถานะใช้สีตามความหมาย (เขียว=ได้งาน, เหลือง=กำลังคุย, ส้ม=เสนอราคา, เทา=ไม่ได้งาน) พร้อมข้อความเสมอ ไม่ใช้สีอย่างเดียว
- โทน: เครื่องมือทำงาน สะอาด ตัวหนังสืออ่านง่าย หนาแน่นพอดี ไม่ใช่หน้าโฆษณา
- ฟอนต์: IBM Plex Sans Thai (Google Fonts) · ตัวเลขใช้ tabular-nums
- ภาษา: ไทยทั้งหมด (ชื่อ field/ตาราง/โค้ดเป็นอังกฤษ)
- ใช้บนจอคอมเป็นหลัก แต่กว้าง 400px ต้องไม่ล้นแนวนอน
- รองรับ dark mode ตาม `prefers-color-scheme`

## 7. สิ่งที่ **ไม่** ต้องทำ

- ไม่เรียก AI / LLM API ใดๆ จากเว็บ และไม่เขียน events.jsonl (บอทเป็นเจ้าของไฟล์นั้น)
- ไม่ต่อ Fastwork, ไม่ scrape, ไม่ส่งข้อความหาลูกค้า
- ไม่มีหน้าสมัครสมาชิก ไม่มีหลายผู้ใช้ ไม่มีสิทธิ์หลายระดับ
- ไม่อัปโหลดไฟล์/รูป
- ไม่แก้ไข/ลบข้อความแชทเดิม ไม่ลบลูกค้าจากเว็บ
- ไม่แก้ส่วนเนื้อหา facts จากเว็บ (Claude Code เป็นคนเขียน)
- ไม่ต้องมีหลายภาษา ไม่ต้องส่งอีเมล ไม่ต้องมี notification

## 8. ของนอกที่ต้องต่อ

| บริการ | ใช้ทำอะไร | ตัวแปร env |
|---|---|---|
| โฟลเดอร์ vault ในเครื่อง | ต้นทางข้อมูลลูกค้า (ไม่ตั้ง = ใช้ `fixtures/customers`) | `CUSTOMERS_DIR` |
| บัญชีเจ้าของ | seed admin | `ADMIN_EMAIL`, `ADMIN_PASSWORD` |
| บันทึกเวลาทำงาน | ชั่วโมงต่องาน (ไม่ตั้ง = `fixtures/time`) | `TIME_DIR` |
| เป้ารายได้ต่อเดือน | แท็บเงินใน `/reports` (ไม่ตั้ง = ไม่แสดงเป้า) | `MONTHLY_GOAL` |

## 9. Deploy

- ปลายทาง: local (docker ในเครื่อง)
- โดเมน: ยังไม่มี
- พอร์ต: caddy เปิดที่ `FACTORY_DEPLOY_PORT` (รันด้วย 3210) และ **bind 127.0.0.1 เท่านั้น** (ข้อมูลส่วนตัวลูกค้า ห้ามเปิดออก LAN) · `npm start` ต้องเป็น `next start` เฉยๆ ไม่ใส่พอร์ต
- docker compose ต้อง mount `CUSTOMERS_DIR` จากเครื่องเข้า container แบบอ่าน-เขียน (ค่า default ใน compose ชี้ `./fixtures/customers`)

---

## Stack (ล็อกไว้แล้ว ไม่ต้องแก้)

Next.js 16 (App Router) · TypeScript · Tailwind · SQLite (better-sqlite3, raw SQL)
NextAuth v5 credentials + bcryptjs · รูปเก็บ local disk + sharp บีบตอนอัป
Docker Compose (web + caddy) · migration เป็น .sql + PRAGMA user_version

**Gotchas ที่ต้องทำตาม** (เจอมาแล้วจริงจาก livincolor):
- middleware ต้องเป็น `proxy.ts` ที่ **root** ไม่ใช่ใน `src/` — ไม่งั้น Turbopack dev ไม่รัน = route ไม่ถูก protect
- `bcryptjs` ต้องอยู่ใน `serverExternalPackages` ของ next.config
- `better-sqlite3` ใช้ v12 (prebuilt สำหรับ node 24)
- Docker base image: `node:22-bookworm-slim`
