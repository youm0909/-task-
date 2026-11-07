-- ================================================================
-- 残り時間タスク (Time-Left Task Manager) - Supabase セットアップ SQL
-- Supabase の「SQL Editor」に貼り付けて「Run」を実行してください。
-- ================================================================

-- 1. tasks テーブル（タスク本体）
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade not null,
  is_shared boolean default false,
  share_code text unique,
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

-- 2. task_members テーブル（共同タスクの参加メンバー）
create table if not exists public.task_members (
  id uuid primary key default gen_random_uuid(),
  task_id uuid references public.tasks(id) on delete cascade not null,
  user_id uuid references auth.users(id) on delete cascade not null,
  role text default 'editor',
  joined_at timestamptz default now(),
  unique(task_id, user_id)
);

-- 検索用インデックス
create index if not exists idx_tasks_user_id on public.tasks(user_id);
create index if not exists idx_tasks_share_code on public.tasks(share_code);
create index if not exists idx_task_members_user_id on public.task_members(user_id);
create index if not exists idx_task_members_task_id on public.task_members(task_id);

-- 3. Row Level Security (RLS: 行レベルセキュリティ) の有効化
alter table public.tasks enable row level security;
alter table public.task_members enable row level security;

-- 古いポリシーがあれば削除
drop policy if exists "tasks_select_policy" on public.tasks;
drop policy if exists "tasks_insert_policy" on public.tasks;
drop policy if exists "tasks_update_policy" on public.tasks;
drop policy if exists "tasks_delete_policy" on public.tasks;

drop policy if exists "task_members_select_policy" on public.task_members;
drop policy if exists "task_members_insert_policy" on public.task_members;
drop policy if exists "task_members_delete_policy" on public.task_members;

-- tasks テーブルのポリシー:
-- 【閲覧】作成者自身 または 共同メンバーのみ閲覧可能
create policy "tasks_select_policy" on public.tasks
  for select using (
    auth.uid() = user_id or
    exists (
      select 1 from public.task_members
      where public.task_members.task_id = public.tasks.id
        and public.task_members.user_id = auth.uid()
    )
  );

-- 【作成】ログイン中のユーザーのみ自分のタスクを作成可能
create policy "tasks_insert_policy" on public.tasks
  for insert with check (
    auth.uid() = user_id
  );

-- 【更新】作成者 または 共同メンバーが更新可能
create policy "tasks_update_policy" on public.tasks
  for update using (
    auth.uid() = user_id or
    exists (
      select 1 from public.task_members
      where public.task_members.task_id = public.tasks.id
        and public.task_members.user_id = auth.uid()
    )
  );

-- 【削除】作成者（オーナー）のみ削除可能
create policy "tasks_delete_policy" on public.tasks
  for delete using (
    auth.uid() = user_id
  );

-- task_members テーブルのポリシー:
-- 【閲覧】参加者自身 または そのタスクの作成者
create policy "task_members_select_policy" on public.task_members
  for select using (
    auth.uid() = user_id or
    exists (
      select 1 from public.tasks
      where public.tasks.id = public.task_members.task_id
        and public.tasks.user_id = auth.uid()
    )
  );

-- 【作成】ログイン中の本人のみ追加可能
create policy "task_members_insert_policy" on public.task_members
  for insert with check (
    auth.uid() = user_id
  );

-- 【削除】参加者自身（退出）またはタスク作成者（除外）
create policy "task_members_delete_policy" on public.task_members
  for delete using (
    auth.uid() = user_id or
    exists (
      select 1 from public.tasks
      where public.tasks.id = public.task_members.task_id
        and public.tasks.user_id = auth.uid()
    )
  );

-- 4. 共有コードを使った安全な参加関数 (RPC)
create or replace function public.join_task_by_code(code text)
returns json
language plpgsql
security definer
as $$
declare
  target_task record;
  current_user_id uuid;
begin
  current_user_id := auth.uid();
  if current_user_id is null then
    return json_build_object('success', false, 'error', 'ログインが必要です。');
  end if;

  -- 共有コードで対象タスクを検索
  select * into target_task from public.tasks where upper(trim(share_code)) = upper(trim(code));
  if not found then
    return json_build_object('success', false, 'error', '指定されたコードのタスクが見つかりませんでした。コードをご確認ください。');
  end if;

  if target_task.user_id = current_user_id then
    return json_build_object('success', false, 'error', 'あなた自身が作成したタスクです。');
  end if;

  -- すでに追加済みか確認
  if exists (select 1 from public.task_members where task_id = target_task.id and user_id = current_user_id) then
    return json_build_object('success', true, 'message', 'このタスクにはすでに追加されています。', 'task_id', target_task.id);
  end if;

  -- メンバーに追加
  insert into public.task_members (task_id, user_id, role)
  values (target_task.id, current_user_id, 'editor');

  return json_build_object('success', true, 'message', '共同タスクに参加しました！', 'task_id', target_task.id);
end;
$$;

-- 5. リアルタイム同期（Realtime）の有効化
-- 誰かがタスクを完了・更新した際に画面リロード不要で即時反映されます
alter table public.tasks replica identity full;
alter table public.task_members replica identity full;

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

alter publication supabase_realtime add table public.tasks;
alter publication supabase_realtime add table public.task_members;

