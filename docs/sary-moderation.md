# «بلّغ عن الرسالة» و«احظر» — المراجعة (App Store 1.2)

ما فيه واجهة إدارة للحين. البلاغات تنحفظ في `sary.chat_reports` والحظر في `sary.user_blocks`
(migration `018_sary_chat_moderation.sql`). هذي الاستعلامات لقراءتها ومراجعتها من قاعدة البيانات
(Supabase SQL editor أو `psql "$DATABASE_URL"`).

## الواجهات (API)

| الطريقة | المسار | الوصف |
|---|---|---|
| `POST` | `/api/outings/:id/chat/:msgId/report` | `{ reason, note?, block? }` — `reason`: `abuse` · `harassment` · `spam` · `sexual` · `violence` · `other`. بلاغ واحد لكل شخص على الرسالة (التكرار يرجع `duplicate: true`). حد: ١٠ بلاغات بالساعة لكل شخص (429). |
| `GET` | `/api/outings/me/blocks` | قائمة «المحظورين». |
| `POST` | `/api/outings/me/blocks/:userId` | احظر. |
| `DELETE` | `/api/outings/me/blocks/:userId` | إلغاء الحظر. |

الحظر يخفي عند الحاظر رسائل المحظور في الدردشة (السجل، الوقت الحقيقي، الإشعارات، عدّاد غير المقروء)
ورسائله الصوتية (ما تنعرض ولا تشتغل لحالها ولا يصحّي جواله)، ويمنع الرسائل الخاصة بينهم بالاتجاهين (`403 blocked`).
**الطوارئ (SOS) ما تنفلتر أبدًا**: توصل للكل، حتى اللي حاظره.

## البلاغات المفتوحة (الأحدث أول)

```sql
SELECT r.id, r.created_at, r.reason, r.note,
       rep.display_name AS reporter, snd.display_name AS sender, r.sender_id,
       r.body_snapshot, o.name AS outing, r.outing_id, r.message_id
FROM sary.chat_reports r
JOIN sary.users rep ON rep.id = r.reporter_id
LEFT JOIN sary.users snd ON snd.id = r.sender_id
LEFT JOIN sary.outings o ON o.id = r.outing_id
WHERE r.status = 'open'
ORDER BY r.created_at DESC
LIMIT 100;
```

## أكثر الناس بلاغات عليهم (آخر ٣٠ يوم)

```sql
SELECT r.sender_id, u.display_name, count(*) AS reports, count(DISTINCT r.reporter_id) AS reporters
FROM sary.chat_reports r LEFT JOIN sary.users u ON u.id = r.sender_id
WHERE r.created_at > now() - interval '30 days'
GROUP BY 1, 2 ORDER BY reports DESC LIMIT 50;
```

## إغلاق بلاغ بعد المراجعة

```sql
-- status: 'reviewed' (اطلعنا) · 'actioned' (اتخذنا إجراء) · 'dismissed' (ما فيه مخالفة)
UPDATE sary.chat_reports SET status = 'actioned', reviewed_at = now() WHERE id = '<report-id>';
```

## إجراء على المحتوى

```sql
-- حذف الرسالة (نفس الحذف الناعم اللي يسويه أمير الطلعة):
UPDATE sary.chat_messages
SET body = NULL, lat = NULL, lng = NULL, label = NULL, deleted_at = now(), deleted_by_role = 'leader'
WHERE id = '<message-id>' AND deleted_at IS NULL;
```

لحذف حساب مسيء بالكامل استخدم مسار «احذف حسابي» نفسه (`service.deleteAccount`) أو اطلبه من فريق الخادم؛
لا تحذف من `sary.users` يدويًا.

## الحظر

```sql
SELECT b.created_at, a.display_name AS blocker, z.display_name AS blocked
FROM sary.user_blocks b JOIN sary.users a ON a.id = b.blocker_id JOIN sary.users z ON z.id = b.blocked_id
ORDER BY b.created_at DESC LIMIT 100;
```

مدة الاحتفاظ: البلاغ يبقى بعد حذف الرسالة (لقطة النص في `body_snapshot`)، ويختفي مع حساب المبلّغ.
الهدف حسب إرشادات Apple: نراجع البلاغات خلال ٢٤ ساعة.
