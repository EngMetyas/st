# خِدمة V5 — ربط Supabase وVercel

## 1) قاعدة البيانات

هذه النسخة تحتاج تشغيل **كل محتوى `supabase-schema.sql` مرة واحدة** في Supabase SQL Editor.

> إذا كانت الجداول موجودة من النسخة السابقة، شغّل الملف كاملًا أيضًا؛ يحتوي على `drop policy if exists` و`create or replace function` و`create table if not exists` ليحدّث الصلاحيات ويضيف الحضور والدروس.

الجداول الأساسية:
- `profiles`
- `classes`
- `sector_messages`
- `attendance`
- `lessons`

### ما الذي تغير؟
- الخادم يرى قطاعه فقط.
- المخدوم يرى قطاعه فقط.
- الخادم لا يستطيع إنشاء مخدوم خارج قطاعه.
- لا يمكن تعيين خادم لفصل في قطاع مختلف.
- شات القطاع مقيد بالقطاع.
- الحضور مربوط بالفصل والخادم المسؤول عنه.
- الدروس مرتبطة بالقطاع.

## 2) Vercel Environment Variables

ضع:

`VITE_SUPABASE_URL` = Project URL

`VITE_SUPABASE_ANON_KEY` = Supabase publishable/anon key المستخدم في الواجهة

`SUPABASE_SERVICE_ROLE_KEY` = Supabase secret/service_role key، ويستخدم فقط داخل `/api/create-user` على السيرفر.

لا تضع المفتاح السري داخل GitHub أو أي متغير `VITE_*`.

## 3) الحساب الأول

أنشئ أول مستخدم من Supabase Authentication ثم أنشئ صفه في `profiles` بدور `site_admin` كما في النسخة السابقة.

## 4) النشر

بعد تعديل Environment Variables أو قاعدة البيانات، اعمل Redeploy من Vercel.

## 5) الاستخدام

- مسؤول الموقع/أب الكنيسة/أمين الخدام: إدارة القطاعات والفصول.
- الخادم: يرى قطاعه، وفصوله، ومخدوميه، وشات قطاعه.
- المخدوم: يرى بياناته وشات قطاعه.
- نقل المخدوم للقطاع الأعلى متاح للإدارة.
- الحضور يعمل على مستوى الفصل والتاريخ.
- المحتوى الروحي يعمل على مستوى القطاع.

## V12 — صور وفيديوهات القطاعات
1. في Supabase افتح SQL Editor وشغّل `supabase-media-migration.sql` مرة واحدة.
2. هذا ينشئ جدول `sector_media` وStorage bucket خاصًا باسم `sector-media`.
3. مسؤول الموقع/أب الكنيسة/أمين الخدام يمكنهم رفع الوسائط لأي قطاع، والخادم يمكنه الرفع لقطاعه فقط.
4. الوسائط مخزنة في Supabase Storage كـ private bucket، ويتم عرضها بروابط موقعة مؤقتة.
5. الحد الأقصى في الواجهة 50MB لكل ملف.
