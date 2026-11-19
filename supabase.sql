-- Warm Media — Supabase schema
-- شغّل هذا الملف مرة واحدة من Supabase Dashboard > SQL Editor.
-- لا تستخدم service_role key في الواجهة الأمامية.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'user' check (role in ('user','admin')),
  created_at timestamptz not null default now()
);

create table if not exists public.user_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  settings jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.site_settings (
  setting_key text primary key,
  setting_value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.news (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  excerpt text,
  body text,
  image_url text,
  category text,
  status text not null default 'draft' check (status in ('draft','published','archived')),
  is_breaking boolean not null default false,
  author_id uuid references auth.users(id),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists news_published_idx on public.news(status,published_at desc);
create index if not exists news_category_idx on public.news(category,published_at desc);

create table if not exists public.advertisements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  image_url text,
  target_url text,
  starts_at timestamptz,
  ends_at timestamptz,
  enabled boolean not null default false,
  impressions bigint not null default 0,
  clicks bigint not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.discussion_rooms (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  is_open boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.room_messages (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.discussion_rooms(id) on delete cascade,
  user_id uuid references auth.users(id),
  message text not null check (char_length(message) between 1 and 5000),
  anonymous_until timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists room_messages_room_created_idx on public.room_messages(room_id,created_at desc);

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references auth.users(id),
  target_type text not null,
  target_id uuid not null,
  reason text not null,
  status text not null default 'open' check (status in ('open','reviewing','resolved','rejected')),
  created_at timestamptz not null default now()
);

-- Helper: role is read from protected profiles row. Users cannot update their own role.
create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path = public
as $$
  select exists(select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin');
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

alter table public.profiles enable row level security;
alter table public.user_preferences enable row level security;
alter table public.site_settings enable row level security;
alter table public.news enable row level security;
alter table public.advertisements enable row level security;
alter table public.discussion_rooms enable row level security;
alter table public.room_messages enable row level security;
alter table public.reports enable row level security;

drop policy if exists "profiles read authenticated" on public.profiles;
create policy "profiles read authenticated" on public.profiles for select to authenticated using (id=auth.uid() or public.is_admin());
drop policy if exists "profile self insert" on public.profiles;
create policy "profile self insert" on public.profiles for insert to authenticated with check (id=auth.uid() and role='user');
drop policy if exists "profile self update safe" on public.profiles;
create policy "profile self update safe" on public.profiles for update to authenticated using (id=auth.uid()) with check (id=auth.uid() and role='user');

drop policy if exists "prefs own access" on public.user_preferences;
create policy "prefs own access" on public.user_preferences for all to authenticated using (user_id=auth.uid()) with check (user_id=auth.uid());

drop policy if exists "settings public read" on public.site_settings;
create policy "settings public read" on public.site_settings for select to anon,authenticated using (true);
drop policy if exists "settings admin write" on public.site_settings;
create policy "settings admin write" on public.site_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "published news public read" on public.news;
create policy "published news public read" on public.news for select to anon,authenticated using (status='published' or public.is_admin());
drop policy if exists "news admin write" on public.news;
create policy "news admin write" on public.news for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "active ads public read" on public.advertisements;
create policy "active ads public read" on public.advertisements for select to anon,authenticated
using (enabled=true and (starts_at is null or starts_at<=now()) and (ends_at is null or ends_at>=now()) or public.is_admin());
drop policy if exists "ads admin write" on public.advertisements;
create policy "ads admin write" on public.advertisements for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "rooms read" on public.discussion_rooms;
create policy "rooms read" on public.discussion_rooms for select to anon,authenticated using (is_open=true or public.is_admin());
drop policy if exists "rooms admin write" on public.discussion_rooms;
create policy "rooms admin write" on public.discussion_rooms for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists "messages read authenticated" on public.room_messages;
create policy "messages read authenticated" on public.room_messages for select to authenticated using (true);
drop policy if exists "messages own insert" on public.room_messages;
create policy "messages own insert" on public.room_messages for insert to authenticated with check (user_id=auth.uid());
drop policy if exists "messages own or admin delete" on public.room_messages;
create policy "messages own or admin delete" on public.room_messages for delete to authenticated using (user_id=auth.uid() or public.is_admin());

drop policy if exists "reports own insert" on public.reports;
create policy "reports own insert" on public.reports for insert to authenticated with check (reporter_id=auth.uid());
drop policy if exists "reports owner/admin read" on public.reports;
create policy "reports owner/admin read" on public.reports for select to authenticated using (reporter_id=auth.uid() or public.is_admin());
drop policy if exists "reports admin update" on public.reports;
create policy "reports admin update" on public.reports for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Create profile automatically for every new auth user. Role always starts as user.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.profiles(id,display_name,role)
  values(new.id, coalesce(new.raw_user_meta_data->>'display_name','مستخدم جديد'),'user')
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

-- Storage buckets. Public read for public media; writes restricted to admins.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values
 ('branding','branding',true,5242880,array['image/png','image/jpeg','image/webp','image/svg+xml']),
 ('site-banners','site-banners',true,8388608,array['image/png','image/jpeg','image/webp']),
 ('news-images','news-images',true,8388608,array['image/png','image/jpeg','image/webp']),
 ('advertisements','advertisements',true,8388608,array['image/png','image/jpeg','image/webp']),
 ('admin-assets','admin-assets',false,8388608,array['image/png','image/jpeg','image/webp'])
on conflict (id) do nothing;

drop policy if exists "public read public media" on storage.objects;
create policy "public read public media" on storage.objects for select to anon,authenticated
using (bucket_id in ('branding','site-banners','news-images','advertisements'));
drop policy if exists "admin upload media" on storage.objects;
create policy "admin upload media" on storage.objects for insert to authenticated
with check (public.is_admin() and bucket_id in ('branding','site-banners','news-images','advertisements','admin-assets'));
drop policy if exists "admin update media" on storage.objects;
create policy "admin update media" on storage.objects for update to authenticated
using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin delete media" on storage.objects;
create policy "admin delete media" on storage.objects for delete to authenticated
using (public.is_admin());

-- تفعيل Realtime للجداول التي تحتاج تحديثًا فوريًا (إذا لم تكن مضافة بالفعل).
do $$
begin
  alter publication supabase_realtime add table public.news;
exception when duplicate_object then null;
when others then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.room_messages;
exception when duplicate_object then null;
when others then null;
end $$;

-- ملاحظة: بعد إنشاء حسابك، امنح حساب الأدمن يدويًا من SQL Editor فقط:
-- update public.profiles set role='admin' where id='AUTH_USER_UUID';
-- لا تضف واجهة تسمح للمستخدم بتغيير role بنفسه.
