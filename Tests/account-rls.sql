-- Runs against a dedicated, empty test database. Everything is rolled back.
begin;
create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;
create schema auth;
create table auth.users (id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$
    select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
grant usage on schema auth to authenticated, anon, service_role;
insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222');
\ir ../supabase/migrations/202610140001_email_accounts.sql
\ir ../supabase/migrations/202610140002_baidu_storage.sql
insert into public.font_admins (user_id) values ('11111111-1111-1111-1111-111111111111');
insert into public.font_favorites(user_id,font_id) values ('22222222-2222-2222-2222-222222222222',repeat('a',64));
insert into public.font_downloads(user_id,font_id,file_name) values ('22222222-2222-2222-2222-222222222222',repeat('a',64),'Other.ttf');

set local role authenticated;
select set_config('request.jwt.claim.sub','11111111-1111-1111-1111-111111111111',true);
insert into public.font_favorites(font_id) values (repeat('b',64));
insert into public.font_downloads(font_id,file_name) values (repeat('b',64),'Mine.ttf');
update public.font_downloads set file_name='Mine-updated.ttf' where font_id=repeat('b',64);
do $$ begin
    if (select count(*) from public.font_favorites) <> 1 then raise exception 'Favorites are not isolated'; end if;
    if (select count(*) from public.font_downloads) <> 1 then raise exception 'Downloads are not isolated'; end if;
    if (select count(*) from public.font_admins) <> 1 then raise exception 'Own admin membership unreadable'; end if;
    begin
        insert into public.font_favorites(user_id,font_id) values ('22222222-2222-2222-2222-222222222222',repeat('c',64));
        raise exception 'Cross-user favorite insert was allowed';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.font_downloads(user_id,font_id,file_name) values ('22222222-2222-2222-2222-222222222222',repeat('c',64),'Injected.ttf');
        raise exception 'Cross-user download insert was allowed';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.font_admins(user_id) values ('22222222-2222-2222-2222-222222222222');
        raise exception 'Client admin promotion was allowed';
    exception when insufficient_privilege then null; end;
    begin
        insert into public.font_upload_history(user_id,font_id,file_name,display_name,storage_reference)
            values ('11111111-1111-1111-1111-111111111111',repeat('b',64),'Fake.ttf','Fake','fake');
        raise exception 'Client audit forgery was allowed';
    exception when insufficient_privilege then null; end;
end $$;
delete from public.font_favorites where user_id='22222222-2222-2222-2222-222222222222';
update public.font_downloads set file_name='Changed.ttf' where user_id='22222222-2222-2222-2222-222222222222';

select set_config('request.jwt.claim.sub','22222222-2222-2222-2222-222222222222',true);
do $$ begin
    if (select count(*) from public.font_favorites) <> 1 then raise exception 'Other favorites were deleted'; end if;
    if (select file_name from public.font_downloads) <> 'Other.ttf' then raise exception 'Other download record was changed'; end if;
    if (select count(*) from public.font_admins) <> 0 then raise exception 'Non-admin can read someone else membership'; end if;
end $$;

set local role anon;
do $$ begin
    begin
        perform * from public.font_downloads;
        raise exception 'Anonymous personal-record access was allowed';
    exception when insufficient_privilege then null; end;
    begin
        perform * from public.baidu_connections;
        raise exception 'Anonymous Baidu credential access was allowed';
    exception when insufficient_privilege then null; end;
    begin
        perform public.claim_baidu_refresh();
        raise exception 'Client refresh-lease access was allowed';
    exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
\echo 'PASS: PostgreSQL user isolation, administrator protection, audit integrity and anonymous access'
