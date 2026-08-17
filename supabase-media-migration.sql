-- V12 migration: sector images/videos
create table if not exists public.sector_media (
 id uuid primary key default gen_random_uuid(),
 sector_id text not null,
 title text not null default '',
 media_type text not null check (media_type in ('image','video')),
 storage_path text not null unique,
 public_url text not null default '',
 uploaded_by uuid not null references public.profiles(id) on delete cascade,
 created_at timestamptz not null default now()
);

alter table public.sector_media enable row level security;

drop policy if exists sector_media_select on public.sector_media;
create policy sector_media_select on public.sector_media for select to authenticated
using (public.can_access_sector(sector_id));

drop policy if exists sector_media_insert on public.sector_media;
create policy sector_media_insert on public.sector_media for insert to authenticated
with check ((public.is_manager() or (public.current_role()='servant' and public.current_sector()=sector_id)) and uploaded_by=auth.uid());

drop policy if exists sector_media_delete on public.sector_media;
create policy sector_media_delete on public.sector_media for delete to authenticated
using (public.is_manager() or uploaded_by=auth.uid());

insert into storage.buckets (id,name,public)
values ('sector-media','sector-media',false)
on conflict (id) do update set public=false;

drop policy if exists sector_media_storage_select on storage.objects;
create policy sector_media_storage_select on storage.objects for select to authenticated
using (bucket_id='sector-media' and (public.is_manager() or public.current_sector()=split_part(name,'/',1)));

drop policy if exists sector_media_storage_insert on storage.objects;
create policy sector_media_storage_insert on storage.objects for insert to authenticated
with check (bucket_id='sector-media' and (public.is_manager() or (public.current_role()='servant' and public.current_sector()=split_part(name,'/',1))));

drop policy if exists sector_media_storage_delete on storage.objects;
create policy sector_media_storage_delete on storage.objects for delete to authenticated
using (bucket_id='sector-media' and (public.is_manager() or owner_id::text=auth.uid()::text));
