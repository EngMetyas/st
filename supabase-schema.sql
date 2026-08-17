-- خِدمة V5 - امنع اختلاط القطاعات واربط الخادم بقطاعه
create extension if not exists pgcrypto;

do $$ begin create type public.app_role as enum ('site_admin','priest','secretary','servant','member'); exception when duplicate_object then null; end $$;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 username text not null unique,
 email text not null unique,
 role public.app_role not null default 'member',
 sector_id text,
 class_id uuid,
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create table if not exists public.classes (
 id uuid primary key default gen_random_uuid(),
 sector_id text not null,
 name text not null,
 servant_id uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now(),
 unique(sector_id,name)
);

alter table public.profiles drop constraint if exists profiles_class_fk;
alter table public.profiles add constraint profiles_class_fk foreign key (class_id) references public.classes(id) on delete set null;

create table if not exists public.sector_messages (
 id uuid primary key default gen_random_uuid(),
 sector_id text not null,
 sender_id uuid not null references public.profiles(id) on delete cascade,
 text text not null check (char_length(text) between 1 and 2000),
 created_at timestamptz not null default now()
);

create table if not exists public.attendance (
 id uuid primary key default gen_random_uuid(),
 class_id uuid not null references public.classes(id) on delete cascade,
 member_id uuid not null references public.profiles(id) on delete cascade,
 date date not null,
 present boolean not null default true,
 created_at timestamptz not null default now(),
 unique(class_id,member_id,date)
);

create table if not exists public.lessons (
 id uuid primary key default gen_random_uuid(),
 sector_id text not null,
 title text not null,
 content text not null,
 created_at timestamptz not null default now(),
 created_by uuid references public.profiles(id) on delete set null
);

create or replace function public.current_role() returns public.app_role
language sql stable security definer set search_path=public
as $$ select role from public.profiles where id=auth.uid() $$;

create or replace function public.current_sector() returns text
language sql stable security definer set search_path=public
as $$ select sector_id from public.profiles where id=auth.uid() $$;

create or replace function public.is_manager() returns boolean
language sql stable security definer set search_path=public
as $$ select coalesce(public.current_role() in ('site_admin','priest','secretary'),false) $$;

create or replace function public.can_access_sector(p_sector text) returns boolean
language sql stable security definer set search_path=public
as $$
 select coalesce(
   public.is_manager()
   or public.current_sector() = p_sector,
   false
 )
$$;

create or replace function public.can_manage_class(p_class uuid) returns boolean
language sql stable security definer set search_path=public
as $$
 select coalesce(
   public.is_manager()
   or exists(select 1 from public.classes c where c.id=p_class and c.servant_id=auth.uid()),
   false
 )
$$;

alter table public.profiles enable row level security;
alter table public.classes enable row level security;
alter table public.sector_messages enable row level security;
alter table public.attendance enable row level security;
alter table public.lessons enable row level security;

-- Profiles
 drop policy if exists profiles_select on public.profiles;
 create policy profiles_select on public.profiles for select to authenticated
 using (id=auth.uid() or public.is_manager() or sector_id=public.current_sector());
 drop policy if exists profiles_insert on public.profiles;
 create policy profiles_insert on public.profiles for insert to authenticated
 with check (
   public.is_manager()
   or (public.current_role()='servant' and role='member' and sector_id=public.current_sector())
 );
 drop policy if exists profiles_update on public.profiles;
 create policy profiles_update on public.profiles for update to authenticated
 using (
   id=auth.uid() or public.is_manager() or (public.current_role()='servant' and role='member' and sector_id=public.current_sector())
 )
 with check (
   id=auth.uid() or public.is_manager() or (public.current_role()='servant' and role='member' and sector_id=public.current_sector())
 );

-- Classes: creation/editing is for managers. Servants can only see classes in their sector.
 drop policy if exists classes_select on public.classes;
 create policy classes_select on public.classes for select to authenticated
 using (public.is_manager() or sector_id=public.current_sector());
 drop policy if exists classes_insert on public.classes;
 create policy classes_insert on public.classes for insert to authenticated
 with check (public.is_manager());
 drop policy if exists classes_update on public.classes;
 create policy classes_update on public.classes for update to authenticated
 using (public.is_manager()) with check (public.is_manager());

-- Sector chat
 drop policy if exists messages_select on public.sector_messages;
 create policy messages_select on public.sector_messages for select to authenticated
 using (public.can_access_sector(sector_id));
 drop policy if exists messages_insert on public.sector_messages;
 create policy messages_insert on public.sector_messages for insert to authenticated
 with check (sender_id=auth.uid() and public.can_access_sector(sector_id));

-- Attendance
 drop policy if exists attendance_select on public.attendance;
 create policy attendance_select on public.attendance for select to authenticated
 using (public.can_manage_class(class_id));
 drop policy if exists attendance_insert on public.attendance;
 create policy attendance_insert on public.attendance for insert to authenticated
 with check (public.can_manage_class(class_id));
 drop policy if exists attendance_update on public.attendance;
 create policy attendance_update on public.attendance for update to authenticated
 using (public.can_manage_class(class_id)) with check (public.can_manage_class(class_id));

-- Lessons: managers publish; users can read only their sector.
 drop policy if exists lessons_select on public.lessons;
 create policy lessons_select on public.lessons for select to authenticated
 using (public.can_access_sector(sector_id));
 drop policy if exists lessons_insert on public.lessons;
 create policy lessons_insert on public.lessons for insert to authenticated
 with check (public.is_manager() and public.can_access_sector(sector_id));
 drop policy if exists lessons_update on public.lessons;
 create policy lessons_update on public.lessons for update to authenticated
 using (public.is_manager()) with check (public.is_manager());

-- Keep member sector synchronized with the selected class.
create or replace function public.sync_member_sector()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if NEW.role='member' and NEW.class_id is not null then
    select sector_id into NEW.sector_id from public.classes where id=NEW.class_id;
  end if;
  return NEW;
end;
$$;
drop trigger if exists profiles_sync_member_sector on public.profiles;
create trigger profiles_sync_member_sector
before insert or update of class_id, role on public.profiles
for each row execute function public.sync_member_sector();

-- A class cannot be assigned to a servant from another sector.
create or replace function public.validate_class_servant_sector()
returns trigger language plpgsql security definer set search_path=public as $$
declare servant_sector text;
begin
  if NEW.servant_id is not null then
    select sector_id into servant_sector from public.profiles where id=NEW.servant_id and role='servant';
    if servant_sector is null or servant_sector <> NEW.sector_id then
      raise exception 'الخادم يجب أن يكون من نفس قطاع الفصل';
    end if;
  end if;
  return NEW;
end;
$$;
drop trigger if exists classes_validate_servant_sector on public.classes;
create trigger classes_validate_servant_sector
before insert or update of servant_id, sector_id on public.classes
for each row execute function public.validate_class_servant_sector();

-- Backfill existing members that were created before sector assignment was enforced.
update public.profiles p
set sector_id=c.sector_id
from public.classes c
where p.class_id=c.id and p.role='member' and (p.sector_id is null or p.sector_id<>c.sector_id);

-- =========================
-- V7: Church services and activities
-- =========================
create table if not exists public.announcements (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 body text not null,
 sector_id text,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);

create table if not exists public.events (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 description text not null default '',
 starts_at timestamptz not null,
 location text,
 sector_id text,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);

create table if not exists public.prayer_requests (
 id uuid primary key default gen_random_uuid(),
 requester_id uuid not null references public.profiles(id) on delete cascade,
 sector_id text not null,
 title text not null,
 details text not null default '',
 status text not null default 'open' check (status in ('open','answered','closed')),
 created_at timestamptz not null default now()
);

create table if not exists public.service_resources (
 id uuid primary key default gen_random_uuid(),
 kind text not null check (kind in ('bible','hymn')),
 title text not null,
 body text not null,
 sector_id text,
 created_by uuid references public.profiles(id) on delete set null,
 created_at timestamptz not null default now()
);

create table if not exists public.visits (
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.profiles(id) on delete cascade,
 servant_id uuid not null references public.profiles(id) on delete cascade,
 visit_date date not null,
 notes text not null default '',
 status text not null default 'completed',
 created_at timestamptz not null default now()
);

alter table public.announcements enable row level security;
alter table public.events enable row level security;
alter table public.prayer_requests enable row level security;
alter table public.service_resources enable row level security;
alter table public.visits enable row level security;

-- Announcements
 drop policy if exists announcements_select on public.announcements;
 create policy announcements_select on public.announcements for select to authenticated
 using (sector_id is null or public.can_access_sector(sector_id));
 drop policy if exists announcements_insert on public.announcements;
 create policy announcements_insert on public.announcements for insert to authenticated
 with check (public.is_manager() and created_by=auth.uid());
 drop policy if exists announcements_update on public.announcements;
 create policy announcements_update on public.announcements for update to authenticated
 using (public.is_manager()) with check (public.is_manager());
 drop policy if exists announcements_delete on public.announcements;
 create policy announcements_delete on public.announcements for delete to authenticated
 using (public.is_manager());

-- Events
 drop policy if exists events_select on public.events;
 create policy events_select on public.events for select to authenticated
 using (sector_id is null or public.can_access_sector(sector_id));
 drop policy if exists events_insert on public.events;
 create policy events_insert on public.events for insert to authenticated
 with check (public.is_manager() and created_by=auth.uid());
 drop policy if exists events_update on public.events;
 create policy events_update on public.events for update to authenticated
 using (public.is_manager()) with check (public.is_manager());
 drop policy if exists events_delete on public.events;
 create policy events_delete on public.events for delete to authenticated
 using (public.is_manager());

-- Prayer requests
 drop policy if exists prayer_select on public.prayer_requests;
 create policy prayer_select on public.prayer_requests for select to authenticated
 using (requester_id=auth.uid() or public.can_access_sector(sector_id));
 drop policy if exists prayer_insert on public.prayer_requests;
 create policy prayer_insert on public.prayer_requests for insert to authenticated
 with check (requester_id=auth.uid() and public.can_access_sector(sector_id));
 drop policy if exists prayer_update on public.prayer_requests;
 create policy prayer_update on public.prayer_requests for update to authenticated
 using (public.is_manager() or (public.current_role()='servant' and public.current_sector()=sector_id))
 with check (public.is_manager() or (public.current_role()='servant' and public.current_sector()=sector_id));

-- Resources
 drop policy if exists resources_select on public.service_resources;
 create policy resources_select on public.service_resources for select to authenticated
 using (sector_id is null or public.can_access_sector(sector_id));
 drop policy if exists resources_insert on public.service_resources;
 create policy resources_insert on public.service_resources for insert to authenticated
 with check (public.is_manager() and created_by=auth.uid());
 drop policy if exists resources_update on public.service_resources;
 create policy resources_update on public.service_resources for update to authenticated
 using (public.is_manager()) with check (public.is_manager());
 drop policy if exists resources_delete on public.service_resources;
 create policy resources_delete on public.service_resources for delete to authenticated
 using (public.is_manager());

-- Visits
 drop policy if exists visits_select on public.visits;
 create policy visits_select on public.visits for select to authenticated
 using (
   public.is_manager()
   or servant_id=auth.uid()
   or (public.current_role()='servant' and exists(select 1 from public.profiles m where m.id=member_id and m.sector_id=public.current_sector()))
   or (public.current_role()='member' and member_id=auth.uid())
 );
 drop policy if exists visits_insert on public.visits;
 create policy visits_insert on public.visits for insert to authenticated
 with check (
   (public.is_manager() or (public.current_role()='servant' and public.current_sector()=(select sector_id from public.profiles where id=member_id)))
   and servant_id=auth.uid()
 );
 drop policy if exists visits_update on public.visits;
 create policy visits_update on public.visits for update to authenticated
 using (public.is_manager() or servant_id=auth.uid())
 with check (public.is_manager() or servant_id=auth.uid());

-- Useful indexes
create index if not exists idx_announcements_sector_created on public.announcements(sector_id, created_at desc);
create index if not exists idx_events_sector_starts on public.events(sector_id, starts_at);
create index if not exists idx_prayer_sector_created on public.prayer_requests(sector_id, created_at desc);
create index if not exists idx_resources_sector_created on public.service_resources(sector_id, created_at desc);
create index if not exists idx_visits_member_date on public.visits(member_id, visit_date desc);

-- Realtime publication for sector chat (safe to run repeatedly only if table not already a member).
do $$ begin
  alter publication supabase_realtime add table public.sector_messages;
exception when duplicate_object then null; when undefined_object then null; end $$;

-- =========================
-- Staff transfer between sectors
-- =========================
create or replace function public.transfer_servant(p_servant_id uuid, p_new_sector text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  actor_role public.app_role;
  servant_role public.app_role;
  old_sector text;
  unassigned_count integer := 0;
begin
  select role into actor_role from public.profiles where id=auth.uid() and active=true;
  if actor_role not in ('site_admin','priest','secretary') then
    raise exception 'ليس لديك صلاحية نقل الخدام';
  end if;

  if p_new_sector not in ('baby','primary','prep','secondary','youth') then
    raise exception 'القطاع الجديد غير صالح';
  end if;

  select role, sector_id into servant_role, old_sector
  from public.profiles
  where id=p_servant_id and active=true;

  if servant_role is null or servant_role <> 'servant' then
    raise exception 'الحساب المحدد ليس حساب خادم نشط';
  end if;

  if old_sector = p_new_sector then
    raise exception 'الخادم موجود بالفعل في هذا القطاع';
  end if;

  update public.classes
  set servant_id=null
  where servant_id=p_servant_id;
  get diagnostics unassigned_count = row_count;

  update public.profiles
  set sector_id=p_new_sector, class_id=null
  where id=p_servant_id;

  return jsonb_build_object(
    'success', true,
    'servant_id', p_servant_id,
    'old_sector', old_sector,
    'new_sector', p_new_sector,
    'unassigned_classes', unassigned_count
  );
end;
$$;

grant execute on function public.transfer_servant(uuid,text) to authenticated;

-- =========================
-- V12: Sector media (images & videos)
-- =========================
create table if not exists public.sector_media (
 id uuid primary key default gen_random_uuid(),
 sector_id text not null,
 title text not null default '',
 media_type text not null check (media_type in ('image','video')),
 storage_path text not null unique,
 public_url text not null,
 uploaded_by uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);

alter table public.sector_media enable row level security;

drop policy if exists sector_media_select on public.sector_media;
create policy sector_media_select on public.sector_media
for select to authenticated
using (public.can_access_sector(sector_id));

drop policy if exists sector_media_insert on public.sector_media;
create policy sector_media_insert on public.sector_media
for insert to authenticated
with check ((public.is_manager() or public.current_role()='servant' and public.current_sector()=sector_id) and uploaded_by=auth.uid());

drop policy if exists sector_media_delete on public.sector_media;
create policy sector_media_delete on public.sector_media
for delete to authenticated
using (public.is_manager() or uploaded_by=auth.uid());

-- Public bucket is used only for the already-authorized sector media gallery.
insert into storage.buckets (id, name, public)
values ('sector-media','sector-media',false)
on conflict (id) do update set public=false;


drop policy if exists sector_media_storage_select on storage.objects;
create policy sector_media_storage_select on storage.objects
for select to authenticated
using (
  bucket_id='sector-media'
  and (
    public.is_manager()
    or public.current_sector()=split_part(name,'/',1)
  )
);

drop policy if exists sector_media_storage_insert on storage.objects;
create policy sector_media_storage_insert on storage.objects
for insert to authenticated
with check (
  bucket_id='sector-media'
  and (
    public.is_manager()
    or (public.current_role()='servant' and public.current_sector()=split_part(name,'/',1))
  )
);

drop policy if exists sector_media_storage_delete on storage.objects;
create policy sector_media_storage_delete on storage.objects
for delete to authenticated
using (
  bucket_id='sector-media'
  and (
    public.is_manager()
    or owner_id::text=auth.uid()::text
  )
);
