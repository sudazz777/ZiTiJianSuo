-- Auth owns passwords and email verification. The application never stores them.
create table public.font_admins (
    user_id uuid primary key references auth.users(id) on delete cascade,
    created_at timestamptz not null default now()
);

create table public.font_favorites (
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    font_id text not null check (font_id ~ '^[0-9a-f]{64}$'),
    created_at timestamptz not null default now(),
    primary key (user_id, font_id)
);

create table public.font_downloads (
    user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
    font_id text not null check (font_id ~ '^[0-9a-f]{64}$'),
    file_name text not null check (length(file_name) between 1 and 240),
    downloaded_at timestamptz not null default now(),
    primary key (user_id, font_id)
);

create table public.font_upload_history (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references auth.users(id) on delete cascade,
    font_id text not null check (font_id ~ '^[0-9a-f]{64}$'),
    file_name text not null,
    display_name text not null,
    storage_reference text not null,
    uploaded_at timestamptz not null default now()
);

alter table public.font_admins enable row level security;
alter table public.font_favorites enable row level security;
alter table public.font_downloads enable row level security;
alter table public.font_upload_history enable row level security;

revoke all on public.font_admins, public.font_favorites, public.font_downloads, public.font_upload_history from anon, authenticated;
grant select on public.font_admins, public.font_upload_history to authenticated;
grant select, insert, delete on public.font_favorites to authenticated;
grant select, insert, update on public.font_downloads to authenticated;
grant all on public.font_admins, public.font_favorites, public.font_downloads, public.font_upload_history to service_role;

create policy "Read own admin membership" on public.font_admins
    for select to authenticated using ((select auth.uid()) = user_id);
-- There is deliberately no client-side INSERT or UPDATE policy for admins.
create policy "Read own favorites" on public.font_favorites
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "Add own favorites" on public.font_favorites
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Delete own favorites" on public.font_favorites
    for delete to authenticated using ((select auth.uid()) = user_id);
create policy "Read own downloads" on public.font_downloads
    for select to authenticated using ((select auth.uid()) = user_id);
create policy "Record own downloads" on public.font_downloads
    for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Update own downloads" on public.font_downloads
    for update to authenticated using ((select auth.uid()) = user_id)
    with check ((select auth.uid()) = user_id);
create policy "Read own uploads" on public.font_upload_history
    for select to authenticated using ((select auth.uid()) = user_id);

create index font_downloads_user_time on public.font_downloads(user_id, downloaded_at desc);
create index font_upload_history_user_time on public.font_upload_history(user_id, uploaded_at desc);
