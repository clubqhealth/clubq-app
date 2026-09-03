-- Remove duplicate exercises (keeps the earliest of each name) and stop it happening again.
delete from exercises a
using exercises b
where lower(a.name) = lower(b.name)
  and a.created_at > b.created_at;

-- also catches identical timestamps
delete from exercises a
using exercises b
where lower(a.name) = lower(b.name)
  and a.created_at = b.created_at
  and a.id > b.id;

create unique index if not exists exercises_unique_name on exercises (lower(name));

select count(*) as exercises_now from exercises;
