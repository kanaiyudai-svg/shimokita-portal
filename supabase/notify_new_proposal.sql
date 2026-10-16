-- みんカレポータル: フォームから新しい議案が提出されたら、事務局メンバーにメールで知らせる
--
-- 流れ
--   1. submit_proposal() が proposal_submissions に1行入れる
--   2. 下のトリガーが「通知待ち」を1行足し、メール送信役（Apps Script のウェブアプリ）へ合図（空のPOST）を送る
--   3. Apps Script が fetch_proposal_notifications() で、通知待ちと宛先（事務局のメール）を受け取る
--   4. Apps Script がメールを送り、ack_proposal_notifications() で「送った」と記録する
--
-- Supabase だけでは任意のメールを送れないため、送信だけを Apps Script に任せる（apps-script/form-to-portal.gs）。
-- 宛先と本文の材料（議案名・リンクの番号）は、すべてここで決まる。合図には中身を載せない。
-- 何度流しても同じ結果になる。SQL Editor に丸ごと貼って Run する。
-- 前提: form_intake.sql と reviews.sql が実行済み（app_secrets, proposals, proposal_submissions, staff を使う）

-- 0. HTTP送信の拡張（Supabase 標準。合図を送るのに使う）
create extension if not exists pg_net;

-- 1. 通知待ち。誰にも読ませない（下の security definer の関数だけが触る）
create table if not exists public.proposal_notifications (
  id         bigint generated always as identity primary key,
  item_id    text not null,
  created_at timestamptz not null default now(),
  sent_at    timestamptz
);
create index if not exists proposal_notifications_pending
  on public.proposal_notifications (id) where sent_at is null;
alter table public.proposal_notifications enable row level security;
revoke all on public.proposal_notifications from anon, authenticated;

-- 2. 合言葉の照合（submit_proposal と同じ方式）。ほかの関数からだけ呼ぶので、外には出さない
create or replace function public.check_form_secret(p_secret text) returns boolean
language sql stable security definer set search_path = public as
$$
  select exists (
    select 1 from public.app_secrets
    where name = 'form_secret'
      and value = encode(sha256(convert_to(coalesce(p_secret, ''), 'UTF8')), 'hex')
  )
$$;
revoke all on function public.check_form_secret(text) from public, anon, authenticated;

-- 3. 提出されたら通知待ちに積み、送信役へ合図を送る。
--    合図に失敗しても議案の登録は止めない（通知待ちは残り、次の合図か1時間おきの確認で送られる）
create or replace function public.enqueue_proposal_notification() returns trigger
language plpgsql security definer set search_path = public as
$$
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
$$;
revoke all on function public.enqueue_proposal_notification() from public, anon, authenticated;

drop trigger if exists proposal_submissions_notify on public.proposal_submissions;
create trigger proposal_submissions_notify after insert on public.proposal_submissions
  for each row execute function public.enqueue_proposal_notification();

-- 4. 送信役が、未送信の通知と宛先を受け取る。合言葉が合うときだけ
create or replace function public.fetch_proposal_notifications(p_secret text) returns jsonb
language plpgsql security definer set search_path = public as
$$
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
$$;
revoke all on function public.fetch_proposal_notifications(text) from public;
grant execute on function public.fetch_proposal_notifications(text) to anon, authenticated;

-- 5. 送ったものを「送信済み」にする。件数を返す
create or replace function public.ack_proposal_notifications(p_secret text, p_ids bigint[]) returns integer
language plpgsql security definer set search_path = public as
$$
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
$$;
revoke all on function public.ack_proposal_notifications(text, bigint[]) from public;
grant execute on function public.ack_proposal_notifications(text, bigint[]) to anon, authenticated;

-- 6. 送信役（Apps Script のウェブアプリ）のURLを登録する。<WEBAPP_URL> を置き換えて実行する
--    例: https://script.google.com/macros/s/xxxxxxxx/exec
-- insert into public.app_secrets (name, value) values ('mail_relay_url', '<WEBAPP_URL>')
-- on conflict (name) do update set value = excluded.value;
