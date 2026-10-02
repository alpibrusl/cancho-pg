-- Queries for the generator test. Each `-- name:` line is followed by one statement.

-- name: user_by_id id
select id, name, age, active, nickname from gen_users where id = $1

-- name: users_older_than min_age
select id, name from gen_users where age > $1 order by id;

-- name: add_user name age
insert into gen_users (name, age) values ($1, $2) returning id

-- name: rename_user id name
update gen_users set name = $2 where id = $1

-- name: posts_with_authors
select p.title, u.name as author from gen_posts p left join gen_users u on u.id = p.user_id order by p.id

-- name: count_users
select count(*) as n from gen_users

-- name: find_by_nickname nickname
select id from gen_users where nickname = $1

-- name: add_post user_id title
insert into gen_posts (user_id, title) values ($1, $2)

-- name: user_details id
select balance, joined, (age + 1) as next_age from gen_users where id = $1

-- name: tricky
select 'say "hi" \ back' as quoted, 'two
lines' as two

-- name: add_user_partial name age? nickname?
insert into gen_users (name, age, nickname) values ($1, $2, $3) returning id
