-- Signal Relay V1.6 shared sync schema
create table if not exists public.signal_records (
  id text primary key,
  workspace text not null default 'default',
  payload jsonb not null,
  updated_at timestamptz not null default now()
);

create index if not exists signal_records_workspace_updated_idx
  on public.signal_records(workspace, updated_at desc);

alter table public.signal_records enable row level security;

drop policy if exists "signal relay shared read" on public.signal_records;
drop policy if exists "signal relay shared insert" on public.signal_records;
drop policy if exists "signal relay shared update" on public.signal_records;
drop policy if exists "signal relay shared delete" on public.signal_records;

-- V1.6 field deployment policy: anyone holding the project's anon key and workspace name
-- may sync records. Replace these policies with authenticated-user policies before a wider rollout.
create policy "signal relay shared read" on public.signal_records for select to anon using (true);
create policy "signal relay shared insert" on public.signal_records for insert to anon with check (true);
create policy "signal relay shared update" on public.signal_records for update to anon using (true) with check (true);
create policy "signal relay shared delete" on public.signal_records for delete to anon using (true);
