-- みんカレポータル: 事務局による議案評価（はい／いいえ＋理由）と、proposals の権限の作り直し
-- 何度流しても同じ結果になるように書いてある（冪等）。Supabase の SQL Editor に丸ごと貼って Run する。

-- 1. 事務局メンバー表 ----------------------------------------------------
create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  created_at timestamptz not null default now()
);
alter table public.staff enable row level security;

-- 自分が事務局かどうか。RLSの中から呼ぶため security definer
create or replace function public.is_staff() returns boolean
  language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.staff where user_id = auth.uid()) $$;
revoke all on function public.is_staff() from public;
grant execute on function public.is_staff() to anon, authenticated;

drop policy if exists "staff read staff" on public.staff;
create policy "staff read staff" on public.staff
  for select to authenticated using (public.is_staff());

-- 事務局メンバーの追加（公開リポジトリのため、メールアドレスはここに書かない）
-- 先に Authentication > Users で本人のアカウントを作り、次を実行する:
--   insert into public.staff (user_id, name)
--   select id, '<表示名>' from auth.users where email = '<メールアドレス>'
--   on conflict (user_id) do nothing;

-- 2. 評価表 --------------------------------------------------------------
create table if not exists public.proposal_reviews (
  id          uuid primary key default gen_random_uuid(),
  item_id     text not null,
  reviewer_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  vote        text not null check (vote in ('yes', 'no')),
  reason      text not null default '',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (item_id, reviewer_id),
  check (vote = 'yes' or length(btrim(reason)) > 0),   -- 「いいえ」は理由が必須
  check (length(reason) <= 1000)
);
alter table public.proposal_reviews enable row level security;

drop policy if exists "staff read reviews"   on public.proposal_reviews;
drop policy if exists "staff insert own review" on public.proposal_reviews;
drop policy if exists "staff update own review" on public.proposal_reviews;
drop policy if exists "staff delete own review" on public.proposal_reviews;
create policy "staff read reviews" on public.proposal_reviews
  for select to authenticated using (public.is_staff());
create policy "staff insert own review" on public.proposal_reviews
  for insert to authenticated with check (public.is_staff() and reviewer_id = auth.uid());
create policy "staff update own review" on public.proposal_reviews
  for update to authenticated using (public.is_staff() and reviewer_id = auth.uid())
  with check (public.is_staff() and reviewer_id = auth.uid());
create policy "staff delete own review" on public.proposal_reviews
  for delete to authenticated using (public.is_staff() and reviewer_id = auth.uid());

-- anon には評価表の権限を一切与えない
revoke all on public.proposal_reviews from anon;
revoke all on public.staff from anon;
grant select, insert, update, delete on public.proposal_reviews to authenticated;
grant select on public.staff to authenticated;

-- 3. proposals の権限を作り直す（重複・緩いポリシーを全部外す） --------------
do $$
declare r record;
begin
  for r in select policyname from pg_policies where schemaname = 'public' and tablename = 'proposals' loop
    execute format('drop policy %I on public.proposals', r.policyname);
  end loop;
end $$;

alter table public.proposals enable row level security;
-- 閲覧: 公開議案は誰でも、非公開は事務局だけ
create policy "read published or staff" on public.proposals
  for select to anon, authenticated using (is_published is not false or public.is_staff());
-- 書き込み: 事務局だけ
create policy "staff insert proposals" on public.proposals
  for insert to authenticated with check (public.is_staff());
create policy "staff update proposals" on public.proposals
  for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy "staff delete proposals" on public.proposals
  for delete to authenticated using (public.is_staff());
