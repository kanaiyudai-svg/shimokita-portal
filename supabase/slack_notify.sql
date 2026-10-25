-- みんカレポータル: 新しい議案が提出されたら、Slack の事務局チャンネルで投票する事務局メンバーを呼ぶ
--
-- 流れ（メール通知と同じ通知待ちを使う。クロコは介在しない）
--   1. 提出 → notify_new_proposal.sql のトリガーが通知待ちに積み、Apps Script へ合図を送る
--   2. Apps Script が fetch_proposal_notifications() で、通知待ちと宛先を受け取る
--   3. 受け取った中の slack_ids（投票する事務局メンバーの Slack ユーザーID）でメンションし、
--      Slack の受け口（Incoming Webhook）へ投稿する。受け口のURLは Apps Script の非公開の設定だけに置く
--
-- ここでは staff 表に Slack ユーザーIDの欄を足し、通知の関数がそれを返すようにする。
-- 各人の Slack ユーザーIDは公開リポジトリに書かない。Supabase の SQL Editor で、メンバーを登録するときに
-- 一緒に入れる（例は末尾のコメント）。何度流しても同じ結果になる。
-- 前提: notify_new_proposal.sql が実行済み

-- 1. staff に Slack ユーザーID（U から始まる英数字）。空なら呼ばれない
alter table public.staff add column if not exists slack_user_id text;

-- 2. 通知の関数を差し替える。返す形は従来に slack_ids を足しただけ（メール側は変わらない）
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
    'slack_ids', coalesce((
      select jsonb_agg(btrim(s.slack_user_id) order by s.created_at, s.name)
      from public.staff s
      where coalesce(btrim(s.slack_user_id), '') ~ '^[UW][A-Z0-9]{6,}$'
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

-- 3. メンバーの Slack ユーザーIDを入れる（実行時に <名前> と <ID> を置き換える。IDは Slack のプロフィール
--    「メンバーIDをコピー」で分かる。入れ替えのときは、辞めた人の行を staff から消せば呼ばれなくなる）
-- update public.staff set slack_user_id = '<ID>' where name = '<staff表の表示名>';
