-- みんカレポータル: Googleフォームの回答を、非公開の議案として自動登録する
-- Apps Script（apps-script/form-to-portal.gs）が submit_proposal() を呼ぶ。何度流しても同じ結果になる。
-- 合言葉そのものはDBに置かず、SHA-256のハッシュだけを置く。合言葉本体はApps Scriptのスクリプトプロパティにだけ置く。
-- 合言葉を替えるときは、最後の insert の <SECRET_SHA256> を新しいハッシュにして流す。

-- 1. 合言葉（ハッシュ）置き場。どのロールにも読ませない
create table if not exists public.app_secrets (
  name text primary key,
  value text not null
);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

-- 2. 提出者情報。議案の表は公開されると全列が誰でも読めるため、氏名・メールは別表に分け、事務局だけが読める
create table if not exists public.proposal_submissions (
  id              uuid primary key default gen_random_uuid(),
  item_id         text not null unique,
  submitter_name  text not null,
  submitter_email text not null,
  extra_note      text not null default '',
  created_at      timestamptz not null default now()
);
alter table public.proposal_submissions enable row level security;
drop policy if exists "staff read submissions" on public.proposal_submissions;
create policy "staff read submissions" on public.proposal_submissions
  for select to authenticated using (public.is_staff());
revoke all on public.proposal_submissions from anon;
grant select on public.proposal_submissions to authenticated;

-- 3. 受付関数。合言葉が合うときだけ、非公開の議案と提出者情報を作る
create or replace function public.submit_proposal(
  p_secret text, p_name text, p_email text, p_title text,
  p_summary text, p_reason text, p_note text default ''
) returns text
language plpgsql security definer set search_path = public as
$$
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

  -- 連投の抑制（全体で1分10件まで）と、同じ人の同じ議案の重複防止（10分以内）
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
$$;
revoke all on function public.submit_proposal(text, text, text, text, text, text, text) from public;
grant execute on function public.submit_proposal(text, text, text, text, text, text, text) to anon, authenticated;

-- 4. 合言葉のハッシュを登録（<SECRET_SHA256> を置き換えて実行する）
-- insert into public.app_secrets (name, value) values ('form_secret', '<SECRET_SHA256>')
-- on conflict (name) do update set value = excluded.value;

-- 5. 議案を削除したら、提出者情報（氏名・メール）と評価も一緒に消す。個人情報を孤立して残さない
create or replace function public.cleanup_proposal_children() returns trigger
language plpgsql security definer set search_path = public as
$$
begin
  delete from public.proposal_submissions where item_id = old.item_id;
  delete from public.proposal_reviews where item_id = old.item_id;
  return old;
end
$$;
revoke all on function public.cleanup_proposal_children() from public;
drop trigger if exists proposals_cleanup on public.proposals;
create trigger proposals_cleanup after delete on public.proposals
  for each row execute function public.cleanup_proposal_children();
