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
