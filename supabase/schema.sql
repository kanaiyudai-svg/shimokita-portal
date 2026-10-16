-- みんカレポータル: データベースの形の控え
--
-- 2026-10-16 に、本番の Supabase から読み取りだけの問い合わせで書き出した。データは入っていない。
-- 表、表の決まり、索引、関数、トリガー、行単位の権限、権限の付け方、リアルタイム配信の設定を、作り直せる順に並べてある。
-- Supabase のプロジェクトが消えたときや、別のプロジェクトへ移すときに、新しいプロジェクトの SQL Editor に流して形を作り直す。
-- 先に流すもの: なし。このファイルだけで形がそろう。ただし次はこのファイルに入っていないので、別に設定する。
--   ・認証の設定。匿名ログインを有効にすること、事務局のアカウント
--   ・app_secrets の中身。合言葉のハッシュと通知メールの宛先URL。値はここに書かない
--   ・データそのもの。議案、コメント、スタンプ、評価、提出者の情報
-- 書き出しに使った問い合わせは、同じフォルダの export_schema.sql。形を変えたら、書き出し直してこのファイルを差し替える。
--
-- ---- ここから書き出し ----
-- ===== 1. 拡張機能 =====

-- pg_net
create extension if not exists pg_net with schema public;

-- pg_stat_statements
create extension if not exists pg_stat_statements with schema extensions;

-- pgcrypto
create extension if not exists pgcrypto with schema extensions;

-- supabase_vault
create extension if not exists supabase_vault with schema vault;

-- uuid-ossp
create extension if not exists "uuid-ossp" with schema extensions;

-- ===== 3. 表 =====

-- app_secrets
create table public.app_secrets (
  name text not null,
  value text not null
);

-- comments
create table public.comments (
  id uuid default gen_random_uuid() not null,
  item_id text not null,
  author text default 'あなた'::text not null,
  content text not null,
  created_at timestamp with time zone default now(),
  user_id uuid default auth.uid()
);

-- proposal_notifications
create table public.proposal_notifications (
  id bigint generated always as identity not null,
  item_id text not null,
  created_at timestamp with time zone default now() not null,
  sent_at timestamp with time zone
);

-- proposal_reviews
create table public.proposal_reviews (
  id uuid default gen_random_uuid() not null,
  item_id text not null,
  reviewer_id uuid default auth.uid() not null,
  vote text not null,
  reason text default ''::text not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

-- proposal_submissions
create table public.proposal_submissions (
  id uuid default gen_random_uuid() not null,
  item_id text not null,
  submitter_name text not null,
  submitter_email text not null,
  extra_note text default ''::text not null,
  created_at timestamp with time zone default now() not null
);

-- proposals
create table public.proposals (
  id uuid default gen_random_uuid() not null,
  item_id text not null,
  title text not null,
  description text default ''::text not null,
  status text default '提案中'::text not null,
  emojis jsonb default '["👍", "🤔", "😟", "🙌"]'::jsonb,
  sort_order integer default 0,
  created_at timestamp with time zone default now(),
  updated_at timestamp with time zone default now(),
  minutes text default ''::text,
  summary text default ''::text,
  gdoc_url text default ''::text,
  is_published boolean default true
);

-- reactions
create table public.reactions (
  id uuid default gen_random_uuid() not null,
  item_id text not null,
  emoji text not null,
  created_at timestamp with time zone default now(),
  user_id uuid default auth.uid()
);

-- staff
create table public.staff (
  user_id uuid not null,
  name text not null,
  created_at timestamp with time zone default now() not null
);

-- ===== 4. 表の決まり（主キー、一意、チェック） =====

-- app_secrets.app_secrets_pkey
alter table public.app_secrets add constraint app_secrets_pkey PRIMARY KEY (name);

-- comments.comments_pkey
alter table public.comments add constraint comments_pkey PRIMARY KEY (id);

-- proposal_notifications.proposal_notifications_pkey
alter table public.proposal_notifications add constraint proposal_notifications_pkey PRIMARY KEY (id);

-- proposal_reviews.proposal_reviews_check
alter table public.proposal_reviews add constraint proposal_reviews_check CHECK (((vote = 'yes'::text) OR (length(btrim(reason)) > 0)));

-- proposal_reviews.proposal_reviews_item_id_reviewer_id_key
alter table public.proposal_reviews add constraint proposal_reviews_item_id_reviewer_id_key UNIQUE (item_id, reviewer_id);

-- proposal_reviews.proposal_reviews_pkey
alter table public.proposal_reviews add constraint proposal_reviews_pkey PRIMARY KEY (id);

-- proposal_reviews.proposal_reviews_reason_check
alter table public.proposal_reviews add constraint proposal_reviews_reason_check CHECK ((length(reason) <= 1000));

-- proposal_reviews.proposal_reviews_vote_check
alter table public.proposal_reviews add constraint proposal_reviews_vote_check CHECK ((vote = ANY (ARRAY['yes'::text, 'no'::text])));

-- proposal_submissions.proposal_submissions_item_id_key
alter table public.proposal_submissions add constraint proposal_submissions_item_id_key UNIQUE (item_id);

-- proposal_submissions.proposal_submissions_pkey
alter table public.proposal_submissions add constraint proposal_submissions_pkey PRIMARY KEY (id);

-- proposals.proposals_item_id_key
alter table public.proposals add constraint proposals_item_id_key UNIQUE (item_id);

-- proposals.proposals_pkey
alter table public.proposals add constraint proposals_pkey PRIMARY KEY (id);

-- proposals.proposals_status_check
alter table public.proposals add constraint proposals_status_check CHECK ((status = ANY (ARRAY['提案中'::text, '取り上げ確定'::text, '議論中'::text, '決議済み'::text])));

-- reactions.reactions_pkey
alter table public.reactions add constraint reactions_pkey PRIMARY KEY (id);

-- staff.staff_pkey
alter table public.staff add constraint staff_pkey PRIMARY KEY (user_id);

-- ===== 5. 表のつながり（外部キー） =====

-- comments.comments_user_id_fkey
alter table public.comments add constraint comments_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- proposal_reviews.proposal_reviews_reviewer_id_fkey
alter table public.proposal_reviews add constraint proposal_reviews_reviewer_id_fkey FOREIGN KEY (reviewer_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- reactions.reactions_user_id_fkey
alter table public.reactions add constraint reactions_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;

-- staff.staff_user_id_fkey
alter table public.staff add constraint staff_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- ===== 6. 索引 =====

-- proposal_notifications_pending
CREATE INDEX proposal_notifications_pending ON public.proposal_notifications USING btree (id) WHERE (sent_at IS NULL);

-- reactions_item_emoji_user_uniq
CREATE UNIQUE INDEX reactions_item_emoji_user_uniq ON public.reactions USING btree (item_id, emoji, user_id);

-- ===== 8. 関数 =====

-- ack_proposal_notifications(p_secret text, p_ids bigint[])
CREATE OR REPLACE FUNCTION public.ack_proposal_notifications(p_secret text, p_ids bigint[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_count integer;
begin
  if not public.check_form_secret(p_secret) then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  update public.proposal_notifications set sent_at = now()
  where id = any(coalesce(p_ids, '{}'::bigint[])) and sent_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end
$function$
;

-- check_form_secret(p_secret text)
CREATE OR REPLACE FUNCTION public.check_form_secret(p_secret text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.app_secrets
    where name = 'form_secret'
      and value = encode(sha256(convert_to(coalesce(p_secret, ''), 'UTF8')), 'hex')
  )
$function$
;

-- cleanup_proposal_children()
CREATE OR REPLACE FUNCTION public.cleanup_proposal_children()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  delete from public.proposal_submissions where item_id = old.item_id;
  delete from public.proposal_reviews where item_id = old.item_id;
  return old;
end
$function$
;

-- enqueue_proposal_notification()
CREATE OR REPLACE FUNCTION public.enqueue_proposal_notification()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_url text;
begin
  insert into public.proposal_notifications (item_id) values (new.item_id);

  select value into v_url from public.app_secrets where name = 'mail_relay_url';
  if v_url is not null and v_url <> '' then
    begin
      perform net.http_post(
        url     := v_url,
        body    := '{}'::jsonb,
        headers := '{"Content-Type": "application/json"}'::jsonb
      );
    exception when others then
      null;
    end;
  end if;
  return new;
end
$function$
;

-- fetch_proposal_notifications(p_secret text)
CREATE OR REPLACE FUNCTION public.fetch_proposal_notifications(p_secret text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if not public.check_form_secret(p_secret) then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'recipients', coalesce((
      select jsonb_agg(u.email order by s.created_at, s.name)
      from public.staff s join auth.users u on u.id = s.user_id
      where coalesce(btrim(u.email), '') <> ''
    ), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(
               jsonb_build_object('id', n.id, 'title', p.title, 'proposal_id', p.id::text)
               order by n.id)
      from public.proposal_notifications n
      join public.proposals p on p.item_id = n.item_id
      where n.sent_at is null
    ), '[]'::jsonb)
  );
end
$function$
;

-- is_mine(rec comments)
CREATE OR REPLACE FUNCTION public.is_mine(rec comments)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ select rec.user_id is not null and rec.user_id = auth.uid(); $function$
;

-- is_mine(rec reactions)
CREATE OR REPLACE FUNCTION public.is_mine(rec reactions)
 RETURNS boolean
 LANGUAGE sql
 STABLE
AS $function$ select rec.user_id is not null and rec.user_id = auth.uid(); $function$
;

-- is_staff()
CREATE OR REPLACE FUNCTION public.is_staff()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select exists (select 1 from public.staff where user_id = auth.uid()) $function$
;

-- submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text)
CREATE OR REPLACE FUNCTION public.submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text DEFAULT ''::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_item_id text := gen_random_uuid()::text;
  v_title   text := btrim(coalesce(p_title, ''));
  v_desc    text;
begin
  if not exists (
    select 1 from public.app_secrets
    where name = 'form_secret'
      and value = encode(sha256(convert_to(coalesce(p_secret, ''), 'UTF8')), 'hex')
  ) then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if v_title = '' or btrim(coalesce(p_name, '')) = '' or btrim(coalesce(p_email, '')) = '' then
    raise exception 'missing required field' using errcode = '22023';
  end if;
  if length(v_title) > 200 or length(coalesce(p_summary, '')) > 5000 or length(coalesce(p_reason, '')) > 5000
     or length(coalesce(p_note, '')) > 3000 or length(p_name) > 100 or length(p_email) > 254 then
    raise exception 'too long' using errcode = '22001';
  end if;

  if (select count(*) from public.proposal_submissions where created_at > now() - interval '1 minute') >= 10 then
    raise exception 'rate limited' using errcode = '54000';
  end if;
  if exists (
    select 1 from public.proposal_submissions s join public.proposals p on p.item_id = s.item_id
    where s.submitter_email = btrim(p_email) and p.title = v_title and s.created_at > now() - interval '10 minutes'
  ) then
    raise exception 'duplicate' using errcode = '23505';
  end if;

  v_desc := '【概要】' || chr(10) || btrim(coalesce(p_summary, '')) || chr(10) || chr(10)
         || '【理由】' || chr(10) || btrim(coalesce(p_reason, ''));

  insert into public.proposals (item_id, title, description, status, is_published)
  values (v_item_id, v_title, v_desc, '提案中', false);

  insert into public.proposal_submissions (item_id, submitter_name, submitter_email, extra_note)
  values (v_item_id, btrim(p_name), btrim(p_email), btrim(coalesce(p_note, '')));

  return v_item_id;
end
$function$
;

-- ===== 9. トリガー =====

-- proposal_submissions.proposal_submissions_notify
CREATE TRIGGER proposal_submissions_notify AFTER INSERT ON public.proposal_submissions FOR EACH ROW EXECUTE FUNCTION enqueue_proposal_notification();

-- proposals.proposals_cleanup
CREATE TRIGGER proposals_cleanup AFTER DELETE ON public.proposals FOR EACH ROW EXECUTE FUNCTION cleanup_proposal_children();

-- ===== 10. 行単位の権限を有効にする =====

-- app_secrets
alter table public.app_secrets enable row level security;

-- comments
alter table public.comments enable row level security;

-- proposal_notifications
alter table public.proposal_notifications enable row level security;

-- proposal_reviews
alter table public.proposal_reviews enable row level security;

-- proposal_submissions
alter table public.proposal_submissions enable row level security;

-- proposals
alter table public.proposals enable row level security;

-- reactions
alter table public.reactions enable row level security;

-- staff
alter table public.staff enable row level security;

-- ===== 11. 行単位の権限の決まり =====

-- comments.comments_delete_own
create policy comments_delete_own on public.comments as permissive for delete to authenticated using ((user_id = auth.uid()));

-- comments.comments_insert_own_ratelimited
create policy comments_insert_own_ratelimited on public.comments as permissive for insert to authenticated with check (((user_id = auth.uid()) AND (( SELECT count(*) AS count
   FROM comments c
  WHERE ((c.user_id = auth.uid()) AND (c.created_at > (now() - '00:01:00'::interval)))) < 3) AND (( SELECT count(*) AS count
   FROM comments c
  WHERE ((c.user_id = auth.uid()) AND (c.item_id = comments.item_id))) < 20)));

-- comments.comments_select_all
create policy comments_select_all on public.comments as permissive for select to anon, authenticated using (true);

-- comments.comments_update_own
create policy comments_update_own on public.comments as permissive for update to authenticated using ((user_id = auth.uid()));

-- proposal_reviews.staff delete own review
create policy "staff delete own review" on public.proposal_reviews as permissive for delete to authenticated using ((is_staff() AND (reviewer_id = auth.uid())));

-- proposal_reviews.staff insert own review
create policy "staff insert own review" on public.proposal_reviews as permissive for insert to authenticated with check ((is_staff() AND (reviewer_id = auth.uid())));

-- proposal_reviews.staff read reviews
create policy "staff read reviews" on public.proposal_reviews as permissive for select to authenticated using (is_staff());

-- proposal_reviews.staff update own review
create policy "staff update own review" on public.proposal_reviews as permissive for update to authenticated using ((is_staff() AND (reviewer_id = auth.uid()))) with check ((is_staff() AND (reviewer_id = auth.uid())));

-- proposal_submissions.staff read submissions
create policy "staff read submissions" on public.proposal_submissions as permissive for select to authenticated using (is_staff());

-- proposals.read published or staff
create policy "read published or staff" on public.proposals as permissive for select to anon, authenticated using (((is_published IS NOT FALSE) OR is_staff()));

-- proposals.staff delete proposals
create policy "staff delete proposals" on public.proposals as permissive for delete to authenticated using (is_staff());

-- proposals.staff insert proposals
create policy "staff insert proposals" on public.proposals as permissive for insert to authenticated with check (is_staff());

-- proposals.staff update proposals
create policy "staff update proposals" on public.proposals as permissive for update to authenticated using (is_staff()) with check (is_staff());

-- reactions.reactions_delete_own
create policy reactions_delete_own on public.reactions as permissive for delete to authenticated using ((user_id = auth.uid()));

-- reactions.reactions_insert_own
create policy reactions_insert_own on public.reactions as permissive for insert to authenticated with check ((user_id = auth.uid()));

-- reactions.reactions_select_all
create policy reactions_select_all on public.reactions as permissive for select to anon, authenticated using (true);

-- staff.staff read staff
create policy "staff read staff" on public.staff as permissive for select to authenticated using (is_staff());

-- ===== 12. 表への権限 =====

-- comments.anon
revoke all on table public.comments from anon; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.comments to anon;

-- comments.authenticated
revoke all on table public.comments from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.comments to authenticated;

-- proposal_reviews.authenticated
revoke all on table public.proposal_reviews from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.proposal_reviews to authenticated;

-- proposal_submissions.authenticated
revoke all on table public.proposal_submissions from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.proposal_submissions to authenticated;

-- proposals.anon
revoke all on table public.proposals from anon; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.proposals to anon;

-- proposals.authenticated
revoke all on table public.proposals from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.proposals to authenticated;

-- reactions.anon
revoke all on table public.reactions from anon; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.reactions to anon;

-- reactions.authenticated
revoke all on table public.reactions from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.reactions to authenticated;

-- staff.authenticated
revoke all on table public.staff from authenticated; grant DELETE, INSERT, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE on table public.staff to authenticated;

-- ===== 13. 関数を実行できる人 =====

-- ack_proposal_notifications(p_secret text, p_ids bigint[])
revoke all on function public.ack_proposal_notifications(p_secret text, p_ids bigint[]) from public, anon, authenticated; grant execute on function public.ack_proposal_notifications(p_secret text, p_ids bigint[]) to authenticated; grant execute on function public.ack_proposal_notifications(p_secret text, p_ids bigint[]) to anon;

-- check_form_secret(p_secret text)
revoke all on function public.check_form_secret(p_secret text) from public, anon, authenticated;

-- cleanup_proposal_children()
revoke all on function public.cleanup_proposal_children() from public, anon, authenticated; grant execute on function public.cleanup_proposal_children() to authenticated; grant execute on function public.cleanup_proposal_children() to anon;

-- enqueue_proposal_notification()
revoke all on function public.enqueue_proposal_notification() from public, anon, authenticated;

-- fetch_proposal_notifications(p_secret text)
revoke all on function public.fetch_proposal_notifications(p_secret text) from public, anon, authenticated; grant execute on function public.fetch_proposal_notifications(p_secret text) to authenticated; grant execute on function public.fetch_proposal_notifications(p_secret text) to anon;

-- is_mine(rec comments)
revoke all on function public.is_mine(rec comments) from public, anon, authenticated; grant execute on function public.is_mine(rec comments) to authenticated; grant execute on function public.is_mine(rec comments) to anon; grant execute on function public.is_mine(rec comments) to public;

-- is_mine(rec reactions)
revoke all on function public.is_mine(rec reactions) from public, anon, authenticated; grant execute on function public.is_mine(rec reactions) to authenticated; grant execute on function public.is_mine(rec reactions) to anon; grant execute on function public.is_mine(rec reactions) to public;

-- is_staff()
revoke all on function public.is_staff() from public, anon, authenticated; grant execute on function public.is_staff() to authenticated; grant execute on function public.is_staff() to anon;

-- submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text)
revoke all on function public.submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text) from public, anon, authenticated; grant execute on function public.submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text) to authenticated; grant execute on function public.submit_proposal(p_secret text, p_name text, p_email text, p_title text, p_summary text, p_reason text, p_note text) to anon;

-- ===== 14. リアルタイム配信 =====

-- supabase_realtime.comments
alter publication supabase_realtime add table public.comments;

-- supabase_realtime.proposals
alter publication supabase_realtime add table public.proposals;
