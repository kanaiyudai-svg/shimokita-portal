-- みんカレポータル: 提案者の名前の公開と、2026-10 に変わった議案フォームの新しい項目
-- 何度流しても同じ結果になる。form_intake.sql の後に流す。
--
-- 名前の置き場の考え方
--   proposals は公開議案なら誰でも全列を読めるので、氏名そのものは proposal_submissions（事務局のみ）に置いたまま。
--   公開してよいと決まったときだけ、表示用の名前を proposals.proposer_name に写す。空なら匿名で表示する。
--   切り替えは管理画面の「フォームの提出者」欄から事務局が行う。

-- 1. 公開用の提案者名。空文字＝匿名
alter table public.proposals add column if not exists proposer_name text not null default '';

-- 2. フォームの新しい項目。名前公開の希望と、事務局との打ち合わせの希望
alter table public.proposal_submissions add column if not exists name_public boolean not null default false;
alter table public.proposal_submissions add column if not exists meeting_request text not null default '';

-- 3. 受付関数を作り直す。引数が増えるので古い形を消してから作る（同名で2つあると呼び分けられない）
drop function if exists public.submit_proposal(text, text, text, text, text, text, text);
create or replace function public.submit_proposal(
  p_secret text, p_name text, p_email text, p_title text,
  p_summary text, p_reason text, p_note text default '',
  p_name_public boolean default false, p_meeting text default ''
) returns text
language plpgsql security definer set search_path = public as
$$
declare
  v_item_id text := gen_random_uuid()::text;
  v_title   text := btrim(coalesce(p_title, ''));
  v_name    text := btrim(coalesce(p_name, ''));
  v_desc    text;
begin
  if not exists (
    select 1 from public.app_secrets
    where name = 'form_secret'
      and value = encode(sha256(convert_to(coalesce(p_secret, ''), 'UTF8')), 'hex')
  ) then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  if v_title = '' or v_name = '' or btrim(coalesce(p_email, '')) = '' then
    raise exception 'missing required field' using errcode = '22023';
  end if;
  if length(v_title) > 200 or length(coalesce(p_summary, '')) > 5000 or length(coalesce(p_reason, '')) > 5000
     or length(coalesce(p_note, '')) > 3000 or length(v_name) > 100 or length(p_email) > 254
     or length(coalesce(p_meeting, '')) > 200 then
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

  v_desc := '【提案内容】' || chr(10) || btrim(coalesce(p_summary, '')) || chr(10) || chr(10)
         || '【提案理由】' || chr(10) || btrim(coalesce(p_reason, ''));

  -- 議案は非公開で入るので、名前を写しておいても公開されるまでは誰にも見えない
  insert into public.proposals (item_id, title, description, status, is_published, proposer_name)
  values (v_item_id, v_title, v_desc, '提案中', false, case when coalesce(p_name_public, false) then v_name else '' end);

  insert into public.proposal_submissions (item_id, submitter_name, submitter_email, extra_note, name_public, meeting_request)
  values (v_item_id, v_name, btrim(p_email), btrim(coalesce(p_note, '')), coalesce(p_name_public, false), btrim(coalesce(p_meeting, '')));

  return v_item_id;
end
$$;
revoke all on function public.submit_proposal(text, text, text, text, text, text, text, boolean, text) from public;
grant execute on function public.submit_proposal(text, text, text, text, text, text, text, boolean, text) to anon, authenticated;
