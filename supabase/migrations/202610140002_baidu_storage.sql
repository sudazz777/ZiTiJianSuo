create table public.font_library (
    id text primary key check (id ~ '^[0-9a-f]{64}$'),
    display_name text not null,
    file_name text not null,
    size bigint not null check (size > 0 and size <= 10485760),
    sha256 text not null check (sha256 = id),
    post_script_names jsonb not null default '[]',
    uploaded_at timestamptz not null default now()
);
create table public.font_files (
    font_id text primary key references public.font_library(id) on delete cascade,
    fs_id text not null check (fs_id ~ '^[0-9]+$'),
    path text not null
);
create table public.baidu_connections (
    id text primary key check (id = 'font-library'),
    encrypted_tokens jsonb not null,
    refresh_lock_until timestamptz
);
create table public.baidu_oauth_states (
    state uuid primary key,
    user_id uuid not null references auth.users(id) on delete cascade,
    expires_at timestamptz not null
);
alter table public.font_library enable row level security;
alter table public.font_files enable row level security;
alter table public.baidu_connections enable row level security;
alter table public.baidu_oauth_states enable row level security;
revoke all on public.font_library, public.font_files, public.baidu_connections, public.baidu_oauth_states from anon, authenticated;
grant select on public.font_library to anon, authenticated;
grant all on public.font_library, public.font_files, public.baidu_connections, public.baidu_oauth_states to service_role;
create policy "Read published font metadata" on public.font_library for select to anon, authenticated using (true);
-- There are no client policies for netdisk identities, OAuth states or tokens.

create function public.claim_baidu_refresh() returns boolean
language plpgsql security definer set search_path = public as $$
declare updated integer;
begin
    update public.baidu_connections set refresh_lock_until = now() + interval '90 seconds'
      where id = 'font-library' and (refresh_lock_until is null or refresh_lock_until < now());
    get diagnostics updated = row_count;
    return updated = 1;
end $$;
create function public.release_baidu_refresh() returns void
language sql security definer set search_path = public as $$
    update public.baidu_connections set refresh_lock_until = null where id = 'font-library';
$$;

create function public.publish_baidu_font(p_user uuid, p_font jsonb, p_storage jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare result jsonb;
begin
    if not exists(select 1 from public.font_admins where user_id = p_user) then
        raise exception 'User is not a font administrator';
    end if;
    insert into public.font_library(id,display_name,file_name,size,sha256,post_script_names,uploaded_at)
      values(p_font->>'id',p_font->>'displayName',p_font->>'fileName',(p_font->>'size')::bigint,
             p_font->>'sha256',p_font->'postScriptNames',(p_font->>'uploadedAt')::timestamptz)
      on conflict(id) do update set display_name=excluded.display_name;
    insert into public.font_files(font_id,fs_id,path)
      values(p_font->>'id',p_storage->>'fs_id',p_storage->>'path')
      on conflict(font_id) do update set fs_id=excluded.fs_id,path=excluded.path;
    delete from public.font_library where lower(file_name)=lower(p_font->>'fileName') and id<>p_font->>'id';
    insert into public.font_upload_history(user_id,font_id,file_name,display_name,storage_reference)
      values(p_user,p_font->>'id',p_font->>'fileName',p_font->>'displayName',p_storage->>'fs_id');
    select jsonb_build_object('schemaVersion',1,'fonts',coalesce(jsonb_agg(jsonb_build_object(
      'id',id,'displayName',display_name,'fileName',file_name,
      'path','fonts/files/'||id||'.'||lower(regexp_replace(file_name,'^.*\.','')),
      'size',size,'sha256',sha256,'postScriptNames',post_script_names,'uploadedAt',uploaded_at
    ) order by uploaded_at desc),'[]'::jsonb)) into result from public.font_library;
    if octet_length(result::text) > 921600 then raise exception 'Font catalog capacity exceeded'; end if;
    return result;
end $$;
revoke all on function public.claim_baidu_refresh(),public.release_baidu_refresh(),public.publish_baidu_font(uuid,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.claim_baidu_refresh(),public.release_baidu_refresh(),public.publish_baidu_font(uuid,jsonb,jsonb) to service_role;
