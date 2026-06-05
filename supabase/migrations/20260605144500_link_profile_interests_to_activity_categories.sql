do $$
begin
  if to_regclass('public.profile_category_links') is null
    and to_regclass('public.profile_interest_links') is not null then
    alter table public.profile_interest_links
      rename to profile_category_links;
  end if;

  if to_regclass('public.profile_category_links') is not null then
    if not exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'profile_category_links'
        and column_name = 'category_id'
    ) then
      alter table public.profile_category_links
        add column category_id uuid;
    end if;

    if exists (
      select 1
      from information_schema.columns
      where table_schema = 'public'
        and table_name = 'profile_category_links'
        and column_name = 'interest_id'
    ) then
      alter table public.profile_category_links
        drop constraint if exists profile_interest_links_pkey;

      alter table public.profile_category_links
        drop constraint if exists profile_category_links_pkey;

      alter table public.profile_category_links
        drop constraint if exists profile_interest_links_interest_id_fkey;

      update public.profile_category_links links
      set category_id = categories.id
      from public.activity_categories categories
      where links.category_id is null
        and (
          links.interest_id = categories.id::text
          or links.interest_id = categories.slug
        );

      delete from public.profile_category_links
      where category_id is null;

      alter table public.profile_category_links
        drop column interest_id;
    end if;

    alter table public.profile_category_links
      alter column category_id set not null;

    if not exists (
      select 1
      from pg_constraint
      where conrelid = 'public.profile_category_links'::regclass
        and conname = 'profile_category_links_pkey'
    ) then
      alter table public.profile_category_links
        add constraint profile_category_links_pkey
        primary key (profile_id, category_id);
    end if;

    if not exists (
      select 1
      from pg_constraint
      where conrelid = 'public.profile_category_links'::regclass
        and conname = 'profile_category_links_category_id_fkey'
    ) then
      alter table public.profile_category_links
        add constraint profile_category_links_category_id_fkey
        foreign key (category_id)
        references public.activity_categories(id)
        on delete restrict;
    end if;
  end if;
end $$;

create index if not exists profile_category_links_category_idx
  on public.profile_category_links (category_id);

drop table if exists public.profile_interests;

notify pgrst, 'reload schema';
